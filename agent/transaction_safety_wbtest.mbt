// Interruption recovery for the memory and impact operations.
//
// AGENTS.md requires interruption recovery, idempotent retry and external edit
// conflict to be actually tested. `@vault.commit` owns the journal, but each
// operation builds its own change list, so a mistake there would only show up
// as a half-applied transaction. These tests drive the operations through a
// store that fails its Nth write, exactly as a killed process would leave the
// vault, and require that recovery always reaches one consistent state.

fn crashing(fail_after : Int) -> (@vault.Storage, @vault.Storage, Map[String, String]) {
  let files : Map[String, String] = Map([])
  let writes : Map[String, Int] = Map([])
  writes["count"] = 0
  let store : @vault.Storage = {
    read: path => files.get(path),
    read_bytes: path => files.get(path).map(text => @utf8.encode(text)),
    digest: path => files.get(path).map(@base.hex_hash),
    write: (path, text) => { files[path] = text },
    write_bytes: (path, bytes) => { files[path] = try @utf8.decode(bytes) catch {
      _ => raise @base.Fault("invalid_utf8_fixture")
    } },
    mkdirs: _ => (),
    remove: path => { files.remove(path) },
    files: prefix => files.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: path => { ignore(@decl.parse(files[path])) },
  }
  let broken : @vault.Storage = {
    ..store,
    write: (path, text) => {
      writes["count"] = writes.get("count").unwrap_or(0) + 1
      if writes.get("count").unwrap_or(0) > fail_after { raise @base.Fault("injected_crash") }
      files[path] = text
    },
  }
  (store, broken, files)
}

fn submit_note(store : @vault.Storage) -> String raise @base.Fault {
  let result = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "preference", "scope": "workspace",
    "text": "优先安排陶瓷窑口对比的参观时间", "conditions": ["规划博物馆行程时"],
    "sources": [], "at": "2026-10-29T09:00:00Z", "key": "k1",
  })
  @base.text(@base.field(result, "id"))
}

