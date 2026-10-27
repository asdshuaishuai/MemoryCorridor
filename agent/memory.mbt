// Lifelong memory notes.
//
// The engine records durable, condition-tagged understanding and serves ranked
// candidates; the external agent decides what is worth retaining and how it
// applies. Nothing here calls a model or the network.

fn memory_kinds() -> Array[String] {
  ["preference", "decision", "constraint", "fact", "goal"]
}

fn memory_id(value : String) -> Unit raise @base.Fault {
  if value.length() != 64 || !value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail("invalid_memory_id")
  }
}

fn memory_path(id : String) -> String raise @base.Fault {
  memory_id(id)
  "state/memory/" + id + ".json"
}

fn memory_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("memory_time_invalid")
  }
}

fn memory_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("memory_idempotency_key_invalid")
  }
}

fn memory_body(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 4096 || value.contains("\r") { @base.fail("memory_text_invalid") }
}

fn memory_conditions(value : Array[String]) -> Unit raise @base.Fault {
  if value.length() > 16 { @base.fail("memory_conditions_count_invalid") }
  for condition in value {
    if condition.is_empty() || condition.length() > 256 ||
      condition.contains("\n") || condition.contains("\r") {
      @base.fail("memory_condition_invalid")
    }
  }
}

fn memory_sources(value : Array[String]) -> Unit raise @base.Fault {
  if value.length() > 32 { @base.fail("memory_sources_count_invalid") }
  let seen : Map[String, Bool] = Map([])
  for source in value {
    @base.path(source)
    if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("memory_source_invalid") }
    seen[source] = true
  }
}

// Pinning the digest only means something if the source is registered and
// active right now; a note may not claim evidence it cannot point at.
fn memory_source_hashes(
  store : @vault.Storage, entries : Array[@core.Entry], sources : Array[String],
) -> Array[String] raise @base.Fault {
  let hashes : Array[String] = []
  for source in sources {
    let entry = match entries.iter().find_first(e => e.id == source) {
      Some(found) => found
      None => raise @base.Fault("memory_source_not_registered: " + source + "; run scan")
    }
    if entry.kind != "raw" || entry.stale { @base.fail("memory_source_not_active: " + source) }
    match (store.digest)(source) {
      Some(digest) => if digest != entry.sha256 { @base.fail("memory_source_changed: " + source) }
      None => @base.fail("memory_source_not_active: " + source)
    }
    hashes.push(entry.sha256)
  }
  hashes
}

fn memory_strings(request : Json, key : String) -> Array[String] raise @base.Fault {
  match optional(request, key) {
    Some(value) => @base.strings(value)
    None => []
  }
}

pub(all) struct MemoryNote {
  id : String
  kind : String
  scope : String
  text : String
  conditions : Array[String]
  sources : Array[String]
  // The digest each bound source had when the note was written. A note whose
  // source was rewritten whole must stop reporting itself as checkable.
  source_hashes : Array[String]
  status : String
  key : String
  created_at : String
  updated_at : String
  archived_at : String?
  superseded_by : String?
  supersedes : String?
  // A5 protects memories that are important despite being used infrequently:
  // a pinned note is never archived, so automated pruning cannot drop it.
  pinned : Bool
  last_used_at : String?
  note_hash : String
}

pub extend MemoryNote with ToJson::{to_json}

pub impl ToJson for MemoryNote with to_json(self) {
  let nullable = (value : String?) => match value {
    None => Json::null()
    Some(text) => text.to_json()
  }
  {
    "version": 1,
    "id": self.id,
    "kind": self.kind,
    "scope": self.scope,
    "text": self.text,
    "conditions": self.conditions.to_json(),
    "sources": self.sources.to_json(),
    "source_hashes": self.source_hashes.to_json(),
    "status": self.status,
    "key": self.key,
    "created_at": self.created_at,
    "updated_at": self.updated_at,
    "archived_at": nullable(self.archived_at),
    "superseded_by": nullable(self.superseded_by),
    "supersedes": nullable(self.supersedes),
    "pinned": self.pinned,
    "last_used_at": nullable(self.last_used_at),
    "note_hash": self.note_hash,
  }
}

