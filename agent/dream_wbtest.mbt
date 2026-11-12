// White-box tests for the dream ledger primitives (续二十八). The full round
// flow runs against the real CLI in scripts/dream_e2e.py; here the identity
// derivation, the policy/hash guards and the advertised schema surface are
// pinned directly so a mutation lands on a focused test.

fn json_int(value : Json, key : String) -> Int raise @base.Fault {
  match @base.field(value, key) {
    Number(n, ..) => n.to_int()
    _ => -1
  }
}

test "dream id binds baseline, policy, space and time" {
  let policy : Json = { "cosine_floor": 0.995 }
  let space : Json = { "id": "s", "dimensions": 2 }
  let id = dream_id("a".repeat(64), policy, space, "2026-11-11T00:00:00Z")
  assert_eq(id.length(), 64)
  assert_true(dream_hash_ok(id))
  assert_true(dream_id("b".repeat(64), policy, space, "2026-11-11T00:00:00Z") != id)
  let other_policy : Json = { "cosine_floor": 0.92 }
  assert_true(dream_id("a".repeat(64), other_policy, space, "2026-11-11T00:00:00Z") != id)
  let other_space : Json = { "id": "t", "dimensions": 2 }
  assert_true(dream_id("a".repeat(64), policy, other_space, "2026-11-11T00:00:00Z") != id)
  assert_true(dream_id("a".repeat(64), policy, space, "2026-11-11T00:00:01Z") != id)
  // canonical policy ordering is key-insensitive: same policy, different
  // insertion order, same round identity.
  let reordered : Json = { "note": "x", "cosine_floor": 0.995 }
  let direct : Json = { "cosine_floor": 0.995, "note": "x" }
  assert_eq(dream_id("a".repeat(64), reordered, space, "2026-11-11T00:00:00Z"),
            dream_id("a".repeat(64), direct, space, "2026-11-11T00:00:00Z"))
}

test "dream hash guard accepts only 64 lowercase hex chars" {
  assert_true(dream_hash_ok("0".repeat(64)))
  assert_true(dream_hash_ok("abcdef0123456789".repeat(4)))
  let bads : Array[String] = ["", "short", "g".repeat(64), "0".repeat(63), "0".repeat(65),
    "ABCDEF0123456789".repeat(4)]
  for bad in bads { assert_true(!dream_hash_ok(bad)) }
}

test "policy shape is closed: scalars in a small object with short keys" {
  dream_policy_shape({ "cosine_floor": 0.995, "mode": "visual", "strict": true })
  let nested : Json = { "a": { "b": 1 } }
  let list : Json = { "a": [1] }
  let bads : Array[Json] = [nested, list, [], { "": 1 }, "text", 1]
  for bad in bads {
    assert_true(try { dream_policy_shape(bad); false } catch { _ => true })
  }
  let long : Json = { "k": "x".repeat(65) }
  assert_true(try { dream_policy_shape(long); false } catch { _ => true })
  let wide : Map[String, Json] = Map([])
  for i = 0; i < 9; i = i + 1 { wide[i.to_string()] = i.to_json() }
  assert_true(try { dream_policy_shape(Json::object(wide)); false } catch { _ => true })
}

test "dream tools are advertised with the closed schema surface" {
  let by_name : Map[String, Tool] = Map([])
  for t in tools() { by_name[t.name] = t }
  for name in ["dream-plan", "dream-open", "dream-close", "dream-list"] {
    assert_true(by_name.contains(name))
  }
  let plan = input_schema(by_name["dream-plan"])
  let plan_props = @base.field(plan, "properties")
  assert_eq(@base.text(@base.field(@base.field(plan_props, "limit"), "type")), "integer")
  assert_eq(json_int(@base.field(plan_props, "limit"), "minimum"), 1)
  assert_eq(json_int(@base.field(plan_props, "limit"), "maximum"), 500)
  let open = input_schema(by_name["dream-open"])
  let open_props = @base.field(open, "properties")
  assert_eq(@base.text(@base.field(@base.field(open_props, "policy"), "type")), "object")
  let open_required = @base.strings(@base.field(open, "required"))
  assert_true(open_required.contains("baseline"))
  assert_true(!open_required.contains("policy"))  // optional stays optional
  let close_required = @base.strings(@base.field(input_schema(by_name["dream-close"]), "required"))
  assert_true(close_required.contains("decision"))
  assert_true(!close_required.contains("note"))
}
test "dream epoch parses canonical timestamps and rejects noise" {
  match dream_epoch("1970-01-01T00:00:00Z") {
    Some(value) => assert_eq(value, 0)
    None => @base.fail("epoch must parse 1970-01-01T00:00:00Z")
  }
  match dream_epoch("2026-11-12T00:00:00Z") {
    Some(value) => assert_true(value > 1793000000)
    None => @base.fail("epoch must parse a modern timestamp")
  }
  let bads : Array[String] = ["2026-11-12T00:00:00", "not-a-time", "2026-13-01T00:00:00Z",
    "2026-11-12T24:00:00Z", "2026-11-12 00:00:00Z"]
  for bad in bads { assert_true(dream_epoch(bad) == None) }
}

test "dream policy fields stay inside their documented bounds" {
  let current : Json = Json::number(5.0)
  let empty : Map[String, Json] = Map([])
  match dream_opt_bounded(empty.to_json(), "due_after_seconds", current, 0, 10) {
    Number(n, ..) => assert_true(n == 5.0)
    _ => @base.fail("default must pass through")
  }
  match dream_opt_bounded({ "due_after_seconds": 0 }.to_json(),
    "due_after_seconds", current, 0, 10) {
    Number(n, ..) => assert_true(n == 0.0)
    _ => @base.fail("explicit value must pass through")
  }
  let bads : Array[Json] = [Json::number(11.0), Json::number(-1.0), Json::number(1.5)]
  for bad in bads {
    assert_true(try {
      ignore(dream_opt_bounded({ "due_after_seconds": bad }.to_json(),
        "due_after_seconds", current, 0, 10))
      false
    } catch { _ => true })
  }
}
