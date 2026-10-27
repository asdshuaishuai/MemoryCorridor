test "tool schemas expose deterministic integer bounds" {
  let log_schema = input_schema(tool("read-log"))
  let log_limit = @base.field(@base.field(log_schema, "properties"), "limit")
  assert_eq(@base.field(log_limit, "minimum"), Json::number(0.0))
  assert_eq(@base.field(log_limit, "maximum"), Json::number(1000.0))

  let search_schema = input_schema(tool("search"))
  let search_props = @base.field(search_schema, "properties")
  let search_limit = @base.field(search_props, "limit")
  let search_budget = @base.field(search_props, "budget")
  assert_eq(@base.field(search_limit, "minimum"), Json::number(1.0))
  assert_eq(@base.field(search_limit, "maximum"), Json::number(100.0))
  assert_eq(@base.field(search_budget, "maximum"), Json::number(65536.0))
}
