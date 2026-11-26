// Dream notes: proposals with bound evidence, resolved only by explicit host
// decisions. The tests pin the two promises that keep them from becoming a
// second source of truth: applying a note never writes pages or memory itself,
// and an applied target must still hold the exact bytes it claimed.

fn dream_note_refuses(action : () -> Unit raise @base.Fault) -> Bool {
  try {
    action()
    false
  } catch {
    _ => true
  }
}

test "dream note submit binds inputs, replays, and resolves through an applied target" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let note = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project",
    "text": "梦境笔记引用的判断", "conditions": ["整理笔记"], "sources": [],
    "at": "2026-11-10T09:00:00Z", "key": "dream-note-source" })
  let note_id = @base.text(@base.field(note, "id"))
  let request : Json = { "op": "dream-note-submit", "workspace": test_ws(),
    "kind": "insight", "title": "釉色与胎质的关联",
    "body": "把胎质与釉层的记录合在一起，能得到更稳定的断代线索。",
    "inputs": { "pages": [], "notes": [note_id] },
    "claims": [{ "text": "判断可作为梦境证据", "evidence": [note_id] }],
    "at": "2026-11-10T09:10:00Z" }
  let submitted = dream_note_submit(store, @vault.load(store), request)
  let id = @base.text(@base.field(submitted, "id"))
  assert_eq(@base.text(@base.field(submitted, "status")), "proposed")
  // Same content is a retry, not a second note.
  let replay = dream_note_submit(store, @vault.load(store), request)
  assert_eq(@base.field(replay, "replayed"), true.to_json())
  assert_eq(@base.text(@base.field(replay, "id")), id)
  // Naming an evidence id that was not declared in inputs is refused before
  // anything is written: the claim would not be checkable.
  let unbound : Json = { "op": "dream-note-submit", "workspace": test_ws(),
    "kind": "insight", "title": "无依据",
    "body": "claim 引用了未声明的证据。",
    "inputs": { "pages": [], "notes": [] },
    "claims": [{ "text": "缺少证据", "evidence": [note_id] }],
    "at": "2026-11-10T09:11:00Z" }
  assert_true(dream_note_refuses(() => ignore(dream_note_submit(store, @vault.load(store), unbound))))
  // The target hash is the active memory record's identity hash; a mismatch is
  // drift, not success.
  let target = (hash : String) => { "kind": "memory", "id": note_id, "hash": hash }
  assert_true(dream_note_refuses(() => ignore(dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": id, "status": "applied",
      "target": target("0".repeat(64)), "at": "2026-11-10T09:20:00Z" }))))
  let identity = @base.text(@base.field(@base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": note_id }), "record"), "note_hash"))
  let applied = dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": id, "status": "applied",
      "target": target(identity), "at": "2026-11-10T09:20:00Z" })
  assert_eq(@base.text(@base.field(applied, "status")), "applied")
  assert_eq(@base.field(applied, "replayed"), false.to_json())
  // The same resolution replays; a different one is terminal.
  let replay_resolution = dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": id, "status": "applied",
      "target": target(identity), "at": "2026-11-10T09:20:00Z" })
  assert_eq(@base.field(replay_resolution, "replayed"), true.to_json())
  assert_true(dream_note_refuses(() => ignore(dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": id, "status": "rejected",
      "at": "2026-11-10T09:21:00Z" }))))
  // A second note can be applied to a memory record.
  let second : Json = { "op": "dream-note-submit", "workspace": test_ws(),
    "kind": "consolidation", "title": "合并两条判断", "body": "把两条判断合并为一条更稳定的偏好。",
    "inputs": { "pages": [], "notes": [note_id] }, "claims": [],
    "at": "2026-11-10T09:30:00Z" }
  let second_id = @base.text(@base.field(dream_note_submit(store, @vault.load(store), second), "id"))
  assert_true(dream_note_refuses(() => ignore(dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": second_id, "status": "applied",
      "target": { "kind": "memory", "id": note_id, "hash": "0".repeat(64) },
      "at": "2026-11-10T09:40:00Z" }))))
  let memory_applied = dream_note_resolve(store, @vault.load(store),
    { "op": "dream-note-resolve", "id": second_id, "status": "applied",
      "target": { "kind": "memory", "id": note_id, "hash": identity },
      "at": "2026-11-10T09:40:00Z" })
  assert_eq(@base.field(memory_applied, "status"), "applied".to_json())
  // Listing is workspace-scoped and reports the state counts.
  let listed = dream_note_list(store, @vault.load(store), { "workspace": test_ws() })
  assert_eq(@base.field(@base.field(listed, "counts"), "total"), Json::number(2.0))
  assert_eq(@base.field(@base.field(listed, "counts"), "applied"), Json::number(2.0))
  memory_open_other(store)
  let none = dream_note_list(store, @vault.load(store), { "workspace": other_ws() })
  assert_eq(@base.field(@base.field(none, "counts"), "total"), Json::number(0.0))
}