pub fn memory_from_json(value : Json) -> MemoryNote raise @base.Fault {
  @base.keys(value, ["version", "id", "kind", "scope", "text", "conditions", "sources",
    "source_hashes", "status", "key", "created_at", "updated_at", "archived_at",
    "superseded_by", "supersedes", "pinned", "last_used_at", "note_hash"])
  // Records written before source version pinning simply have no hashes; they
  // fall back to path-only validity and stay readable.
  let source_hashes = match optional(value, "source_hashes") {
    Some(Null) => []
    Some(other) => @base.strings(other)
    None => []
  }
  let text = key => @base.text(@base.field(value, key))
  let nullable = key => match optional(value, key) {
    Some(Null) => None
    Some(other) => Some(@base.text(other))
    None => None
  }
  {
    id: text("id"), kind: text("kind"), scope: text("scope"), text: text("text"),
    conditions: @base.strings(@base.field(value, "conditions")),
    sources: @base.strings(@base.field(value, "sources")),
    source_hashes,
    status: text("status"), key: text("key"),
    created_at: text("created_at"), updated_at: text("updated_at"),
    archived_at: nullable("archived_at"),
    superseded_by: nullable("superseded_by"), supersedes: nullable("supersedes"),
    pinned: @base.boolean(@base.field(value, "pinned")),
    last_used_at: nullable("last_used_at"),
    note_hash: text("note_hash"),
  }
}

fn memory_entry(note : MemoryNote) -> @core.Entry {
  let path = "state/memory/" + note.id + ".json"
  { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(@base.canonical(note.to_json())), sources: [], stale: false }
}

fn memory_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/memory/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

pub fn memory_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[MemoryNote] raise @base.Fault {
  memory_entries(entries).map(e => memory_from_json(@base.parse(@vault.required(store, e.path))))
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
pub fn memory_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[MemoryNote] raise @base.Fault {
  @vault.verify(store, entries)
  memory_rows_unchecked(store, entries)
}

// Sources are recorded inside the note rather than as catalog sources: a state
// entry cannot carry them, and a judgment stays reviewable after drift.
// `invalid` covers a source that is gone or revoked; `drifted` covers one that
// still exists but no longer holds the bytes the note was written against.
fn invalid_memory_sources(note : MemoryNote, entries : Array[@core.Entry]) -> Array[String] {
  note.sources.filter(s => !entries.iter().any(e => e.id == s && e.kind == "raw" && !e.stale))
}

fn drifted_memory_sources(note : MemoryNote, entries : Array[@core.Entry]) -> Array[String] {
  if note.source_hashes.length() != note.sources.length() { return [] }
  let out : Array[String] = []
  for i = 0; i < note.sources.length(); i = i + 1 {
    let source = note.sources[i]
    let registered = entries.iter().any(e => e.id == source && e.kind == "raw" && !e.stale)
    if registered && entries.iter().any(e => e.id == source && e.sha256 != note.source_hashes[i]) {
      out.push(source)
    }
  }
  out
}

fn memory_view(note : MemoryNote, entries : Array[@core.Entry], conflicted : Bool) -> Json {
  let invalid = invalid_memory_sources(note, entries)
  let drifted = drifted_memory_sources(note, entries)
  match note.to_json() {
    Object(fields) => {
      fields["valid"] = (invalid.is_empty() && drifted.is_empty()).to_json()
      fields["invalid_sources"] = invalid.to_json()
      fields["drifted_sources"] = drifted.to_json()
      fields["conflicted"] = conflicted.to_json()
      Json::object(fields)
    }
    other => other
  }
}

// A5 keeps detailed notes on disk so the agent can read them as needed instead
// of carrying every detail into the conversation. Listing everything to read one
// note does not scale, so a single note is addressable by id.
pub fn memory_read(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  memory_id(id)
  let path = memory_path(id)
  let note = memory_load(store, id)
  let conflicted = memory_conflicted(memory_rows(store, entries))
  // A read never carries `execution`: that field marks an operation which
  // recorded a plan the host still has to carry out.
  { "id": id, "path": path,
    "record": memory_view(note, entries, conflicted.get(note.id).unwrap_or(false)) }
}

// A5's Autodream keeps the conditions a judgment was made under and marks
// unresolved conflicts for confirmation instead of silently dropping one side.
// Two active notes of the same kind whose applicability conditions coincide but
// whose text differs are exactly such a candidate. The engine reports them; the
// host resolves them through memory-supersede, which keeps both histories.
fn memory_conflict_key(note : MemoryNote) -> String {
  let conditions = note.conditions.copy()
  conditions.sort_by(@base.compare)
  @base.hex_hash("memory-conflict-v1\n" + note.kind + "\n" + @base.canonical(conditions.to_json()))
}

pub fn memory_conflict_groups(rows : Array[MemoryNote]) -> Array[Array[MemoryNote]] {
  let buckets : Map[String, Array[MemoryNote]] = Map([])
  for note in rows {
    if note.status != "active" { continue }
    let key = memory_conflict_key(note)
    let row = buckets.get(key).unwrap_or([])
    row.push(note)
    buckets[key] = row
  }
  let groups : Array[Array[MemoryNote]] = []
  for key in buckets.keys() {
    let row = buckets.get(key).unwrap_or([])
    let distinct : Map[String, Bool] = Map([])
    for note in row {
      distinct[@core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions)] = true
    }
    if distinct.length() < 2 { continue }
    row.sort_by((a, b) => @base.compare(a.id, b.id))
    groups.push(row)
  }
  groups.sort_by((a, b) => @base.compare(a[0].id, b[0].id))
  groups
}

