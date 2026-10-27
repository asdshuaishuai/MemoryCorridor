test "impact identity is one record per kind, subject and cause" {
  let a = @core.impact_id("research", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "baseline-drift")
  let b = @core.impact_id("research", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "baseline-drift")
  assert_eq(a, b)
  assert_true(@core.impact_id("research", "state/research/" + "1111111111111111111111111111111111111111111111111111111111111111" + ".json", "baseline-drift") != a)
  assert_true(@core.impact_id("research", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "page-drift") != a)
  assert_true(@core.impact_id("overview-synthesis", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json",
    "baseline-drift") != a)
}

fn impact_entry_at(id : String) -> @core.Entry {
  let path = "state/impacts/" + id + ".json"
  { id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false }
}

test "impact record validation rejects unsupported kinds, subjects and status drift" {
  let id = @core.impact_id("research", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "baseline-drift")
  let path = "state/impacts/" + id + ".json"
  let entry : @core.Entry = {
    id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  let base : Json = { "version": 1, "id": id, "kind": "research",
    "subject": "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "cause": "baseline-drift",
    "frozen": "1111111111111111111111111111111111111111111111111111111111111111", "current": "2222222222222222222222222222222222222222222222222222222222222222", "detail": "open research topic drifted",
    "created_at": "2026-10-21T09:00:00Z", "updated_at": "2026-10-21T09:00:00Z",
    "status": "open", "resolved_at": Json::null(), "dismissed": Json::null(),
    "key": "impact-audit-v1" }
  @core.validate_record(entry, @base.canonical(base))
  let refused : Array[Json] = [
    json_override(base, "kind", "purpose-suggestion".to_json()),
    json_override(base, "cause", "unknown-drift".to_json()),
    json_override(base, "subject", "state/orders/x.json".to_json()),
    json_override(base, "status", "dismissed".to_json()),
    json_override(base, "frozen", "short".to_json()),
    json_override(base, "detail", "".to_json()),
    json_override(base, "extra", Json::number(1.0)),
    // An open record may not carry a resolve timestamp or a decision digest.
    json_override(base, "resolved_at", "2026-10-21T10:00:00Z".to_json()),
    json_override(base, "dismissed", ("3333333333333333333333333333333333333333333333333333333333333333").to_json()),
  ]
  for bad in refused {
    assert_true(refuses(() => @core.validate_record(entry, @base.canonical(bad))))
  }
  // The identity must derive from kind/subject/cause: that is what makes an
  // audit re-run replay instead of forking a second record for the same work.
  // The entry path has to match the forged id, otherwise the earlier path check
  // refuses it and this derivation is never reached.
  let forged_id = "f".repeat(64)
  let forged = json_override(base, "id", forged_id.to_json())
  assert_true(refuses(() => @core.validate_record(impact_entry_at(forged_id), @base.canonical(forged))))
  // An id derived from different fields than the record carries is refused too.
  let other = @core.impact_id("research", "state/research/" + "0".repeat(64) + ".json", "page-drift")
  let mismatched = json_override(json_override(base, "cause", "purpose-drift".to_json()),
    "id", other.to_json())
  assert_true(refuses(() => @core.validate_record(impact_entry_at(other), @base.canonical(mismatched))))

  // A resolved record needs its timestamp, and a decision digest must be a hash.
  let resolved = json_override(base, "status", "resolved".to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(resolved))))
  let closed = json_override(json_override(resolved, "resolved_at", "2026-10-21T10:00:00Z".to_json()),
    "dismissed", ("3333333333333333333333333333333333333333333333333333333333333333").to_json())
  @core.validate_record(entry, @base.canonical(closed))
  let bad_digest = json_override(closed, "dismissed", "not-a-hash".to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(bad_digest))))
}

