// Change impact for durable work.
//
// A5's Diff Engine watches connected context and decides whether a change is
// relevant to work that is still in progress. Here the durable work is a
// research topic or a pending purpose/overview suggestion, each of which froze
// the inputs it was created from. The engine compares those frozen inputs with
// the current vault and records the drift; the host decides what to revisit.

pub(all) struct Impact {
  id : String
  kind : String
  subject : String
  cause : String
  frozen : String
  current : String
  detail : String
  created_at : String
  updated_at : String
  status : String
  resolved_at : String?
  // The inputs a host decision was made against. A resolved impact only comes
  // back when the inputs move again, so a handled item is not re-reported.
  dismissed : String?
  key : String
}

pub extend Impact with ToJson::{to_json}

pub impl ToJson for Impact with to_json(self) {
  let nullable = (value : String?) => match value {
    None => Json::null()
    Some(text) => text.to_json()
  }
  {
    "version": 1,
    "id": self.id,
    "kind": self.kind,
    "subject": self.subject,
    "cause": self.cause,
    "frozen": self.frozen,
    "current": self.current,
    "detail": self.detail,
    "created_at": self.created_at,
    "updated_at": self.updated_at,
    "status": self.status,
    "resolved_at": nullable(self.resolved_at),
    "dismissed": nullable(self.dismissed),
    "key": self.key,
  }
}

pub fn impact_from_json(value : Json) -> Impact raise @base.Fault {
  @base.keys(value, ["version", "id", "kind", "subject", "cause", "frozen", "current",
    "detail", "created_at", "updated_at", "status", "resolved_at", "dismissed", "key"])
  let text = key => @base.text(@base.field(value, key))
  let nullable = key => match optional(value, key) {
    Some(Null) => None
    Some(other) => Some(@base.text(other))
    None => None
  }
  {
    id: text("id"), kind: text("kind"), subject: text("subject"), cause: text("cause"),
    frozen: text("frozen"), current: text("current"), detail: text("detail"),
    created_at: text("created_at"), updated_at: text("updated_at"),
    status: text("status"), resolved_at: nullable("resolved_at"),
    dismissed: nullable("dismissed"), key: text("key"),
  }
}

fn impact_path(id : String) -> String raise @base.Fault {
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail("invalid_impact_id")
  }
  "state/impacts/" + id + ".json"
}

fn impact_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("impact_time_invalid")
  }
}

fn impact_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("impact_idempotency_key_invalid")
  }
}

fn impact_entry(row : Impact) -> @core.Entry {
  let path = "state/impacts/" + row.id + ".json"
  { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(@base.canonical(row.to_json())), sources: [], stale: false }
}

fn impact_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/impacts/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

fn impact_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Impact] raise @base.Fault {
  impact_entries(entries).map(e => impact_from_json(@base.parse(@vault.required(store, e.path))))
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
fn impact_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Impact] raise @base.Fault {
  @vault.verify(store, entries)
  impact_rows_unchecked(store, entries)
}

fn impact_view(row : Impact, entries : Array[@core.Entry]) -> Json {
  // A subject that no longer exists cannot drift: the work is gone, not stale.
  let live = entries.iter().any(e => e.path == row.subject)
  match row.to_json() {
    Object(fields) => {
      fields["subject_present"] = live.to_json()
      Json::object(fields)
    }
    other => other
  }
}

// A host that has dealt with a stranded work item closes its impact explicitly.
// Re-running the audit would otherwise keep reporting the same drift forever.
pub fn impact_resolve(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  let path = impact_path(id)
  let before = @vault.required(store, path)
  let row = impact_from_json(@base.parse(before))
  // Validate before the replay check so a retried decision cannot smuggle in a
  // note the engine would have refused.
  let at = @base.text(@base.field(request, "at"))
  impact_time(at)
  let note = @base.text(@base.field(request, "note"))
  if note.is_empty() || note.length() > 512 || note.contains("\r") { @base.fail("impact_note_invalid") }
  if row.status == "resolved" {
    return { "id": id, "path": path, "status": "resolved", "replayed": true,
      "record": impact_view(row, entries) }
  }
  let closed : Impact = { ..row, status: "resolved", resolved_at: Some(at),
    updated_at: at, dismissed: Some(row.current) }
  let event_path = "state/events/impact-resolve-" + id + "-" + @base.hex_hash(at) + ".json"
  if (store.read)(event_path) is Some(_) { @base.fail("impact_event_conflict") }
  let event : Json = { "op": "impact-resolve", "impact": id, "at": at }
  let event_content = @base.canonical(event)
  let content = @base.canonical(closed.to_json())
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state",
    format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries),
    upsert(upsert(entries, impact_entry(closed)), event_entry), [
    { path, before: Some(before), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "path": path, "status": "resolved", "replayed": false,
    "record": impact_view(closed, entries), "event": event_path, "execution": "host_required" }
}