fn memory_conflicted(rows : Array[MemoryNote]) -> Map[String, Bool] {
  let conflicted : Map[String, Bool] = Map([])
  for group in memory_conflict_groups(rows) {
    for note in group { conflicted[note.id] = true }
  }
  conflicted
}

fn memory_conflict_view(group : Array[MemoryNote], entries : Array[@core.Entry]) -> Json {
  {
    "kind": group[0].kind,
    "conditions": group[0].conditions.to_json(),
    "notes": group.map(n => memory_view(n, entries, true)).to_json(),
  }
}

fn memory_conflict_counts(groups : Array[Array[MemoryNote]]) -> Json {
  let mut notes = 0
  for group in groups { notes += group.length() }
  { "groups": groups.length(), "notes": notes }
}

fn memory_counts(rows : Array[MemoryNote], entries : Array[@core.Entry]) -> Json {
  {
    "active": rows.filter(n => n.status == "active").length(),
    "archived": rows.filter(n => n.status == "archived").length(),
    "superseded": rows.filter(n => n.status == "superseded").length(),
    "invalid": rows.filter(n => !invalid_memory_sources(n, entries).is_empty()).length(),
    "drifted": rows.filter(n => !drifted_memory_sources(n, entries).is_empty()).length(),
    "conflicted": memory_conflicted(rows).length(),
  }
}

pub fn memory_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  let rows = memory_rows(store, entries)
  let conflicted = memory_conflicted(rows)
  let views = rows.map(n => memory_view(n, entries, conflicted.get(n.id).unwrap_or(false)))
  { "notes": views.to_json(), "counts": memory_counts(rows, entries), "fingerprint": @vault.fingerprint(entries) }
}

// A5's Autodream keeps conflicting judgments and marks them for confirmation
// with the user instead of dropping one side. Listing them separately lets a
// host review the whole picture, not only what a query surfaced.
pub fn memory_conflicts(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  let rows = memory_rows(store, entries)
  let groups = memory_conflict_groups(rows)
  { "conflicts": groups.map(g => memory_conflict_view(g, entries)).to_json(),
    "counts": memory_conflict_counts(groups),
    "fingerprint": @vault.fingerprint(entries) }
}

// A5's Autodream consolidates a lifelong store: it merges reworded duplicates
// and prunes what was never used. The engine must not decide either one -- it
// records the signals and an external agent acts on them. `memory-conflicts`
// already exposes competing judgments without a seed; this is the sibling for
// merge and prune candidates, so an agent can discover the work without first
// having to guess a query that would surface it through `memory-prefetch`.
pub fn memory_candidates(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let rows = memory_rows_unchecked(store, entries)
  let conflicted = memory_conflicted(rows)
  let active = rows.filter(n => n.status == "active")
  // Superseded and archived notes are history: proposing them would ask the host
  // to re-decide something already settled.
  let live = active.filter(n => !conflicted.get(n.id).unwrap_or(false))
  let merge : Array[Json] = []
  let keepers : Array[(String, Array[String], String, String)] = []
  // Sorted by id so the keeper of each group and the output order are stable.
  let ordered = live.copy()
  ordered.sort_by((a, b) => @base.compare(a.id, b.id))
  for note in ordered {
    if !@index.similar_eligible(note.text) { continue }
    let tokens = @index.similar_tokens(note.text)
    let mut keeper = ""
    for kept in keepers {
      // A reworded duplicate is the same judgment in different bytes. The same
      // words under a different kind or scope are a different sort of judgment,
      // and merging them would silently drop that distinction.
      if kept.2 == note.kind && kept.3 == note.scope &&
        @index.similar_merge(tokens, kept.1) { keeper = kept.0 }
    }
    if keeper != "" {
      let kept_note = live.filter(n => n.id == keeper)[0]
      merge.push({ "duplicate": note.id, "keeper": keeper,
        "duplicate_key": note.key, "keeper_key": kept_note.key,
        "duplicate_text": note.text, "keeper_text": kept_note.text,
        "reason": "similar_text" })
      continue
    }
    keepers.push((note.id, tokens, note.kind, note.scope))
  }
  // Pruning is a signal, never a verdict: the engine records whether a host ever
  // reported using a note, and nothing else. A recency threshold would be a
  // judgment, so it is left to the host.
  let prune : Array[Json] = []
  let by_id = active.copy()
  by_id.sort_by((a, b) => @base.compare(a.id, b.id))
  // A note already proposed as a merge duplicate is going away either way, and
  // nominating its keeper for deletion would contradict the merge it heads.
  let in_merge : Map[String, Bool] = Map([])
  for row in merge {
    in_merge[@base.text(@base.field(row, "duplicate"))] = true
    in_merge[@base.text(@base.field(row, "keeper"))] = true
  }
  for note in by_id {
    if in_merge.get(note.id).unwrap_or(false) { continue }
    if note.pinned { continue }
    if note.last_used_at is Some(_) { continue }
    // A note in an unresolved conflict is the host's to confirm, so proposing it
    // for pruning would pre-empt that decision and double up with
    // `memory-conflicts`.
    if conflicted.get(note.id).unwrap_or(false) { continue }
    // A note whose source was revoked or rewritten needs superseding, not
    // deleting, and `inbox` already proposes that debt.
    if !invalid_memory_sources(note, entries).is_empty() { continue }
    if !drifted_memory_sources(note, entries).is_empty() { continue }
    prune.push({ "id": note.id, "key": note.key, "kind": note.kind,
      "scope": note.scope, "created_at": note.created_at, "last_used_at": Json::null(),
      "pinned": false, "reason": "never_used" })
  }
  { "merge": merge.to_json(), "prune": prune.to_json(),
    "counts": { "merge": merge.length(), "prune": prune.length(),
      "conflicted": conflicted.length(),
      "pinned": active.filter(n => n.pinned).length(),
      "eligible": live.filter(n => @index.similar_eligible(n.text)).length(),
      "active": active.length() },
    "fingerprint": @vault.fingerprint(entries) }
}

