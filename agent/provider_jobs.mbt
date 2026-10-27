// Provider jobs are durable handoff envelopes. The engine records the exact
// request and lifecycle, and commits only validated result shapes; a host owns
// process execution and model semantics.
fn provider_job_path(id : String) -> String {
  "state/provider-jobs/" + id + ".json"
}

fn provider_job_hash(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c =>
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

fn provider_job_event_path(kind : String, id : String) -> String {
  "state/events/provider-job-" + kind + "-" + id + ".json"
}

fn provider_job_time(value : String, field : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("provider_job_time_invalid: " + field)
  }
}

fn provider_job_key(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
    @base.fail("provider_job_key_invalid")
  }
}

fn provider_job_payload(value : Json) -> String raise @base.Fault {
  let encoded = @base.canonical(value)
  if encoded.length() > 262144 { @base.fail("provider_job_payload_too_large") }
  encoded
}

fn provider_job_error(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 4096 || value.contains("\n") || value.contains("\r") {
    @base.fail("provider_job_error_invalid")
  }
}

fn provider_job_worker(value : String) -> Unit raise @base.Fault {
  provider_job_key(value)
}

// Timestamps are required to be canonical, caller-supplied ISO strings. Their
// lexical order is therefore the engine's deterministic lease comparison.
fn provider_job_lease_active(at : String, lease_until : String) -> Bool {
  @base.compare(at, lease_until) <= 0
}

fn validate_provider_job_request(kind : String, value : Json) -> Unit raise @base.Fault {
  if kind == "embedding" {
    @base.keys(value, ["items", "text_recipe"])
    let items = @base.array(@base.field(value, "items"))
    if items.is_empty() || items.length() > 128 { @base.fail("provider_job_items_invalid") }
    for item in items {
      @base.keys(item, ["page", "sha256", "text", "truncated"])
      let page = @base.text(@base.field(item, "page"))
      let sha = @base.text(@base.field(item, "sha256"))
      let text = @base.text(@base.field(item, "text"))
      if page.is_empty() || page.length() > 1024 || !provider_job_hash(sha) || text.length() > 16384 {
        @base.fail("provider_job_embedding_item_invalid")
      }
      ignore(@base.boolean(@base.field(item, "truncated")))
    }
    if @base.text(@base.field(value, "text_recipe")) != "title-body-prefix16KiB-v1" {
      @base.fail("provider_job_text_recipe_invalid")
    }
  } else {
    @base.keys(value, ["query", "limit"])
    let query = @base.text(@base.field(value, "query"))
    if query.length() > 4096 { @base.fail("provider_job_query_too_large") }
    match @base.field(value, "limit") {
      Number(n, ..) if n >= 1.0 && n <= 100.0 && n == n.to_int().to_double() => ()
      _ => @base.fail("provider_job_limit_invalid")
    }
  }
}

fn validate_embedding_job_pages(store : @vault.Storage, entries : Array[@core.Entry], value : Json) -> Unit raise @base.Fault {
  let items = @base.array(@base.field(value, "items"))
  let seen : Map[String, Bool] = Map([])
  for item in items {
    let page = @base.text(@base.field(item, "page"))
    if seen.contains(page) { @base.fail("provider_job_request_duplicate_page") }
    seen[page] = true
    let entry = @core.find(entries, page)
    if !@core.is_page(entry) || entry.stale { @base.fail("provider_job_page_not_active: " + page) }
    if @base.text(@base.field(item, "sha256")) != entry.sha256 { @base.fail("provider_job_page_version_mismatch: " + page) }
    let (expected_text, expected_truncated) = embedding_task_text(store, entry)
    if @base.text(@base.field(item, "text")) != expected_text ||
      @base.boolean(@base.field(item, "truncated")) != expected_truncated {
      @base.fail("provider_job_embedding_text_mismatch: " + page)
    }
  }
}

