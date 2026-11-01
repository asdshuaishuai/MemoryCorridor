// Regression probes for the replay/state reconciliation fixes: archive and
// restore replays must reconcile with the live catalog, commit must not skip
// the freshness gate when the token is absent, restore must re-derive its
// provenance and heal propagated dependents, and the memory/provider replay
// paths must compare payloads and volatile fields instead of trusting keys.
// The fixtures reuse the crash-test helpers from transaction_safety_wbtest.mbt.

// Publishes a small wiki from one raw source. Each page body may carry
// [[wikilinks]], so the same fixture builds chains (A←B←C) and rings (A↔B).
fn publish_linked(
  store : @vault.Storage, pages : Array[Json],
) -> Unit raise @base.Fault {
  ignore(initialize(store, "研究陶瓷"))
  (store.write)("raw/ceramics.md", "南宋官窑的器形与釉色记录。\n")
  let scanned = scan(store, @vault.load(store))
  let order = @base.text(@base.array(@base.field(scanned, "orders"))[0])
  let context = context(store, @vault.load(store), order)
  ignore(submit_analysis(store, @vault.load(store), order, {
    "entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷记录",
  }))
  let drafts = submit_drafts(store, @vault.load(store), {
    "op": "draft-submit", "order": order,
    "context_token": @base.field(context, "context_token"),
    "pages": pages.to_json(),
  })
  ignore(commit_pages(store, @vault.load(store), order,
    @base.field(drafts, "pages"), "2026-10-29T08:30:00Z"))
}

fn fault_of(run : () -> Unit raise @base.Fault) -> String {
  try { run(); "" } catch { @base.Fault(message) => message }
}

test "archive replay reconciles with the live page state" {
  let (store, _broken, _files) = crashing(-1)
  ignore(seed_page(store))
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concepts/ceramics", "at": "2026-10-29T09:00:00Z", "reason": "清理" }))
  assert_true(@core.find(@vault.load(store), "concepts/ceramics").stale)
  ignore(restore_page(store, @vault.load(store), { "op": "restore-page",
    "id": "concepts/ceramics", "at": "2026-10-29T10:00:00Z" }))
  assert_false(@core.find(@vault.load(store), "concepts/ceramics").stale)
  // The same idempotency key after a restore: the archive is no longer in
  // effect, so the retry must refuse instead of reporting archived:true.
  let replay = fault_of(() => ignore(archive_page(store, @vault.load(store),
    { "op": "archive-page", "id": "concepts/ceramics",
      "at": "2026-10-29T09:00:00Z", "reason": "清理" })))
  assert_true(replay.has_prefix("page_not_active"), msg=replay)
  assert_false(@core.find(@vault.load(store), "concepts/ceramics").stale)
  // A genuinely archived page still replays its own event.
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concepts/ceramics", "at": "2026-10-29T11:00:00Z", "reason": "清理" }))
  let honest = archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concepts/ceramics", "at": "2026-10-29T11:00:00Z", "reason": "清理" })
  assert_eq(@base.boolean(@base.field(honest, "replayed")), true)
}

test "restore refuses when the source bytes changed under the archived version" {
  let (store, _broken, files) = crashing(-1)
  ignore(seed_page(store))
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concepts/ceramics", "at": "2026-10-29T09:00:00Z", "reason": "清理" }))
  // A wholesale source rewrite re-registers under a new hash; the archived
  // body still derives from the old bytes.
  files["raw/ceramics.md"] = "彻底不同的元代青花记录。\n"
  ignore(dispatch(store, { "op": "refresh" }))
  assert_false(@core.find(@vault.load(store), "raw/ceramics.md").stale)
  let refused = fault_of(() => ignore(restore_page(store, @vault.load(store),
    { "op": "restore-page", "id": "concepts/ceramics", "at": "2026-10-29T10:00:00Z" })))
  assert_true(refused.has_prefix("restore_source_changed"), msg=refused)
  assert_true(@core.find(@vault.load(store), "concepts/ceramics").stale)
}

