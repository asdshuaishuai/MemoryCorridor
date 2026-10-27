// The inbox: one place a host looks for work worth doing next.
//
// A5's Proposal Engine gathers evidence from contextual changes, completed
// interactions and knowledge updates, screens it against proposal history, and
// puts what survives into an Inbox where the user decides. Here the engine
// cannot decide whether something is worth doing, so it does the parts that are
// deterministic: it gathers every open piece of durable work, drops what is
// already closed or already covered, and names the operation that would advance
// each item. An empty inbox means there is nothing worth proposing.

priv struct InboxItem {
  kind : String
  subject : String
  reason : String
  detail : String
  next : String
  created_at : String
  // Open impact causes for this subject, so one item carries both the work and
  // the reason its inputs moved.
  drift : Array[String]
}

fn inbox_item(
  kind : String, subject : String, reason : String, detail : String, next : String, created_at : String,
) -> InboxItem {
  { kind, subject, reason, detail, next, created_at, drift: [] }
}

fn inbox_view(item : InboxItem) -> Json {
  { "kind": item.kind, "subject": item.subject, "reason": item.reason,
    "detail": item.detail, "next": item.next, "created_at": item.created_at,
    "drift": item.drift.to_json() }
}

// Deterministic order: kind groups related work, subject keeps it stable.
fn inbox_sort(items : Array[InboxItem]) -> Unit {
  items.sort_by((a, b) => {
    let key = (item : InboxItem) => item.kind + "\u0000" + item.subject + "\u0000" + item.reason
    @base.compare(key(a), key(b))
  })
}

fn inbox_text(value : Json, key : String) -> String {
  match optional(value, key) {
    Some(String(text)) => text
    _ => ""
  }
}

fn inbox_counts(items : Array[InboxItem]) -> Json {
  let by_kind : Map[String, Int] = Map([])
  for item in items {
    by_kind[item.kind] = by_kind.get(item.kind).unwrap_or(0) + 1
  }
  let kinds = by_kind.keys().to_array()
  kinds.sort_by(@base.compare)
  let rows : Array[(String, Int)] = []
  for kind in kinds { rows.push((kind, by_kind.get(kind).unwrap_or(0))) }
  { "total": items.length(), "by_kind": rows.to_json() }
}