fn validate_embedding_job_result(old : Json, result : Json) -> Array[Json] raise @base.Fault {
  @base.keys(result, ["items"])
  let requested = @base.array(@base.field(@base.field(old, "request"), "items"))
  let items = @base.array(@base.field(result, "items"))
  if items.length() != requested.length() || items.is_empty() || items.length() > 128 {
    @base.fail("provider_job_result_items_invalid")
  }
  let expected : Map[String, String] = Map([])
  for item in requested {
    let page = @base.text(@base.field(item, "page"))
    if expected.contains(page) { @base.fail("provider_job_request_duplicate_page") }
    expected[page] = @base.text(@base.field(item, "sha256"))
  }
  let seen : Map[String, Bool] = Map([])
  for item in items {
    @base.keys(item, ["page", "sha256", "values", "values_b64"])
    let page = @base.text(@base.field(item, "page"))
    let sha = @base.text(@base.field(item, "sha256"))
    if !expected.contains(page) || expected[page] != sha || seen.contains(page) { @base.fail("provider_job_result_page_mismatch: " + page) }
    seen[page] = true
  }
  items
}

fn validate_search_job_result(entries : Array[@core.Entry], old : Json, result : Json) -> Unit raise @base.Fault {
  let (hits, space) = external_candidates(entries, result)
  let expected = @index.space_from_json(@base.field(old, "space"))
  if space != expected { @base.fail("provider_job_result_space_mismatch") }
  ignore(hits)
}

fn provider_job_row(value : Json) -> Json raise @base.Fault {
  @base.keys(value, ["id", "provider", "kind", "space", "key", "request", "request_hash", "status", "created_at", "updated_at", "closed_at", "result", "result_hash", "error", "worker", "lease_until"])
  let id = @base.text(@base.field(value, "id"))
  if !provider_job_hash(id) { @base.fail("provider_job_id_invalid") }
  let kind = @base.text(@base.field(value, "kind"))
  if !["embedding", "search"].contains(kind) { @base.fail("provider_job_kind_invalid") }
  let space = @index.space_from_json(@base.field(value, "space"))
  provider_job_key(@base.text(@base.field(value, "key")))
  let request = @base.field(value, "request")
  validate_provider_job_request(kind, request)
  let request_hash = @base.text(@base.field(value, "request_hash"))
  if request_hash != @base.hex_hash(@base.canonical(request)) { @base.fail("provider_job_request_hash_invalid") }
  let status = @base.text(@base.field(value, "status"))
  if !["pending", "completed", "cancelled", "failed"].contains(status) { @base.fail("provider_job_status_invalid") }
  for field in ["created_at", "updated_at"] { provider_job_time(@base.text(@base.field(value, field)), field) }
  let closed = @base.field(value, "closed_at")
  let result = @base.field(value, "result")
  let result_hash = @base.field(value, "result_hash")
  let error = match value {
    Object(fields) => fields.get("error").unwrap_or(Json::null())
    _ => Json::null()
  }
  let worker = match optional(value, "worker") {
    None => Json::null()
    Some(v) => if v == Json::null() { Json::null() } else { provider_job_worker(@base.text(v)); v }
  }
  let lease_until = match optional(value, "lease_until") {
    None => Json::null()
    Some(v) => if v == Json::null() { Json::null() } else { let at = @base.text(v); provider_job_time(at, "lease_until"); v }
  }
  if (worker == Json::null()) != (lease_until == Json::null()) {
    @base.fail("provider_job_lease_pair_invalid")
  }
  if status == "pending" {
    if closed != Json::null() || result != Json::null() || result_hash != Json::null() || error != Json::null() { @base.fail("provider_job_pending_invalid") }
  } else {
    provider_job_time(@base.text(closed), "closed_at")
    if status == "completed" {
      if result == Json::null() || result_hash == Json::null() || error != Json::null() || @base.text(result_hash) != @base.hex_hash(@base.canonical(result)) {
        @base.fail("provider_job_result_invalid")
      }
      ignore(provider_job_payload(result))
    } else if status == "cancelled" {
      if result != Json::null() || result_hash != Json::null() || error != Json::null() { @base.fail("provider_job_cancelled_result") }
    } else {
      if result != Json::null() || result_hash != Json::null() { @base.fail("provider_job_failed_result") }
      provider_job_error(@base.text(error))
    }
  }
  ignore(space)
  match value {
    Object(fields) => {
      if !fields.contains("error") { fields["error"] = Json::null() }
      if !fields.contains("worker") { fields["worker"] = Json::null() }
      if !fields.contains("lease_until") { fields["lease_until"] = Json::null() }
      Json::object(fields)
    }
    _ => value
  }
}