test "restore reactivates dependents that only propagation staled" {
  let (store, _broken, _files) = crashing(-1)
  ignore(publish_linked(store, [
    { "id": "entity/core", "kind": "entity", "title": "核心", "sources": ["raw/ceramics.md"],
      "tags": ["陶瓷"], "body": "南宋官窑的器形与釉色记录。" },
    { "id": "concept/mid", "kind": "concept", "title": "中期", "sources": ["raw/ceramics.md"],
      "tags": ["陶瓷"], "body": "中期整理，参见 [[entity/core]]。" },
    { "id": "synthesis/top", "kind": "synthesis", "title": "顶层", "sources": ["raw/ceramics.md"],
      "tags": ["陶瓷"], "body": "顶层综述，参见 [[concept/mid]]。" },
  ]))
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concept/mid", "at": "2026-10-29T09:00:00Z", "reason": "整理" }))
  let archived = @vault.load(store)
  assert_true(@core.find(archived, "concept/mid").stale)
  assert_true(@core.find(archived, "synthesis/top").stale)
  assert_false(@core.find(archived, "entity/core").stale)
  let restored = restore_page(store, @vault.load(store), { "op": "restore-page",
    "id": "concept/mid", "at": "2026-10-29T10:00:00Z" })
  // The dependent that was never archived itself recovers with the chain.
  let reactivated = @base.strings(@base.field(restored, "reactivated"))
  assert_true(reactivated.contains("synthesis/top"), msg=@base.canonical(restored))
  let after = @vault.load(store)
  @vault.verify(store, after)
  assert_false(@core.find(after, "concept/mid").stale)
  assert_false(@core.find(after, "synthesis/top").stale)
  assert_false(@core.find(after, "entity/core").stale)
}

test "restore unlocks the archived side of a mutual-link ring" {
  let (store, _broken, _files) = crashing(-1)
  ignore(publish_linked(store, [
    { "id": "concepts/a", "kind": "concept", "title": "甲", "sources": ["raw/ceramics.md"],
      "tags": [], "body": "甲页，参见 [[concepts/b]]。" },
    { "id": "concepts/b", "kind": "concept", "title": "乙", "sources": ["raw/ceramics.md"],
      "tags": [], "body": "乙页，参见 [[concepts/a]]。" },
  ]))
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concepts/a", "at": "2026-10-29T09:00:00Z", "reason": "整理" }))
  let archived = @vault.load(store)
  assert_true(@core.find(archived, "concepts/a").stale)
  assert_true(@core.find(archived, "concepts/b").stale)
  ignore(restore_page(store, @vault.load(store), { "op": "restore-page",
    "id": "concepts/a", "at": "2026-10-29T10:00:00Z" }))
  let after = @vault.load(store)
  @vault.verify(store, after)
  assert_false(@core.find(after, "concepts/a").stale)
  assert_false(@core.find(after, "concepts/b").stale)
}

test "an explicitly archived page is not resurrected by another page's restore" {
  let (store, _broken, _files) = crashing(-1)
  ignore(publish_linked(store, [
    { "id": "entity/core", "kind": "entity", "title": "核心", "sources": ["raw/ceramics.md"],
      "tags": [], "body": "南宋官窑的器形与釉色记录。" },
    { "id": "concept/mid", "kind": "concept", "title": "中期", "sources": ["raw/ceramics.md"],
      "tags": [], "body": "中期整理，参见 [[entity/core]]。" },
  ]))
  // A human decision archives the dependent; the source revocation of the
  // root afterwards must not let a later restore pull it back.
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "concept/mid", "at": "2026-10-29T09:00:00Z", "reason": "人工下线" }))
  ignore(archive_page(store, @vault.load(store), { "op": "archive-page",
    "id": "entity/core", "at": "2026-10-29T10:00:00Z", "reason": "整理" }))
  ignore(restore_page(store, @vault.load(store), { "op": "restore-page",
    "id": "entity/core", "at": "2026-10-29T11:00:00Z" }))
  let after = @vault.load(store)
  assert_false(@core.find(after, "entity/core").stale)
  assert_true(@core.find(after, "concept/mid").stale)
  // Its own restore path stays available.
  ignore(restore_page(store, after, { "op": "restore-page",
    "id": "concept/mid", "at": "2026-10-29T12:00:00Z" }))
  assert_false(@core.find(@vault.load(store), "concept/mid").stale)
}

