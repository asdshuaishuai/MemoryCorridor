test "raw entry identity must equal its path" {
  let entry : Entry = {
    id: "raw/source-id.md",
    path: "raw/source.md",
    kind: "raw",
    format: "markdown",
    sha256: @base.hex_hash("source"),
    sources: [],
    stale: false,
  }
  assert_true(try { validate_entries([entry]); false } catch { _ => true })
}

test "raw entry identity remains valid for path references" {
  let entry : Entry = {
    id: "raw/source.md",
    path: "raw/source.md",
    kind: "raw",
    format: "markdown",
    sha256: @base.hex_hash("source"),
    sources: [],
    stale: false,
  }
  validate_entries([entry])
}

test "state events reject unsupported operations" {
  let text = @base.canonical({ "op": "forged-event", "payload": "ignored" })
  let entry : Entry = {
    id: "state/events/forged.json", path: "state/events/forged.json", kind: "state",
    format: "json", sha256: @base.hex_hash(text), sources: [], stale: false,
  }
  assert_true(try { validate_record(entry, text); false } catch { _ => true })
}

test "known state events reject unknown fields" {
  let text = @base.canonical({ "op": "refresh", "before": "0".repeat(64), "changes": [], "extra": true })
  let entry : Entry = {
    id: "state/events/refresh.json", path: "state/events/refresh.json", kind: "state",
    format: "json", sha256: @base.hex_hash(text), sources: [], stale: false,
  }
  assert_true(try { validate_record(entry, text); false } catch { _ => true })
}

test "known state events require declared fields" {
  let text = @base.canonical({ "op": "refresh", "changes": [] })
  let entry : Entry = {
    id: "state/events/refresh-missing.json", path: "state/events/refresh-missing.json", kind: "state",
    format: "json", sha256: @base.hex_hash(text), sources: [], stale: false,
  }
  assert_true(try { validate_record(entry, text); false } catch { _ => true })
}

test "known state events bind content addressed paths" {
  let id = "0".repeat(64)
  let text = @base.canonical({ "op": "provider-job-open", "id": id, "provider": "demo", "kind": "embedding", "at": "2026-10-17T00:00:00Z" })
  let wrong : Entry = {
    id: "state/events/provider-job-open.json", path: "state/events/provider-job-open.json", kind: "state",
    format: "json", sha256: @base.hex_hash(text), sources: [], stale: false,
  }
  assert_true(try { validate_record(wrong, text); false } catch { _ => true })
  let expected_path = "state/events/provider-job-open-" + id + ".json"
  let right : Entry = { ..wrong, id: expected_path, path: expected_path }
  validate_record(right, text)
}
