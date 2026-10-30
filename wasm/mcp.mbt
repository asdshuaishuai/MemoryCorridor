// MCP JSON-RPC envelope for the corridor face: a faithful port of
// mcp/main.mbt's reply logic with @nativehost.execute replaced by the same
// service_run session glue the stdio face uses. Handshake state lives for
// the whole module instance.

let mcp_session : Ref[ServiceState] = @ref.new(new_service())
let mcp_initialized : Ref[Bool] = @ref.new(false)
let mcp_ready : Ref[Bool] = @ref.new(false)

fn mcp_error(id : Json, code : Int, message : String) -> Json {
  { "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message,
    "data": @base.fault_data(message) } }
}

fn mcp_progress_token(request : Json) -> Json? {
  let rpc_name = try { @base.text(@base.field(request, "method")) } catch { _ => "" }
  if rpc_name != "tools/call" { return None }
  match request {
    Object(fields) => if fields.get("id") is None { None } else {
      let params = fields.get("params").unwrap_or(Json::object(Map([])))
      match params {
        Object(param_fields) => match param_fields.get("_meta") {
          Some(Object(meta)) => match meta.get("progressToken") {
            Some(String(_) | Number(_, ..)) as value => value
            _ => None
          }
          _ => None
        }
        _ => None
      }
    }
    _ => None
  }
}

fn mcp_progress_notice(token : Json, value : Json, message : String) -> Json {
  { "jsonrpc": "2.0", "method": "notifications/progress",
    "params": { "progressToken": token, "progress": value, "total": 1, "message": message } }
}

fn mcp_reply(session : ServiceState, request : Json, ready : Bool, initialized : Bool) -> Json? {
  let id = match request { Object(fields) => fields.get("id"); _ => None }
  let rid = id.unwrap_or(Json::null())
  let mut code = -32602
  try {
    @base.keys(request, ["jsonrpc", "id", "method", "params"])
    if @base.field(request, "jsonrpc") != "2.0".to_json() { raise @base.Fault("jsonrpc_2_required") }
    let rpc_method = @base.text(@base.field(request, "method"))
    let params = match request { Object(fields) => fields.get("params").unwrap_or(Json::object(Map([]))); _ => Json::null() }
    if id is None {
      // Notifications never produce a JSON-RPC response.
      return None
    }
    match rid {
      String(_) | Number(_, ..) | Null => ()
      _ => raise @base.Fault("id_must_be_string_or_number")
    }
    let result : Json = match rpc_method {
      "initialize" => {
        if initialized { raise @base.Fault("already_initialized") }
        @base.keys(params, ["protocolVersion", "capabilities", "clientInfo"])
        let version = @base.text(@base.field(params, "protocolVersion"))
        if !["2024-11-05", "2025-03-26", "2025-06-18"].contains(version) { raise @base.Fault("unsupported_protocol_version") }
        ignore(@base.field(params, "capabilities"))
        ignore(@base.field(params, "clientInfo"))
        { "protocolVersion": version,
          "capabilities": { "tools": { "listChanged": false } },
          "serverInfo": { "name": "MemoryCorridor", "version": "0.1.0" } }
      }
      "ping" => { @base.keys(params, []); Json::object(Map([])) }
      "tools/list" => {
        if !ready { raise @base.Fault("initialization_required") }
        @base.keys(params, [])
        { "tools": @agent.mcp_tools() }
      }
      "tools/call" => {
        if !ready { raise @base.Fault("initialization_required") }
        @base.keys(params, ["name", "arguments", "_meta"])
        let name = @base.text(@base.field(params, "name"))
        let args = @base.field(params, "arguments")
        let tools = @agent.tools()
        let mut op = ""
        for t in tools { if @agent.tool_name(t) == name { op = t.name; break } }
        if op == "" { raise @base.Fault("unknown_tool: " + name) }
        let t = @agent.tool(op)
        @base.keys(args, ["vault", "progress", "receipts"] + t.fields)
        // Receipts are a transport field and inert here: compilation goes
        // through the corridor-host moon import, so strip before dispatch
        // (the engine rejects unknown fields).
        let request = match args {
          Object(fields) => {
            fields["op"] = op.to_json()
            fields.remove("receipts")
            Json::object(fields)
          }
          _ => raise @base.Fault("arguments_object_required")
        }
        let (value, failed) = try (service_run(session, request), false) catch {
          @base.Fault(message) => {
            let data = @base.fault_data(message)
            let failed_value = match data {
              Object(fields) => { fields["error"] = message.to_json(); Json::object(fields) }
              _ => { "error": message }
            }
            (failed_value, true)
          }
        }
        { "content": [{ "type": "text", "text": @base.canonical(value) }],
          "structuredContent": { "result": value },
          "isError": failed }
      }
      _ => { code = -32601; raise @base.Fault("method_not_found: " + rpc_method) }
    }
    Some({ "jsonrpc": "2.0", "id": rid, "result": result })
  } catch {
    @base.Fault(message) => if id is None {
      None
    } else {
      Some(mcp_error(rid, code, message))
    }
  }
}

