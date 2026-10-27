test "read source tool declares a strict field set with bounded ranges" {
  assert_eq(tool("read-source").fields, ["id", "start", "end"])
  let schema = input_schema(tool("read-source"))
  let properties = @base.field(schema, "properties")
  assert_eq(@base.field(@base.field(properties, "id"), "type"), "string".to_json())
  assert_eq(@base.field(@base.field(properties, "start"), "type"), "integer".to_json())
  assert_eq(@base.field(@base.field(properties, "start"), "minimum"), Json::number(0.0))
  assert_eq(@base.field(@base.field(properties, "start"), "maximum"), Json::number(16777216.0))
  assert_eq(@base.field(@base.field(properties, "end"), "maximum"), Json::number(16777216.0))
  assert_eq(@base.field(schema, "required"), ["id"].to_json())
  // start and end stay optional so a whole source can be read.
  for name in ["start", "end"] {
    assert_true(!@base.array(@base.field(schema, "required")).contains(name.to_json()))
  }
}

test "source byte cap steps back to a character boundary" {
  // The cap counts UTF-8 bytes, so a multi-byte tail must not be split.
  let text = "陶".repeat(30000)
  assert_eq(@base.utf8_size(text), 90000)
  let capped = source_capped(text, 90000)
  assert_true(@base.utf8_size(capped) <= 65536)
  assert_true(text.has_prefix(capped))
  // A source under the cap is returned whole.
  assert_eq(source_capped("陶瓷", 6), "陶瓷")
  // An ASCII source caps exactly.
  let ascii = "a".repeat(70000)
  assert_eq(@base.utf8_size(source_capped(ascii, 70000)), 65536)
}

test "optional numeric fields are advertised as optional integers" {
  // A schema that marks an optional field required, or types an integer field
  // as a string, sends conforming clients down a path the engine refuses.
  // `read-source` is the first tool with an optional integer range, so pin the
  // whole shape rather than the two fields in isolation.
  let schema = input_schema(tool("read-source"))
  let required = @base.array(@base.field(schema, "required"))
  assert_eq(required.length(), 1)
  assert_eq(required[0], "id".to_json())
  let properties = @base.field(schema, "properties")
  for name in ["start", "end"] {
    let field = @base.field(properties, name)
    assert_eq(@base.field(field, "type"), "integer".to_json())
    assert_eq(@base.field(field, "minimum"), Json::number(0.0))
    assert_eq(@base.field(field, "maximum"), Json::number(16777216.0))
    assert_true(!required.contains(name.to_json()))
  }
  // The engine accepts both a whole read and a ranged read.
  assert_eq(tool("read-source").fields, ["id", "start", "end"])
}

fn lacks_execution(value : Json) -> Bool {
  match optional(value, "execution") {
    None => true
    Some(_) => false
  }
}

test "read operations never claim a pending host action" {
  // `execution:"host_required"` marks an operation that recorded a plan the host
  // still has to carry out. Claiming it on a read would make a generic client
  // believe it owes the engine work. This drives the operations rather than
  // inspecting the dictionary, so a read that grows the field fails here.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  files["raw/a.md"] = "官窑记录：器形与釉色。\n"
  ignore(dispatch(store, { "op": "scan" }))
  // A real page, so page-history is exercised against something that exists.
  let order = @base.array(dispatch(store, { "op": "plan" }))[0]
  let order_id = @base.text(@base.field(order, "id"))
  let context = dispatch(store, { "op": "context", "order": order_id })
  ignore(dispatch(store, { "op": "analysis-submit", "order": order_id,
    "context_token": @base.text(@base.field(context, "context_token")),
    "analysis": { "entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷" } }))
  files["staging/" + order_id + "/page.md"] =
    "---\ntype: concept\ntitle: 陶瓷\nsources: [\"raw/a.md\"]\n---\n官窑器形与釉色。\n"
  ignore(dispatch(store, { "op": "commit", "order": order_id,
    "pages": [{ "id": "concepts/ceramics", "path": "wiki/concepts/ceramics.md",
      "staged": "staging/" + order_id + "/page.md" }], "at": "2026-11-10T09:15:00Z" }))
  ignore(dispatch(store, { "op": "research-topic", "topic": "陶瓷", "queries": ["陶瓷"],
    "at": "2026-11-10T09:00:00Z" }))
  ignore(memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "fact", "scope": "workspace",
    "text": "官窑记录可据此核对", "conditions": ["核对官窑资料时"],
    "sources": ["raw/a.md"], "at": "2026-11-10T09:05:00Z", "key": "k1" }))
  // A write operation that records host work keeps the field.
  let planned = dispatch(store, { "op": "research-topic", "topic": "釉色", "queries": ["釉色"],
    "at": "2026-11-10T09:10:00Z" })
  assert_eq(@base.text(@base.field(planned, "execution")), "host_required")
  // Every read operation must stay free of it.
  let reads : Array[Json] = [
    dispatch(store, { "op": "read-purpose" }),
    dispatch(store, { "op": "read-index" }),
    dispatch(store, { "op": "read-log" }),
    dispatch(store, { "op": "read-source", "id": "raw/a.md" }),
    dispatch(store, { "op": "read-source", "id": "raw/a.md", "start": 0, "end": 6 }),
    dispatch(store, { "op": "memory-read", "id": @base.text(@base.field(
      memory_rows(store, @vault.load(store))[0].to_json(), "id")) }),
    dispatch(store, { "op": "memory-list" }),
    dispatch(store, { "op": "memory-conflicts" }),
    dispatch(store, { "op": "memory-prefetch", "query": "陶瓷" }),
    dispatch(store, { "op": "impact-list" }),
    dispatch(store, { "op": "inbox" }),
    dispatch(store, { "op": "topics" }),
    dispatch(store, { "op": "page-history", "id": "concepts/ceramics" }),
    dispatch(store, { "op": "search", "query": "陶瓷" }),
    dispatch(store, { "op": "list-pages" }),
  ]
  for value in reads {
    assert_true(lacks_execution(value))
  }
}
