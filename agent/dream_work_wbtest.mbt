// White-box tests for the RSI work outbox primitives (续二十九). The full
// lease/backpressure flow runs against the real CLI in
// scripts/dream_work_e2e.py; here identity, the structured-result boundary and
// the advertised schema are pinned so a mutation lands on a focused test.

test "work id binds round, kind and subject" {
  let id = dream_work_id("a".repeat(64), "uncovered_source", "raw/x.md")
  assert_eq(id.length(), 64)
  assert_true(dream_hash_ok(id))
  assert_true(dream_work_id("b".repeat(64), "uncovered_source", "raw/x.md") != id)
  assert_true(dream_work_id("a".repeat(64), "stale_page", "raw/x.md") != id)
  assert_true(dream_work_id("a".repeat(64), "uncovered_source", "raw/y.md") != id)
  // same inputs replay to the same task, never a fork
  assert_eq(dream_work_id("a".repeat(64), "uncovered_source", "raw/x.md"), id)
}

test "work results admit only structured judgments and staged references" {
  dream_work_result_check({ "judgments": { "k": "v" }, "proposals": Json::array([]) })
  let bads : Array[Json] = [
    {},
    { "judgments": Json::array([]), "proposals": Json::array([]) },
    { "judgments": { "k": [1] }, "proposals": Json::array([]) },
    { "judgments": {}, "proposals": "x" },
    { "judgments": {}, "proposals": [
      { "page": "raw/x.md", "kind": "link", "staged_path": "staging/x" }] },
    { "judgments": {}, "proposals": [
      { "page": "wiki/x.md", "kind": "", "staged_path": "staging/x" }] },
    { "judgments": {}, "proposals": [
      { "page": "wiki/x.md", "kind": "link", "staged_path": "raw/x.md" }] },
  ]
  for bad in bads {
    assert_true(try { dream_work_result_check(bad); false } catch { _ => true })
  }
}

test "work tools declare the strict queue schema" {
  let by_name : Map[String, Tool] = Map([])
  for tool in tools() { by_name[tool.name] = tool }
  for name in ["dream-work-open", "dream-work-claim", "dream-work-complete",
               "dream-work-fail", "dream-work-list"] {
    assert_true(by_name.contains(name))
  }
  assert_eq(by_name["dream-work-open"].fields, ["round", "at", "limit"])
  let open_schema = input_schema(by_name["dream-work-open"])
  let props = @base.field(open_schema, "properties")
  assert_eq(json_int(@base.field(props, "limit"), "maximum"), 50)
  let required = @base.strings(@base.field(open_schema, "required"))
  assert_true(required.contains("round") && !required.contains("limit"))
  let complete = input_schema(by_name["dream-work-complete"])
  let complete_required = @base.strings(@base.field(complete, "required"))
  assert_true(complete_required.contains("result") && complete_required.contains("driver"))
  let result_prop = @base.field(@base.field(complete, "properties"), "result")
  assert_eq(@base.text(@base.field(result_prop, "type")), "object")
  let claim_required = @base.strings(@base.field(input_schema(by_name["dream-work-claim"]), "required"))
  assert_true(claim_required.contains("lease_until"))
}