test "commit without a token still refuses a drifted catalog" {
  let (store, _broken, files) = crashing(-1)
  ignore(publish_linked(store, [
    { "id": "concepts/first", "kind": "concept", "title": "第一", "sources": ["raw/ceramics.md"],
      "tags": [], "body": "第一版来源记录。" },
  ]))
  (store.write)("raw/second.md", "另一份来源记录。\n")
  let scanned = scan(store, @vault.load(store))
  let order2 = @base.text(@base.array(@base.field(scanned, "orders"))[0])
  let token = context(store, @vault.load(store), order2)
  ignore(submit_analysis(store, @vault.load(store), order2, {
    "entities": [], "concepts": ["第二"], "conflicts": [], "summary": "第二",
  }))
  let drafts = submit_drafts(store, @vault.load(store), {
    "op": "draft-submit", "order": order2, "context_token": @base.field(token, "context_token"),
    "pages": [{ "id": "concepts/second", "kind": "concept", "title": "第二",
      "sources": ["raw/second.md"], "tags": [], "body": "第二份整理。" }],
  })
  // The catalog drifts after the order froze its inputs.
  let page = @vault.required(store, "wiki/concepts/first.md")
  files["wiki/concepts/first.md"] = @base.replace_all(page, "第一版来源记录。", "第二版来源记录。")
  ignore(dispatch(store, { "op": "refresh" }))
  // The token is absent, so the gate must come from commit_pages itself.
  let refused = fault_of(() => ignore(commit_pages(store, @vault.load(store), order2,
    @base.field(drafts, "pages"), "2026-10-29T09:30:00Z")))
  assert_true(refused.has_prefix("context_stale"), msg=refused)
  // With a fresh context the same token-less commit publishes.
  ignore(context(store, @vault.load(store), order2))
  ignore(submit_analysis(store, @vault.load(store), order2, {
    "entities": [], "concepts": ["第二"], "conflicts": [], "summary": "第二",
  }))
  let refresh = context(store, @vault.load(store), order2)
  let redrafted = submit_drafts(store, @vault.load(store), {
    "op": "draft-submit", "order": order2,
    "context_token": @base.field(refresh, "context_token"),
    "pages": [{ "id": "concepts/second", "kind": "concept", "title": "第二",
      "sources": ["raw/second.md"], "tags": [], "body": "第二份整理。" }],
  })
  let committed = commit_pages(store, @vault.load(store), order2,
    @base.field(redrafted, "pages"), "2026-10-29T09:40:00Z")
  assert_eq(@base.text(@base.field(committed, "phase")), "committed")
}

fn memory_seed_note(store : @vault.Storage) -> String raise @base.Fault {
  let first = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "preference", "scope": "workspace",
    "text": "优先安排陶瓷窑口对比的参观时间", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T09:00:00Z", "key": "k1" })
  @base.text(@base.field(first, "id"))
}

test "memory-submit replay reports archived and superseded notes as refusals" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let id = memory_seed_note(store)
  let request : Json = { "op": "memory-submit", "kind": "preference", "scope": "workspace",
    "text": "优先安排陶瓷窑口对比的参观时间", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T09:00:00Z", "key": "k1" }
  let active = memory_submit(store, @vault.load(store), request)
  assert_eq(@base.boolean(@base.field(active, "replayed")), true)
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive",
    "id": id, "at": "2026-10-29T10:00:00Z" }))
  let archived = fault_of(() => ignore(memory_submit(store, @vault.load(store), request)))
  assert_true(archived.has_prefix("memory_archived_note_refused"), msg=archived)
  // The superseded side of the key refuses just as distinctly.
  ignore(memory_restore(store, @vault.load(store), { "op": "memory-restore",
    "id": id, "at": "2026-10-29T11:00:00Z" }))
  ignore(memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "id": id, "text": "改期后的参观安排", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T12:00:00Z", "key": "k1" }))
  let superseded = fault_of(() => ignore(memory_submit(store, @vault.load(store), request)))
  assert_true(superseded.has_prefix("memory_superseded_note_refused"), msg=superseded)
}

test "memory-pin refuses archived and superseded notes" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let id = memory_seed_note(store)
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive",
    "id": id, "at": "2026-10-29T10:00:00Z" }))
  let archived = fault_of(() => ignore(memory_protect(store, @vault.load(store),
    { "op": "memory-pin", "id": id, "pinned": true, "at": "2026-10-29T10:30:00Z" })))
  assert_true(archived.has_prefix("memory_archived_note_refused"), msg=archived)
  ignore(memory_restore(store, @vault.load(store), { "op": "memory-restore",
    "id": id, "at": "2026-10-29T11:00:00Z" }))
  ignore(memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "id": id, "text": "改期后的参观安排", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T12:00:00Z", "key": "k1" }))
  let superseded = fault_of(() => ignore(memory_protect(store, @vault.load(store),
    { "op": "memory-pin", "id": id, "pinned": true, "at": "2026-10-29T12:30:00Z" })))
  assert_true(superseded.has_prefix("memory_superseded_note_refused"), msg=superseded)
}