test "memory pin recovers from a crash at any publish point" {
  // Seven writes land in one transaction, so 0..6 fails on each of them.
  for fail_after in [0, 1, 2, 3, 4, 5, 6] {
    let (store, broken, files) = crashing(fail_after)
    ignore(initialize(store, "研究陶瓷"))
    let id = submit_note(store)
    let request : Json = { "op": "memory-pin", "id": id, "pinned": true,
      "at": "2026-10-29T09:30:00Z" }
    let failed = try { ignore(memory_protect(broken, @vault.load(broken), request)); false } catch {
      _ => true
    }
    assert_true(failed)
    // Recovery runs against a working store and always reaches a clean state.
    ignore(@vault.recover(store))
    assert_false(@vault.recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    let row = memory_rows(store, after).filter(n => n.id == id)[0]
    // Either the whole transition landed, or none of it did.
    if row.pinned {
      assert_eq(row.updated_at, "2026-10-29T09:30:00Z")
      assert_true(files.contains("state/events/memory-pin-" + id + "-" +
        @base.hex_hash("true\n2026-10-29T09:30:00Z") + ".json"))
    } else {
      assert_eq(row.updated_at, "2026-10-29T09:00:00Z")
      assert_false(files.contains("state/events/memory-pin-" + id + "-" +
        @base.hex_hash("true\n2026-10-29T09:30:00Z") + ".json"))
    }
    // A pinned note survives an interrupted archive attempt.
    if row.pinned {
      let refused = try {
        ignore(memory_archive(broken, @vault.load(broken), { "op": "memory-archive", "id": id,
          "at": "2026-10-29T10:00:00Z" }))
        false
      } catch { _ => true }
      assert_true(refused)
    }
  }
}

test "memory supersede recovers from a crash at any publish point" {
  // Three changes land in one transaction: the event, the superseded record and
  // its replacement. A partial apply would leave the chain asymmetric.
  // Eight writes land here: the event, the superseded record and its replacement.
  for fail_after in [0, 1, 2, 3, 4, 5, 6, 7] {
    let (store, broken, files) = crashing(fail_after)
    ignore(initialize(store, "研究陶瓷"))
    let id = submit_note(store)
    let request : Json = { "op": "memory-supersede", "id": id,
      "text": "优先安排陶瓷窑口对比的参观时间，并保留半天自由活动",
      "conditions": ["规划博物馆行程时"], "sources": [], "at": "2026-10-29T09:30:00Z" }
    let failed = try { ignore(memory_supersede(broken, @vault.load(broken), request)); false } catch {
      _ => true
    }
    assert_true(failed)
    ignore(@vault.recover(store))
    assert_false(@vault.recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    let rows = memory_rows(store, after)
    let replacement = rows.filter(n => n.supersedes == Some(id))
    if replacement.is_empty() {
      // Nothing landed: the original note is untouched and still active.
      assert_eq(rows.length(), 1)
      assert_eq(rows[0].status, "active")
      assert_eq(rows[0].superseded_by, None)
    } else {
      // The chain landed whole: exactly one replacement, one superseded record.
      assert_eq(replacement.length(), 1)
      assert_eq(rows.length(), 2)
      let old = rows.filter(n => n.id == id)[0]
      assert_eq(old.status, "superseded")
      assert_eq(old.superseded_by, Some(replacement[0].id))
      assert_eq(replacement[0].status, "active")
      assert_eq(replacement[0].supersedes, Some(id))
      // The supersede link is mirrored, which is what lint checks for.
      assert_true(!has_lint_predicate(@base.array(@base.field(lint_result(store, (store.read)("index.mbt.md")), "violations")),
        "memory_supersede_link_asymmetric"))
    }
  }
}

test "memory pin is idempotent and refuses an externally edited record" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let id = submit_note(store)
  let entries = @vault.load(store)
  let first = memory_protect(store, entries, { "op": "memory-pin", "id": id, "pinned": true,
    "at": "2026-10-29T09:30:00Z" })
  assert_eq(@base.boolean(@base.field(first, "replayed")), false)
  let replay = memory_protect(store, @vault.load(store), { "op": "memory-pin", "id": id,
    "pinned": true, "at": "2026-10-29T09:30:00Z" })
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  // A human editing the record outside the engine must not be overwritten.
  let path = "state/memory/" + id + ".json"
  let edited = @base.replace_all(@vault.required(store, path), "\"pinned\":true", "\"pinned\":false")
  files[path] = edited
  let refused = try {
    ignore(memory_protect(store, @vault.load(store), { "op": "memory-pin", "id": id,
      "pinned": true, "at": "2026-10-29T10:00:00Z" }))
    false
  } catch { _ => true }
  assert_true(refused)
  // The edit survives untouched and lint reports the drift.
  assert_eq(@vault.required(store, path), edited)
  assert_true(has_lint_predicate(@base.array(@base.field(lint_result(store, (store.read)("index.mbt.md")), "violations")),
    "content_hash_drift"))
}

test "impact audit recovers from a crash at any publish point" {
  // `impact-audit` writes every drift record and its event in one transaction,
  // so a mistake in its change list would surface only as a half-applied batch.
  // Two research topics drifting together make nine writes; 0..6 fails before
  // the catalog is published and 7..8 after it.
  for fail_after in [0, 1, 2, 3, 4, 5, 6, 7, 8] {
    let (store, broken, files) = crashing(fail_after)
    ignore(initialize(store, "研究陶瓷"))
    ignore(dispatch(store, { "op": "research-topic", "topic": "陶瓷", "queries": ["陶瓷"],
      "at": "2026-11-09T09:00:00Z" }))
    ignore(dispatch(store, { "op": "research-topic", "topic": "釉色", "queries": ["釉色"],
      "at": "2026-11-09T09:05:00Z" }))
    // An adopted external purpose edit moves the knowledge inputs both topics
    // froze, so one audit has to record two drifts.
    files["purpose.md"] = "更新后的目标\n"
    ignore(dispatch(store, { "op": "refresh" }))
    let request : Json = { "op": "impact-audit", "at": "2026-11-09T10:00:00Z" }
    let failed = try {
      ignore(impact_audit(broken, @vault.load(broken), request))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    // Recovery always reaches one consistent state.
    ignore(@vault.recover(store))
    assert_false(@vault.recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    let rows = impact_rows(store, after)
    // The batch is atomic: either both drifts landed or neither did.
    assert_true(rows.length() == 0 || rows.length() == 2)
    // Every landed record must have its event registered in the catalog, not
    // merely written to disk: a dropped event change is invisible to read-log
    // and to the lint check that hunts unregistered state files.
    let events = after.filter(e => e.kind == "state" && e.path.has_prefix("state/events/"))
    for row in rows {
      assert_eq(row.status, "open")
      assert_true(row.frozen != row.current)
      let mut registered = false
      for event in events {
        if !event.path.has_prefix("state/events/impact-open-") { continue }
        let parsed = @base.parse(@vault.required(store, event.path))
        if @base.text(@base.field(parsed, "impact")) == row.id { registered = true }
      }
      assert_true(registered)
    }
    // A re-run either replays a batch that landed or applies one that was
    // rolled back; either way the vault settles and a further run is silent.
    ignore(impact_audit(store, after, { "op": "impact-audit",
      "at": "2026-11-09T11:00:00Z" }))
    let settled_count = impact_rows(store, @vault.load(store)).length()
    assert_true(settled_count == rows.length() || settled_count == 2)
    let settled_fingerprint = @vault.fingerprint(@vault.load(store))
    let quiet = impact_audit(store, @vault.load(store), { "op": "impact-audit",
      "at": "2026-11-09T11:30:00Z" })
    assert_eq(@base.boolean(@base.field(quiet, "committed")), false)
    assert_eq(impact_rows(store, @vault.load(store)).length(), settled_count)
    assert_eq(@vault.fingerprint(@vault.load(store)), settled_fingerprint)
  }
}

fn use_note_request(key : String) -> Json {
  { "op": "memory-submit", "kind": "fact", "scope": "workspace",
    "text": "判断 " + key, "conditions": [], "sources": [],
    "at": "2026-11-11T09:00:00Z", "key": key }
}

test "memory use recovers from a crash at any publish point" {
  // A batch usage report writes one record per note plus a single event, so a
  // mistake in its change list would surface as a partially reported batch.
  for fail_after in [0, 1, 2, 3, 4, 5, 6, 7] {
    let (store, broken, files) = crashing(fail_after)
    ignore(initialize(store, "研究陶瓷"))
    let first = memory_submit(store, @vault.load(store), use_note_request("k1"))
    let first_id = @base.text(@base.field(first, "id"))
    let second = memory_submit(store, @vault.load(store), use_note_request("k2"))
    let second_id = @base.text(@base.field(second, "id"))
    let request : Json = { "op": "memory-use", "ids": [first_id, second_id],
      "at": "2026-11-11T10:00:00Z" }
    let failed = try {
      ignore(memory_use(broken, @vault.load(broken), request))
      false
    } catch {
      _ => true
    }
    assert_true(failed)
    ignore(@vault.recover(store))
    assert_false(@vault.recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    let rows = memory_rows(store, after)
    // The batch is atomic: either both notes were reported or neither was.
    let stamped = rows.filter(n => n.last_used_at == Some("2026-11-11T10:00:00Z"))
    assert_true(stamped.length() == 0 || stamped.length() == 2)
    // The event is registered in the catalog, not merely written to disk.
    let events = after.filter(e => e.kind == "state" && e.path.has_prefix("state/events/"))
    let mut registered = false
    for event in events {
      if !event.path.has_prefix("state/events/memory-use-") { continue }
      let parsed = @base.parse(@vault.required(store, event.path))
      if @base.text(@base.field(parsed, "at")) == "2026-11-11T10:00:00Z" { registered = true }
    }
    assert_eq(registered, stamped.length() == 2)
    // Re-reporting settles and a further report with the same time is silent.
    ignore(memory_use(store, after, request))
    let settled = memory_rows(store, @vault.load(store)).filter(n =>
      n.last_used_at == Some("2026-11-11T10:00:00Z"))
    assert_eq(settled.length(), 2)
    let quiet = memory_use(store, @vault.load(store), request)
    assert_eq(@base.boolean(@base.field(quiet, "replayed")), true)
  }
}

// The core publish path. `commit` rewrites the catalog, the page body, the
// order record and the event file in one transaction, so a change list that
// forgets one of them would leave the catalog describing a page that was never
// written, or an event no record points at.
fn publish_fixture(store : @vault.Storage) -> Json raise @base.Fault {
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
    "pages": [{ "id": "concepts/ceramics", "kind": "concept", "title": "陶瓷",
      "sources": ["raw/ceramics.md"], "tags": ["陶瓷"],
      "body": "南宋官窑的器形与釉色记录。" }],
  })
  { "op": "commit", "order": order, "pages": @base.field(drafts, "pages"),
    "at": "2026-10-29T11:00:00Z" }
}

test "page commit recovers from a crash at any publish point" {
  // One commit writes the staged page, the source summary, the page entries, the
  // order record, the event and the wiki index/log, so the range has to reach
  // past the last write for forward recovery to be exercised at all.
  for fail_after in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] {
    let (store, broken, files) = crashing(fail_after)
    let request = publish_fixture(store)
    let failed = try {
      ignore(commit_pages(broken, @vault.load(broken),
        @base.text(@base.field(request, "order")), @base.field(request, "pages"),
        @base.text(@base.field(request, "at"))))
      false
    } catch { _ => true }
    assert_true(failed)
    ignore(@vault.recover(store))
    assert_false(@vault.recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    // The catalog must never describe a page whose body was not written. This
    // covers every page the commit produced, including the source summary.
    for entry in after {
      if !@core.is_page(entry) { continue }
      assert_true(files.contains(entry.path))
      assert_false(entry.stale)
    }
    // An orphan event file would be unreachable state, so none may survive.
    for path in files.keys() {
      if path.has_prefix("state/events/") {
        assert_true(after.any(e => e.path == path))
      }
    }
  }
}

// The operations below each build their change array inline, so a forgotten
// entry would leave a record on disk that the catalog does not describe, or the
// reverse. Recovery must always reach one consistent state. The raising half
// stays in the test block; this helper holds the pure invariants.
fn assert_consistent(after : Array[@core.Entry], files : Map[String, String]) -> Unit raise {
  // No orphan event file: every event on disk must be registered in the catalog.
  for path in files.keys() {
    if path.has_prefix("state/events/") {
      assert_true(after.any(e => e.path == path))
    }
  }
  // No orphan record: every registered state record must exist on disk.
  for entry in after {
    if entry.kind != "state" { continue }
    assert_true(files.contains(entry.path))
  }
}

// Route through `dispatch`, not `maintenance`: several operations are dispatched
// from the session table, and calling the wrong one fails for a reason that has
// nothing to do with the injected crash. `dispatch` requires the transport keys
// even though it operates on the store it is handed, so `vault` is supplied here
// rather than at every call site. Its value is never read.
fn run_crashed(broken : @vault.Storage, request : Json) -> Unit raise @base.Fault {
  let with_vault : Json = match request {
    Object(fields) => { fields["vault"] = ".".to_json(); Json::object(fields) }
    _ => request
  }
  ignore(dispatch(broken, with_vault))
}

test "research topic recovers from a crash at any publish point" {
  for fail_after in [0, 1, 2, 3, 4, 5] {
    let (store, broken, files) = crashing(fail_after)
    ignore(initialize(store, "研究陶瓷"))
    let failed = try {
      ignore(run_crashed(broken, { "op": "research-topic", "topic": "陶瓷窑口",
        "queries": ["陶瓷 器形"], "at": "2026-10-29T09:00:00Z", "key": "rt" }))
      false
    } catch { _ => true }
    assert_true(failed)
    ignore(@vault.recover(store))
    let again : Bool = try { @vault.recover(store) } catch { _ => true }
    assert_false(again)
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    assert_consistent(after, files)
    let rows = research_rows(store, after)
    // Either the topic is registered with its event, or neither exists.
    if rows.length() == 1 {
      assert_true(files.contains("state/events/research-" +
        @base.text(@base.field(rows[0], "id")) + ".json"))
    } else {
      assert_true(rows.is_empty())
    }
  }
}

test "purpose suggestion recovers from a crash at any publish point" {
  let store = each_crash_point(seed_quality, { "op": "purpose-suggest",
    "at": "2026-10-29T09:00:00Z", "key": "ps" })
  let rows = suggestion_rows(store, @vault.load(store))
  assert_eq(rows.length(), 1)
  assert_eq(@base.text(@base.field(rows[0], "status")), "proposed")
  assert_true((store.read)("state/suggestions/" +
    @base.text(@base.field(rows[0], "id")) + ".json") is Some(_))
  // A suggestion never rewrites purpose.md: the host applies it explicitly.
  assert_eq(@vault.required(store, "purpose.md"), "研究陶瓷\n")
}

test "overview suggestion recovers from a crash at any publish point" {
  let store = each_crash_point(seed_quality, { "op": "overview-suggest",
    "at": "2026-10-29T09:00:00Z", "key": "os" })
  let rows = overview_rows(store, @vault.load(store))
  assert_eq(rows.length(), 1)
  assert_eq(@base.text(@base.field(rows[0], "status")), "proposed")
  assert_true((store.read)("state/overview/" +
    @base.text(@base.field(rows[0], "id")) + ".json") is Some(_))
  // A suggestion never publishes the synthesis page itself.
  assert_true((store.read)("wiki/overview.md") is None)
}

test "provider registration recovers from a crash at any publish point" {
  let store = each_crash_point(seed_quality, { "op": "provider-register",
    "provider": "本地向量后端", "kind": "embedding",
    "space": { "id": "ceramics-vec", "dimensions": 8 },
    "capabilities": ["embed"], "at": "2026-10-29T09:00:00Z" })
  let rows = provider_entries(store, @vault.load(store))
  assert_eq(rows.length(), 1)
  assert_eq(@base.text(@base.field(rows[0], "status")), "active")
}

// Crash at every publish point of one transaction. The loop stops as soon as
// the operation lands, and that final iteration is the clean run: an operation
// whose change list forgets to register an event leaves an orphan file exactly
// there, which is what `assert_consistent` catches. Returns the store after the
// clean run so the caller can assert the landed state.
fn each_crash_point(
  seed : (@vault.Storage) -> Unit raise @base.Fault,
  request : Json,
) -> @vault.Storage raise {
  // Prove the operation is reachable before crashing it. `assert_true(failed)`
  // below is satisfied by ANY failure, so a request with a wrong field name or a
  // missing transport key fails validation and looks exactly like an injected
  // crash -- three tests were decorative that way. Running the op on a clean
  // store first makes an unreachable operation fail loudly instead.
  let (probe, _, _) = crashing(1 << 20)
  seed(probe)
  let reachable = try { ignore(run_crashed(probe, request)); true } catch { _ => false }
  assert_true(reachable, msg="operation never ran on a clean store: " + @base.canonical(request))
  let mut fail_after = 0
  let mut landed = crashing(0).0
  while (true) {
    let (store, broken, files) = crashing(fail_after)
    seed(store)
    let failed = try { ignore(run_crashed(broken, request)); false } catch { _ => true }
    if !failed {
      // The clean run: no crash, so the whole change list landed.
      landed = store
      let after = @vault.load(store)
      assert_consistent(after, files)
      break
    }
    ignore(@vault.recover(store))
    let again : Bool = try { @vault.recover(store) } catch { _ => true }
    assert_false(again)
    assert_false(files.contains("state/transactions/pending.json"))
    let after = @vault.load(store)
    @vault.verify(store, after)
    assert_consistent(after, files)
    fail_after = fail_after + 1
    // An operation that never lands would otherwise spin forever.
    if fail_after > 64 { @base.fail("operation never landed: " + @base.canonical(request)) }
  }
  landed
}

// Writes one raw source and returns the order `scan` created for it. Scanning
// twice would find nothing the second time, so the order is captured here.
fn seed_source(store : @vault.Storage) -> String raise @base.Fault {
  ignore(initialize(store, "研究陶瓷"))
  (store.write)("raw/ceramics.md", "南宋官窑的器形与釉色记录。\n")
  let scanned = scan(store, @vault.load(store))
  @base.text(@base.array(@base.field(scanned, "orders"))[0])
}

fn seed_quality(store : @vault.Storage) -> Unit raise @base.Fault {
  ignore(seed_source(store))
}

test "quality audit recovers from a crash at any publish point" {
  ignore(each_crash_point(seed_quality, { "op": "quality-audit",
    "at": "2026-10-29T09:00:00Z" }))
}

fn seed_research(store : @vault.Storage) -> Unit raise @base.Fault {
  seed_quality(store)
  ignore(run_crashed(store, { "op": "research-topic", "topic": "陶瓷窑口",
    "queries": ["陶瓷 器形"], "at": "2026-10-29T08:00:00Z", "key": "rt" }))
}

test "research completion recovers from a crash at any publish point" {
  let topic = {
    let (store, _, _) = crashing(0)
    seed_research(store)
    @base.text(@base.field(research_rows(store, @vault.load(store))[0], "id"))
  }
  let store = each_crash_point(seed_research, { "op": "research-complete", "id": topic,
    "sources": ["raw/ceramics.md"], "at": "2026-10-29T09:00:00Z" })
  let rows = research_rows(store, @vault.load(store)).filter(r =>
    @base.text(@base.field(r, "id")) == topic)
  assert_eq(rows.length(), 1)
  assert_eq(@base.text(@base.field(rows[0], "status")), "completed")
  assert_eq(@base.text(@base.field(rows[0], "closed_at")), "2026-10-29T09:00:00Z")
}

fn seed_page(store : @vault.Storage) -> Unit raise @base.Fault {
  let order = seed_source(store)
  let context = context(store, @vault.load(store), order)
  ignore(submit_analysis(store, @vault.load(store), order, {
    "entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷记录",
  }))
  let drafts = submit_drafts(store, @vault.load(store), {
    "op": "draft-submit", "order": order,
    "context_token": @base.field(context, "context_token"),
    "pages": [{ "id": "concepts/ceramics", "kind": "concept", "title": "陶瓷",
      "sources": ["raw/ceramics.md"], "tags": ["陶瓷"],
      "body": "南宋官窑的器形与釉色记录。" }],
  })
  ignore(commit_pages(store, @vault.load(store), order,
    @base.field(drafts, "pages"), "2026-10-29T08:30:00Z"))
}

test "page archive recovers from a crash at any publish point" {
  let store = each_crash_point(seed_page, { "op": "archive-page",
    "id": "concepts/ceramics", "at": "2026-10-29T09:00:00Z",
    "reason": "来源内容已变更" })
  // An archived page keeps its body on disk; only its catalog state changes.
  let after = @vault.load(store)
  assert_true((store.read)("wiki/concepts/ceramics.md") is Some(_))
  assert_true(@core.find(after, "concepts/ceramics").stale)
}

test "source revocation recovers from a crash at any publish point" {
  let store = each_crash_point(seed_quality, { "op": "forget",
    "source": "raw/ceramics.md", "at": "2026-10-29T09:00:00Z" })
  // Revocation is durable and visible in the catalog once it lands.
  assert_true(@core.find(@vault.load(store), "raw/ceramics.md").stale)
}
