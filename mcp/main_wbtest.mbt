// The native MCP face must honor the schema it advertises: `receipts` is a
// declared transport field, so tools/call accepts and strips it instead of
// rejecting it as unknown_field (the two wasm faces behave the same).

test "tools/call accepts the schema-declared receipts transport field" {
  let session = @nativehost.new_session()
  let request = @base.parse(
    "{ \"jsonrpc\": \"2.0\", \"id\": 1, \"method\": \"tools/call\", \"params\": { \"name\": \"corridor_session_close\", \"arguments\": { \"receipts\": [] } } }")
  let response = reply(session, request, true, true)
  let result = match response { Some(value) => value; None => Json::null() }
  // Receipts allowed: the call executes and reports the domain fault, not
  // the -32602 unknown_field error.
  assert_eq(try @base.field(result, "error") catch { _ => Json::null() }, Json::null())
  let structured = @base.field(@base.field(result, "result"), "structuredContent")
  assert_eq(@base.text(@base.field(@base.field(structured, "result"), "error")), "session_not_open")
  // A genuinely unknown field is still rejected.
  let forged = @base.parse(
    "{ \"jsonrpc\": \"2.0\", \"id\": 2, \"method\": \"tools/call\", \"params\": { \"name\": \"corridor_session_close\", \"arguments\": { \"nonsense\": 1 } } }")
  let rejected = match reply(session, forged, true, true) { Some(value) => value; None => Json::null() }
  assert_eq(@base.text(@base.field(@base.field(rejected, "error"), "message")), "unknown_field: nonsense; allowed=vault,progress,receipts")
}
