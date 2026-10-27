fn overview_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/overview/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

fn overview_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  overview_entries(entries).map(e => @base.parse(@vault.required(store, e.path)))
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
fn overview_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  overview_rows_unchecked(store, entries)
}

fn overview_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") { @base.fail("overview_time_invalid") }
}

fn overview_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("overview_idempotency_key_invalid")
  }
}

fn overview_page_hashes(entries : Array[@core.Entry]) -> Map[String, String] {
  let hashes : Map[String, String] = Map([])
  for entry in entries {
    if @core.is_page(entry) && !entry.stale && entry.id != "overview" { hashes[entry.id] = entry.sha256 }
  }
  hashes
}

// The digest of the exact inputs an overview suggestion froze. Callers that
// compare a stored record against the live vault must reuse this recipe.
pub fn overview_digest(purpose_hash : String, page_hashes : Map[String, String]) -> String {
  @base.hex_hash(@base.canonical({ "purpose_hash": purpose_hash, "page_hashes": page_hashes.to_json() }))
}

fn overview_inputs(entries : Array[@core.Entry], purpose_hash : String) -> String {
  overview_digest(purpose_hash, overview_page_hashes(entries))
}

fn overview_page_entry(entries : Array[@core.Entry]) -> @core.Entry? {
  for entry in entries { if entry.id == "overview" && @core.is_page(entry) && !entry.stale { return Some(entry) } }
  None
}

// The caller must have verified the vault already: `status`/`stats` verify once
// and then aggregate every source themselves.
fn overview_status_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> String raise @base.Fault {
  let page = match overview_page_entry(entries) {
    None => None
    Some(entry) => Some(entry)
  }
  let current_purpose = @base.hex_hash(@vault.required(store, "purpose.md"))
  let current_pages = overview_page_hashes(entries)
  let mut pending = false
  let mut applied = false
  for row in overview_rows_unchecked(store, entries) {
    let status = @base.text(@base.field(row, "status"))
    if status == "proposed" { pending = true }
    if status == "applied" {
      applied = true
      if page is Some(entry) && @base.field(row, "purpose_hash") == current_purpose.to_json() &&
        @base.field(row, "page_hashes") == current_pages.to_json() &&
        @base.text(@base.field(row, "result_hash")) == entry.sha256 {
        return "current"
      }
    }
  }
  if pending { "pending" } else if applied { "stale" } else { "missing" }
}

