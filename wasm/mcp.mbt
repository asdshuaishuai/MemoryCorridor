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
        @base.keys(args, ["vault", "progress"] + t.fields)
        let request = match args { Object(fields) => { fields["op"] = op.to_json(); Json::object(fields) }; _ => raise @base.Fault("arguments_object_required") }
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

/// One JSON-RPC request line in, one reply line out. Notifications produce
/// an empty string so the host writes nothing. Handshake state persists for
/// the whole module instance.
pub fn mcp_execute_line(text : String) -> String {
  let request : Json = try {
    @base.parse(text)
  } catch {
    _ => Json::null()
  }
  if request is Null {
    return @base.canonical(mcp_error(Json::null(), -32700, "parse_error"))
  }
  let valid = match request {
    Object(fields) => fields.get("jsonrpc") == Some("2.0".to_json()) &&
      (match fields.get("method") { Some(String(_)) => true; _ => false }) &&
      (match fields.get("id") { None | Some(String(_)) | Some(Number(_, ..)) | Some(Null) => true; _ => false })
    _ => false
  }
  if !valid {
    return @base.canonical(mcp_error(Json::null(), -32600, "invalid_request"))
  }
  match mcp_reply(mcp_session.val, request, mcp_ready.val, mcp_initialized.val) {
    Some(value) => {
      if (try @base.field(value, "result") catch { _ => Json::null() }) != Json::null() {
        if (try @base.field(request, "method") catch { _ => Json::null() }) == "initialize".to_json() {
          mcp_initialized.val = true
        }
      }
      @base.canonical(value)
    }
    None => ""
  }
}
