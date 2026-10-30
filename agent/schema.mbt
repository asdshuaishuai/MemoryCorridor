pub fn tool_name(t : Tool) -> String {
  "corridor_" + @base.replace_all(t.name, "-", "_")
}

pub fn input_schema(t : Tool) -> Json {
  let properties : Map[String, Json] = Map([])
  properties["vault"] = { "type": "string", "description": "Vault root; required by session-open and legacy one-shot calls, omitted after session-open" }
  properties["progress"] = { "type": "boolean", "description": "CLI transport hint; emit structured progress events before the terminal response" }
  properties["receipts"] = { "type": "array", "items": { "type": "object" }, "description": "Transport field; compile receipts [{path, sha256, ok}] proving the caller ran moon check itself (required by hosts without an in-process compiler)" }
  let required : Array[String] = if t.name == "session-open" { ["vault"] } else { [] }
  for name in t.fields {
    let ty = if ["pages", "items", "queries", "capabilities", "sources", "conditions",
      "kinds", "ids"].contains(name) { "array" }
      else if name == "archived" || name == "pinned" { "boolean" }
      else { match name {
        "limit" | "budget" | "hops" | "start" | "end" => "integer"
        "analysis" | "space" | "query_vector" | "vector_candidates" | "request" | "result" => "object"
        _ => "string"
      } }
    properties[name] = if ty == "array" {
      { "type": ty, "items": if ["queries", "capabilities", "sources", "conditions",
        "kinds", "ids"].contains(name) { { "type": "string" } } else { { "type": "object" } } }
    } else if ty == "integer" {
      let bounds = match (t.name, name) {
        ("read-log", "limit") => (0, 1000)
        ("search", "limit") => (1, 100)
        ("search", "budget") => (1, 65536)
        ("search", "hops") => (0, 2)
        ("graph", "hops") => (0, 8)
        ("embedding-plan", "limit") => (1, 128)
        ("memory-prefetch", "limit") => (1, 50)
        ("read-source", "start") => (0, 16777216)
        ("read-source", "end") => (0, 16777216)
        _ => (0, 2147483647)
      }
      { "type": ty, "minimum": bounds.0, "maximum": bounds.1 }
    } else { { "type": ty } }
    if !["purpose", "view", "bundle", "limit", "budget", "hops", "query_vector", "vector_candidates", "provider", "seed", "key", "dedup", "spread", "conditions", "archived", "kinds",
      "start", "end", "query", "page", "ids"].contains(name) &&
      !(name == "context_token" && t.name != "draft-submit") { required.push(name) }
  }
  { "type": "object", "properties": Json::object(properties), "required": required.to_json(), "additionalProperties": false }
}

pub fn mcp_tools() -> Json {
  tools().map(t => {
    let value : Json = { "name": tool_name(t), "description": t.description, "inputSchema": input_schema(t) }
    value
  }).to_json()
}

pub fn describe_tools() -> Json {
  tools().map(t => {
    let value : Json = { "name": t.name, "description": t.description, "fields": t.fields.to_json(), "inputSchema": input_schema(t) }
    value
  }).to_json()
}
