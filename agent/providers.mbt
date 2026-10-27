// Provider lifecycle records make the external model boundary explicit. The
// engine never starts a provider or calls a model; it only leases, validates,
// and audits the provider's declared space and submitted results.
fn provider_path(provider : String) -> String raise @base.Fault {
  if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") {
    @base.fail("provider_name_invalid")
  }
  "state/providers/" + @base.hex_hash("provider-v1\n" + provider) + ".json"
}

fn provider_time(value : String, field : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") { @base.fail("provider_time_invalid: " + field) }
}

fn provider_kind(value : String) -> Unit raise @base.Fault {
  if !["embedding", "search"].contains(value) { @base.fail("provider_kind_invalid") }
}

fn provider_row(value : Json) -> Json raise @base.Fault {
  @base.keys(value, ["id", "provider", "kind", "space", "capabilities", "protocol", "registered_at", "last_seen", "status", "closed_at"])
  ignore(@base.text(@base.field(value, "provider")))
  provider_kind(@base.text(@base.field(value, "kind")))
  ignore(@index.space_from_json(@base.field(value, "space")))
  let capabilities = @base.strings(@base.field(value, "capabilities"))
  if capabilities.is_empty() || capabilities.length() > 16 { @base.fail("provider_capabilities_invalid") }
  let seen : Map[String, Bool] = Map([])
  for capability in capabilities {
    if capability.is_empty() || capability.length() > 64 || capability.contains("\n") || seen.contains(capability) { @base.fail("provider_capability_invalid") }
    seen[capability] = true
  }
  let registered = @base.text(@base.field(value, "registered_at"))
  let last_seen = @base.text(@base.field(value, "last_seen"))
  provider_time(registered, "registered_at")
  provider_time(last_seen, "last_seen")
  let status = @base.text(@base.field(value, "status"))
  if !["active", "revoked"].contains(status) { @base.fail("provider_status_invalid") }
  if status == "active" && @base.field(value, "closed_at") != Json::null() { @base.fail("provider_active_closed") }
  if status == "revoked" { provider_time(@base.text(@base.field(value, "closed_at")), "closed_at") }
  value
}

fn provider_entries_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/providers/") {
      rows.push(provider_row(@base.parse(@vault.required(store, entry.path))))
    }
  }
  rows
}

fn provider_for(
  store : @vault.Storage, entries : Array[@core.Entry], provider : String,
  kind : String, space : @index.VectorSpace,
) -> Json raise @base.Fault {
  let path = provider_path(provider)
  let row = match (store.read)(path) {
    None => { @base.fail("provider_not_registered: " + provider); Json::null() }
    Some(text) => provider_row(@base.parse(text))
  }
  if @base.text(@base.field(row, "status")) != "active" { @base.fail("provider_not_active: " + provider) }
  if @base.text(@base.field(row, "kind")) != kind { @base.fail("provider_kind_mismatch: " + provider) }
  if @base.field(row, "space") != space.to_json() { @base.fail("provider_space_mismatch: " + provider) }
  if !entries.any(e => e.path == path && e.kind == "state") { @base.fail("provider_record_unregistered: " + provider) }
  row
}

fn provider_name(request : Json) -> String? raise @base.Fault {
  match optional(request, "provider") {
    None => None
    Some(Null) => None
    Some(value) => Some(@base.text(value))
  }
}