fn overview_suggest(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let at = @base.text(@base.field(request, "at"))
  overview_time(at)
  let purpose = @vault.required(store, "purpose.md")
  let purpose_hash = @base.hex_hash(purpose)
  let baseline = @vault.fingerprint(entries)
  let page_hashes = overview_page_hashes(entries)
  let input_hash = overview_inputs(entries, purpose_hash)
  let key = match optional(request, "key") {
    Some(value) => { let value = @base.text(value); overview_key(value); value }
    None => @base.hex_hash("overview-suggest-v1\n" + input_hash)
  }
  let id = @base.hex_hash("overview-suggest-v1\n" + key)
  let path = "state/overview/" + id + ".json"
  for row in overview_rows(store, entries) {
    if @base.text(@base.field(row, "key")) == key {
      if @base.text(@base.field(row, "purpose_hash")) == purpose_hash &&
        @base.field(row, "page_hashes") == page_hashes.to_json() {
        return { "id": id, "path": path, "status": @base.text(@base.field(row, "status")),
          "replayed": true, "execution": "host_required", "record": row }
      }
      @base.fail("overview_key_conflict")
    }
  }
  let record : Json = { "id": id, "baseline": baseline, "purpose_hash": purpose_hash,
    "page_hashes": page_hashes.to_json(), "created_at": at, "status": "proposed", "key": key,
    "closed_at": Json::null(), "result_hash": Json::null() }
  let content = @base.canonical(record)
  let event_path = "state/events/overview-suggest-" + id + ".json"
  let event : Json = { "op": "overview-suggest", "suggestion": id, "at": at, "key": key,
    "baseline": baseline, "purpose_hash": purpose_hash }
  let event_content = @base.canonical(event)
  if (store.read)(path) is Some(_) || (store.read)(event_path) is Some(_) { @base.fail("overview_record_conflict") }
  let entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(entries, entry), event_entry)
  @vault.commit(store, baseline, next, [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  let g = graph_unchecked(store, entries)
  let current_overview = match overview_page_entry(entries) {
    None => Json::null()
    Some(e) => @vault.required(store, e.path).to_json()
  }
  { "id": id, "path": path, "status": "proposed", "replayed": false,
    "execution": "host_required", "overview": current_overview,
    "purpose": purpose, "context": { "baseline": baseline, "purpose_hash": purpose_hash,
      "page_hashes": page_hashes.to_json(), "graph": g.to_json(), "insights": @index.insights(g) },
    "record": record }
}

fn overview_apply(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_overview_id") }
  let at = @base.text(@base.field(request, "at"))
  overview_time(at)
  let raw_text = @base.text(@base.field(request, "text"))
  if raw_text.is_empty() || raw_text.length() > 1048576 || raw_text.contains("\r") { @base.fail("overview_text_invalid") }
  let new_text = if raw_text.has_suffix("\n") { raw_text } else { raw_text + "\n" }
  let page = @core.parse_page(new_text)
  if page.kind != "synthesis" || page.title.is_empty() || page.sources.is_empty() { @base.fail("overview_page_required") }
  let seen : Map[String, Bool] = Map([])
  for source in page.sources {
    if seen.contains(source) { @base.fail("overview_source_invalid") }
    seen[source] = true
    let source_entry = @core.find(entries, source)
    if source_entry.kind != "raw" || source_entry.stale || (store.digest)(source) != Some(source_entry.sha256) {
      @base.fail("overview_source_not_active: " + source)
    }
  }
  let path = "state/overview/" + id + ".json"
  let suggestion_entry = @core.find(entries, path)
  let before_suggestion = @vault.required(store, path)
  let old = @base.parse(before_suggestion)
  let status = @base.text(@base.field(old, "status"))
  let result_hash = @base.hex_hash(new_text)
  if status == "applied" && @base.field(old, "result_hash") == result_hash.to_json() && @base.field(old, "closed_at") == at.to_json() {
    return { "id": id, "status": "applied", "replayed": true, "result_hash": result_hash }
  }
  if status != "proposed" { @base.fail("overview_terminal") }
  let baseline = @base.text(@base.field(old, "baseline"))
  let purpose_hash = @base.text(@base.field(old, "purpose_hash"))
  let current_pages = overview_page_hashes(entries)
  let purpose_entry = @core.find(entries, "purpose.md")
  if @base.hex_hash(@vault.required(store, "purpose.md")) != purpose_hash || purpose_entry.sha256 != purpose_hash || current_pages.to_json() != @base.field(old, "page_hashes") {
    @base.fail("overview_suggestion_stale")
  }
  let suggestion_event = "state/events/overview-suggest-" + id + ".json"
  let context_entries = entries.filter(e => e.id != path && e.id != suggestion_event)
  if @vault.fingerprint(context_entries) != baseline { @base.fail("overview_suggestion_stale") }
  let next_record = match old {
    Object(fields) => {
      fields["status"] = "applied".to_json()
      fields["closed_at"] = at.to_json()
      fields["result_hash"] = result_hash.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("invalid_overview_record")
  }
  let record_content = @base.canonical(next_record)
  let overview_before = (store.read)("wiki/overview.md")
  let overview_entry : @core.Entry = { id: "overview", path: "wiki/overview.md", kind: "synthesis", format: "markdown", sha256: result_hash, sources: page.sources, stale: false }
  let event_path = "state/events/overview-apply-" + id + "-" + result_hash + ".json"
  let event : Json = { "op": "overview-apply", "suggestion": id, "at": at, "result_hash": result_hash, "sources": page.sources.to_json() }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("overview_event_conflict") }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(upsert(entries, overview_entry), { ..suggestion_entry, sha256: @base.hex_hash(record_content) }), event_entry)
  let changes : Array[@vault.Change] = [
    { path: "wiki/overview.md", before: overview_before, after: Some(new_text) },
    { path, before: Some(before_suggestion), after: Some(record_content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  with_views(store, next, changes, "## [" + at + "] overview | " + id + "\n")
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": "applied", "replayed": false, "result_hash": result_hash,
    "sources": page.sources.to_json(), "event": event_path }
}

// Same reason as purpose-cancel: a suggestion whose frozen inputs moved can
// never be applied, and nothing else removes it from the pending set.
pub fn overview_cancel(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_overview_id") }
  let at = @base.text(@base.field(request, "at"))
  overview_time(at)
  let path = "state/overview/" + id + ".json"
  let before = @vault.required(store, path)
  let old = @base.parse(before)
  let status = @base.text(@base.field(old, "status"))
  if status == "cancelled" {
    return { "id": id, "status": "cancelled", "replayed": true }
  }
  if status != "proposed" { @base.fail("overview_terminal") }
  let next = match old {
    Object(fields) => {
      fields["status"] = "cancelled".to_json()
      fields["closed_at"] = at.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("invalid_overview_record")
  }
  let content = @base.canonical(next)
  let event_path = "state/events/overview-cancel-" + id + "-" + @base.hex_hash(at) + ".json"
  let event : Json = { "op": "overview-cancel", "suggestion": id, "at": at }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("overview_event_conflict") }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries),
    upsert(upsert(entries, { ..@core.find(entries, path), sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) },
     { path: event_path, before: None, after: Some(event_content) }])
  { "id": id, "status": "cancelled", "replayed": false, "event": event_path }
}
