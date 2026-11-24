// Workspace registration: the anchor memory scoping will use. These tests pin
// the identity recipe, the idempotent replay window, the refusal to rewind time
// and the deterministic listing, because a workspace id that drifts would make
// every note in that project unreachable.

fn workspace_store_snapshot(files : Map[String, String]) -> String {
  let keys = files.keys().to_array()
  keys.sort_by(@base.compare)
  let rows : Array[String] = []
  for key in keys { rows.push(key + "\n" + files[key]) }
  @base.hex_hash(rows.join("\n"))
}

fn workspace_open_call(
  store : @vault.Storage, path : String, at : String,
) -> Json raise @base.Fault {
  dispatch(store, { "op": "workspace-open", "path": path, "at": at })
}

test "workspace id is content addressed and open replays byte-identically" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let path = "/Users/kelthas/work/陶瓷"
  let first = workspace_open_call(store, path, "2026-11-20T09:00:00Z")
  assert_eq(@base.boolean(@base.field(first, "replayed")), false)
  assert_eq(@base.text(@base.field(first, "id")), @core.workspace_id(path))
  assert_eq(@base.text(@base.field(first, "created_at")), "2026-11-20T09:00:00Z")
  assert_eq(@base.text(@base.field(first, "last_opened_at")), "2026-11-20T09:00:00Z")
  let record = "state/workspaces/" + @core.workspace_id(path) + ".json"
  assert_true(files[record].contains("\"path\":\"/Users/kelthas/work/陶瓷\""))
  // The same timestamp is a pure replay: no write, no new files, same bytes.
  let before = workspace_store_snapshot(files)
  let again = workspace_open_call(store, path, "2026-11-20T09:00:00Z")
  assert_eq(@base.boolean(@base.field(again, "replayed")), true)
  assert_eq(workspace_store_snapshot(files), before)
}

test "a newer open refreshes only last_opened_at and an older one is refused" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let path = "/Users/kelthas/work/窑址"
  ignore(workspace_open_call(store, path, "2026-11-20T09:00:00Z"))
  let record = "state/workspaces/" + @core.workspace_id(path) + ".json"
  let created = @base.text(@base.field(@base.parse(files[record]), "created_at"))
  let later = workspace_open_call(store, path, "2026-11-21T10:00:00Z")
  assert_eq(@base.text(@base.field(later, "created_at")), created)
  assert_eq(@base.text(@base.field(later, "last_opened_at")), "2026-11-21T10:00:00Z")
  assert_true(try {
    ignore(workspace_open_call(store, path, "2026-11-19T09:00:00Z"))
    false
  } catch {
    @base.Fault(message) => message.has_prefix("workspace_time_order")
  })
  assert_eq(@base.text(@base.field(@base.parse(files[record]), "last_opened_at")), "2026-11-21T10:00:00Z")
}

test "workspace paths must be canonical absolute paths" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  for path in ["relative/dir", "/tmp/../etc", "/tmp/dir/", "", "/tmp/a\nb", "//tmp/dir", "/tmp/."] {
    assert_true(try {
      ignore(workspace_open_call(store, path, "2026-11-20T09:00:00Z"))
      false
    } catch {
      @base.Fault(message) => message.has_prefix("workspace_path_invalid")
    })
  }
  // Two distinct canonical paths never share a workspace id.
  assert_true(@core.workspace_id("/tmp/a") != @core.workspace_id("/tmp/b"))
}

test "workspace list is sorted by path and counts records" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  ignore(workspace_open_call(store, "/z/项目", "2026-11-20T09:00:00Z"))
  ignore(workspace_open_call(store, "/a/项目", "2026-11-20T09:00:00Z"))
  let listed = workspace_list(store, @vault.load(store))
  assert_eq(@base.field(listed, "count"), Json::number(2.0))
  let rows = @base.array(@base.field(listed, "workspaces"))
  assert_eq(@base.text(@base.field(rows[0], "path")), "/a/项目")
  assert_eq(@base.text(@base.field(rows[1], "path")), "/z/项目")
}

test "workspace records reject a drifted id, path or time order" {
  let path = "/Users/kelthas/work/官窑"
  let id = @core.workspace_id(path)
  let row : Json = { "version": Json::number(1.0), "id": id.to_json(), "path": path.to_json(),
    "created_at": "2026-11-20T09:00:00Z".to_json(), "last_opened_at": "2026-11-20T09:00:00Z".to_json() }
  let record_path = "state/workspaces/" + id + ".json"
  @core.validate_record(workspace_entry(record_path, @base.canonical(row)), @base.canonical(row))
  // Id must derive from the path it claims. The filename and the JSON id agree
  // here, so only the workspace-specific identity check can refuse the record.
  let fake_id = @base.hex_hash("not-a-workspace-path")
  let fake_row : Json = { "version": Json::number(1.0), "id": fake_id.to_json(),
    "path": "/Users/kelthas/work/别的".to_json(),
    "created_at": "2026-11-20T09:00:00Z".to_json(), "last_opened_at": "2026-11-20T09:00:00Z".to_json() }
  assert_true(refuses(() => @core.validate_record(
    workspace_entry("state/workspaces/" + fake_id + ".json", @base.canonical(fake_row)), @base.canonical(fake_row))))
  // last_opened_at may not precede created_at.
  let inverted = json_override(row, "last_opened_at", "2026-11-19T09:00:00Z".to_json())
  assert_true(refuses(() => @core.validate_record(
    workspace_entry(record_path, @base.canonical(inverted)), @base.canonical(inverted))))
  // Unknown fields stay closed like every other durable record.
  let extra = json_override(row, "owner", "someone".to_json())
  assert_true(refuses(() => @core.validate_record(
    workspace_entry(record_path, @base.canonical(extra)), @base.canonical(extra))))
}

fn workspace_entry(path : String, content : String) -> @core.Entry {
  { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
}