// Pinning is explicit and reversible: it exists so that a host automating
// archiving cannot drop a note a human marked as important.
pub fn memory_protect(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  memory_id(id)
  let pinned = @base.boolean(@base.field(request, "pinned"))
  let at = @base.text(@base.field(request, "at"))
  memory_time(at)
  let path = memory_path(id)
  let note = memory_load(store, id)
  if note.pinned == pinned && note.updated_at == at {
    return { "id": id, "path": path, "pinned": pinned, "replayed": true }
  }
  let record : MemoryNote = { ..note, pinned, updated_at: at }
  let content = @base.canonical(record.to_json())
  let event_path = "state/events/memory-pin-" + id + "-" +
    @base.hex_hash(pinned.to_string() + "\n" + at) + ".json"
  if (store.read)(event_path) is Some(_) { @base.fail("memory_event_conflict") }
  let event : Json = { "op": "memory-pin", "memory": id, "at": at, "pinned": pinned }
  let event_content = @base.canonical(event)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state",
    format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries),
    upsert(upsert(entries, memory_entry(record)), event_entry), [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "path": path, "pinned": pinned, "replayed": false, "event": event_path }
}

// Reporting foreground usage is what makes Autodream's selective pruning
// possible: without it a host can only guess which notes have gone stale by
// disuse. Prefetch itself stays read-only; the host reports what it used.
pub fn memory_use(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let ids = @base.strings(@base.field(request, "ids"))
  if ids.is_empty() || ids.length() > 64 { @base.fail("memory_use_count_invalid") }
  let at = @base.text(@base.field(request, "at"))
  memory_time(at)
  let seen : Map[String, Bool] = Map([])
  let by_id : Map[String, MemoryNote] = Map([])
  for note in memory_rows(store, entries) { by_id[note.id] = note }
  let changes : Array[@vault.Change] = []
  let mut next = entries
  let mut used = 0
  for id in ids {
    memory_id(id)
    if seen.contains(id) { @base.fail("memory_use_duplicate_id") }
    seen[id] = true
    match by_id.get(id) {
      None => @base.fail("entry_not_found: " + id)
      Some(note) => {
        // The same report twice is a replay, not a second write.
        if note.last_used_at == Some(at) { continue }
        let record : MemoryNote = { ..note, last_used_at: Some(at) }
        let path = memory_path(id)
        let content = @base.canonical(record.to_json())
        changes.push({ path, before: (store.read)(path), after: Some(content) })
        next = upsert(next, memory_entry(record))
        used += 1
      }
    }
  }
  if changes.is_empty() {
    return { "used": 0, "replayed": true, "fingerprint": @vault.fingerprint(entries),
      "committed": false }
  }
  // One event per batch keeps a usage report to a single transaction.
  let event_path = "state/events/memory-use-" +
    @base.hex_hash(@base.canonical(ids.to_json()) + "\n" + at) + ".json"
  if (store.read)(event_path) is Some(_) { @base.fail("memory_event_conflict") }
  let event : Json = { "op": "memory-use", "memories": ids.to_json(), "at": at }
  let event_content = @base.canonical(event)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state",
    format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  changes.push({ path: event_path, before: None, after: Some(event_content) })
  next = upsert(next, event_entry)
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "used": used, "replayed": false, "fingerprint": @vault.fingerprint(next),
    "committed": true, "event": event_path }
}

