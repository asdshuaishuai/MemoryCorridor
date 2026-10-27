fn research_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/research/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

fn research_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  research_entries(entries).map(e => @base.parse(@vault.required(store, e.path)))
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
fn research_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  research_rows_unchecked(store, entries)
}

fn research_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("research_time_invalid")
  }
}

fn research_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("research_idempotency_key_invalid")
  }
}

fn research_status(row : Json) -> String raise @base.Fault {
  @base.text(@base.field(row, "status"))
}

fn research_topic(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let topic = @base.text(@base.field(request, "topic"))
  if topic.is_empty() || topic.length() > 512 || topic.contains("\n") || topic.contains("\r") {
    @base.fail("research_topic_invalid")
  }
  let query_value = @base.field(request, "queries")
  let queries = @base.strings(query_value)
  if queries.length() < 1 || queries.length() > 16 { @base.fail("research_queries_count_invalid") }
  for query in queries {
    if query.is_empty() || query.length() > 256 || query.contains("\n") || query.contains("\r") {
      @base.fail("research_query_invalid")
    }
  }
  let at = @base.text(@base.field(request, "at"))
  research_time(at)
  let key = match optional(request, "key") {
    Some(value) => {
      let value = @base.text(value)
      research_key(value)
      value
    }
    None => @base.hex_hash("research-topic-v1\n" + topic + "\n" + @base.canonical(query_value))
  }
  let id = @base.hex_hash("research-topic-v1\n" + key)
  let path = "state/research/" + id + ".json"
  for row in research_rows(store, entries) {
    if @base.text(@base.field(row, "key")) == key {
      if @base.text(@base.field(row, "topic")) == topic &&
        @base.field(row, "queries") == query_value {
        return { "id": id, "path": path, "status": research_status(row), "replayed": true,
          "execution": "host_required", "record": row }
      }
      @base.fail("research_key_conflict")
    }
  }
  if (store.read)(path) is Some(_) { @base.fail("research_record_conflict") }
  let baseline = @vault.fingerprint(entries)
  // The knowledge fingerprint covers purpose, raw, pages and vectors but not
  // state records: filing more work must not look like new research material.
  let inputs_hash = knowledge_fingerprint(entries)
  let record : Json = { "id": id, "topic": topic, "queries": queries.to_json(),
    "baseline": baseline, "inputs_hash": inputs_hash, "created_at": at, "status": "proposed", "key": key,
    "closed_at": Json::null(), "sources": Json::array([]) }
  let content = @base.canonical(record)
  let event_path = "state/events/research-" + id + ".json"
  let event : Json = { "op": "research-topic", "research": id, "topic": topic,
    "queries": queries.to_json(), "at": at, "key": key }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("research_event_conflict") }
  let record_entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(entries, record_entry), event_entry)
  @vault.commit(store, baseline, next, [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "path": path, "status": "proposed", "replayed": false,
    "execution": "host_required", "record": record }
}

fn close_research(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json, completed : Bool,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail("invalid_research_id")
  }
  let at = @base.text(@base.field(request, "at"))
  research_time(at)
  let sources = if completed {
    let values = @base.strings(@base.field(request, "sources"))
    if values.length() < 1 || values.length() > 64 { @base.fail("research_sources_count_invalid") }
    let seen : Map[String, Bool] = Map([])
    for source in values {
      @base.path(source)
      if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("research_source_invalid") }
      seen[source] = true
      let entry = @core.find(entries, source)
      if entry.kind != "raw" || entry.stale || (store.digest)(source) != Some(entry.sha256) { @base.fail("research_source_not_active: " + source) }
    }
    values
  } else { [] }
  let path = "state/research/" + id + ".json"
  let entry = @core.find(entries, path)
  let before = @vault.required(store, path)
  let old = @base.parse(before)
  let old_status = research_status(old)
  let target = if completed { "completed" } else { "cancelled" }
  let old_closed = match @base.field(old, "closed_at") {
    String(value) => value
    Null => ""
    _ => raise @base.Fault("research_closed_at_invalid")
  }
  if old_status == target && old_closed == at && @base.field(old, "sources") == sources.to_json() {
    return { "id": id, "status": target, "replayed": true }
  }
  if old_status != "proposed" { @base.fail("research_terminal") }
  let next = match old {
    Object(fields) => {
      fields["status"] = target.to_json()
      fields["closed_at"] = at.to_json()
      fields["sources"] = sources.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("invalid_research_record")
  }
  let content = @base.canonical(next)
  let event_path = "state/events/research-" + target + "-" + id + "-" + @base.hex_hash(at + "\n" + @base.canonical(sources.to_json())) + ".json"
  let event : Json = { "op": "research-" + target, "research": id, "at": at, "sources": sources.to_json() }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("research_event_conflict") }
      let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next_entries = upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry)
  @vault.commit(store, @vault.fingerprint(entries), next_entries, [
    { path, before: Some(before), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "status": target, "replayed": false, "event": event_path,
    "sources": sources.to_json() }
}