// Only reached from `status`/`stats`, which verify before aggregating.
pub fn impact_summary(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  let rows = impact_rows_unchecked(store, entries)
  let open = rows.filter(r => r.status == "open").length()
  { "open": open, "resolved": rows.length() - open, "total": rows.length(),
    "by_cause": {
      "baseline-drift": rows.filter(r => r.cause == "baseline-drift" && r.status == "open").length(),
      "purpose-drift": rows.filter(r => r.cause == "purpose-drift" && r.status == "open").length(),
      "page-drift": rows.filter(r => r.cause == "page-drift" && r.status == "open").length(),
      "synthesis-drift": rows.filter(r => r.cause == "synthesis-drift" && r.status == "open").length(),
    } }
}

// Reached directly from dispatch, which does not verify before the match, so
// this entry point must verify itself.
pub fn impact_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let rows = impact_rows_unchecked(store, entries)
  let views = rows.map(r => impact_view(r, entries))
  let open = rows.filter(r => r.status == "open").length()
  { "impacts": views.to_json(),
    "counts": { "open": open, "resolved": rows.length() - open, "total": rows.length() },
    "fingerprint": @vault.fingerprint(entries) }
}

// A drift finding: what work moved, which inputs it froze, and what they are now.
priv struct Finding {
  kind : String
  subject : String
  cause : String
  frozen : String
  current : String
  detail : String
}

fn finding(
  kind : String, subject : String, cause : String, frozen : String, current : String, detail : String,
) -> Finding {
  { kind, subject, cause, frozen, current, detail }
}

// Knowledge inputs are purpose, raw sources, pages and vectors. State records
// are deliberately excluded so that filing more work, or running this audit,
// never looks like a change to the material the work was frozen against.
fn knowledge_fingerprint(entries : Array[@core.Entry]) -> String {
  @vault.fingerprint(entries.filter(e => e.kind != "state"))
}

fn record_page_hashes(value : Json) -> Map[String, String] raise @base.Fault {
  let hashes : Map[String, String] = Map([])
  match @base.field(value, "page_hashes") {
    Object(fields) => for (page, hash) in fields { hashes[page] = @base.text(hash) }
    _ => ()
  }
  hashes
}

