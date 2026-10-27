fn respond(session : @nativehost.SessionState, text : String) -> Json {
  let mut request_id = Json::null()
  let result : Json = try {
    let request = @base.parse(text)
    request_id = try @base.field(request, "request_id") catch { _ => Json::null() }
    let op = @base.text(@base.field(request, "op"))
    let t = @agent.tool(op)
    @base.keys(request, ["op", "vault", "request_id", "progress"] + t.fields)
    match request {
      Object(fields) => match fields.get("progress") {
        Some(value) => ignore(@base.boolean(value))
        None => ()
      }
      _ => ()
    }
    if op == "list-tools" || op == "help" {
      { "ok": true, "op": op, "result": @agent.describe_tools(), "request_id": request_id }
    } else {
      let value = @nativehost.execute(session, request)
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

fn progress_enabled(request : Json) -> Bool {
  try { @base.boolean(@base.field(request, "progress")) } catch { _ => false }
}

fn progress_event(request : Json, phase : String) -> Json {
  let op = try { @base.text(@base.field(request, "op")) } catch { _ => "unknown" }
  let request_id = try { @base.field(request, "request_id") } catch { _ => Json::null() }
  { "event": "progress", "op": op, "phase": phase, "request_id": request_id }
}

fn main {
  let session = @nativehost.new_session()
  while true {
    match @nativehost.line() {
      None => break
      Some(":exit") => break
      Some(text) => {
        let request = try Some(@base.parse(text)) catch { _ => None }
        match request {
          Some(value) if progress_enabled(value) => @nativehost.emit(progress_event(value, "started"))
          _ => ()
        }
        let response = respond(session, text)
        match request {
          Some(value) if progress_enabled(value) => {
            let ok = try @base.boolean(@base.field(response, "ok")) catch { _ => false }
            let phase = if ok {
              "completed"
            } else { "failed" }
            @nativehost.emit(progress_event(value, phase))
          }
          _ => ()
        }
        @nativehost.emit(response)
      }
    }
  }
}