test "a workspace dream round carries memory metrics and gates retention" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  // Two competing judgments give the round one conflict to report.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project", "text": "先看青瓷",
    "conditions": ["安排参观"], "sources": [], "at": "2026-11-11T09:00:00Z", "key": "a" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project", "text": "先看白瓷",
    "conditions": ["安排参观"], "sources": [], "at": "2026-11-11T09:01:00Z", "key": "b" }))
  let at = "2027-11-11T00:00:00Z"
  assert_true(dream_note_refuses(() => ignore(dream_plan(store, @vault.load(store),
    { "workspace": test_ws() }))))
  let plan = dream_plan(store, @vault.load(store), { "workspace": test_ws(), "at": at })
  let memory = @base.field(plan, "memory")
  assert_eq(@base.field(@base.field(memory, "metrics"), "active"), Json::number(2.0))
  assert_eq(@base.field(@base.field(memory, "metrics"), "conflicted"), Json::number(2.0))
  let kinds : Array[String] = []
  for opportunity in @base.array(@base.field(memory, "opportunities")) {
    kinds.push(@base.text(@base.field(opportunity, "kind")))
  }
  assert_true(kinds.contains("memory_conflict"))
  // A round binds the workspace and its baseline memory metrics in the record.
  let baseline = @vault.fingerprint(@vault.load(store))
  let round = dream_open(store, @vault.load(store), { "op": "dream-open",
    "baseline": baseline, "policy": {}, "workspace": test_ws(), "at": at })
  let round_id = @base.text(@base.field(round, "id"))
  let record = @base.parse(@vault.required(store, "state/dreams/" + round_id + ".json"))
  assert_eq(@base.field(record, "workspace"), test_ws().to_json())
  assert_eq(@base.field(@base.field(record, "memory_metrics"), "conflicted"), Json::number(2.0))
  // A note cannot claim a different workspace than the round it belongs to.
  memory_open_other(store)
  assert_true(dream_note_refuses(() => ignore(dream_note_submit(store, @vault.load(store),
    { "op": "dream-note-submit", "workspace": other_ws(), "round": round_id,
      "kind": "insight", "title": "错配", "body": "工作区与轮次不一致。",
      "inputs": { "pages": [], "notes": [] }, "claims": [],
      "at": "2027-11-11T00:00:01Z" }))))
  // Memory tasks from that workspace enter the same queue.
  let work = dream_work_open(store, @vault.load(store), { "op": "dream-work-open",
    "round": round_id, "at": at })
  assert_true(@base.array(@base.field(work, "tasks")).length() >= 1)
  let mut has_conflict_task = false
  for task in dream_work_rows(store, @vault.load(store)) {
    if @base.text(@base.field(task, "kind")) == "memory_conflict" {
      has_conflict_task = true
    }
  }
  assert_true(has_conflict_task)
  // The work queue round can be rejected with its task still pending.
  ignore(dream_close(store, @vault.load(store), { "op": "dream-close",
    "id": round_id, "decision": "rejected", "at": "2027-11-13T00:00:00Z" }))
  // A fresh round with no tasks isolates the memory compatibility gate.
  let baseline2 = @vault.fingerprint(@vault.load(store))
  let round2 = dream_open(store, @vault.load(store), { "op": "dream-open",
    "baseline": baseline2, "policy": {}, "workspace": test_ws(),
    "at": "2027-11-13T01:00:00Z" })
  let round2_id = @base.text(@base.field(round2, "id"))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "decision", "scope": "project", "text": "先记录A",
    "conditions": ["新冲突"], "sources": [], "at": "2027-11-13T02:00:00Z", "key": "c" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "decision", "scope": "project", "text": "先记录B",
    "conditions": ["新冲突"], "sources": [], "at": "2027-11-13T02:01:00Z", "key": "d" }))
  assert_true(dream_note_refuses(() => ignore(dream_close(store, @vault.load(store),
    { "op": "dream-close", "id": round2_id, "decision": "retained",
      "at": "2027-11-14T00:00:00Z" }))))
  let closed = dream_close(store, @vault.load(store), { "op": "dream-close",
    "id": round2_id, "decision": "rejected", "at": "2027-11-14T00:00:00Z" })
  let outcome = @base.field(closed, "outcome")
  assert_eq(@base.field(@base.field(outcome, "memory_delta"), "conflicted"),
    Json::number(2.0))
  assert_eq(@base.field(@base.field(outcome, "memory_delta"), "active"),
    Json::number(2.0))
  assert_eq(@base.field(@base.field(outcome, "memory"), "conflicted"),
    Json::number(4.0))
}