fn provider_job_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/provider-jobs/") {
      rows.push(provider_job_row(@base.parse(@vault.required(store, entry.path))))
    }
  }
  rows
}

fn provider_job_open(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "provider", "kind", "space", "request", "at", "key"])
  let provider = @base.text(@base.field(request, "provider"))
  let kind = @base.text(@base.field(request, "kind"))
  provider_kind(kind)
  let space = @index.space_from_json(@base.field(request, "space"))
  ignore(provider_for(store, entries, provider, kind, space))
  let payload = @base.field(request, "request")
  validate_provider_job_request(kind, payload)
  if kind == "embedding" { validate_embedding_job_pages(store, entries, payload) }
  let key = match optional(request, "key") {
    Some(value) => @base.text(value)
    None => @base.hex_hash(provider + "\n" + kind + "\n" + @base.canonical(payload))
  }
  provider_job_key(key)
  let at = @base.text(@base.field(request, "at"))
  provider_job_time(at, "at")
  let id = @base.hex_hash("provider-job-v1\n" + provider + "\n" + key)
  let path = provider_job_path(id)
  let request_hash = @base.hex_hash(@base.canonical(payload))
  let row : Json = { "id": id, "provider": provider, "kind": kind, "space": space.to_json(), "key": key,
    "request": payload, "request_hash": request_hash, "status": "pending", "created_at": at,
    "updated_at": at, "closed_at": Json::null(), "result": Json::null(), "result_hash": Json::null(), "error": Json::null(),
    "worker": Json::null(), "lease_until": Json::null() }
  match (store.read)(path) {
    Some(existing) => {
      let old = provider_job_row(@base.parse(existing))
      if old == row { return { "id": id, "status": "pending", "replayed": true, "provider": provider } }
      @base.fail("provider_job_key_conflict: " + key)
    }
    None => ()
  }
  let event_path = provider_job_event_path("open", id)
  let event : Json = { "op": "provider-job-open", "id": id, "provider": provider, "kind": kind, "at": at }
  let event_text = @base.canonical(event)
  let entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(@base.canonical(row)), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, entry), event_entry),
    [{ path, before: None, after: Some(@base.canonical(row)) }, { path: event_path, before: None, after: Some(event_text) }])
  { "id": id, "status": "pending", "replayed": false, "provider": provider, "kind": kind, "request_hash": request_hash }
}

fn provider_job_guard_owner(old : Json, request : Json, at : String, allow_expired : Bool) -> Unit raise @base.Fault {
  match optional(old, "worker") {
    None => ()
    Some(value) if value == Json::null() => ()
    Some(owner_value) => {
      let owner = @base.text(owner_value)
      let worker = match optional(request, "worker") {
        Some(value) => { let value = @base.text(value); provider_job_worker(value); value }
        None => { @base.fail("provider_job_worker_required"); "" }
      }
      if worker != owner { @base.fail("provider_job_worker_mismatch") }
      let lease_until = @base.text(@base.field(old, "lease_until"))
      if !allow_expired && !provider_job_lease_active(at, lease_until) {
        @base.fail("provider_job_lease_expired")
      }
    }
  }
}

fn provider_job_claim(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "worker", "lease_until", "at"])
  let id = @base.text(@base.field(request, "id"))
  if !provider_job_hash(id) { @base.fail("provider_job_id_invalid") }
  let worker = @base.text(@base.field(request, "worker"))
  provider_job_worker(worker)
  let lease_until = @base.text(@base.field(request, "lease_until"))
  provider_job_time(lease_until, "lease_until")
  let at = @base.text(@base.field(request, "at"))
  provider_job_time(at, "at")
  if !provider_job_lease_active(at, lease_until) || at == lease_until { @base.fail("provider_job_lease_invalid") }
  let path = provider_job_path(id)
  let before = @vault.required(store, path)
  let old = provider_job_row(@base.parse(before))
  if @base.text(@base.field(old, "status")) != "pending" { @base.fail("provider_job_terminal") }
  match optional(old, "worker") {
    Some(value) if value != Json::null() => {
      let owner = @base.text(value)
      let current_lease = @base.text(@base.field(old, "lease_until"))
      if owner == worker && current_lease == lease_until { return { "id": id, "status": "pending", "worker": worker, "lease_until": lease_until, "replayed": true } }
      if provider_job_lease_active(at, current_lease) { @base.fail("provider_job_already_claimed") }
    }
    _ => ()
  }
  let next = match old {
    Object(fields) => { fields["worker"] = worker.to_json(); fields["lease_until"] = lease_until.to_json(); fields["updated_at"] = at.to_json(); Json::object(fields) }
    _ => raise @base.Fault("provider_job_record_invalid")
  }
  let content = @base.canonical(next)
  let event_path = provider_job_event_path("claim-" + @base.hex_hash(worker + "\n" + at + "\n" + lease_until), id)
  let event_text = @base.canonical({ "op": "provider-job-claim", "id": id, "worker": worker, "lease_until": lease_until, "at": at })
  let entry = @core.find(entries, path)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) }, { path: event_path, before: None, after: Some(event_text) }])
  { "id": id, "status": "pending", "worker": worker, "lease_until": lease_until, "replayed": false, "event": event_path }
}