fn provider_register(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "provider", "kind", "space", "capabilities", "at"])
  let provider = @base.text(@base.field(request, "provider"))
  let kind = @base.text(@base.field(request, "kind"))
  provider_kind(kind)
  let space = @index.space_from_json(@base.field(request, "space"))
  let capabilities = @base.strings(@base.field(request, "capabilities"))
  if capabilities.is_empty() || capabilities.length() > 16 { @base.fail("provider_capabilities_invalid") }
  if kind == "embedding" && !capabilities.contains("embed") { @base.fail("provider_embed_capability_required") }
  if kind == "search" && !capabilities.contains("search") { @base.fail("provider_search_capability_required") }
  let at = @base.text(@base.field(request, "at"))
  provider_time(at, "at")
  let path = provider_path(provider)
  let id = @base.hex_hash("provider-v1\n" + provider)
  let row : Json = { "id": id, "provider": provider, "kind": kind, "space": space.to_json(),
    "capabilities": capabilities.to_json(), "protocol": "memorycorridor-provider-v1",
    "registered_at": at, "last_seen": at, "status": "active", "closed_at": Json::null() }
  match (store.read)(path) {
    Some(existing) => {
      let old = provider_row(@base.parse(existing))
      if old == row { return { "provider": provider, "status": "active", "replayed": true, "path": path } }
      @base.fail("provider_registration_conflict: " + provider)
    }
    None => ()
  }
  let event_path = "state/events/provider-register-" + id + ".json"
  let event : Json = { "op": "provider-register", "provider": provider, "kind": kind, "space": space.to_json(), "at": at }
  let event_text = @base.canonical(event)
  let entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(@base.canonical(row)), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, entry), event_entry),
    [{ path, before: None, after: Some(@base.canonical(row)) }, { path: event_path, before: None, after: Some(event_text) }])
  { "provider": provider, "status": "active", "replayed": false, "path": path, "protocol": "memorycorridor-provider-v1" }
}

fn provider_heartbeat(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "provider", "at"])
  let provider = @base.text(@base.field(request, "provider"))
  let at = @base.text(@base.field(request, "at"))
  provider_time(at, "at")
  let path = provider_path(provider)
  let before = @vault.required(store, path)
  let old = provider_row(@base.parse(before))
  if @base.text(@base.field(old, "status")) != "active" { @base.fail("provider_not_active: " + provider) }
  if @base.text(@base.field(old, "last_seen")) == at { return { "provider": provider, "status": "active", "replayed": true } }
  let next = match old {
    Object(fields) => { fields["last_seen"] = at.to_json(); Json::object(fields) }
    _ => raise @base.Fault("provider_record_invalid")
  }
  let content = @base.canonical(next)
  let entry = @core.find(entries, path)
  @vault.commit(store, @vault.fingerprint(entries), upsert(entries, { ..entry, sha256: @base.hex_hash(content) }),
    [{ path, before: Some(before), after: Some(content) }])
  { "provider": provider, "status": "active", "replayed": false, "last_seen": at }
}

fn provider_unregister(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "provider", "at"])
  let provider = @base.text(@base.field(request, "provider"))
  let at = @base.text(@base.field(request, "at"))
  provider_time(at, "at")
  let path = provider_path(provider)
  let before = @vault.required(store, path)
  let old = provider_row(@base.parse(before))
  if @base.text(@base.field(old, "status")) == "revoked" {
    if @base.field(old, "closed_at") == at.to_json() { return { "provider": provider, "status": "revoked", "replayed": true } }
    @base.fail("provider_already_revoked: " + provider)
  }
  let next = match old {
    Object(fields) => { fields["status"] = "revoked".to_json(); fields["closed_at"] = at.to_json(); Json::object(fields) }
    _ => raise @base.Fault("provider_record_invalid")
  }
  let content = @base.canonical(next)
  let entry = @core.find(entries, path)
  let event_path = "state/events/provider-revoke-" + @base.hex_hash(provider + "\n" + at) + ".json"
  let event : Json = { "op": "provider-unregister", "provider": provider, "at": at }
  let event_text = @base.canonical(event)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_text), sources: [], stale: false }
  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry),
    [{ path, before: Some(before), after: Some(content) }, { path: event_path, before: None, after: Some(event_text) }])
  { "provider": provider, "status": "revoked", "replayed": false, "closed_at": at }
}

pub fn provider_dispatch(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  match @base.text(@base.field(request, "op")) {
    "provider-register" => provider_register(store, entries, request)
    "provider-heartbeat" => provider_heartbeat(store, entries, request)
    "provider-unregister" => provider_unregister(store, entries, request)
    "provider-list" => provider_entries(store, entries).to_json()
    _ => raise @base.Fault("unknown_provider_operation")
  }
}

pub fn require_registered_provider(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
  kind : String, space : @index.VectorSpace,
) -> Unit raise @base.Fault {
  match provider_name(request) {
    None => ()
    Some(provider) => ignore(provider_for(store, entries, provider, kind, space))
  }
}

fn provider_entries(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  provider_entries_unchecked(store, entries)
}