pub fn memory_summary(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  // Every caller (`status`, `stats`) verifies once before aggregating, so this
  // must not re-hash every file in the vault on top of that.
  memory_counts(memory_rows_unchecked(store, entries), entries)
}

// Schema faults are already reported by validate_record; this pass adds the
// cross-record invariants a single record cannot express.
fn lint_memory_notes(store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  let rows : Array[MemoryNote] = []
  for entry in memory_entries(entries) {
    let text = try { (store.read)(entry.path) } catch { _ => None }
    match text {
      None => ()
      Some(value) => {
        let note = try { Some(memory_from_json(@base.parse(value))) } catch { _ => None }
        match note {
          None => ()
          Some(parsed) => {
            // A superseded note is history: its source drift is not actionable,
            // and `memory-list` still reports it for audit.
            if parsed.status != "superseded" {
              for source in invalid_memory_sources(parsed, entries) {
                lint_add(issues, "memory_source_stale", entry.id, entry.path,
                  "memory note references a revoked or missing raw source: " + source,
                  "restore the source or supersede the note without that binding", "warning")
              }
              for source in drifted_memory_sources(parsed, entries) {
                lint_add(issues, "memory_source_drift", entry.id, entry.path,
                  "memory note was written against different bytes of raw source: " + source,
                  "supersede the note against the current source, or drop the binding", "warning")
              }
            }
            rows.push(parsed)
          }
        }
      }
    }
  }
  let by_id : Map[String, MemoryNote] = Map([])
  for note in rows { by_id[note.id] = note }
  for note in rows {
    match note.supersedes {
      None => ()
      Some(previous) => if by_id.get(previous) is None {
        lint_add(issues, "memory_supersede_origin_missing", entry_path(note), entry_path(note),
          "note claims to supersede an unrecorded memory note: " + previous,
          "recreate the chain through memory-supersede", "error")
      }
    }
    match note.superseded_by {
      None => ()
      Some(next) => match by_id.get(next) {
        None => lint_add(issues, "memory_supersede_target_missing", entry_path(note), entry_path(note),
          "superseded note points at an unrecorded replacement: " + next,
          "recreate the chain through memory-supersede", "error")
        Some(target) => match target.supersedes {
          Some(back) if back == note.id => ()
          _ => lint_add(issues, "memory_supersede_link_asymmetric", entry_path(note), entry_path(note),
            "supersede link is not mirrored by the replacement note",
            "rewrite both records through memory-supersede", "error")
        }
      }
    }
  }
  let content : Map[String, String] = Map([])
  for note in rows {
    // Only active notes compete; superseded ones are history and archived ones
    // have left the default set.
    if note.status != "active" { continue }
    let judgment = @core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions)
    match content.get(judgment) {
      Some(first) => lint_add(issues, "memory_duplicate_note", entry_path(note), entry_path(note),
        "identical memory content is recorded twice, first as " + first,
        "supersede or archive one of the duplicates", "error")
      None => content[judgment] = note.id
    }
  }
  let keys : Map[String, String] = Map([])
  for note in rows {
    if note.status != "active" { continue }
    match keys.get(note.key) {
      Some(first) => lint_add(issues, "memory_key_ambiguous", entry_path(note), entry_path(note),
        "more than one active note shares an idempotency key, first as " + first,
        "supersede the older note so only one active note keeps the key", "error")
      None => keys[note.key] = note.id
    }
  }
  // Competing judgments under the same conditions are review debt, not a fault:
  // both sides stay readable until a human or the host resolves them.
  for group in memory_conflict_groups(rows) {
    let ids = group.map(n => n.id).join(", ")
    lint_add(issues, "memory_conflict", entry_path(group[0]), entry_path(group[0]),
      "active notes of kind " + group[0].kind + " share conditions but disagree: " + ids,
      "supersede the losing judgment so its history and conditions stay auditable", "warning")
  }
}

fn entry_path(note : MemoryNote) -> String {
  "state/memory/" + note.id + ".json"
}