test "supersede inherits the pinned marker into the successor" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let id = memory_seed_note(store)
  ignore(memory_protect(store, @vault.load(store), { "op": "memory-pin",
    "id": id, "pinned": true, "at": "2026-10-29T10:00:00Z" }))
  ignore(memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "id": id, "text": "改期后的参观安排", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T11:00:00Z" }))
  let rows = memory_rows(store, @vault.load(store))
  let successor = rows.filter(n => n.supersedes == Some(id))[0]
  assert_true(successor.pinned)
  let old = rows.filter(n => n.id == id)[0]
  assert_true(old.pinned)
  // The inherited pin keeps the successor out of automated pruning's reach.
  let refused = fault_of(() => ignore(memory_archive(store, @vault.load(store),
    { "op": "memory-archive", "id": successor.id, "at": "2026-10-29T12:00:00Z" })))
  assert_true(refused.has_prefix("memory_pinned_archive_refused"), msg=refused)
}

test "memory transitions refuse backwards timestamps and lint reports them" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let id = memory_seed_note(store)
  let backwards = fault_of(() => ignore(memory_archive(store, @vault.load(store),
    { "op": "memory-archive", "id": id, "at": "2026-10-29T08:00:00Z" })))
  assert_true(backwards.has_prefix("memory_time_order_invalid"), msg=backwards)
  let pin_back = fault_of(() => ignore(memory_protect(store, @vault.load(store),
    { "op": "memory-pin", "id": id, "pinned": true, "at": "2020-01-01" })))
  assert_true(pin_back.has_prefix("memory_time_order_invalid"), msg=pin_back)
  let supersede_back = fault_of(() => ignore(memory_supersede(store, @vault.load(store),
    { "op": "memory-supersede", "id": id, "text": "更早的改写", "conditions": [],
      "sources": [], "at": "2026-10-28T09:00:00Z" })))
  assert_true(supersede_back.has_prefix("memory_time_order_invalid"), msg=supersede_back)
  // An inverted record that predates the guard is a lint finding, not silence.
  let path = "state/memory/" + id + ".json"
  let value = @base.parse(@vault.required(store, path))
  let record = match value {
    Object(fields) => { fields["updated_at"] = "2026-10-28T09:00:00Z".to_json(); Json::object(fields) }
    other => other
  }
  (store.write)(path, @base.canonical(record))
  let report = lint_result(store, (store.read)("index.mbt.md"))
  assert_true(has_lint_predicate(@base.array(@base.field(report, "violations")),
    "memory_time_inverted"))
}

fn search_provider_fixture(store : @vault.Storage, at : String) -> Unit raise @base.Fault {
  ignore(dispatch(store, { "op": "provider-register", "provider": "ranker",
    "kind": "search", "space": { "id": "sv", "dimensions": 8 },
    "capabilities": ["search"], "at": at }))
}

test "provider job complete replay is bound to the stored result" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  ignore(search_provider_fixture(store, "2026-10-29T09:00:00Z"))
  let opened = dispatch(store, { "op": "provider-job-open", "provider": "ranker",
    "kind": "search", "space": { "id": "sv", "dimensions": 8 },
    "request": { "query": "陶瓷", "limit": 5 }, "key": "j1",
    "at": "2026-10-29T09:10:00Z" })
  let id = @base.text(@base.field(opened, "id"))
  let valid : Json = { "space": { "id": "sv", "dimensions": 8 }, "hits": [] }
  let first = dispatch(store, { "op": "provider-job-complete", "id": id,
    "result": valid, "at": "2026-10-29T10:00:00Z" })
  assert_eq(@base.boolean(@base.field(first, "replayed")), false)
  // A different payload under the same key is a conflict, not a replay: the
  // ghost hit would never survive validation, so reporting replayed would
  // silently bury a lost result.
  let ghost : Json = { "space": { "id": "sv", "dimensions": 8 },
    "hits": [{ "id": "ghost-page-not-in-vault", "score": 1.0 }] }
  let conflict = fault_of(() => ignore(dispatch(store, { "op": "provider-job-complete",
    "id": id, "result": ghost, "at": "2026-10-29T10:00:00Z" })))
  assert_true(conflict.has_prefix("provider_job_terminal"), msg=conflict)
  let rows = provider_job_rows_unchecked(store, @vault.load(store)).filter(r =>
    @base.text(@base.field(r, "id")) == id)
  // The ghost hit never entered storage: the stored result is the empty one.
  assert_eq(@base.array(@base.field(@base.field(rows[0], "result"), "hits")).length(), 0)
  // The original payload still replays.
  let honest = dispatch(store, { "op": "provider-job-complete", "id": id,
    "result": valid, "at": "2026-10-29T10:00:00Z" })
  assert_eq(@base.boolean(@base.field(honest, "replayed")), true)
}