fn inbox_items(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[InboxItem] raise @base.Fault {
  let items : Array[InboxItem] = []
  // HumanGate review debt raised by quality-audit.
  for row in review_rows_unchecked(store, entries) {
    if inbox_text(row, "status") != "pending" { continue }
    let predicate = inbox_text(row, "predicate")
    let detail = inbox_text(row, "reason")
    items.push(inbox_item("review", "state/reviews/" + inbox_text(row, "id") + ".json",
      predicate, detail, "review-resolve with create-page, research or skip",
      inbox_text(row, "created_at")))
  }
  // Research topics are host-executed queues; an open one is work in progress.
  for row in research_rows_unchecked(store, entries) {
    if inbox_text(row, "status") != "proposed" { continue }
    items.push(inbox_item("research", "state/research/" + inbox_text(row, "id") + ".json",
      "research-open", inbox_text(row, "topic"),
      "research-complete after writing results into raw/, or research-cancel",
      inbox_text(row, "created_at")))
  }
  // Suggestions wait on a human decision before anything is published.
  for row in suggestion_rows_unchecked(store, entries) {
    if inbox_text(row, "status") != "proposed" { continue }
    items.push(inbox_item("purpose-suggestion",
      "state/suggestions/" + inbox_text(row, "id") + ".json", "purpose-pending",
      "purpose.md update awaits confirmation",
      "purpose-apply after human confirmation", inbox_text(row, "created_at")))
  }
  for row in overview_rows_unchecked(store, entries) {
    if inbox_text(row, "status") != "proposed" { continue }
    items.push(inbox_item("overview-suggestion",
      "state/overview/" + inbox_text(row, "id") + ".json", "overview-pending",
      "wiki/overview.md synthesis awaits confirmation",
      "overview-apply after human confirmation", inbox_text(row, "created_at")))
  }
  // Invalidated pages and unregistered material are the cheapest items to clear.
  for entry in entries {
    if @core.is_page(entry) && entry.stale {
      items.push(inbox_item("stale-page", entry.id, "page-invalidated",
        "page depends on a revoked source or a stale link",
        "refresh the sources and commit a new page version", ""))
    }
  }
  let registered : Map[String, Bool] = Map([])
  for entry in entries {
    if entry.kind == "raw" { registered[entry.path] = true }
  }
  let raw_paths = (store.files)("raw")
  raw_paths.sort_by(@base.compare)
  for path in raw_paths {
    if registered.contains(path) { continue }
    items.push(inbox_item("unscanned-source", path, "source-unregistered",
      "raw file is present but not registered in the catalog", "scan", ""))
  }
  // A memory note whose bound source was revoked or rewritten keeps its history
  // but can no longer be checked, which is confirmation debt as well.
  for note in memory_rows_unchecked(store, entries) {
    if note.status != "active" { continue }
    let invalid = invalid_memory_sources(note, entries)
    let drifted = drifted_memory_sources(note, entries)
    if invalid.is_empty() && drifted.is_empty() { continue }
    let reason = if invalid.is_empty() { "source-bytes-changed" } else { "source-revoked-or-drifted" }
    let detail = if invalid.is_empty() {
      note.kind + " note was written against different bytes of " + drifted.join(", ")
    } else {
      note.kind + " note is bound to " + invalid.join(", ")
    }
    items.push(inbox_item("memory-source-stale", "state/memory/" + note.id + ".json",
      reason, detail,
      "restore the source, or memory-supersede the note against the current bytes",
      note.updated_at))
  }
  // Competing memory judgments are confirmation debt too: A5 marks unresolved
  // conflicts for the user rather than resolving them silently.
  for group in memory_conflict_groups(memory_rows_unchecked(store, entries)) {
    let ids = group.map(n => "state/memory/" + n.id + ".json").join(", ")
    items.push(inbox_item("memory-conflict", ids, "conditions-overlap",
      group[0].kind + " notes share conditions " + group[0].conditions.join("/") + " but disagree",
      "memory-supersede with narrower conditions, or memory-archive the losing side",
      group[0].created_at))
  }
  // A5's Proposal Engine screens out work that is already underway or
  // duplicated. An open impact whose subject already has its own item is not a
  // second proposal: its cause travels with that item instead.
  let covered : Map[String, Bool] = Map([])
  for item in items { covered[item.subject] = true }
  let drift : Map[String, Array[String]] = Map([])
  let standalone : Map[String, InboxItem] = Map([])
  for row in impact_rows_unchecked(store, entries) {
    if row.status != "open" { continue }
    let causes = drift.get(row.subject).unwrap_or([])
    causes.push(row.cause)
    drift[row.subject] = causes
    if covered.get(row.subject).unwrap_or(false) { continue }
    let next = match row.kind {
      "research" => "research-complete or research-cancel, then impact-resolve"
      "overview-suggestion" => "overview-suggest for a fresh baseline, then impact-resolve"
      _ => "overview-suggest and overview-apply for a fresh synthesis, then impact-resolve"
    }
    match standalone.get(row.subject) {
      Some(existing) => standalone[row.subject] = { ..existing, reason: existing.reason + "+" + row.cause }
      None => standalone[row.subject] = inbox_item("impact", row.subject, row.cause, row.detail,
        next, row.created_at)
    }
  }
  let merged : Array[InboxItem] = []
  for item in items {
    match drift.get(item.subject) {
      None => merged.push(item)
      Some(causes) => merged.push({ ..item, drift: causes })
    }
  }
  for item in standalone.values() { merged.push(item) }
  inbox_sort(merged)
  merged
}

pub fn inbox(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let items = inbox_items(store, entries)
  { "items": items.map(inbox_view).to_json(), "counts": inbox_counts(items),
    "fingerprint": @vault.fingerprint(entries) }
}