fn memory_transition(
  store : @vault.Storage, entries : Array[@core.Entry], note : MemoryNote,
  status : String, at : String, event_op : String,
) -> Json raise @base.Fault {
  let path = memory_path(note.id)
  let record : MemoryNote = {
    ..note,
    status,
    updated_at: at,
    archived_at: if status == "archived" { Some(at) } else { None },
  }
  let content = @base.canonical(record.to_json())
  let event_path = "state/events/" + event_op + "-" + note.id + "-" + @base.hex_hash(at) + ".json"
  let event : Json = { "op": event_op, "memory": note.id, "at": at }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("memory_event_conflict") }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state",
    format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries),
    upsert(upsert(entries, memory_entry(record)), event_entry), [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  // Reload so the returned record reports the conflict state that actually
  // holds after the transition, not the one that held before it.
  let live = @vault.load(store)
  let conflicted = memory_conflicted(memory_rows(store, live))
  { "id": note.id, "path": path, "status": status, "replayed": false,
    "record": memory_view(record, live, conflicted.get(record.id).unwrap_or(false)),
    "event": event_path }
}

fn memory_load(store : @vault.Storage, id : String) -> MemoryNote raise @base.Fault {
  memory_from_json(@base.parse(@vault.required(store, memory_path(id))))
}

pub fn memory_archive(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  memory_id(id)
  let note = memory_load(store, id)
  if note.status == "archived" {
    return { "id": id, "path": memory_path(id), "status": "archived", "replayed": true,
      "record": memory_view(note, entries, false) }
  }
  if note.status == "superseded" { @base.fail("memory_superseded_note_refused") }
  // A pinned note is important despite being used infrequently: archiving it
  // has to go through an explicit unprotect first.
  if note.pinned { @base.fail("memory_pinned_archive_refused") }
  memory_transition(store, entries, note, "archived", @base.text(@base.field(request, "at")), "memory-archive")
}

pub fn memory_restore(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  memory_id(id)
  let note = memory_load(store, id)
  if note.status == "active" {
    return { "id": id, "path": memory_path(id), "status": "active", "replayed": true,
      "record": memory_view(note, entries, false) }
  }
  if note.status == "superseded" { @base.fail("memory_superseded_note_refused") }
  memory_transition(store, entries, note, "active", @base.text(@base.field(request, "at")), "memory-restore")
}

fn memory_write(
  store : @vault.Storage, entries : Array[@core.Entry], kind : String, scope : String,
  body : String, conditions : Array[String], sources : Array[String],
  at : String, key : String, previous : MemoryNote?, event_op : String,
) -> Json raise @base.Fault {
  memory_body(body)
  memory_conditions(conditions)
  memory_sources(sources)
  memory_time(at)
  let source_hashes = memory_source_hashes(store, entries, sources)
  let digest = @core.memory_note_hash(kind, scope, body, conditions, sources, source_hashes)
  let id = @core.memory_note_id(key, digest)
  let path = memory_path(id)
  let rows = memory_rows(store, entries)
  for note in rows {
    if note.id == id {
      return { "id": id, "path": path, "status": note.status, "replayed": true,
        "record": memory_view(note, entries, false) }
    }
  }
  // Identical understanding under another key is a duplicate, not a new note.
  // Merging is a judgment the host makes, so refuse instead of guessing.
  let judgment = @core.memory_judgment_hash(kind, scope, body, conditions)
  for note in rows {
    // Superseded notes are history and archived notes have left the default
    // set, so neither competes with a fresh submission of the same judgment.
    if note.status != "active" { continue }
    if @core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions) == judgment &&
      (match previous { Some(old) => note.id != old.id; None => true }) {
      @base.fail("memory_duplicate_text: " + note.id + "; supersede or archive that note instead")
    }
  }
  let record : MemoryNote = {
    id, kind, scope, text: body, conditions, sources, status: "active", key,
    created_at: at, updated_at: at, archived_at: None,
    source_hashes,
    superseded_by: None, supersedes: previous.map(p => p.id), pinned: false,
    last_used_at: None, note_hash: digest,
  }
  let content = @base.canonical(record.to_json())
  let event_path = if event_op == "memory-supersede" {
    "state/events/memory-supersede-" + previous.unwrap().id + "-" + id + ".json"
  } else {
    "state/events/memory-submit-" + id + ".json"
  }
  let event : Json = { "op": event_op, "memory": id, "at": at, "key": key, "note_hash": digest,
    "supersedes": match previous { None => Json::null(); Some(old) => old.id.to_json() } }
  let event_content = @base.canonical(event)
  if (store.read)(path) is Some(_) { @base.fail("memory_record_conflict") }
  if (store.read)(event_path) is Some(_) { @base.fail("memory_event_conflict") }
  let changes : Array[@vault.Change] = [{ path: event_path, before: None, after: Some(event_content) }]
  let mut next = upsert(entries, memory_entry(record))
  match previous {
    None => ()
    Some(old) => {
      let superseded : MemoryNote = { ..old, status: "superseded", superseded_by: Some(id), updated_at: at }
      changes.push({ path: memory_path(old.id), before: (store.read)(memory_path(old.id)),
        after: Some(@base.canonical(superseded.to_json())) })
      next = upsert(next, memory_entry(superseded))
    }
  }
  changes.push({ path, before: None, after: Some(content) })
  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
    sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  let live = @vault.load(store)
  let conflicted = memory_conflicted(memory_rows(store, live))
  { "id": id, "path": path, "status": "active", "replayed": false, "key": key,
    "supersedes": match previous { None => Json::null(); Some(old) => old.id.to_json() },
    "record": memory_view(record, live, conflicted.get(record.id).unwrap_or(false)),
    "event": event_path }
}