test "a revoked provider keeps cancel available; complete stays gated" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  ignore(search_provider_fixture(store, "2026-10-29T09:00:00Z"))
  let first = dispatch(store, { "op": "provider-job-open", "provider": "ranker",
    "kind": "search", "space": { "id": "sv", "dimensions": 8 },
    "request": { "query": "陶瓷", "limit": 5 }, "key": "j1",
    "at": "2026-10-29T09:10:00Z" })
  let second = dispatch(store, { "op": "provider-job-open", "provider": "ranker",
    "kind": "search", "space": { "id": "sv", "dimensions": 8 },
    "request": { "query": "釉色", "limit": 5 }, "key": "j2",
    "at": "2026-10-29T09:11:00Z" })
  ignore(dispatch(store, { "op": "provider-unregister", "provider": "ranker",
    "at": "2026-10-29T09:30:00Z" }))
  // Cancellation survives the revocation; the pending count must drain.
  let cancelled = dispatch(store, { "op": "provider-job-cancel",
    "id": @base.text(@base.field(first, "id")), "at": "2026-10-29T09:40:00Z" })
  assert_eq(@base.text(@base.field(cancelled, "status")), "cancelled")
  // Completing new work for a revoked provider is still refused.
  let gated = fault_of(() => ignore(dispatch(store, { "op": "provider-job-complete",
    "id": @base.text(@base.field(second, "id")),
    "result": { "space": { "id": "sv", "dimensions": 8 }, "hits": [] },
    "at": "2026-10-29T09:41:00Z" })))
  assert_true(gated.has_prefix("provider_not_active"), msg=gated)
  // The documented escape hatch still works.
  let failed = dispatch(store, { "op": "provider-job-fail",
    "id": @base.text(@base.field(second, "id")), "error": "provider_revoked",
    "at": "2026-10-29T09:42:00Z" })
  assert_eq(@base.text(@base.field(failed, "status")), "failed")
  assert_true(tool("provider-job-cancel").description.contains("撤销"))
}

test "provider register replay survives heartbeats and echoes the live status" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let request : Json = { "op": "provider-register", "provider": "embedder",
    "kind": "embedding", "space": { "id": "pv", "dimensions": 8 },
    "capabilities": ["embed"], "at": "2026-10-29T09:00:00Z" }
  ignore(dispatch(store, request))
  let replay = dispatch(store, request)
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  // A heartbeat must not close the retry window of the original request.
  ignore(dispatch(store, { "op": "provider-heartbeat", "provider": "embedder",
    "at": "2026-10-29T09:30:00Z" }))
  let after_beat = dispatch(store, request)
  assert_eq(@base.boolean(@base.field(after_beat, "replayed")), true)
  assert_eq(@base.text(@base.field(after_beat, "status")), "active")
  // After revocation the replay still answers, but with the live status.
  ignore(dispatch(store, { "op": "provider-unregister", "provider": "embedder",
    "at": "2026-10-29T10:00:00Z" }))
  let revoked = dispatch(store, request)
  assert_eq(@base.boolean(@base.field(revoked, "replayed")), true)
  assert_eq(@base.text(@base.field(revoked, "status")), "revoked")
  // A genuinely different registration still conflicts.
  let drifted = fault_of(() => ignore(dispatch(store, { "op": "provider-register",
    "provider": "embedder", "kind": "embedding",
    "space": { "id": "pv", "dimensions": 8 }, "capabilities": ["embed"],
    "at": "2026-10-29T09:05:00Z" })))
  assert_true(drifted.has_prefix("provider_registration_conflict"), msg=drifted)
}

test "quality audit replay reports the live fingerprint and the input snapshot" {
  let (store, _broken, _files) = crashing(-1)
  ignore(seed_quality(store))
  let first = quality_audit(store, @vault.load(store),
    { "op": "quality-audit", "at": "2026-10-29T09:00:00Z" })
  let replay = quality_audit(store, @vault.load(store),
    { "op": "quality-audit", "at": "2026-10-29T09:00:00Z" })
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  // Both paths answer with the same live catalog fingerprint.
  assert_eq(@base.text(@base.field(replay, "fingerprint")),
    @base.text(@base.field(first, "fingerprint")))
  // The input snapshot the audit addressed stays separately addressable.
  assert_eq(@base.text(@base.field(replay, "input_fingerprint")),
    quality_baseline(@vault.load(store)))
  assert_eq(@base.text(@base.field(first, "input_fingerprint")),
    quality_baseline(@vault.load(store)))
}