fn provider_job_heartbeat(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "worker", "lease_until", "at"])
  let id = @base.text(@base.field(request, "id"))
  if !provider_job_hash(id) { @base.fail("provider_job_id_invalid") }
  let worker = @base.text(@base.field(request, "worker")); provider_job_worker(worker)
  let lease_until = @base.text(@base.field(request, "lease_until")); provider_job_time(lease_until, "lease_until")
  let at = @base.text(@base.field(request, "at")); provider_job_time(at, "at")
  if !provider_job_lease_active(at, lease_until) || at == lease_until { @base.fail("provider_job_lease_invalid") }
  let path = provider_job_path(id)
  let before = @vault.required(store, path)
  let old = provider_job_row(@base.parse(before))
  if @base.text(@base.field(old, "status")) != "pending" { @base.fail("provider_job_terminal") }
  match optional(old, "worker") {
    None => @base.fail("provider_job_worker_required")
    Some(value) if value == Json::null() => @base.fail("provider_job_worker_required")
    _ => ()
  }
  provider_job_guard_owner(old, request, at, false)
  if @base.text(@base.field(old, "lease_until")) == lease_until { return { "id": id, "status": "pending", "worker": worker, "lease_until": lease_until, "replayed": true } }
  let next = match old {
    Object(fields) => { fields["lease_until"] = lease_until.to_json(); fields["updated_at"] = at.to_json(); Json::object(fields) }
    _ => raise @base.Fault("provider_job_record_invalid")
  }
  let content = @base.canonical(next)
  let event_path = provider_job_event_path("heartbeat-" + @base.hex_hash(worker + "\n" + at + "\n" + lease_until), id)
  let event_text = @base.canonical({ "op": "provider-job-heartbeat", "id": id, "worker": worker, "lease_until": lease_until, "at": at })
  let entry = @core.find(entries, path)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) }, { path: event_path, before: None, after: Some(event_text) }])
  { "id": id, "status": "pending", "worker": worker, "lease_until": lease_until, "replayed": false, "event": event_path }
}

