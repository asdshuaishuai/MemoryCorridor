test "topics tool is read-only with no fields" {
  assert_eq(tool("topics").fields, [])
  let schema = input_schema(tool("topics"))
  assert_eq(@base.field(schema, "type"), "object".to_json())
  assert_eq(@base.array(@base.field(schema, "required")).length(), 0)
  assert_eq(@base.field(schema, "additionalProperties"), Json::boolean(false))
}

