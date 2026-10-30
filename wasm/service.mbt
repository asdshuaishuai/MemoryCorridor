// Service face: a line-protocol session equivalent to nativehost/host.mbt,
// with every platform touch resolved through the corridor-host imports.
// The pure 15-op face (execute()) is untouched and stays import-free in
// behavior; ops outside the pure set route through @agent.dispatch_with_catalog.

pub(all) struct ServiceState {
  root : Ref[String?]
  held : Ref[Bool]
  catalog : Ref[String?]
}

pub fn new_service() -> ServiceState {
  { root: @ref.new(None), held: @ref.new(false), catalog: @ref.new(None) }
}

let service : Ref[ServiceState] = @ref.new(new_service())

// Every op on the service face routes through @agent.dispatch_with_catalog —
// the same surface the native CLI exposes. Ops that share a name with the
// pure face (search, context, graph, …) take their vault-shaped forms here;
// the pure, documents-in-request forms remain on the execute() entry.

fn service_run(session : ServiceState, request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  ignore(@agent.tool(op))
  if op == "session-close" {
    if session.root.val is None { @base.fail("session_not_open") }
    if session.held.val { host_unlock() }
    session.root.val = None
    session.held.val = false
    session.catalog.val = None
    return { "closed": true }
  }
  if op == "session-open" {
    let requested = @base.text(@base.field(request, "vault"))
    match session.root.val {
      Some(current) => {
        if current != requested { @base.fail("session_already_open: " + current) }
        if !session.held.val {
          host_lock()
          session.held.val = true
          return { "opened": true, "upgraded": true, "vault": current }
        }
        return { "opened": false, "reused": true, "vault": current }
      }
      None => ()
    }
    host_lock()
    session.root.val = Some(requested)
    session.held.val = true
    return { "opened": true, "vault": requested }
  }
  let requested_json = try @base.field(request, "vault") catch { _ => Json::null() }
  let requested = match requested_json {
    Null => None
    value => Some(@base.text(value))
  }
  let root = match session.root.val {
    Some(current) => {
      match requested {
        Some(value) if value != current => @base.fail("session_vault_mismatch")
        None if !session.held.val => @base.fail("vault_required: use session-open or provide vault")
        _ => ()
      }
      current
    }
    None => match requested {
      Some(value) => value
      None => { @base.fail("vault_required: use session-open or provide vault"); "" }
    }
  }
  let legacy = !session.held.val
  if session.root.val is None { session.root.val = Some(root) }
  let result = try {
    if op == "init" || op == "pack" || op == "unpack" {
      for dir in ["raw", "wiki", "staging", "views", "vectors", "state/orders", "state/events", "state/reviews", "state/research", "state/suggestions", "state/overview", "state/evidence", "state/providers", "state/transactions", "state/transactions/history", ".corridor"] { host_mkdirs(dir) }
    }
    let cached_catalog = match session.catalog.val {
      None => None
      Some(previous) => match host_read("index.mbt.md") {
        Some(current) if current == previous => Some(previous)
        _ => None
      }
    }
    let value = @agent.dispatch_with_catalog(host_store(), request, cached_catalog)
    match host_read("index.mbt.md") {
      Some(current) => session.catalog.val = Some(current)
      None => session.catalog.val = None
    }
    value
  } catch {
    @base.Fault(message) => {
      if legacy { host_unlock() }
      raise @base.Fault(message)
    }
  }
  if legacy { host_unlock() }
  result
}

// Scratch buffer the host writes the next request into before input_load.
let scratch_hold : Ref[Bytes?] = @ref.new(None)

pub fn scratch(cap : Int) -> Int {
  let buf = Bytes::new(cap)
  scratch_hold.val = Some(buf)
  bytes2ptr(buf)
}

// Bulk request load: the host writes one chunk at `ptr` (a scratch buffer)
// and the chunks append, so text-carrying ops (backfill, drafts, evidence
// payloads) reach the same 16 MiB ceiling as single files instead of the
// pure face's 2 MiB line limit. Overflow flags and service_execute reports
// the canonical input_overflow envelope.
pub fn input_load(ptr : Int, len : Int) -> Int {
  if len < 0 || incoming.val.length() + len > 16777216 {
    overflow.val = true
    return -1
  }
  for i in 0..<len { incoming.val.push(load8(ptr + i).to_byte()) }
  0
}

pub fn output_ptr() -> Int {
  bytes2ptr(outgoing.val)
}

// Service entry: mirrors cli/main.mbt's respond layer so the envelope
// ({ok,op,result,request_id} / fault_data-enriched errors, list-tools/help
// special case, unknown-field rejection via @agent.tool) is byte-compatible
// with the native CLI. The host driver only moves bytes.
pub fn service_execute() -> Int {
  let result : Json = try {
    if overflow.val { @base.fail("input_overflow") }
    let text = try @utf8.decode(Bytes::from_array(incoming.val)) catch { _ => raise @base.Fault("invalid_utf8") }
    cli_respond(text)
  } catch {
    @base.Fault(message) => { "ok": false, "error": message, "request_id": Json::null() }
  }
  outgoing.val = @utf8.encode(@base.canonical(result))
  outgoing.val.length()
}

fn cli_respond(text : String) -> Json {
  let mut request_id = Json::null()
  let result : Json = try {
    let request = @base.parse(text)
    request_id = try @base.field(request, "request_id") catch { _ => Json::null() }
    let op = @base.text(@base.field(request, "op"))
    let t = @agent.tool(op)
    @base.keys(request, ["op", "vault", "request_id", "progress"] + t.fields)
    if op == "list-tools" || op == "help" {
      { "ok": true, "op": op, "result": @agent.describe_tools(), "request_id": request_id }
    } else {
      let value = service_run(service.val, request)
      { "ok": true, "op": op, "result": value, "request_id": request_id }
    }
  } catch {
    @base.Fault(message) => {
      let data = @base.fault_data(message)
      match data {
        Object(fields) => {
          fields["ok"] = false.to_json()
          fields["error"] = message.to_json()
          fields["request_id"] = request_id
          Json::object(fields)
        }
        _ => { "ok": false, "error": message, "request_id": request_id }
      }
    }
  }
  result
}