test "impact event dictionary rejects forged paths and unknown operations" {
  let id = @core.impact_id("research", "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json", "baseline-drift")
  let subject = "state/research/" + "0000000000000000000000000000000000000000000000000000000000000000" + ".json"
  let at = "2026-10-21T09:00:00Z"
  let open : Json = { "op": "impact-open", "impact": id, "at": at, "key": "k",
    "kind": "research", "subject": subject, "cause": "baseline-drift",
    "frozen": "1111111111111111111111111111111111111111111111111111111111111111", "current": "2222222222222222222222222222222222222222222222222222222222222222" }
  let expected = "state/events/impact-open-" + id + "-" +
    @base.hex_hash("k" + "\n" + "2222222222222222222222222222222222222222222222222222222222222222" + "\n" + at) + ".json"
  @core.validate_record(event_entry(expected, @base.canonical(open)), @base.canonical(open))
  // The path binds the key, the observed inputs and the time.
  let forged = "state/events/impact-open-" + id + "-" + @base.hex_hash("other") + ".json"
  assert_true(refuses(() => @core.validate_record(event_entry(forged, @base.canonical(open)),
    @base.canonical(open))))
  let mismatch = json_override(open, "current", ("9999999999999999999999999999999999999999999999999999999999999999").to_json())
  assert_true(refuses(() => @core.validate_record(event_entry(expected, @base.canonical(mismatch)),
    @base.canonical(mismatch))))
  let resolve : Json = { "op": "impact-resolve", "impact": id, "at": at }
  let resolve_path = "state/events/impact-resolve-" + id + "-" + @base.hex_hash(at) + ".json"
  @core.validate_record(event_entry(resolve_path, @base.canonical(resolve)), @base.canonical(resolve))
  let unknown : Json = { "op": "impact-forget", "impact": id, "at": at }
  assert_true(refuses(() => @core.validate_record(
    event_entry("state/events/impact-forget-" + id + ".json", @base.canonical(unknown)),
    @base.canonical(unknown))))
}

test "impact tools declare strict field sets" {
  assert_eq(tool("impact-audit").fields, ["at", "key"])
  assert_eq(tool("impact-list").fields, [])
  assert_eq(tool("impact-resolve").fields, ["id", "note", "at"])
  for name in ["id", "note", "at"] {
    assert_true(@base.array(@base.field(input_schema(tool("impact-resolve")), "required")).contains(name.to_json()))
  }
  // `at` is an explicit caller timestamp and stays required, like research-topic.
  assert_true(@base.array(@base.field(input_schema(tool("impact-audit")), "required")).contains("at".to_json()))
  assert_true(!@base.array(@base.field(input_schema(tool("impact-audit")), "required")).contains("key".to_json()))
  // research topics carry the knowledge fingerprint the impact audit compares.
  let research : Json = { "id": "0000000000000000000000000000000000000000000000000000000000000000",
    "topic": "t", "queries": ["q"],
    "baseline": "1111111111111111111111111111111111111111111111111111111111111111",
    "inputs_hash": "2222222222222222222222222222222222222222222222222222222222222222",
    "created_at": "2026-10-21T09:00:00Z", "status": "proposed", "key": "k",
    "closed_at": Json::null(), "sources": Json::array([]) }
  @core.validate_record({ id: "state/research/0000000000000000000000000000000000000000000000000000000000000000.json",
    path: "state/research/0000000000000000000000000000000000000000000000000000000000000000.json",
    kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false }, @base.canonical(research))
  // Without the knowledge fingerprint a topic cannot be checked for drift.
  let legacy = json_override(research, "inputs_hash", Json::null())
  assert_true(refuses(() => @core.validate_record(
    { id: "state/research/0000000000000000000000000000000000000000000000000000000000000000.json",
      path: "state/research/0000000000000000000000000000000000000000000000000000000000000000.json",
      kind: "state", format: "json",
      sha256: "0000000000000000000000000000000000000000000000000000000000000000",
      sources: [], stale: false }, @base.canonical(legacy))))
}