pub fn memory_submit(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let kind = @base.text(@base.field(request, "kind"))
  if !memory_kinds().contains(kind) { @base.fail("memory_kind_unsupported: " + kind) }
  let scope = @base.text(@base.field(request, "scope"))
  if scope != "workspace" { @base.fail("memory_scope_unsupported: " + scope) }
  let key = match optional(request, "key") {
    Some(value) => { let value = @base.text(value); memory_key(value); value }
    None => @base.hex_hash("memory-submit-v1\n" + kind + "\n" + @base.text(@base.field(request, "text")))
  }
  let rows = memory_rows(store, entries)
  let active = rows.filter(n => n.key == key && n.status == "active")
  if active.length() > 1 { @base.fail("memory_key_ambiguous: " + key) }
  let previous = if active.is_empty() { None } else { Some(active[0]) }
  memory_write(store, entries, kind, scope, @base.text(@base.field(request, "text")),
    memory_strings(request, "conditions"), memory_strings(request, "sources"),
    @base.text(@base.field(request, "at")), key, previous, "memory-submit")
}

pub fn memory_supersede(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  memory_id(id)
  let old = memory_load(store, id)
  if old.status == "superseded" { @base.fail("memory_superseded_note_refused") }
  // Archiving is an explicit decision; leave it through memory-restore first.
  if old.status == "archived" { @base.fail("memory_archived_note_refused") }
  let key = match optional(request, "key") {
    Some(value) => { let value = @base.text(value); memory_key(value); value }
    None => old.key
  }
  memory_write(store, entries, old.kind, old.scope, @base.text(@base.field(request, "text")),
    memory_strings(request, "conditions"), memory_strings(request, "sources"),
    @base.text(@base.field(request, "at")), key, Some(old), "memory-supersede")
}