fn provider_job_close(store : @vault.Storage, entries : Array[@core.Entry], request : Json, complete : Bool) -> Json raise @base.Fault {
  let allowed = if complete { ["op", "vault", "request_id", "id", "result", "at", "worker"] } else { ["op", "vault", "request_id", "id", "at", "worker"] }
  @base.keys(request, allowed)
  let id = @base.text(@base.field(request, "id"))
  if !provider_job_hash(id) { @base.fail("provider_job_id_invalid") }
  let path = provider_job_path(id)
  let before = @vault.required(store, path)
  let old = provider_job_row(@base.parse(before))
  let provider = @base.text(@base.field(old, "provider"))
  let kind = @base.text(@base.field(old, "kind"))
  let space = @index.space_from_json(@base.field(old, "space"))
  ignore(provider_for(store, entries, provider, kind, space))
  let at = @base.text(@base.field(request, "at"))
  provider_job_time(at, "at")
  let next_status = if complete { "completed" } else { "cancelled" }
  if @base.text(@base.field(old, "status")) != "pending" {
    if @base.text(@base.field(old, "status")) == next_status && @base.text(@base.field(old, "closed_at")) == at {
      return { "id": id, "status": next_status, "replayed": true }
    }
    @base.fail("provider_job_terminal")
  }
  provider_job_guard_owner(old, request, at, false)
  let mut next_entries = entries.copy()
  let changes : Array[@vault.Change] = []
  let mut applied_vectors = 0
  if complete {
    let result = @base.field(request, "result")
    if result == Json::null() { @base.fail("provider_job_result_invalid") }
    if kind == "embedding" {
      let result_items = validate_embedding_job_result(old, result)
      let prepared = prepare_embeddings(store, entries, space.to_json(), result_items.to_json(), provider.to_json())
      next_entries = prepared.entries
      for change in prepared.changes { changes.push(change) }
      applied_vectors = prepared.submitted
    } else {
      validate_search_job_result(entries, old, result)
    }
  }
  let next = match old {
    Object(fields) => {
      fields["status"] = next_status.to_json(); fields["updated_at"] = at.to_json(); fields["closed_at"] = at.to_json()
      if complete {
        let result = @base.field(request, "result")
        ignore(provider_job_payload(result))
        fields["result"] = result; fields["result_hash"] = @base.hex_hash(@base.canonical(result)).to_json()
      }
      Json::object(fields)
    }
    _ => raise @base.Fault("provider_job_record_invalid")
  }
  let content = @base.canonical(next)
  let event_path = provider_job_event_path(next_status, id)
  let event : Json = { "op": "provider-job-" + next_status, "id": id, "provider": provider, "at": at }
  let event_text = @base.canonical(event)
  let entry = @core.find(next_entries, path)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  next_entries = upsert(upsert(next_entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry)
  changes.push({ path, before: Some(before), after: Some(content) })
  changes.push({ path: event_path, before: None, after: Some(event_text) })
  @vault.commit(store, @vault.fingerprint(entries), next_entries, changes)
  { "id": id, "status": next_status, "replayed": false, "event": event_path, "applied_vectors": applied_vectors }
}

fn provider_job_fail(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "error", "at", "worker"])
  let id = @base.text(@base.field(request, "id"))
  if !provider_job_hash(id) { @base.fail("provider_job_id_invalid") }
  let path = provider_job_path(id)
  let before = @vault.required(store, path)
  let old = provider_job_row(@base.parse(before))
  let at = @base.text(@base.field(request, "at"))
  provider_job_time(at, "at")
  let error = @base.text(@base.field(request, "error"))
  provider_job_error(error)
  let old_status = @base.text(@base.field(old, "status"))
  if old_status != "pending" {
    if old_status == "failed" && @base.text(@base.field(old, "closed_at")) == at && @base.text(@base.field(old, "error")) == error {
      return { "id": id, "status": "failed", "replayed": true }
    }
    @base.fail("provider_job_terminal")
  }
  // A claimed provider may report an expired lease as a deterministic timeout;
  // completion/cancellation remain forbidden after expiry.
  provider_job_guard_owner(old, request, at, true)
  let next = match old {
    Object(fields) => {
      fields["status"] = "failed".to_json(); fields["updated_at"] = at.to_json(); fields["closed_at"] = at.to_json(); fields["error"] = error.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("provider_job_record_invalid")
  }
  let content = @base.canonical(next)
  let event_path = provider_job_event_path("failed", id)
  let event : Json = { "op": "provider-job-failed", "id": id, "error": error, "at": at }
  let event_text = @base.canonical(event)
  let entry = @core.find(entries, path)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) }, { path: event_path, before: None, after: Some(event_text) }])
  { "id": id, "status": "failed", "replayed": false, "event": event_path }
}

pub fn provider_job_dispatch(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  match @base.text(@base.field(request, "op")) {
    "provider-job-open" => provider_job_open(store, entries, request)
    "provider-job-claim" => provider_job_claim(store, entries, request)
    "provider-job-heartbeat" => provider_job_heartbeat(store, entries, request)
    "provider-job-complete" => provider_job_close(store, entries, request, true)
    "provider-job-cancel" => provider_job_close(store, entries, request, false)
    "provider-job-fail" => provider_job_fail(store, entries, request)
    "provider-job-list" => provider_job_rows(store, entries).to_json()
    _ => raise @base.Fault("unknown_provider_job_operation")
  }
}

fn provider_job_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  provider_job_rows_unchecked(store, entries)
}
