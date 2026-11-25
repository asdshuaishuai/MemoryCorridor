// Assistant export: derived Markdown for global assistants. These tests pin the
// two promises that make the view safe to read: only current project-scope
// notes are exported, and a rerun is byte-identical (no mtime churn).

fn memory_export_call(store : @vault.Storage, workspace : String?) -> Json raise @base.Fault {
  let request : Json = match workspace {
    None => { "op": "memory-export" }
    Some(value) => { "op": "memory-export", "workspace": value }
  }
  memory_export(store, @vault.load(store), request)
}

test "export publishes active project notes and never session notes" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  memory_open_other(store)
  let project = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project",
    "text": "优先安排釉色对照", "conditions": ["规划行程时"], "sources": [],
    "at": "2026-11-20T09:00:00Z", "key": "project" })
  let session = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "session", "session": "s1",
    "text": "本次会话先看青瓷", "conditions": [], "sources": [],
    "at": "2026-11-20T09:01:00Z", "key": "session" })
  let other = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": other_ws(), "kind": "fact", "scope": "project",
    "text": "另一项目的判断", "conditions": [], "sources": [],
    "at": "2026-11-20T09:02:00Z", "key": "other" })
  let result = memory_export_call(store, None)
  assert_eq(@base.field(result, "workspaces"), Json::number(2.0))
  assert_eq(@base.field(result, "notes"), Json::number(2.0))
  assert_eq(@base.field(result, "session_notes"), Json::number(1.0))
  let project_id = @base.text(@base.field(project, "id"))
  let session_id = @base.text(@base.field(session, "id"))
  let other_id = @base.text(@base.field(other, "id"))
  let project_doc = @vault.required(store, "index/memory/" + test_ws() + "/" + project_id + ".md")
  assert_true(project_doc.contains("note_hash: "))
  assert_true(project_doc.contains("优先安排釉色对照"))
  assert_true(project_doc.contains("id: \"" + project_id + "\""))
  assert_true(project_doc.contains("valid: true"))
  assert_true((store.read)("index/memory/" + test_ws() + "/" + session_id + ".md") is None)
  assert_true((store.read)("index/memory/" + other_ws() + "/" + other_id + ".md") is Some(_))
  let projects = @base.parse(@vault.required(store, "index/projects.json"))
  assert_eq(@base.array(@base.field(projects, "workspaces")).length(), 2)
}

test "export is idempotent and removes stale files" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let note = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "constraint", "scope": "project",
    "text": "窑址资料不得外借", "conditions": [], "sources": [],
    "at": "2026-11-20T09:00:00Z", "key": "constraint" })
  let note_id = @base.text(@base.field(note, "id"))
  let path = "index/memory/" + test_ws() + "/" + note_id + ".md"
  let first = memory_export_call(store, None)
  assert_eq(@base.field(first, "written"), Json::number(2.0))
  let before = @vault.required(store, path)
  let second = memory_export_call(store, None)
  assert_eq(@base.field(second, "written"), Json::number(0.0))
  assert_eq(@base.field(second, "unchanged"), Json::number(2.0))
  assert_eq(@vault.required(store, path), before)
  // A note leaving the active set removes its export on the next run.
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive",
    "workspace": test_ws(), "id": note_id, "at": "2026-11-20T10:00:00Z" }))
  let third = memory_export_call(store, None)
  assert_eq(@base.field(third, "notes"), Json::number(0.0))
  assert_eq(@base.field(third, "removed"), Json::number(1.0))
  assert_true((store.read)(path) is None)
}

test "a workspace-scoped export only reconciles its own directory" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  memory_open_other(store)
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "甲判断",
    "conditions": [], "sources": [], "at": "2026-11-20T09:00:00Z", "key": "a" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": other_ws(), "kind": "fact", "scope": "project", "text": "乙判断",
    "conditions": [], "sources": [], "at": "2026-11-20T09:01:00Z", "key": "b" }))
  ignore(memory_export_call(store, None))
  // A foreign file in another workspace's export is left alone when only this
  // workspace is reconciled.
  let foreign = "index/memory/" + other_ws() + "/foreign.md"
  (store.write)(foreign, "external\n")
  let scoped = memory_export_call(store, Some(test_ws()))
  assert_eq(@base.field(scoped, "notes"), Json::number(1.0))
  assert_eq(@base.field(scoped, "removed"), Json::number(0.0))
  assert_true((store.read)(foreign) is Some(_))
  // Exporting that workspace removes it as stale derived data.
  let reconciled = memory_export_call(store, Some(other_ws()))
  assert_eq(@base.field(reconciled, "removed"), Json::number(1.0))
  assert_true((store.read)(foreign) is None)
  // An unregistered workspace is refused instead of exporting nothing.
  assert_true(refuses(() => ignore(memory_export_call(store, Some("0".repeat(64))))))
}