fn impact_findings(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Finding] raise @base.Fault {
  let purpose_hash = @base.hex_hash(@vault.required(store, "purpose.md"))
  let out : Array[Finding] = []
  // Research topics stay open across sessions, so new material is the signal
  // that the host should reconsider the topic before spending more work. The
  // comparison uses the knowledge fingerprint, which ignores state records:
  // filing more work must not look like new research material.
  for row in research_rows_unchecked(store, entries) {
    if @base.text(@base.field(row, "status")) != "proposed" { continue }
    let frozen = @base.text(@base.field(row, "inputs_hash"))
    let current = knowledge_fingerprint(entries)
    if frozen == current { continue }
    let id = @base.text(@base.field(row, "id"))
    out.push(finding("research", "state/research/" + id + ".json", "baseline-drift", frozen, current,
      "open research topic was frozen against different knowledge inputs"))
  }
  // A pending purpose suggestion can no longer be applied once purpose.md moved.
  // Only purpose-apply writes purpose.md and it closes the suggestion it applies,
  // so this stays reachable only through an external edit that verify refuses;
  // the engine therefore reports nothing here and the kind is not registered.
  // Overview suggestions freeze purpose plus every active page hash.
  for row in overview_rows_unchecked(store, entries) {
    if @base.text(@base.field(row, "status")) != "proposed" { continue }
    let frozen = overview_digest(@base.text(@base.field(row, "purpose_hash")),
      record_page_hashes(row))
    let current = overview_inputs(entries, purpose_hash)
    if frozen == current { continue }
    let id = @base.text(@base.field(row, "id"))
    let cause = if @base.text(@base.field(row, "purpose_hash")) != purpose_hash {
      "purpose-drift"
    } else {
      "page-drift"
    }
    out.push(finding("overview-suggestion", "state/overview/" + id + ".json", cause, frozen, current,
      "pending overview suggestion was frozen against different purpose or page inputs"))
  }
  // A published synthesis counts as edited outside the engine only when no
  // applied record still matches it: applying a newer suggestion is not drift.
  match overview_page_entry(entries) {
    None => ()
    Some(entry) => {
      let applied = overview_rows_unchecked(store, entries).filter(row =>
        @base.text(@base.field(row, "status")) == "applied")
      let mut matched = false
      for row in applied {
        if @base.text(@base.field(row, "result_hash")) == entry.sha256 { matched = true }
      }
      if !matched {
        let frozen = match applied.last() {
          Some(row) => @base.text(@base.field(row, "result_hash"))
          None => @base.hex_hash(@vault.required(store, "wiki/overview.md"))
        }
        out.push(finding("overview-synthesis", "wiki/overview.md", "synthesis-drift", frozen,
          entry.sha256, "published synthesis no longer matches any applied overview record"))
      }
    }
  }
  out
}
pub fn impact_audit(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let at = @base.text(@base.field(request, "at"))
  impact_time(at)
  // Validate the explicit key up front: a replayed audit must not accept a key
  // it would have refused when the record was first created.
  let explicit_key = match optional(request, "key") {
    Some(value) => { let value = @base.text(value); impact_key(value); Some(value) }
    None => None
  }
  let findings = impact_findings(store, entries)
  let rows = impact_rows_unchecked(store, entries)
  let by_id : Map[String, Impact] = Map([])
  for row in rows { by_id[row.id] = row }
  let changes : Array[@vault.Change] = []
  let mut next = entries
  let mut opened = 0
  let mut updated = 0
  let mut resolved = 0
  let mut replayed = 0
  // Drift that is gone closes the record; the audit is a live view, not a log.
  for row in rows {
    let live = findings.iter().any(f => @core.impact_id(f.kind, f.subject, f.cause) == row.id)
    if live { continue }
    if row.status == "resolved" { continue }
    let closed : Impact = { ..row, status: "resolved", resolved_at: Some(at),
      updated_at: at, dismissed: None }
    let path = impact_path(row.id)
    let event_path = "state/events/impact-resolve-" + row.id + "-" + @base.hex_hash(at) + ".json"
    if (store.read)(event_path) is Some(_) { @base.fail("impact_event_conflict") }
    let event : Json = { "op": "impact-resolve", "impact": row.id, "at": at }
    let event_content = @base.canonical(event)
    changes.push({ path, before: (store.read)(path), after: Some(@base.canonical(closed.to_json())) })
    changes.push({ path: event_path, before: None, after: Some(event_content) })
    next = upsert(next, impact_entry(closed))
    next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
    resolved += 1
  }
  for f in findings {
    let id = @core.impact_id(f.kind, f.subject, f.cause)
    let path = impact_path(id)
    match by_id.get(id) {
      Some(existing) if existing.status == "open" => {
        if existing.current == f.current { replayed += 1; continue }
        // Same work, newer inputs: keep the original creation time and refresh.
        let refreshed : Impact = { ..existing, frozen: f.frozen, current: f.current,
          detail: f.detail, updated_at: at }
        let event_path = "state/events/impact-open-" + id + "-" +
          @base.hex_hash(existing.key + "\n" + f.current + "\n" + at) + ".json"
        let event : Json = { "op": "impact-open", "impact": id, "at": at, "key": existing.key,
          "kind": f.kind, "subject": f.subject, "cause": f.cause, "frozen": f.frozen, "current": f.current }
        let event_content = @base.canonical(event)
        changes.push({ path, before: (store.read)(path), after: Some(@base.canonical(refreshed.to_json())) })
        changes.push({ path: event_path, before: None, after: Some(event_content) })
        next = upsert(next, impact_entry(refreshed))
        next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
          sha256: @base.hex_hash(event_content), sources: [], stale: false })
        updated += 1
      }
      Some(existing) => {
        // Resolved drift only comes back when the inputs moved again. A host
        // decision made against these exact inputs stays closed.
        let suppressed = match existing.dismissed {
          None => false
          Some(value) => value == f.current
        }
        if suppressed { replayed += 1; continue }
        let reopened : Impact = { ..existing, status: "open", resolved_at: None, dismissed: None,
          frozen: f.frozen, current: f.current, detail: f.detail, created_at: at, updated_at: at }
        let event_path = "state/events/impact-open-" + id + "-" +
          @base.hex_hash(existing.key + "\n" + f.current + "\n" + at) + ".json"
        let event : Json = { "op": "impact-open", "impact": id, "at": at, "key": existing.key,
          "kind": f.kind, "subject": f.subject, "cause": f.cause, "frozen": f.frozen, "current": f.current }
        let event_content = @base.canonical(event)
        changes.push({ path, before: (store.read)(path), after: Some(@base.canonical(reopened.to_json())) })
        changes.push({ path: event_path, before: None, after: Some(event_content) })
        next = upsert(next, impact_entry(reopened))
        next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
          sha256: @base.hex_hash(event_content), sources: [], stale: false })
        opened += 1
      }
      None => {
        let key = match explicit_key {
          Some(value) => value
          None => @base.hex_hash("impact-audit-v1\n" + f.kind + "\n" + f.subject + "\n" + f.cause)
        }
        let row : Impact = { id, kind: f.kind, subject: f.subject, cause: f.cause,
          frozen: f.frozen, current: f.current, detail: f.detail,
          created_at: at, updated_at: at, status: "open", resolved_at: None, dismissed: None, key }
        let event_path = "state/events/impact-open-" + id + "-" +
          @base.hex_hash(key + "\n" + f.current + "\n" + at) + ".json"
        if (store.read)(path) is Some(_) { @base.fail("impact_record_conflict") }
        if (store.read)(event_path) is Some(_) { @base.fail("impact_event_conflict") }
        let event : Json = { "op": "impact-open", "impact": id, "at": at, "key": key,
          "kind": f.kind, "subject": f.subject, "cause": f.cause, "frozen": f.frozen, "current": f.current }
        let event_content = @base.canonical(event)
        changes.push({ path, before: None, after: Some(@base.canonical(row.to_json())) })
        changes.push({ path: event_path, before: None, after: Some(event_content) })
        next = upsert(next, impact_entry(row))
        next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
          sha256: @base.hex_hash(event_content), sources: [], stale: false })
        opened += 1
      }
    }
  }
  if changes.is_empty() {
    return { "opened": 0, "updated": 0, "resolved": 0, "replayed": replayed,
      "open": impact_rows_unchecked(store, entries).filter(r => r.status == "open").length(),
      "fingerprint": @vault.fingerprint(entries), "committed": false }
  }
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "opened": opened, "updated": updated, "resolved": resolved, "replayed": replayed,
    "open": impact_rows(store, next).filter(r => r.status == "open").length(),
    "fingerprint": @vault.fingerprint(next), "committed": true }
}

