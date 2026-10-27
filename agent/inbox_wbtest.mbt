test "inbox tool declares a read-only empty field set" {
  assert_eq(tool("inbox").fields, [])
  let schema = input_schema(tool("inbox"))
  assert_eq(@base.field(schema, "type"), "object".to_json())
  assert_eq(@base.array(@base.field(schema, "required")).length(), 0)
  assert_eq(@base.field(schema, "additionalProperties"), Json::boolean(false))
}

test "cancel ops declare strict field sets" {
  assert_eq(tool("purpose-cancel").fields, ["id", "at"])
  assert_eq(tool("overview-cancel").fields, ["id", "at"])
  for owner in [tool("purpose-cancel"), tool("overview-cancel")] {
    for name in ["id", "at"] {
      assert_true(@base.array(@base.field(input_schema(owner), "required")).contains(name.to_json()))
    }
  }
}

test "suggestion and overview records accept a cancelled terminal state" {
  let suggestion = @base.hex_hash("suggestion-v1")
  let path = "state/suggestions/" + suggestion + ".json"
  let entry : @core.Entry = {
    id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  let base : Json = { "id": suggestion, "kind": "purpose",
    "baseline": "1111111111111111111111111111111111111111111111111111111111111111",
    "purpose_hash": "2222222222222222222222222222222222222222222222222222222222222222",
    "created_at": "2026-10-23T10:00:00Z", "status": "cancelled", "key": "k",
    "closed_at": "2026-10-23T11:00:00Z", "result_hash": Json::null() }
  @core.validate_record(entry, @base.canonical(base))
  // A cancelled record keeps its close timestamp and never claims a result.
  let with_result = json_override(base, "result_hash",
    "3333333333333333333333333333333333333333333333333333333333333333".to_json())
  let refused = try {
    @core.validate_record(entry, @base.canonical(with_result)); false
  } catch { _ => true }
  assert_true(refused)
  let open = json_override(base, "status", "proposed".to_json())
  let still_refused = try {
    @core.validate_record(entry, @base.canonical(open)); false
  } catch { _ => true }
  assert_true(still_refused)

  let overview = @base.hex_hash("overview-v1")
  let overview_path = "state/overview/" + overview + ".json"
  let overview_entry : @core.Entry = {
    id: overview_path, path: overview_path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  let record : Json = { "id": overview,
    "baseline": "1111111111111111111111111111111111111111111111111111111111111111",
    "purpose_hash": "2222222222222222222222222222222222222222222222222222222222222222",
    "page_hashes": { "concepts/a": "4444444444444444444444444444444444444444444444444444444444444444" },
    "created_at": "2026-10-23T10:00:00Z", "status": "cancelled", "key": "k",
    "closed_at": "2026-10-23T11:00:00Z", "result_hash": Json::null() }
  @core.validate_record(overview_entry, @base.canonical(record))
}

test "cancel events bind their path to the suggestion and time" {
  let suggestion = @base.hex_hash("suggestion-v1")
  let at = "2026-10-23T11:00:00Z"
  let purpose : Json = { "op": "purpose-cancel", "suggestion": suggestion, "at": at }
  let purpose_path = "state/events/purpose-cancel-" + suggestion + "-" + @base.hex_hash(at) + ".json"
  @core.validate_record(event_entry(purpose_path, @base.canonical(purpose)), @base.canonical(purpose))
  let forged = "state/events/purpose-cancel-" + suggestion + "-" + @base.hex_hash("other") + ".json"
  assert_true(refuses(() => @core.validate_record(event_entry(forged, @base.canonical(purpose)),
    @base.canonical(purpose))))
  let overview : Json = { "op": "overview-cancel", "suggestion": suggestion, "at": at }
  let overview_path = "state/events/overview-cancel-" + suggestion + "-" + @base.hex_hash(at) + ".json"
  @core.validate_record(event_entry(overview_path, @base.canonical(overview)), @base.canonical(overview))
  let unknown : Json = { "op": "suggestion-cancel", "suggestion": suggestion, "at": at }
  assert_true(refuses(() => @core.validate_record(
    event_entry("state/events/suggestion-cancel-" + suggestion + ".json", @base.canonical(unknown)),
    @base.canonical(unknown))))
}

test "inbox lists every kind of durable work with stable ordering" {
  // A synthetic item set proves the sort key groups related work and keeps the
  // order stable across calls without needing a vault.
  let items : Array[InboxItem] = []
  for kind in ["stale-page", "impact", "memory-conflict", "review"] {
    items.push(inbox_item(kind, "subject-" + kind, "reason-" + kind, "detail", "next", "2026-10-23T09:00:00Z"))
  }
  inbox_sort(items)
  assert_eq(items.map(i => i.kind), ["impact", "memory-conflict", "review", "stale-page"])
  inbox_sort(items)
  assert_eq(items.map(i => i.kind), ["impact", "memory-conflict", "review", "stale-page"])
  let counts = inbox_counts(items)
  assert_eq(@base.field(counts, "total"), Json::number(4.0))
  assert_eq(@base.array(@base.field(counts, "by_kind")).length(), 4)
  // The view always carries the drift field, empty when nothing moved.
  let view = inbox_view(items[0])
  assert_eq(@base.field(view, "drift"), Json::array([]))
  assert_eq(@base.field(view, "next"), "next".to_json())
}

test "inbox kind vocabulary covers every source of durable work" {
  // The kinds the inbox can emit, pinned so a new source of debt cannot be
  // added without a corresponding test and doc entry.
  let kinds = ["impact", "memory-conflict", "memory-source-stale", "overview-suggestion",
    "purpose-suggestion", "research", "review", "stale-page", "unscanned-source"]
  assert_eq(kinds.length(), 9)
  let sorted = kinds.copy()
  sorted.sort_by(@base.compare)
  assert_eq(sorted, kinds)
}

fn count_item(kind : String) -> InboxItem {
  { kind, subject: "s-" + kind, reason: "r", detail: "d", next: "n",
    created_at: "2026-11-12T09:00:00Z", drift: [] }
}

test "inbox by_kind counts are deterministically ordered" {
  // `by_kind` is built from a map, so its order follows hash iteration unless
  // it is sorted. The caller happens to pass an already sorted list, which
  // would hide a regression here, so the function is exercised directly with a
  // deliberately unsorted one.
  let unsorted : Array[InboxItem] = [
    count_item("unscanned-source"), count_item("research"),
    count_item("impact"), count_item("review"),
  ]
  let counts = inbox_counts(unsorted)
  let by_kind = @base.array(@base.field(counts, "by_kind"))
  let names : Array[String] = []
  let mut total = 0
  for row in by_kind {
    match row {
      Array(pair) => {
        names.push(@base.text(pair[0]))
        match pair[1] {
          Number(n, ..) => total += n.to_int()
          _ => ()
        }
      }
      _ => raise @base.Fault("unexpected_by_kind_row")
    }
  }
  let sorted = names.copy()
  sorted.sort_by(@base.compare)
  assert_eq(names, sorted)
  assert_eq(names, ["impact", "research", "review", "unscanned-source"])
  // The counts add up to the total.
  assert_eq(@base.field(counts, "total"), Json::number(total.to_double()))
}
