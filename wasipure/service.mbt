// Service glue for the pure-WASI face: the nativehost/session layer and the
// CLI response envelope, with every platform touch resolved through WASI and
// compile verification resolved through request receipts (see storage.mbt).
// Response envelope is byte-compatible with the native CLI.

pub(all) struct ServiceState {
  root : Ref[String?]
  held : Ref[Bool]
  catalog : Ref[String?]
}

pub fn new_service() -> ServiceState {
  { root: @ref.new(None), held: @ref.new(false), catalog: @ref.new(None) }
}

let service : Ref[ServiceState] = @ref.new(new_service())

fn wasipure_store() -> @vault.Storage {
  {
    read: wasi_read, digest: wasi_digest, write: wasi_write, remove: wasi_remove,
    files: wasi_files, check: wasi_check,
    read_bytes: wasi_read_bytes, write_bytes: wasi_write_bytes,
    mkdirs: wasi_mkdirs,
  }
}

fn service_run(session : ServiceState, request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  ignore(@agent.tool(op))
  if op == "session-close" {
    if session.root.val is None { @base.fail("session_not_open") }
    if session.held.val { wasi_unlock() }
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
          wasi_lock()
          session.held.val = true
          return { "opened": true, "upgraded": true, "vault": current }
        }
        return { "opened": false, "reused": true, "vault": current }
      }
      None => ()
    }
    wasi_lock()
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
      for dir in ["raw", "wiki", "staging", "views", "vectors", "state/orders", "state/events", "state/reviews", "state/research", "state/suggestions", "state/overview", "state/evidence", "state/providers", "state/transactions", "state/transactions/history", ".corridor"] { wasi_mkdirs(dir) }
    }
    let cached_catalog = match session.catalog.val {
      None => None
      Some(previous) => match wasi_read("index.mbt.md") {
        Some(current) if current == previous => Some(previous)
        _ => None
      }
    }
    let value = @agent.dispatch_with_catalog(wasipure_store(), request, cached_catalog)
    match wasi_read("index.mbt.md") {
      Some(current) => session.catalog.val = Some(current)
      None => session.catalog.val = None
    }
    value
  } catch {
    @base.Fault(message) => {
      if legacy { wasi_unlock() }
      raise @base.Fault(message)
    }
  }
  if legacy { wasi_unlock() }
  result
}

fn cli_respond(text : String) -> Json {
  let mut request_id = Json::null()
  let result : Json = try {
    let request = @base.parse(text)
    request_id = try @base.field(request, "request_id") catch { _ => Json::null() }
    let op = @base.text(@base.field(request, "op"))
    let t = @agent.tool(op)
    @base.keys(request, ["op", "vault", "request_id", "progress", "receipts"] + t.fields)
    let req_receipts = try @base.field(request, "receipts") catch { _ => Json::null() }
    match req_receipts {
      Null => ()
      value => set_receipts(value)
    }
    // Receipts are a transport field (compile verification bookkeeping); the
    // engine never sees them — dispatch rejects unknown fields.
    let cleaned = match request {
      Object(fields) => {
        let kept : Map[String, Json] = Map([])
        for kv in fields.iter() {
          if kv.0 != "receipts" { kept[kv.0] = kv.1 }
        }
        Json::object(kept)
      }
      other => other
    }
    if op == "list-tools" || op == "help" {
      { "ok": true, "op": op, "result": @agent.describe_tools(), "request_id": request_id }
    } else {
      let value = service_run(service.val, cleaned)
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

// Same {ok,...}/{ok:false,error} envelope contract as the other faces.
pub fn service_execute_text(text : String) -> String {
  @base.canonical(cli_respond(text))
}
