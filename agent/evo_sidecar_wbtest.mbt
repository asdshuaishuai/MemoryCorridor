// Sidecar machinery white-box tests (续六十二 slice 1): the mini-catalog, the
// two-phase journal and forward recovery must give the same interruption
// guarantees @vault.commit gives state/ records — crash at any publish point,
// recover to exactly one consistent state, and fail closed on tamper or
// conflicting writes.

fn evo_sidecar_test_changes() -> Array[@vault.Change] {
  [
    { path: "evo/state/a.json", before: None, after: Some("{\"v\":1}\n") },
    { path: "evo/genomes/b.json", before: None, after: Some("{\"v\":2}\n") },
  ]
}

test "evo sidecar commit and load round trip" {
  let (store, _, _) = crashing(1 << 20)
  evo_sidecar_commit(store, evo_sidecar_test_changes())
  let files = evo_sidecar_load(store)
  assert_eq(files.length(), 2)
  assert_eq(files.get("evo/state/a.json").unwrap(),
    @base.hex_hash("{\"v\":1}\n"))
  assert_eq((store.read)("evo/transactions/pending.json") is None, true)
  // A second commit replaces a record and removes the other.
  evo_sidecar_commit(store, [
    { path: "evo/state/a.json", before: Some("{\"v\":1}\n"), after: Some("{\"v\":3}\n") },
    { path: "evo/genomes/b.json", before: Some("{\"v\":2}\n"), after: None },
  ])
  let updated = evo_sidecar_load(store)
  assert_eq(updated.length(), 1)
  assert_eq(updated.get("evo/state/a.json").unwrap(),
    @base.hex_hash("{\"v\":3}\n"))
  assert_eq((store.read)("evo/genomes/b.json") is None, true)
}

test "evo sidecar recovers forward from a crash at any publish point" {
  // Write points: journal, two files, index swap = 4 interrupts.
  for interrupt in [1, 2, 3, 4] {
    let (store, _, _) = crashing(1 << 20)
    let failed = try {
      evo_sidecar_commit(store, evo_sidecar_test_changes(), interrupt_after=interrupt)
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    // Recovery runs inside load and must reach the intended final state.
    let files = evo_sidecar_load(store)
    assert_eq(files.length(), 2)
    assert_eq(files.get("evo/state/a.json").unwrap(),
      @base.hex_hash("{\"v\":1}\n"))
    assert_eq((store.read)("evo/transactions/pending.json") is None, true)
  }
}

test "evo sidecar refuses conflicting writes without side effects" {
  let (store, _, files) = crashing(1 << 20)
  files["evo/state/a.json"] = "stale bytes"
  let code = try {
    evo_sidecar_commit(store, [
      { path: "evo/state/a.json", before: None, after: Some("{\"v\":1}\n") },
    ])
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(code, "evo_sidecar_write_conflict")
  assert_eq(files.get("evo/index.json") is None, true)
  assert_eq(files.get("evo/transactions/pending.json") is None, true)
  assert_eq(files.get("evo/state/a.json").unwrap(), "stale bytes")
}

test "evo sidecar refuses duplicate, reserved and escaping paths" {
  let (store, _, _) = crashing(1 << 20)
  let duplicate = try {
    evo_sidecar_commit(store, [
      { path: "evo/state/a.json", before: None, after: Some("x\n") },
      { path: "evo/state/a.json", before: None, after: Some("y\n") },
    ])
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(duplicate, "evo_sidecar_duplicate_change")
  let reserved = try {
    evo_sidecar_commit(store, [
      { path: "evo/index.json", before: None, after: Some("x\n") },
    ])
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(reserved, "evo_sidecar_path_reserved")
  let escaping = try {
    evo_sidecar_commit(store, [
      { path: "evo/state/../escape.json", before: None, after: Some("x\n") },
    ])
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(escaping, "evo_sidecar_path_invalid")
}

test "evo sidecar load fails closed on tamper and demands recovery" {
  let (store, _, files) = crashing(1 << 20)
  evo_sidecar_commit(store, evo_sidecar_test_changes())
  files["evo/state/a.json"] = "{\"v\":9}\n"
  let tampered = try {
    ignore(evo_sidecar_load(store))
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(tampered, "evo_sidecar_corrupt")
  // A pending journal blocks new commits until recovery runs.
  files["evo/transactions/pending.json"] = "{\"version\":1}\n"
  let blocked = try {
    evo_sidecar_commit(store, [])
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(blocked, "evo_sidecar_recovery_required")
}
