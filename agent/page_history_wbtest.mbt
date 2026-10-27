test "page history tool declares a strict field set" {
  assert_eq(tool("page-history").fields, ["id"])
  let schema = input_schema(tool("page-history"))
  assert_eq(@base.field(schema, "required"), ["id"].to_json())
  assert_eq(@base.field(schema, "additionalProperties"), Json::boolean(false))
}

test "ingest event accepts a missing pages field for legacy commits" {
  let order = @base.hex_hash("order-v1")
  let path = "state/events/" + order + ".json"
  let entry : @core.Entry = {
    id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  // Commits recorded before publication hashes were logged stay readable.
  let legacy : Json = { "op": "ingest", "order": order, "source": "raw/a.md",
    "at": "2026-10-31T09:00:00Z" }
  @core.validate_record(entry, @base.canonical(legacy))
  // A logged commit carries the published hash of every page it wrote.
  let logged : Json = { "op": "ingest", "order": order, "source": "raw/a.md",
    "at": "2026-10-31T09:00:00Z",
    "pages": { "concepts/a": "1111111111111111111111111111111111111111111111111111111111111111" } }
  @core.validate_record(entry, @base.canonical(logged))
  for bad in [
    json_override(logged, "pages", Json::array([])),
    json_override(logged, "pages", { "concepts/a": "short" }.to_json()),
    json_override(logged, "pages", { "../escape": "1111111111111111111111111111111111111111111111111111111111111111" }.to_json()),
  ] {
    assert_true(refuses(() => @core.validate_record(entry, @base.canonical(bad))))
  }
  // The path still binds the order, with or without the field.
  let forged = "state/events/" + @base.hex_hash("other") + ".json"
  assert_true(refuses(() => @core.validate_record(
    { id: forged, path: forged, kind: "state", format: "json",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      sources: [], stale: false }, @base.canonical(logged))))
}
