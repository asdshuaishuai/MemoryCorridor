fn suggestion_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/suggestions/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

fn suggestion_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  suggestion_entries(entries).map(e => @base.parse(@vault.required(store, e.path)))
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
fn suggestion_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  suggestion_rows_unchecked(store, entries)
}

fn suggestion_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") { @base.fail("suggestion_time_invalid") }
}

fn suggestion_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("suggestion_idempotency_key_invalid")
  }
}

fn suggestion_status(row : Json) -> String raise @base.Fault {
  @base.text(@base.field(row, "status"))
}

fn purpose_suggest(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let at = @base.text(@base.field(request, "at"))
  suggestion_time(at)
  let purpose_entry = @core.find(entries, "purpose.md")
  let purpose_text = @vault.required(store, "purpose.md")
  let baseline = @vault.fingerprint(entries)
  let purpose_hash = @base.hex_hash(purpose_text)
  let key = match optional(request, "key") {
    Some(value) => { let value = @base.text(value); suggestion_key(value); value }
    None => @base.hex_hash("purpose-suggest-v1\n" + purpose_hash)
  }
  let id = @base.hex_hash("purpose-suggest-v1\n" + key)
  let path = "state/suggestions/" + id + ".json"
  for row in suggestion_rows(store, entries) {
    if @base.text(@base.field(row, "key")) == key {
      if @base.text(@base.field(row, "purpose_hash")) == purpose_hash {
        return { "id": id, "path": path, "status": suggestion_status(row), "replayed": true,
          "execution": "host_required", "record": row, "purpose": purpose_text }
      }
      @base.fail("suggestion_key_conflict")
    }
  }
  let record : Json = { "id": id, "kind": "purpose", "baseline": baseline,
    "purpose_hash": purpose_hash, "created_at": at, "status": "proposed", "key": key,
    "closed_at": Json::null(), "result_hash": Json::null() }
  let content = @base.canonical(record)
  let event_path = "state/events/purpose-suggest-" + id + ".json"
  let event : Json = { "op": "purpose-suggest", "suggestion": id, "at": at, "key": key,
    "baseline": baseline, "purpose_hash": purpose_hash }
  let event_content = @base.canonical(event)
  if (store.read)(path) is Some(_) || (store.read)(event_path) is Some(_) { @base.fail("suggestion_record_conflict") }
  let entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(entries, entry), event_entry)
  let g = graph_unchecked(store, entries)
  @vault.commit(store, baseline, next, [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "path": path, "status": "proposed", "replayed": false,
    "execution": "host_required", "purpose": purpose_text,
    "context": { "baseline": baseline, "purpose_hash": purpose_hash,
      "graph": g.to_json(), "insights": @index.insights(g) },
    "record": record, "purpose_entry": purpose_entry.to_json() }
}

fn purpose_apply(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_suggestion_id") }
  let at = @base.text(@base.field(request, "at"))
  suggestion_time(at)
  let raw_text = @base.text(@base.field(request, "text"))
  if raw_text.is_empty() || raw_text.length() > 65536 || raw_text.contains("\r") { @base.fail("purpose_text_invalid") }
  let new_text = if raw_text.has_suffix("\n") { raw_text } else { raw_text + "\n" }
  let path = "state/suggestions/" + id + ".json"
  let entry = @core.find(entries, path)
  let before = @vault.required(store, path)
  let old = @base.parse(before)
  let status = suggestion_status(old)
  let result_hash = @base.hex_hash(new_text)
  if status == "applied" && @base.field(old, "result_hash") == result_hash.to_json() &&
    @base.field(old, "closed_at") == at.to_json() {
    return { "id": id, "status": "applied", "replayed": true, "result_hash": result_hash }
  }
  if status != "proposed" { @base.fail("suggestion_terminal") }
  let baseline = @base.text(@base.field(old, "baseline"))
  let purpose_hash = @base.text(@base.field(old, "purpose_hash"))
  let purpose_entry = @core.find(entries, "purpose.md")
  let current_purpose = @vault.required(store, "purpose.md")
  let suggestion_event = "state/events/purpose-suggest-" + id + ".json"
  let context_entries = entries.filter(e => e.id != path && e.id != suggestion_event)
  if @vault.fingerprint(context_entries) != baseline || @base.hex_hash(current_purpose) != purpose_hash || purpose_entry.sha256 != purpose_hash {
    @base.fail("purpose_suggestion_stale")
  }
  let next_record = match old {
    Object(fields) => {
      fields["status"] = "applied".to_json()
      fields["closed_at"] = at.to_json()
      fields["result_hash"] = result_hash.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("invalid_suggestion_record")
  }
  let content = @base.canonical(next_record)
  let event_path = "state/events/purpose-apply-" + id + "-" + result_hash + ".json"
  let event : Json = { "op": "purpose-apply", "suggestion": id, "at": at, "result_hash": result_hash }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("suggestion_event_conflict") }
  let purpose_change : @vault.Change = { path: "purpose.md", before: Some(current_purpose), after: Some(new_text) }
  let purpose_updated = { ..purpose_entry, sha256: result_hash }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), purpose_updated)
  let next = upsert(next, event_entry)
  @vault.commit(store, @vault.fingerprint(entries), next, [
    purpose_change,
    { path, before: Some(before), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "status": "applied", "replayed": false, "result_hash": result_hash,
    "purpose": new_text, "event": event_path }
}

// A stranded suggestion can never be applied once its baseline moved, and
// nothing else closes it. Cancelling keeps the record and its frozen context
// for audit while removing it from the pending set.
pub fn purpose_cancel(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_suggestion_id") }
  let at = @base.text(@base.field(request, "at"))
  suggestion_time(at)
  let path = "state/suggestions/" + id + ".json"
  let before = @vault.required(store, path)
  let old = @base.parse(before)
  if suggestion_status(old) == "cancelled" {
    return { "id": id, "status": "cancelled", "replayed": true }
  }
  if suggestion_status(old) != "proposed" { @base.fail("suggestion_terminal") }
  let next = match old {
    Object(fields) => {
      fields["status"] = "cancelled".to_json()
      fields["closed_at"] = at.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("invalid_suggestion_record")
  }
  let content = @base.canonical(next)
  let event_path = "state/events/purpose-cancel-" + id + "-" + @base.hex_hash(at) + ".json"
  let event : Json = { "op": "purpose-cancel", "suggestion": id, "at": at }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("suggestion_event_conflict") }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries),
    upsert(upsert(entries, { ..@core.find(entries, path), sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) },
     { path: event_path, before: None, after: Some(event_content) }])
  { "id": id, "status": "cancelled", "replayed": false, "event": event_path }
}