// A5-style prefetch: rank durable notes against the incoming request and hand
// the host a bounded brief that still carries each judgment's applicability
// conditions and source validity. Selection stays with the external agent.
pub fn memory_prefetch(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  // A host that already knows which page it is working on should not have to
  // distil a query from it. A page seed is derived from the page itself with the
  // same tokenizer the ranking uses, so it stays deterministic.
  let page_seed = match optional(request, "page") {
    Some(value) => Some(@base.text(value))
    None => None
  }
  let explicit_query = match optional(request, "query") {
    Some(value) => Some(@base.text(value))
    None => None
  }
  if page_seed is None && explicit_query is None {
    @base.fail("memory_query_required: query or page")
  }
  if page_seed is Some(_) && explicit_query is Some(_) {
    @base.fail("memory_query_exclusive: query or page, not both")
  }
  let query = match explicit_query {
    Some(value) => value
    None => {
      let id = page_seed.unwrap()
      @base.path(id)
      let entry = @core.find(entries, id)
      if !@core.is_page(entry) { @base.fail("memory_page_required") }
      let page = @core.parse_page(@vault.required(store, entry.path))
      // The title carries most of the topic; the body supplies the rest. Both
      // are capped so one huge page cannot dominate the seed.
      let seed = page.title + " " + page.body
      if seed.length() > 4096 { seed[:4096].to_owned() } else { seed }
    }
  }
  if query.is_empty() || query.length() > 4096 || query.contains("\r") { @base.fail("memory_query_invalid") }
  let limit = match optional(request, "limit") {
    Some(value) => match value {
      Number(n, ..) if n >= 1.0 && n <= 50.0 && n == n.to_int().to_double() => n.to_int()
      _ => raise @base.Fault("memory_limit_invalid: integer 1..50")
    }
    None => 10
  }
  let archived = match optional(request, "archived") {
    Some(value) => @base.boolean(value)
    None => false
  }
  let dedup = match optional(request, "dedup") {
    Some(value) => {
      let value = @base.text(value)
      // `exact` is not offered: identical note text is already refused at submit
      // time, so the only merge left is the deterministic similar one.
      if !["none", "similar"].contains(value) { @base.fail("memory_dedup_unsupported: " + value) }
      value
    }
    None => "none"
  }
  let kinds = memory_strings(request, "kinds")
  for kind in kinds {
    if !memory_kinds().contains(kind) { @base.fail("memory_kind_unsupported: " + kind) }
  }
  // The op verified once at the top; the row helper and overview status must
  // not each re-hash every file in the vault.
  let rows = memory_rows_unchecked(store, entries).filter(n =>
    (if archived { n.status != "superseded" } else { n.status == "active" }) &&
    (kinds.is_empty() || kinds.contains(n.kind)))
  let documents : Array[@index.Document] = []
  for note in rows {
    let haystack = note.text + " " + note.conditions.join(" ") + " " + note.sources.join(" ")
    documents.push({ id: note.id, title: note.kind, body: haystack,
      title_terms: @index.tokens(note.kind), body_terms: @index.tokens(haystack) })
  }
  let hits = @index.search_index(@index.build_index(documents), query, limit~)
  let by_id : Map[String, MemoryNote] = Map([])
  for note in rows { by_id[note.id] = note }
  let conflicted = memory_conflicted(rows)
  let notes : Array[Json] = []
  let surfaced : Array[MemoryNote] = []
  let keepers : Array[(String, Array[String], String, String)] = []
  let similar_duplicates : Array[Json] = []
  let mut used = 0
  let mut truncated = false
  for hit in hits {
    match by_id.get(hit.id) {
      None => ()
      Some(note) => {
        let estimate = @base.estimate_tokens(note.text)
        if !notes.is_empty() && used + estimate > 4096 { truncated = true; continue }
        // A5's Autodream merges duplicate information instead of letting a
        // reworded judgment crowd out distinct ones from the budget. A note in
        // an unresolved conflict is never merged: dropping one side would hide
        // the competing judgment the host has to confirm. The same words under a
        // different kind or scope are a different sort of judgment, so they are
        // not duplicates either -- `memory-candidates` applies the same rule.
        if dedup == "similar" && @index.similar_eligible(note.text) &&
          !conflicted.get(note.id).unwrap_or(false) {
          let tokens = @index.similar_tokens(note.text)
          let mut keeper = ""
          for kept in keepers {
            if kept.2 == note.kind && kept.3 == note.scope &&
              @index.similar_merge(tokens, kept.1) { keeper = kept.0 }
          }
          if keeper != "" {
            similar_duplicates.push({ "duplicate": note.id, "keeper": keeper })
            continue
          }
          keepers.push((note.id, tokens, note.kind, note.scope))
        }
        used += estimate
        surfaced.push(note)
        match memory_view(note, entries, conflicted.get(note.id).unwrap_or(false)) {
          Object(fields) => {
            fields["score"] = hit.score.to_json()
            fields["excerpt"] = hit.excerpt.to_json()
            notes.push(Json::object(fields))
          }
          other => notes.push(other)
        }
      }
    }
  }
  // A5 surfaces an unresolved conflict when it becomes relevant again, so the
  // competing judgments travel with the candidates instead of waiting for a
  // separate maintenance pass.
  let conflict_groups = memory_conflict_groups(surfaced)
  let mut purpose = @vault.required(store, "purpose.md")
  if purpose.length() > 8192 { purpose = purpose[:8192].to_owned(); truncated = true }
  let synthesis_status = overview_status_unchecked(store, entries)
  let mut synthesis = ""
  match overview_page_entry(entries) {
    None => ()
    Some(entry) => {
      synthesis = @vault.required(store, entry.path)
      if synthesis.length() > 8192 { synthesis = synthesis[:8192].to_owned(); truncated = true }
    }
  }
  {
    "query": query,
    "query_seed": match page_seed {
      None => "query".to_json()
      Some(id) => ("page:" + id).to_json()
    },
    "fingerprint": @vault.fingerprint(entries),
    "candidates": hits.length(),
    "notes": notes.to_json(),
    "conflicts": conflict_groups.map(g => memory_conflict_view(g, entries)).to_json(),
    "conflict_counts": memory_conflict_counts(conflict_groups),
    "dedup": dedup,
    "similar_duplicates": similar_duplicates.to_json(),
    "overview": { "purpose": purpose, "synthesis": synthesis, "synthesis_status": synthesis_status },
    "estimated_tokens": used + @base.estimate_tokens(purpose) + @base.estimate_tokens(synthesis),
    "estimate_recipe": "cjk_char_latin_word_v1",
    "truncated": truncated,
    "selection": "host_required",
  }
}