/// One JSON-RPC request line in, the protocol's reply lines out: a
/// tools/call carrying _meta.progressToken also yields
/// notifications/progress lines (started first, completed/failed after the
/// reply is decided), and a notification yields no line at all (empty
/// output, zero length). Handshake state persists for the whole module
/// instance: initialize pins `initialized`, the follow-up silent
/// notifications/initialized notice unlocks `ready` and with it tools/*.
pub fn mcp_execute_line() -> Int {
  let text = try @utf8.decode(Bytes::from_array(incoming.val)) catch {
    _ => "invalid_utf8_request"
  }
  let request : Json = try {
    @base.parse(text)
  } catch {
    _ => Json::null()
  }
  if request is Null {
    outgoing.val = @utf8.encode(@base.canonical(mcp_error(Json::null(), -32700, "parse_error")))
    return outgoing.val.length()
  }
  let valid = match request {
    Object(fields) => fields.get("jsonrpc") == Some("2.0".to_json()) &&
      (match fields.get("method") { Some(String(_)) => true; _ => false }) &&
      (match fields.get("id") { None | Some(String(_)) | Some(Number(_, ..)) | Some(Null) => true; _ => false })
    _ => false
  }
  if !valid {
    outgoing.val = @utf8.encode(@base.canonical(mcp_error(Json::null(), -32600, "invalid_request")))
    return outgoing.val.length()
  }
  let rpc_method = try { @base.text(@base.field(request, "method")) } catch { _ => "" }
  let token = mcp_progress_token(request)
  let lines : Array[String] = []
  match token {
    Some(value) => lines.push(@base.canonical(mcp_progress_notice(value, 0, "started")))
    None => ()
  }
  let reply = mcp_reply(mcp_session.val, request, mcp_ready.val, mcp_initialized.val)
  match reply {
    Some(value) =>
      if (try @base.field(value, "result") catch { _ => Json::null() }) != Json::null() && rpc_method == "initialize" {
        mcp_initialized.val = true
      }
    None =>
      // notifications/initialized 是握手收尾：回复仍为空，但解锁 tools/*。
      if mcp_initialized.val && rpc_method == "notifications/initialized" {
        let valid_notice = try {
          @base.keys(request, ["jsonrpc", "method", "params"])
          true
        } catch {
          _ => false
        }
        if valid_notice { mcp_ready.val = true }
      }
  }
  match token {
    Some(value) => {
      let failed = match reply {
        None => true
        Some(result) => {
          let error_value = try @base.field(result, "error") catch { _ => Json::null() }
          if error_value != Json::null() {
            true
          } else {
            let result_value = try @base.field(result, "result") catch { _ => Json::null() }
            match result_value {
              Object(fields) => fields.get("isError").unwrap_or(false.to_json()) == true.to_json()
              _ => false
            }
          }
        }
      }
      lines.push(@base.canonical(mcp_progress_notice(value, if failed { 0 } else { 1 }, if failed { "failed" } else { "completed" })))
    }
    None => ()
  }
  match reply {
    Some(value) => lines.push(@base.canonical(value))
    None => ()
  }
  outgoing.val = @utf8.encode(lines.join("\n"))
  outgoing.val.length()
}