// Cross-record invariants a single impact record cannot express.
fn lint_impact_notes(store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  let rows : Array[Impact] = []
  for entry in impact_entries(entries) {
    let text = try { (store.read)(entry.path) } catch { _ => None }
    match text {
      None => ()
      Some(value) => {
        let row = try { Some(impact_from_json(@base.parse(value))) } catch { _ => None }
        match row {
          None => ()
          Some(parsed) => {
            if !entries.iter().any(e => e.path == parsed.subject) && parsed.status == "open" {
              lint_add(issues, "impact_subject_missing", entry.id, entry.path,
                "open impact references an unrecorded subject: " + parsed.subject,
                "re-run impact-audit after restoring or closing the work record", "error")
            }
            if parsed.frozen == parsed.current && parsed.status == "open" {
              lint_add(issues, "impact_no_drift", entry.id, entry.path,
                "open impact records identical frozen and current inputs",
                "re-run impact-audit so resolved drift is closed", "error")
            }
            rows.push(parsed)
          }
        }
      }
    }
  }
  let seen : Map[String, String] = Map([])
  for row in rows {
    match seen.get(row.id) {
      Some(first) => lint_add(issues, "impact_duplicate", entry_id(row), entry_id(row),
        "impact identity is recorded twice, first as " + first,
        "keep one record per kind/subject/cause", "error")
      None => seen[row.id] = row.id
    }
  }
}

fn entry_id(row : Impact) -> String {
  "state/impacts/" + row.id + ".json"
}
