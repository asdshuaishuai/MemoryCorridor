// Every memory note now belongs to a registered workspace. Tests register one
// canonical path and derive its id with the same recipe the engine uses.
fn test_ws() -> String {
  @core.workspace_id("/test/memory-project")
}

fn memory_open_workspace(store : @vault.Storage) -> Unit raise @base.Fault {
  ignore(dispatch(store, { "op": "workspace-open", "path": "/test/memory-project",
    "at": "2026-10-20T00:00:00Z" }))
}

test "memory note identity is content addressed and supersede preserves history" {
  let conditions = ["规划博物馆行程时"]
  let digest = @core.memory_note_hash(test_ws(), "project", "", "preference", "优先安排陶瓷参观时间", conditions, [], [], Json::null(), Json::null(), false, "judgment")
  let id = @core.memory_note_id("ceramics", digest)
  assert_eq(id, @core.memory_note_id("ceramics", digest))
  // Same key and content replay; a correction derives a different id.
  let corrected = @core.memory_note_hash(test_ws(), "project", "", "preference", "优先安排陶瓷参观时间并保留自由活动", conditions, [], [], Json::null(), Json::null(), false, "judgment")
  assert_true(@core.memory_note_id("ceramics", corrected) != id)
  // A condition changes the identity even when the text does not.
  let reconditioned = @core.memory_note_hash(test_ws(), "project", "", "preference", "优先安排陶瓷参观时间", ["规划城市行程时"], [], [], Json::null(), Json::null(), false, "judgment")
  assert_true(reconditioned != digest)
  // The key participates in the record id, so two keys never share a note.
  assert_true(@core.memory_note_id("other", digest) != id)
}

test "memory note json round trip keeps nullable transition fields" {
  let body = "官窑记录来自已登记来源"
  let note : MemoryNote = {
    id: @core.memory_note_id("k", @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment")),
    workspace: test_ws(), kind: "fact", scope: "project", layer: "judgment", session: None, text: body,
    conditions: [], sources: [], source_hashes: [], status: "archived", key: "k",
    created_at: "2026-10-20T09:00:00Z", updated_at: "2026-10-20T10:00:00Z",
    archived_at: Some("2026-10-20T10:00:00Z"), superseded_by: None, supersedes: None,
    pinned: false, last_used_at: None,
    importance: None, emotion: None, episodic: false, promoted_at: None, use_count: 0,
    note_hash: @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment"),
  }
  let text = @base.canonical(note.to_json())
  let parsed = memory_from_json(@base.parse(text))
  assert_eq(parsed.id, note.id)
  assert_eq(parsed.status, "archived")
  assert_eq(parsed.archived_at, Some("2026-10-20T10:00:00Z"))
  assert_eq(parsed.superseded_by, None)
  assert_eq(@base.canonical(parsed.to_json()), text)
}

fn json_override(value : Json, key : String, replacement : Json) -> Json {
  match value {
    Object(fields) => {
      let copy = fields.copy()
      copy[key] = replacement
      Json::object(copy)
    }
    other => other
  }
}

fn refuses(action : () -> Unit raise @base.Fault) -> Bool {
  try {
    action()
    false
  } catch {
    _ => true
  }
}

fn event_entry(path : String, content : String) -> @core.Entry {
  { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
}

test "memory record validation rejects drift between fields and identity" {
  let body = "t"
  let id = @core.memory_note_id("k", @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment"))
  let path = "state/memory/" + test_ws() + "/" + id + ".json"
  let entry : @core.Entry = {
    id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  let base : Json = { "version": 4, "id": id, "workspace": test_ws(), "kind": "fact", "scope": "project", "layer": "judgment", "session": Json::null(),
    "text": body, "conditions": [], "sources": [], "status": "active", "key": "k",
    "created_at": "2026-10-20T09:00:00Z", "updated_at": "2026-10-20T09:00:00Z",
    "archived_at": Json::null(), "superseded_by": Json::null(), "supersedes": Json::null(),
    "source_hashes": Json::array([]), "pinned": false, "last_used_at": Json::null(),
    "importance": Json::null(), "emotion": Json::null(), "episodic": false,
    "promoted_at": Json::null(), "use_count": Json::number(0.0),
    "note_hash": @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment") }
  @core.validate_record(entry, @base.canonical(base))
  // Unknown fields and unsupported kinds/scopes are refused, not ignored.
  let refused : Array[Json] = [
    json_override(base, "kind", "habit".to_json()),
    json_override(base, "scope", "user".to_json()),
    json_override(base, "extra", Json::number(1.0)),
    json_override(base, "text", "changed".to_json()),
    json_override(base, "note_hash", "0000000000000000000000000000000000000000000000000000000000000001".to_json()),
  ]
  // Source hashes pair one-to-one with sources and must be real digests. Both
  // fields take part in the identity, so a mismatch is refused either way.
  let bound = json_override(base, "sources", ["raw/a.md"].to_json())
  for bad in [
    json_override(bound, "source_hashes", Json::array([])),
    json_override(bound, "source_hashes", ["short"].to_json()),
    json_override(bound, "source_hashes",
      ["1111111111111111111111111111111111111111111111111111111111111111"].to_json()),
  ] {
    assert_true(refuses(() => @core.validate_record(entry, @base.canonical(bad))))
  }
  for bad in refused {
    assert_true(refuses(() => @core.validate_record(entry, @base.canonical(bad))))
  }
  // An archived note must carry its archive timestamp; a superseded one a target.
  let archived = json_override(base, "status", "archived".to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(archived))))
  let superseded = json_override(base, "status", "superseded".to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(superseded))))
  // A replacement may not be the note itself.
  let self_supersede = json_override(json_override(superseded, "superseded_by", id.to_json()),
    "note_hash", @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment").to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(self_supersede))))
}

test "memory event dictionary rejects unknown operations and forged paths" {
  let body = "t"
  let note_id = @core.memory_note_id("k", @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment"))
  let note_hash = @core.memory_note_hash(test_ws(), "project", "", "fact", body, [], [], [], Json::null(), Json::null(), false, "judgment")
  let submit : Json = { "op": "memory-submit", "memory": note_id, "at": "2026-10-20T09:00:00Z",    "key": "k", "note_hash": note_hash, "supersedes": Json::null() }
  let submit_path = "state/events/memory-submit-" + note_id + ".json"
  @core.validate_record(event_entry(submit_path, @base.canonical(submit)), @base.canonical(submit))
  assert_true(refuses(() => @core.validate_record(
    event_entry("state/events/memory-submit-other.json", @base.canonical(submit)),
    @base.canonical(submit))))
  let archive : Json = { "op": "memory-archive", "memory": note_id, "at": "2026-10-20T10:00:00Z" }
  let archive_event = "state/events/memory-archive-" + note_id + "-" + @base.hex_hash("2026-10-20T10:00:00Z") + ".json"
  @core.validate_record(event_entry(archive_event, @base.canonical(archive)), @base.canonical(archive))
  let unknown : Json = { "op": "memory-forget", "memory": note_id, "at": "2026-10-20T10:00:00Z" }
  assert_true(refuses(() => @core.validate_record(
    event_entry("state/events/memory-forget-" + note_id + ".json", @base.canonical(unknown)),
    @base.canonical(unknown))))
}

test "memory tools declare strict field sets and bounded prefetch limits" {
  assert_eq(tool("memory-submit").fields, ["workspace", "session", "kind", "scope", "layer", "text", "conditions", "sources", "importance", "emotion", "at", "key"])
  assert_eq(tool("memory-supersede").fields, ["workspace", "session", "id", "text", "conditions", "sources", "importance", "emotion", "at", "key"])
  assert_eq(tool("memory-archive").fields, ["workspace", "session", "id", "at"])
  assert_eq(tool("memory-restore").fields, ["workspace", "session", "id", "at"])
  assert_eq(tool("memory-list").fields, ["workspace", "session"])
  let prefetch = tool("memory-prefetch")
  assert_eq(prefetch.fields, ["workspace", "session", "query", "page", "limit", "rank", "now", "archived", "dedup", "kinds"])
  let properties = @base.field(input_schema(prefetch), "properties")
  assert_eq(@base.field(@base.field(properties, "limit"), "maximum"), Json::number(50.0))
  assert_eq(@base.field(@base.field(properties, "limit"), "minimum"), Json::number(1.0))
  assert_eq(@base.field(@base.field(properties, "archived"), "type"), "boolean".to_json())
  let submit_properties = @base.field(input_schema(tool("memory-submit")), "properties")
  assert_eq(@base.field(@base.field(submit_properties, "conditions"), "type"), "array".to_json())
  assert_eq(@base.field(@base.field(submit_properties, "conditions"), "items"), { "type": "string" })
  assert_eq(@base.field(@base.field(submit_properties, "sources"), "type"), "array".to_json())
  assert_eq(@base.field(@base.field(submit_properties, "text"), "type"), "string".to_json())
  let optional_fields = ["conditions", "sources", "key", "limit", "rank", "now", "archived"]
  for name in optional_fields {
    assert_true(!@base.array(@base.field(input_schema(prefetch), "required")).contains(name.to_json()))
  }
  // `query` and `page` are alternatives, so neither is required by the schema;
  // the operation enforces that exactly one is supplied.
  for name in ["query", "page"] {
    assert_true(!@base.array(@base.field(input_schema(prefetch), "required")).contains(name.to_json()))
  }
  for name in ["workspace", "kind", "scope", "text", "at"] {
    assert_true(@base.array(@base.field(input_schema(tool("memory-submit")), "required")).contains(name.to_json()))
  }
  for name in ["workspace", "id", "text", "at"] {
    assert_true(@base.array(@base.field(input_schema(tool("memory-supersede")), "required")).contains(name.to_json()))
  }
  // Derived workspace pages are a list of page ids, not the object array other
  // tools use for newly authored pages.
  let wiki = tool("workspace-wiki-plan")
  assert_eq(wiki.fields, ["workspace", "namespace", "pages", "limit"])
  let wiki_props = @base.field(input_schema(wiki), "properties")
  assert_eq(@base.field(@base.field(wiki_props, "pages"), "items"), { "type": "string" })
  let wiki_required = @base.array(@base.field(input_schema(wiki), "required"))
  assert_true(!wiki_required.contains("namespace".to_json()) &&
    !wiki_required.contains("pages".to_json()))
  let note_props = @base.field(input_schema(tool("dream-note-submit")), "properties")
  assert_eq(@base.field(@base.field(note_props, "inputs"), "type"), "object".to_json())
  assert_eq(@base.field(@base.field(note_props, "claims"), "items"), { "type": "object" })
}

fn memory_note(
  id : String, kind : String, text : String, conditions : Array[String], status : String,
) -> MemoryNote {
  {
    id, workspace: test_ws(), kind, scope: "project", layer: "judgment", session: None, text, conditions, sources: [], source_hashes: [],
    status, key: id,
    created_at: "2026-10-22T09:00:00Z", updated_at: "2026-10-22T09:00:00Z",
    archived_at: None, superseded_by: None, supersedes: None, pinned: false,
    last_used_at: None,
    importance: None, emotion: None, episodic: false, promoted_at: None, use_count: 0,
    note_hash: @core.memory_note_hash(test_ws(), "project", "", kind, text, conditions, [], [], Json::null(), Json::null(), false, "judgment"),
  }
}

test "memory conflict grouping needs the same kind and conditions" {
  let same = memory_note("a", "preference", "先看陶瓷", ["规划行程"], "active")
  let rival = memory_note("b", "preference", "先看青铜器", ["规划行程"], "active")
  let other_kind = memory_note("c", "constraint", "预算三千", ["规划行程"], "active")
  let other_condition = memory_note("d", "preference", "阅读先看摘要", ["整理资料"], "active")
  let superseded = memory_note("e", "preference", "先看书画", ["规划行程"], "superseded")
  let archived = memory_note("f", "preference", "先看玉器", ["规划行程"], "archived")
  let rows = [same, rival, other_kind, other_condition, superseded, archived]
  let groups = memory_conflict_groups(rows)
  assert_eq(groups.length(), 1)
  assert_eq(groups[0].length(), 2)
  assert_eq(groups[0][0].id, "a")
  assert_eq(groups[0][1].id, "b")
  let conflicted = memory_conflicted(rows)
  assert_true(conflicted.get("a").unwrap_or(false))
  assert_true(conflicted.get("b").unwrap_or(false))
  for quiet in ["c", "d", "e", "f"] {
    assert_true(!conflicted.get(quiet).unwrap_or(false))
  }
  // Condition order is not part of the conflict key.
  let reordered = memory_note("g", "preference", "先看陶瓷", ["乙条件", "甲条件"], "active")
  let base = memory_note("h", "preference", "先看青铜器", ["甲条件", "乙条件"], "active")
  assert_eq(memory_conflict_key(reordered), memory_conflict_key(base))
  assert_eq(memory_conflict_groups([reordered, base]).length(), 1)
  // Identical text under the same conditions is a duplicate, not a conflict.
  let twin = memory_note("i", "preference", "先看陶瓷", ["规划行程"], "active")
  assert_eq(memory_conflict_groups([same, twin]).length(), 0)
}

test "memory conflict tools and views" {
  assert_eq(tool("memory-conflicts").fields, ["workspace", "session"])
  let schema = input_schema(tool("memory-conflicts"))
  assert_eq(@base.field(schema, "type"), "object".to_json())
  let required = @base.array(@base.field(schema, "required"))
  assert_eq(required.length(), 1)
  assert_eq(required[0], "workspace".to_json())
}

test "memory prefetch dedup and kind filters are schema-checked" {
  let prefetch = tool("memory-prefetch")
  assert_eq(prefetch.fields, ["workspace", "session", "query", "page", "limit", "rank", "now", "archived", "dedup", "kinds"])
  let schema = input_schema(prefetch)
  let properties = @base.field(schema, "properties")
  assert_eq(@base.field(@base.field(properties, "kinds"), "type"), "array".to_json())
  assert_eq(@base.field(@base.field(properties, "kinds"), "items"), { "type": "string" })
  assert_eq(@base.field(@base.field(properties, "dedup"), "type"), "string".to_json())
  for name in ["dedup", "kinds", "archived", "limit"] {
    assert_true(!@base.array(@base.field(schema, "required")).contains(name.to_json()))
  }
  // `query` and `page` are alternatives, so neither is required by the schema.
  for name in ["query", "page"] {
    assert_true(!@base.array(@base.field(schema, "required")).contains(name.to_json()))
  }
  // The similar gate is shared with page retrieval, so both sides must clear it.
  assert_true(@index.similar_eligible("陶瓷窑口对比的参观时间安排，需要保留半天的自由活动余量"))
  assert_true(!@index.similar_eligible("预算三千"))
  let long_note = "陶瓷窑口对比的参观时间安排，需要保留半天的自由活动余量"
  assert_true(@index.similar_merge(@index.similar_tokens(long_note),
    @index.similar_tokens(long_note + "。")))
  assert_true(!@index.similar_merge(@index.similar_tokens(long_note),
    @index.similar_tokens("完全不同的另一段说明文字，长度也足够通过门槛")))
}

test "memory read and pin tools declare strict field sets" {
  assert_eq(tool("memory-read").fields, ["workspace", "session", "id"])
  assert_eq(tool("memory-pin").fields, ["workspace", "session", "id", "pinned", "at"])
  let read_schema = input_schema(tool("memory-read"))
  assert_eq(@base.field(read_schema, "required"), ["workspace", "id"].to_json())
  let pin_schema = input_schema(tool("memory-pin"))
  let pin_properties = @base.field(pin_schema, "properties")
  assert_eq(@base.field(@base.field(pin_properties, "pinned"), "type"), "boolean".to_json())
  for name in ["id", "pinned", "at"] {
    assert_true(@base.array(@base.field(pin_schema, "required")).contains(name.to_json()))
  }
}

test "memory pin event path binds the flag and the time" {
  let memory = @core.memory_note_id("k", @core.memory_note_hash(test_ws(), "project", "", "fact", "t", [], [], [], Json::null(), Json::null(), false, "judgment"))
  let at = "2026-10-27T09:30:00Z"
  for pinned in [true, false] {
    let event : Json = { "op": "memory-pin", "memory": memory, "at": at, "pinned": pinned }
    let path = "state/events/memory-pin-" + memory + "-" +
      @base.hex_hash(pinned.to_string() + "\n" + at) + ".json"
    @core.validate_record(event_entry(path, @base.canonical(event)), @base.canonical(event))
    // The other flag value addresses a different transition.
    let other = "state/events/memory-pin-" + memory + "-" +
      @base.hex_hash((!pinned).to_string() + "\n" + at) + ".json"
    assert_true(refuses(() => @core.validate_record(event_entry(other, @base.canonical(event)),
      @base.canonical(event))))
  }
  // A supersede event must name the note it replaces.
  let superseded = @base.hex_hash("memory-v1\nold\n" + @core.memory_note_hash(test_ws(), "project", "", "fact", "a", [], [], [], Json::null(), Json::null(), false, "judgment"))
  let replacement = @core.memory_note_id("old", @core.memory_note_hash(test_ws(), "project", "", "fact", "b", [], [], [], Json::null(), Json::null(), false, "judgment"))
  let event : Json = { "op": "memory-supersede", "memory": replacement, "at": at, "key": "k",
    "note_hash": @core.memory_note_hash(test_ws(), "project", "", "fact", "b", [], [], [], Json::null(), Json::null(), false, "judgment"),
    "supersedes": superseded }
  let path = "state/events/memory-supersede-" + superseded + "-" + replacement + ".json"
  @core.validate_record(event_entry(path, @base.canonical(event)), @base.canonical(event))
  let no_previous = json_override(event, "supersedes", Json::null())
  assert_true(refuses(() => @core.validate_record(event_entry(path, @base.canonical(no_previous)),
    @base.canonical(no_previous))))
  let self_reference = json_override(event, "supersedes", replacement.to_json())
  assert_true(refuses(() => @core.validate_record(event_entry(path, @base.canonical(self_reference)),
    @base.canonical(self_reference))))
}

test "memory prefetch accepts exactly one of query or page" {
  let prefetch = tool("memory-prefetch")
  assert_eq(prefetch.fields, ["workspace", "session", "query", "page", "limit", "rank", "now", "archived", "dedup", "kinds"])
  let schema = input_schema(prefetch)
  let required = @base.array(@base.field(schema, "required"))
  // Both are optional in the schema because exactly one must be supplied; the
  // operation itself enforces the exclusivity.
  for name in ["query", "page", "limit", "rank", "now", "archived", "dedup", "kinds"] {
    assert_true(!required.contains(name.to_json()))
  }
  let properties = @base.field(schema, "properties")
  assert_eq(@base.field(@base.field(properties, "query"), "type"), "string".to_json())
  assert_eq(@base.field(@base.field(properties, "page"), "type"), "string".to_json())
}

test "memory source hashes pin the bytes a note was written against" {
  // Without the digest a note survives a wholesale rewrite of its source and
  // keeps claiming evidence that now says something else entirely.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  files["raw/a.md"] = "官窑记录：器形与釉色。\\n"
  ignore(dispatch(store, { "op": "scan" }))
  ignore(memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "fact", "scope": "project", "workspace": test_ws(),
    "text": "官窑记录来自已登记来源，器形与釉色可据此核对",
    "conditions": ["核对官窑资料时"], "sources": ["raw/a.md"],
    "at": "2026-11-05T09:00:00Z", "key": "k1" }))
  let entries = @vault.load(store)
  let note = memory_rows(store, entries, test_ws(), None)[0]
  assert_eq(note.sources, ["raw/a.md"])
  assert_eq(note.source_hashes.length(), 1)
  assert_eq(note.source_hashes[0], @base.hex_hash("官窑记录：器形与釉色。\\n"))
  assert_true(@base.boolean(@base.field(memory_view(note, entries, false), "valid")))
  // Rewriting the source and re-registering it is drift, not survival.
  files["raw/a.md"] = "完全无关的内容：天气与市场行情。\\n"
  ignore(dispatch(store, { "op": "scan" }))
  let rewritten = @vault.load(store)
  let drifted = memory_rows(store, rewritten, test_ws(), None)[0]
  let view = memory_view(drifted, rewritten, false)
  assert_false(@base.boolean(@base.field(view, "valid")))
  assert_eq(@base.field(view, "drifted_sources"), ["raw/a.md"].to_json())
  assert_eq(@base.array(@base.field(view, "invalid_sources")).length(), 0)
  // Revoking the source is a different diagnosis from rewriting it.
  ignore(memory_archive(store, rewritten, { "op": "memory-archive", "workspace": test_ws(), "id": drifted.id,
    "at": "2026-11-05T10:00:00Z" }))
  let revoked = @vault.load(store)
  let after = memory_rows(store, revoked, test_ws(), None)[0]
  assert_false(@base.boolean(@base.field(memory_view(after, revoked, false), "valid")))
}

fn memory_submit_request(source : String, key : String, text : String) -> Json {
  { "op": "memory-submit", "kind": "fact", "scope": "project", "workspace": test_ws(),
    "text": text, "conditions": ["核对官窑资料时"],
    "sources": [source], "at": "2026-11-06T09:00:00Z", "key": key }
}

test "duplicate and conflict detection ignore the evidence binding" {
  // `note_hash` pins which bytes a note was written against, so it must not
  // decide whether two notes say the same thing. Two notes with identical text
  // and conditions are duplicates even when they cite different sources, and
  // must not be reported as competing judgments.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  files["raw/a.md"] = "官窑记录：器形与釉色。\n"
  files["raw/b.md"] = "另一份官窑记录。\n"
  ignore(dispatch(store, { "op": "scan" }))
  let judgment = "官窑记录的器形与釉色可据此核对"
  let first = memory_submit(store, @vault.load(store),
    memory_submit_request("raw/a.md", "k1", judgment))
  let first_id = @base.text(@base.field(first, "id"))
  let refused = try {
    ignore(memory_submit(store, @vault.load(store),
      memory_submit_request("raw/b.md", "k2", judgment)))
    "accepted"
  } catch {
    @base.Fault(message) => message
  }
  assert_true(refused.has_prefix("memory_duplicate_text"))
  let rows = memory_rows(store, @vault.load(store), test_ws(), None)
  assert_eq(rows.length(), 1)
  assert_eq(memory_conflict_groups(rows).length(), 0)
  // A genuinely different judgment under the same conditions still conflicts.
  ignore(memory_submit(store, @vault.load(store),
    memory_submit_request("raw/a.md", "k3", "官窑记录只说明器形，不涉及釉色")))
  let conflicted = memory_rows(store, @vault.load(store), test_ws(), None)
  assert_eq(conflicted.length(), 2)
  let groups = memory_conflict_groups(conflicted)
  assert_eq(groups.length(), 1)
  assert_eq(groups[0].length(), 2)
  let mut holds_first = false
  for note in groups[0] {
    if note.id == first_id { holds_first = true }
  }
  assert_true(holds_first)
  // An identical retry still replays rather than forking.
  let again = memory_submit(store, @vault.load(store),
    memory_submit_request("raw/a.md", "k1", judgment))
  assert_true(@base.boolean(@base.field(again, "replayed")))
  assert_eq(@base.text(@base.field(again, "id")), first_id)
  assert_eq(memory_rows(store, @vault.load(store), test_ws(), None).length(), 2)
}


fn archived_note_request(key : String, at : String) -> Json {
  { "op": "memory-submit", "kind": "decision", "scope": "project", "workspace": test_ws(),
    "text": "阶段性结论：先整理陶瓷资料", "conditions": ["规划资料整理范围时"],
    "sources": [], "at": at, "key": key }
}

test "an archived note does not block the same judgment" {
  // Archived notes have left the default set and stay restorable, so they must
  // not be treated as competing with a fresh submission of the same judgment.
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let first = memory_submit(store, @vault.load(store),
    archived_note_request("k1", "2026-11-07T09:00:00Z"))
  let first_id = @base.text(@base.field(first, "id"))
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive", "workspace": test_ws(),
    "id": first_id, "at": "2026-11-07T09:30:00Z" }))
  let reborn = memory_submit(store, @vault.load(store),
    archived_note_request("k2", "2026-11-07T10:00:00Z"))
  assert_eq(@base.text(@base.field(reborn, "status")), "active")
  assert_true(@base.text(@base.field(reborn, "id")) != first_id)
  let rows = memory_rows(store, @vault.load(store), test_ws(), None)
  assert_eq(rows.length(), 2)
  assert_eq(rows.filter(n => n.status == "archived").length(), 1)
  assert_eq(memory_conflict_groups(rows).length(), 0)
  // The competing ACTIVE note still refuses a duplicate.
  let refused = try {
    ignore(memory_submit(store, @vault.load(store),
      archived_note_request("k3", "2026-11-07T11:00:00Z")))
    "accepted"
  } catch {
    @base.Fault(message) => message
  }
  assert_true(refused.has_prefix("memory_duplicate_text"))
}

test "memory use records foreground usage and replays" {
  // Autodream archives long-unused notes, which needs a usage signal the engine
  // cannot infer from a read-only prefetch.
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let first = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "fact", "scope": "project", "workspace": test_ws(),
    "text": "官窑记录可据此核对", "conditions": ["核对官窑资料时"],
    "sources": [], "at": "2026-11-11T09:00:00Z", "key": "k1" })
  let first_id = @base.text(@base.field(first, "id"))
  let second = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "decision", "scope": "project", "workspace": test_ws(),
    "text": "先整理陶瓷资料", "conditions": [], "sources": [],
    "at": "2026-11-11T09:05:00Z", "key": "k2" })
  let second_id = @base.text(@base.field(second, "id"))
  assert_eq(memory_rows(store, @vault.load(store), test_ws(), None).filter(n => n.last_used_at is None).length(), 2)
  // A batch reports many notes in one transaction.
  let used = memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [first_id, second_id], "at": "2026-11-11T10:00:00Z" })
  assert_eq(@base.field(used, "used"), Json::number(2.0))
  let rows = memory_rows(store, @vault.load(store), test_ws(), None)
  assert_eq(rows.filter(n => n.last_used_at == Some("2026-11-11T10:00:00Z")).length(), 2)
  // The same report twice is a replay, not a second write.
  let replay = memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [first_id, second_id], "at": "2026-11-11T10:00:00Z" })
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  assert_eq(@base.field(replay, "committed"), Json::boolean(false))
  // A later report advances the timestamp.
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [first_id], "at": "2026-11-11T11:00:00Z" }))
  let advanced = memory_rows(store, @vault.load(store), test_ws(), None).filter(n =>
    n.last_used_at == Some("2026-11-11T11:00:00Z"))
  assert_eq(advanced.length(), 1)
  // Prefetch itself never records usage.
  ignore(memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch", "workspace": test_ws(), "query": "陶瓷" }))
  let still = memory_rows(store, @vault.load(store), test_ws(), None).filter(n =>
    n.last_used_at == Some("2026-11-11T11:00:00Z"))
  assert_eq(still.length(), 1)
  // Bad batches are refused without touching the vault.
  let bad : Array[Json] = [
    { "op": "memory-use", "workspace": test_ws(), "ids": Json::array([]), "at": "2026-11-11T12:00:00Z" },
    { "op": "memory-use", "workspace": test_ws(), "ids": [first_id, first_id], "at": "2026-11-11T12:00:00Z" },
    { "op": "memory-use", "workspace": test_ws(), "ids": ["0".repeat(64)], "at": "2026-11-11T12:00:00Z" },
  ]
  for bad_request in bad {
    assert_true(refuses(() => ignore(memory_use(store, @vault.load(store), bad_request))))
  }
}

// Same tokens, different bytes: the merge signal is "reworded duplicate", which
// is what `similar_merge` actually tests.
fn merge_pair_texts() -> (String, String) {
  ("官窑记录的器形与釉色特征可以据此核对，包括胎质釉层厚度与开片形态便于断代参考",
   "官窑记录的器形与釉色特征可以据此核对；包括胎质釉层厚度与开片形态便于断代参考")
}

test "memory candidates proposes a reworded duplicate without a seed" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let (first, second) = merge_pair_texts()
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": first, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "a" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": second, "conditions": ["撰写说明"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "b" }))
  let candidates = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2026-11-26T00:00:00Z" })
  let merge = @base.array(@base.field(candidates, "merge"))
  assert_eq(merge.length(), 1)
  let row = merge[0]
  // The keeper is the earlier id, so the pair is stable across runs without
  // pinning which key happened to hash first.
  assert_eq(@base.text(@base.field(row, "keeper")) < @base.text(@base.field(row, "duplicate")), true)
  let kept_key = @base.text(@base.field(row, "keeper_key"))
  let duplicate_key = @base.text(@base.field(row, "duplicate_key"))
  assert_true((kept_key == "a" && duplicate_key == "b") ||
    (kept_key == "b" && duplicate_key == "a"))
  assert_eq(@base.text(@base.field(row, "reason")), "similar_text")
  // A read operation must not claim a pending host action.
  match candidates {
    Object(fields) => assert_false(fields.contains("execution"))
    _ => assert_true(false)
  }
  // The same vault state always yields the same candidates.
  assert_eq(memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2026-11-26T00:00:00Z" }), candidates)
}

test "memory candidates groups every duplicate under one keeper" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  // Three notes with the same tokens. Two notes cannot show whether the group
  // stops after the first pair or chains n1 -> n0 and n2 -> n1, which would make
  // a host merge into a note that is itself a duplicate.
  let base_text = "官窑记录的器形与釉色特征可以据此核对，包括胎质釉层厚度与开片形态便于断代参考"
  let variants = [base_text,
    base_text.replace(old=", ", new="; "),
    base_text.replace(old=", ", new="、")]
  for index in 0..<3 {
    ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
      "kind": "fact", "scope": "project", "workspace": test_ws(), "text": variants[index],
      "conditions": ["c" + index.to_string()], "sources": [],
      "at": "2026-11-12T09:0" + index.to_string() + ":00Z", "key": "n" + index.to_string() }))
  }
  let candidates = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2026-11-26T00:00:00Z" })
  let merge = @base.array(@base.field(candidates, "merge"))
  assert_eq(merge.length(), 2)
  let keepers : Array[String] = []
  for row in merge {
    keepers.push(@base.text(@base.field(row, "keeper_key")))
  }
  // Every duplicate points at the same keeper, so following the proposals never
  // lands on a note that is itself proposed for merging.
  assert_eq(keepers[0], keepers[1])
  let duplicates : Array[String] = []
  for row in merge {
    duplicates.push(@base.text(@base.field(row, "duplicate_key")))
  }
  assert_eq(duplicates.length(), 2)
  for keeper in keepers {
    assert_true(!duplicates.contains(keeper))
  }
  // The seeded surface collapses the same group to a single kept note.
  let brief = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch", "workspace": test_ws(),
    "query": "官窑", "dedup": "similar" })
  assert_eq(@base.array(@base.field(brief, "similar_duplicates")).length(), 2)
  assert_eq(@base.array(@base.field(brief, "notes")).length(), 1)
}

test "memory candidates never merges across kinds or scopes" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let (first, second) = merge_pair_texts()
  // Identical tokens, different kinds: the same words are not the same judgment.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": first, "conditions": ["c1"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "fact" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "preference", "scope": "project", "workspace": test_ws(), "text": second, "conditions": ["c2"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "pref" }))
  let candidates = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2026-11-26T00:00:00Z" })
  assert_eq(@base.array(@base.field(candidates, "merge")).length(), 0)
  // The same rule governs the seeded surface, so the two never disagree.
  let brief = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch", "workspace": test_ws(),
    "query": "官窑", "dedup": "similar" })
  assert_eq(@base.array(@base.field(brief, "similar_duplicates")).length(), 0)
  // A third note of the original kind does merge.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": second, "conditions": ["c3"],
    "sources": [], "at": "2026-11-12T09:10:00Z", "key": "fact2" }))
  let after = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2026-11-26T00:00:00Z" })
  let merge = @base.array(@base.field(after, "merge"))
  assert_eq(merge.length(), 1)
  let duplicate_key = @base.text(@base.field(merge[0], "duplicate_key"))
  let keeper_key = @base.text(@base.field(merge[0], "keeper_key"))
  // Id ordering decides which note is the keeper; the pair itself is the contract.
  assert_true((duplicate_key == "fact" && keeper_key == "fact2") ||
    (duplicate_key == "fact2" && keeper_key == "fact"))
}

test "memory candidates excludes conflicted notes from merging and pruning" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  // Both sides carry the same conditions, so they conflict; both carry the same
  // tokens, so they WOULD merge if the conflict guard did not come first. A pair
  // whose tokens differ proves nothing, because it never merges either way.
  let (first, second) = merge_pair_texts()
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": first, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "x" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "project", "workspace": test_ws(), "text": second, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "y" }))
  // A far-future clock is deliberate: both notes have decayed well past the
  // normal prune threshold, so the only reason they stay out of `prune` is the
  // unresolved-conflict guard.
  let candidates = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2030-01-01T00:00:00Z" })
  // Dropping one side would hide the competing judgment the host must confirm.
  assert_eq(@base.array(@base.field(candidates, "merge")).length(), 0)
  assert_eq(@base.array(@base.field(candidates, "prune")).length(), 0)
  assert_eq(@base.field(@base.field(candidates, "counts"), "conflicted"),
            Json::number(2.0))
}

fn unused_note_request(key : String, at : String, suffix : String, condition : String) -> Json {
  { "op": "memory-submit", "kind": "preference", "scope": "project", "workspace": test_ws(),
    "text": "偏好安排：" + suffix + "。这条记录足够长以通过门槛并且从未被使用过。",
    "conditions": [condition], "sources": [], "at": at, "key": key }
}

test "memory candidates never proposes a pinned or already-settled note" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let pinned_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("pinned", "2026-11-12T09:00:00Z", "上午参观", "保护项")), "id"))
  let used_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("used", "2026-11-12T09:05:00Z", "下午参观", "常用项")), "id"))
  let archived_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("archived", "2026-11-12T09:10:00Z", "傍晚参观", "归档项")), "id"))
  let fresh_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("fresh", "2026-11-12T09:15:00Z", "夜间参观", "待定项")), "id"))
  ignore(memory_protect(store, @vault.load(store), { "op": "memory-pin", "workspace": test_ws(), "id": pinned_id,
    "pinned": true, "at": "2026-11-12T09:20:00Z" }))
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(), "ids": [used_id],
    "at": "2026-11-12T09:25:00Z" }))
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive", "workspace": test_ws(),
    "id": archived_id, "at": "2026-11-12T09:30:00Z" }))
  let candidates = memory_candidates(store, @vault.load(store), { "workspace": test_ws(), "now": "2027-11-12T00:00:00Z" })
  let prune = @base.array(@base.field(candidates, "prune"))
  // Pinning is a hard protection and archiving already settled the note. A
  // reported use is not permanent immunity: a year later both live notes have
  // decayed, so the untouched one is `never_used` and the used one `decayed`.
  assert_eq(prune.length(), 2)
  let by_id : Map[String, Json] = Map([])
  for row in prune { by_id[@base.text(@base.field(row, "id"))] = row }
  let fresh = by_id[fresh_id]
  let used = by_id[used_id]
  assert_eq(@base.text(@base.field(fresh, "reason")), "never_used")
  assert_true(@base.field(fresh, "last_used_at") == Json::null())
  assert_eq(@base.text(@base.field(used, "reason")), "decayed")
  assert_true(@base.field(used, "last_used_at") != Json::null())
  assert_false(@base.boolean(@base.field(fresh, "pinned")))
  // Pinning also makes the note `core`, which is reported in the tier counts.
  assert_eq(@base.field(@base.field(candidates, "tiers"), "core"), Json::number(1.0))
  assert_true(refuses(() => ignore(memory_candidates(store, @vault.load(store),
    { "workspace": test_ws() }))))
}

test "three-tier decay protects core and slows important notes" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let submit = (key : String, importance : Json?, at : String) => {
    let request : Json = match importance {
      None => { "op": "memory-submit", "workspace": test_ws(), "kind": "fact",
        "scope": "project", "text": "衰减分层：" + key, "conditions": ["主题：" + key],
        "sources": [], "at": at, "key": key }
      Some(value) => { "op": "memory-submit", "workspace": test_ws(), "kind": "fact",
        "scope": "project", "text": "衰减分层：" + key, "conditions": ["主题：" + key],
        "sources": [], "at": at, "key": key, "importance": value }
    }
    @base.text(@base.field(memory_submit(store, @vault.load(store), request), "id"))
  }
  let core_id = submit("core", Some(Json::number(0.9)), "2020-01-01T00:00:00Z")
  let important_id = submit("important", Some(Json::number(0.6)), "2025-08-01T00:00:00Z")
  let normal_id = submit("normal", None, "2025-08-01T00:00:00Z")
  let candidates = memory_candidates(store, @vault.load(store), {
    "workspace": test_ws(), "now": "2025-12-01T00:00:00Z" })
  let tiers = @base.field(candidates, "tiers")
  assert_eq(@base.field(tiers, "core"), Json::number(1.0))
  assert_eq(@base.field(tiers, "important"), Json::number(1.0))
  assert_eq(@base.field(tiers, "normal"), Json::number(1.0))
  let prune = @base.array(@base.field(candidates, "prune"))
  // The normal note crosses its fast threshold; the important note's longer
  // half-life leaves it above its slower threshold; the core note is exempt.
  assert_eq(prune.length(), 1)
  assert_eq(@base.text(@base.field(prune[0], "id")), normal_id)
  assert_eq(@base.text(@base.field(prune[0], "tier")), "normal")
  assert_true(core_id != normal_id && important_id != normal_id)
  for field in ["decay", "strength", "score", "age_days"] {
    match @base.field(prune[0], field) {
      Number(value, ..) => assert_true(value > 0.0)
      _ => assert_true(false)
    }
  }
  assert_true(@base.field(prune[0], "importance") == Json::null())
}

// ---- workspace and session isolation --------------------------------------

fn other_ws() -> String {
  @core.workspace_id("/test/other-project")
}

fn memory_open_other(store : @vault.Storage) -> Unit raise @base.Fault {
  ignore(dispatch(store, { "op": "workspace-open", "path": "/test/other-project",
    "at": "2026-10-20T00:00:00Z" }))
}

test "a note is invisible outside its workspace and its session" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  memory_open_other(store)
  let project_note = dispatch(store, { "op": "memory-submit", "workspace": test_ws(),
    "kind": "fact", "scope": "project", "text": "项目级判断", "conditions": [],
    "sources": [], "at": "2026-10-21T09:00:00Z", "key": "p" })
  let session_note = dispatch(store, { "op": "memory-submit", "workspace": test_ws(),
    "kind": "fact", "scope": "session", "session": "s1", "text": "会话级判断",
    "conditions": [], "sources": [], "at": "2026-10-21T09:01:00Z", "key": "s" })
  let session_id = @base.text(@base.field(session_note, "id"))
  // Default visibility is project-level only; the exact session adds its note.
  let plain = memory_list(store, @vault.load(store), { "workspace": test_ws() })
  assert_eq(@base.array(@base.field(plain, "notes")).length(), 1)
  let scoped = memory_list(store, @vault.load(store),
    { "workspace": test_ws(), "session": "s1" })
  assert_eq(@base.array(@base.field(scoped, "notes")).length(), 2)
  // Another workspace sees nothing at all, not even counts of A's notes.
  let foreign = memory_list(store, @vault.load(store), { "workspace": other_ws() })
  assert_eq(@base.array(@base.field(foreign, "notes")).length(), 0)
  assert_eq(@base.field(@base.field(foreign, "counts"), "active"), Json::number(0.0))
  // Reading a session note without that session behaves like a missing id.
  let hidden = try {
    ignore(memory_read(store, @vault.load(store), { "workspace": test_ws(), "id": session_id }))
    false
  } catch {
    @base.Fault(message) => message.has_prefix("entry_not_found")
  }
  assert_true(hidden)
  let visible = memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "session": "s1", "id": session_id })
  assert_eq(@base.text(@base.field(visible, "id")), session_id)
  // The foreign workspace cannot read the project note by id either.
  let project_id = @base.text(@base.field(project_note, "id"))
  assert_true(refuses(() => ignore(memory_read(store, @vault.load(store),
    { "workspace": other_ws(), "id": project_id }))))
  // Prefetch never crosses the boundary.
  let brief = memory_prefetch(store, @vault.load(store),
    { "workspace": other_ws(), "query": "判断" })
  assert_eq(@base.array(@base.field(brief, "notes")).length(), 0)
}

fn two_workspace_request(workspace : String) -> Json {
  { "op": "memory-submit", "workspace": workspace, "kind": "preference",
    "scope": "project", "text": "先看陶瓷釉色", "conditions": ["规划行程"],
    "sources": [], "at": "2026-10-21T09:00:00Z", "key": "same" }
}

test "the same judgment in two workspaces stays two independent notes" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  memory_open_other(store)
  let first = dispatch(store, two_workspace_request(test_ws()))
  let second = dispatch(store, two_workspace_request(other_ws()))
  assert_eq(@base.text(@base.field(first, "status")), "active")
  assert_eq(@base.text(@base.field(second, "status")), "active")
  assert_true(@base.text(@base.field(first, "id")) != @base.text(@base.field(second, "id")))
  // Duplicate and conflict detection are scoped: each workspace has one note.
  assert_eq(@base.array(@base.field(memory_list(store, @vault.load(store),
    { "workspace": test_ws() }), "notes")).length(), 1)
  assert_eq(@base.array(@base.field(memory_conflicts(store, @vault.load(store),
    { "workspace": test_ws() }), "conflicts")).length(), 0)
}

test "a project note may not carry a session selector" {
  // A project note is visible to every session in its workspace. Accepting a
  // stray `session` field would silently imply a restriction that does not
  // exist, so the contradiction is refused rather than ignored.
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let refused = try {
    ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
      "workspace": test_ws(), "kind": "fact", "scope": "project", "session": "s1",
      "text": "项目级判断", "conditions": [], "sources": [],
      "at": "2026-10-21T09:00:00Z", "key": "x" }))
    false
  } catch {
    @base.Fault(message) => message.has_prefix("memory_session_unexpected")
  }
  assert_true(refused)
  // The session-scoped spelling with the same text is a different, valid note.
  let accepted = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "session", "session": "s1",
    "text": "项目级判断", "conditions": [], "sources": [],
    "at": "2026-10-21T09:01:00Z", "key": "x" })
  assert_eq(@base.text(@base.field(accepted, "status")), "active")
}

fn lint_memory_conflict_count(store : @vault.Storage) -> Int raise @base.Fault {
  let report = lint_result(store, (store.read)("index.mbt.md"))
  @base.array(@base.field(report, "violations"))
    .filter(issue => @base.text(@base.field(issue, "predicate")) == "memory_conflict")
    .length()
}

test "conflicts stay inside a workspace and a visibility scope" {
  // Two workspaces never see each other, so the same conditions with different
  // judgments in each are not a conflict. The same holds for a project note and
  // a session note: the session note is a narrower commitment, not a rival.
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  memory_open_other(store)
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "项目判断甲",
    "conditions": ["核对时"], "sources": [], "at": "2026-10-22T09:00:00Z", "key": "a" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": other_ws(), "kind": "fact", "scope": "project", "text": "项目判断乙",
    "conditions": ["核对时"], "sources": [], "at": "2026-10-22T09:01:00Z", "key": "b" }))
  assert_eq(@base.array(@base.field(memory_conflicts(store, @vault.load(store),
    { "workspace": test_ws() }), "conflicts")).length(), 0)
  assert_eq(lint_memory_conflict_count(store), 0)
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "session", "session": "s1",
    "text": "会话判断丙", "conditions": ["核对时"], "sources": [],
    "at": "2026-10-22T09:02:00Z", "key": "c" }))
  assert_eq(@base.array(@base.field(memory_conflicts(store, @vault.load(store),
    { "workspace": test_ws(), "session": "s1" }), "conflicts")).length(), 0)
  assert_eq(lint_memory_conflict_count(store), 0)
  // The same scope and conditions with disagreeing text still conflict.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "session", "session": "s1",
    "text": "会话判断丁", "conditions": ["核对时"], "sources": [],
    "at": "2026-10-22T09:03:00Z", "key": "d" }))
  assert_eq(@base.array(@base.field(memory_conflicts(store, @vault.load(store),
    { "workspace": test_ws(), "session": "s1" }), "conflicts")).length(), 1)
  assert_eq(lint_memory_conflict_count(store), 1)
}

test "memory ops require a registered workspace" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let refused = try {
    ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
      "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "未登记",
      "conditions": [], "sources": [], "at": "2026-10-21T09:00:00Z", "key": "x" }))
    false
  } catch {
    @base.Fault(message) => message.has_prefix("memory_workspace_unknown")
  }
  assert_true(refused)
}

test "importance and emotion are identity-bound companion metadata" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let emotion : Json = { "valence": 0.6, "arousal": 0.4, "dominance": 0.5, "label": "欣慰" }
  let first = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project",
    "text": "那次看展很触动", "conditions": ["聊到展览时"], "sources": [],
    "importance": 0.8, "emotion": emotion,
    "at": "2026-11-21T09:00:00Z", "key": "moment" })
  let first_id = @base.text(@base.field(first, "id"))
  let first_note = memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": first_id })
  assert_eq(@base.field(@base.field(first_note, "record"), "importance"), Json::number(0.8))
  assert_eq(@base.field(@base.field(@base.field(first_note, "record"), "emotion"), "label"),
    "欣慰".to_json())
  assert_eq(@base.field(@base.field(first_note, "record"), "use_count"), Json::number(0.0))
  // Usage is a mutable signal outside the identity hash.
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use",
    "workspace": test_ws(), "ids": [first_id], "at": "2026-11-21T09:10:00Z" }))
  // Changing the weight keeps history: a superseding record inherits the
  // fields that were not overridden, including usage count.
  let second = memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "workspace": test_ws(), "id": first_id, "text": "那次看展至今难忘",
    "conditions": ["聊到展览时"], "sources": [], "importance": 0.2, "emotion": Json::null(),
    "at": "2026-11-21T09:20:00Z", "key": "moment" })
  let second_id = @base.text(@base.field(second, "id"))
  assert_true(second_id != first_id)
  let second_note = @base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": second_id }), "record")
  assert_eq(@base.field(second_note, "importance"), Json::number(0.2))
  assert_eq(@base.field(second_note, "emotion"), Json::null())
  assert_eq(@base.field(second_note, "use_count"), Json::number(1.0))
  // Omitted metadata is inherited, not reset.
  let third = memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "workspace": test_ws(), "id": second_id, "text": "那次看展至今难忘，细节仍在",
    "conditions": ["聊到展览时"], "sources": [],
    "at": "2026-11-21T09:30:00Z", "key": "moment" })
  let third_note = @base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": @base.text(@base.field(third, "id")) }), "record")
  assert_eq(@base.field(third_note, "importance"), Json::number(0.2))
  assert_eq(@base.field(third_note, "emotion"), Json::null())
  assert_eq(@base.field(third_note, "use_count"), Json::number(1.0))
  // The identity hash covers the metadata: rewriting only importance without
  // recomputing note_hash is refused by record validation.
  let path = memory_path(test_ws(), first_id)
  let raw = @base.parse(files[path])
  let changed = json_override(raw, "importance", Json::number(0.9))
  let text = @base.canonical(changed)
  let entry : @core.Entry = { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(text), sources: [], stale: false }
  assert_true(refuses(() => @core.validate_record(entry, text)))
  // Flipping episodic without recomputing the hash is refused too.
  let promoted = json_override(json_override(raw, "episodic", true.to_json()),
    "promoted_at", "2026-11-21T09:40:00Z".to_json())
  let promoted_text = @base.canonical(promoted)
  let promoted_entry : @core.Entry = { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(promoted_text), sources: [], stale: false }
  assert_true(refuses(() => @core.validate_record(promoted_entry, promoted_text)))
}

test "companion metadata bounds are refused" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let base : Json = { "op": "memory-submit", "workspace": test_ws(), "kind": "fact",
    "scope": "project", "text": "边界检查", "conditions": [], "sources": [],
    "at": "2026-11-21T10:00:00Z", "key": "bounds" }
  let invalid : Array[Json] = [
    json_override(base, "importance", Json::number(1.5)),
    json_override(base, "importance", Json::number(-0.1)),
    json_override(base, "emotion", { "valence": 2.0, "arousal": 0.0, "dominance": 0.0 }),
    json_override(base, "emotion", { "valence": 0.0, "arousal": 0.0 }),
    json_override(base, "emotion", { "valence": 0.0, "arousal": 0.0, "dominance": 0.0, "extra": 1 }),
    json_override(base, "emotion", { "valence": 0.0, "arousal": 0.0, "dominance": 0.0,
      "label": "a\nb" }),
  ]
  for request in invalid {
    assert_true(refuses(() => ignore(memory_submit(store, @vault.load(store), request))))
  }
  // Even a hand-written record whose note_hash is self-consistent is refused:
  // the record validator, not only the request parser, enforces the bounds.
  let (valid_store, _broken, files) = crashing(-1)
  ignore(initialize(valid_store, "研究陶瓷"))
  memory_open_workspace(valid_store)
  let note = memory_submit(valid_store, @vault.load(valid_store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "边界基线",
    "conditions": [], "sources": [], "at": "2026-11-21T10:10:00Z", "key": "ok" })
  let path = memory_path(test_ws(), @base.text(@base.field(note, "id")))
  let raw = @base.parse(files[path])
  let tampered : Array[Json] = [
    json_override(raw, "importance", Json::number(1.5)),
  ]
  for row in tampered {
    let digest = @core.memory_note_hash(test_ws(), "project", "", "fact", "边界基线", [], [],
      [], Json::number(1.5), Json::null(), false, "judgment")
    let id = @core.memory_note_id("ok", digest)
    let rewritten = json_override(json_override(row, "note_hash", digest.to_json()),
      "id", id.to_json())
    let text = @base.canonical(rewritten)
    let entry : @core.Entry = { id: memory_path(test_ws(), id), path: memory_path(test_ws(), id),
      kind: "state", format: "json", sha256: @base.hex_hash(text), sources: [], stale: false }
    assert_true(refuses(() => @core.validate_record(entry, text)))
  }
  let emotion_row = json_override(raw, "emotion", { "valence": 2.0, "arousal": 0.0, "dominance": 0.0 })
  let digest = @core.memory_note_hash(test_ws(), "project", "", "fact", "边界基线", [], [],
    [], Json::null(), { "valence": 2.0, "arousal": 0.0, "dominance": 0.0 }, false, "judgment")
  let id = @core.memory_note_id("ok", digest)
  let emotion_written = json_override(json_override(emotion_row, "note_hash", digest.to_json()),
    "id", id.to_json())
  let emotion_text = @base.canonical(emotion_written)
  let emotion_entry : @core.Entry = { id: memory_path(test_ws(), id),
    path: memory_path(test_ws(), id), kind: "state", format: "json",
    sha256: @base.hex_hash(emotion_text), sources: [], stale: false }
  assert_true(refuses(() => @core.validate_record(emotion_entry, emotion_text)))
}

test "memory layer is identity-bearing and constrained by scope" {
  let plain = @core.memory_note_hash(test_ws(), "project", "", "fact", "分层检查", [], [], [],
    Json::null(), Json::null(), false, "judgment")
  let profile = @core.memory_note_hash(test_ws(), "project", "", "fact", "分层检查", [], [], [],
    Json::null(), Json::null(), false, "profile")
  assert_true(plain != profile)
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let submitted = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project", "layer": "profile",
    "text": "长期偏好手作器物", "conditions": [], "sources": [],
    "at": "2026-10-23T09:00:00Z", "key": "profile" })
  assert_eq(@base.field(@base.field(submitted, "record"), "layer"), "profile".to_json())
  // A summary belongs to one session; a profile or episode belongs to the
  // workspace. Submitting an episode is refused because promotion is a
  // separate, auditable transition.
  let invalid : Array[Json] = [
    { "op": "memory-submit", "workspace": test_ws(), "kind": "fact", "scope": "project",
      "layer": "session_summary", "text": "错误的会话摘要", "conditions": [], "sources": [],
      "at": "2026-10-23T09:01:00Z", "key": "bad-summary" },
    { "op": "memory-submit", "workspace": test_ws(), "kind": "fact", "scope": "session",
      "session": "s1", "layer": "profile", "text": "错误的会话画像", "conditions": [],
      "sources": [], "at": "2026-10-23T09:02:00Z", "key": "bad-profile" },
    { "op": "memory-submit", "workspace": test_ws(), "kind": "fact", "scope": "project",
      "layer": "episode", "text": "绕过提升写入情景", "conditions": [], "sources": [],
      "at": "2026-10-23T09:03:00Z", "key": "bad-episode" },
    { "op": "memory-submit", "workspace": test_ws(), "kind": "fact", "scope": "project",
      "layer": "habit", "text": "未知层", "conditions": [], "sources": [],
      "at": "2026-10-23T09:04:00Z", "key": "bad-layer" },
  ]
  for request in invalid {
    assert_true(refuses(() => ignore(memory_submit(store, @vault.load(store), request))))
  }
  let summary = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "session", "session": "s1",
    "layer": "session_summary", "text": "本次会话先看青瓷", "conditions": [], "sources": [],
    "at": "2026-10-23T09:05:00Z", "key": "summary" })
  assert_eq(@base.field(@base.field(summary, "record"), "layer"), "session_summary".to_json())
  // Supersede carries the layer forward; a correction must not silently
  // demote a profile back to an ordinary judgment.
  let superseded = memory_supersede(store, @vault.load(store), { "op": "memory-supersede",
    "workspace": test_ws(), "id": @base.text(@base.field(submitted, "id")),
    "text": "长期偏好手作器物与旧窑址", "conditions": [], "sources": [],
    "at": "2026-10-23T09:10:00Z" })
  assert_eq(@base.field(@base.field(superseded, "record"), "layer"), "profile".to_json())
}

test "memory record layer rules are enforced without trusting the request" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let submitted = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "层规则基线",
    "conditions": [], "sources": [], "at": "2026-10-23T10:00:00Z", "key": "layer" })
  let id = @base.text(@base.field(submitted, "id"))
  let path = memory_path(test_ws(), id)
  let raw = @base.parse(files[path])
  let digest = (layer : String, episodic : Bool) => @core.memory_note_hash(test_ws(), "project",
    "", "fact", "层规则基线", [], [], [], Json::null(), Json::null(), episodic, layer)
  let record = (layer : String, episodic : Bool, promoted : String?) => {
    let note_hash = digest(layer, episodic)
    json_override(
      json_override(
        json_override(json_override(raw, "layer", layer.to_json()), "note_hash", note_hash.to_json()),
        "episodic", episodic.to_json()),
      "promoted_at", match promoted { None => Json::null(); Some(value) => value.to_json() })
  }
  let check = (value : Json) => {
    let note_id = @core.memory_note_id("layer", @base.text(@base.field(value, "note_hash")))
    let written = json_override(value, "id", note_id.to_json())
    let text = @base.canonical(written)
    let recomputed = @core.memory_note_hash(test_ws(), "project", "", "fact", "层规则基线",
      [], [], [], Json::null(), Json::null(), @base.boolean(@base.field(written, "episodic")),
      @base.text(@base.field(written, "layer")))
    if recomputed != @base.text(@base.field(written, "note_hash")) {
      raise @base.Fault("memory_note_hash_mismatch")
    }
    let entry : @core.Entry = { id: memory_path(test_ws(), note_id),
      path: memory_path(test_ws(), note_id), kind: "state", format: "json",
      sha256: @base.hex_hash(text), sources: [], stale: false }
    @core.validate_record(entry, text)
  }
  // A self-consistent profile is legal; an episode must agree with both the
  // episodic flag and its promotion timestamp; a summary may not be a project
  // note. Every rejected row is refused by the layer rules, not by the hash.
  check(record("profile", false, None))
  check(record("episode", true, Some("2026-10-23T10:05:00Z")))
  for bad in [
    record("session_summary", false, None),
    record("episode", false, None),
    record("judgment", true, Some("2026-10-23T10:05:00Z")),
    record("habit", false, None),
  ] {
    assert_true(refuses(() => check(bad)))
  }
}

test "episodic promotion writes a new core record and preserves history" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let weak = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "普通记录",
    "conditions": ["弱信号"], "sources": [], "importance": 0.2,
    "at": "2026-10-24T09:00:00Z", "key": "weak" })
  assert_true(refuses(() => ignore(memory_promote(store, @vault.load(store),
    { "op": "memory-promote", "workspace": test_ws(),
      "id": @base.text(@base.field(weak, "id")), "at": "2026-10-24T09:10:00Z" }))))
  let strong = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project",
    "text": "重要经历：在窑址确认了釉色来源", "conditions": ["实地考察"],
    "sources": [], "importance": 0.8,
    "at": "2026-10-24T09:20:00Z", "key": "strong" })
  let old_id = @base.text(@base.field(strong, "id"))
  let promoted = memory_promote(store, @vault.load(store), { "op": "memory-promote",
    "workspace": test_ws(), "id": old_id, "at": "2026-10-24T09:30:00Z" })
  let record = @base.field(promoted, "record")
  let new_id = @base.text(@base.field(record, "id"))
  assert_true(new_id != old_id)
  assert_eq(@base.field(record, "layer"), "episode".to_json())
  assert_eq(@base.field(record, "episodic"), true.to_json())
  assert_eq(@base.field(record, "promoted_at"), "2026-10-24T09:30:00Z".to_json())
  assert_eq(@base.field(record, "importance"), Json::number(0.8))
  assert_eq(@base.field(record, "supersedes"), old_id.to_json())
  let event = "state/events/memory-promote-" + old_id + "-" + new_id + ".json"
  assert_true(files.contains(event))
  let history = @base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": old_id }), "record")
  assert_eq(@base.field(history, "status"), "superseded".to_json())
  assert_eq(@base.field(history, "superseded_by"), new_id.to_json())
  assert_eq(@base.field(history, "layer"), "judgment".to_json())
  // The old id can no longer be promoted, and the episode refuses a replay.
  assert_true(refuses(() => ignore(memory_promote(store, @vault.load(store),
    { "op": "memory-promote", "workspace": test_ws(), "id": old_id,
      "at": "2026-10-24T09:40:00Z" }))))
  assert_true(refuses(() => ignore(memory_promote(store, @vault.load(store),
    { "op": "memory-promote", "workspace": test_ws(), "id": new_id,
      "at": "2026-10-24T09:40:00Z" }))))
  // Emotion intensity alone is enough to promote; importance stays optional.
  let emotional = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "decision", "scope": "project",
    "text": "现场决定改走东门", "conditions": ["临时变更"], "sources": [],
    "emotion": { "valence": -0.2, "arousal": 0.8, "dominance": 0.1 },
    "at": "2026-10-24T09:50:00Z", "key": "emotional" })
  let emotional_promoted = memory_promote(store, @vault.load(store), {
    "op": "memory-promote", "workspace": test_ws(),
    "id": @base.text(@base.field(emotional, "id")), "at": "2026-10-24T10:00:00Z" })
  assert_eq(@base.field(@base.field(emotional_promoted, "record"), "layer"), "episode".to_json())
  // Episodes are core: a far-future decay scan must never nominate them.
  let candidates = memory_candidates(store, @vault.load(store), {
    "workspace": test_ws(), "now": "2030-01-01T00:00:00Z" })
  let pruned : Map[String, Bool] = Map([])
  for row in @base.array(@base.field(candidates, "prune")) {
    pruned[@base.text(@base.field(row, "id"))] = true
  }
  assert_false(pruned.get(new_id).unwrap_or(false))
  assert_false(pruned.get(@base.text(@base.field(
    @base.field(emotional_promoted, "record"), "id"))).unwrap_or(false))
}

test "prefetch honours the requested lexical limit" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  for index in 0..<3 {
    ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
      "workspace": test_ws(), "kind": "fact", "scope": "project",
      "text": "陶瓷记录第" + index.to_string() + "条，用于核对词汇检索上限。",
      "conditions": [], "sources": [],
      "at": "2026-11-12T09:0" + index.to_string() + ":00Z",
      "key": "limit-" + index.to_string() }))
  }
  let brief = memory_prefetch(store, @vault.load(store), {
    "workspace": test_ws(), "query": "陶瓷", "limit": 2 })
  // All three notes match the query; the lexical candidate window must be the
  // caller's limit, not a hard-coded one.
  assert_eq(@base.array(@base.field(brief, "notes")).length(), 2)
}

test "weighted prefetch balances relevance, strength and importance" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let old = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project",
    "text": "陶瓷判断记录甲", "conditions": [], "sources": [], "importance": 1.0,
    "emotion": { "valence": 0.9, "arousal": 1.0, "dominance": 0.5 },
    "at": "2025-01-01T00:00:00Z", "key": "old" })
  let recent = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "preference", "scope": "project",
    "text": "陶瓷判断记录乙", "conditions": [], "sources": [],
    "at": "2026-11-25T00:00:00Z", "key": "recent" })
  let old_id = @base.text(@base.field(old, "id"))
  let recent_id = @base.text(@base.field(recent, "id"))
  let weighted = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "workspace": test_ws(), "query": "陶瓷", "limit": 1,
    "rank": "weighted", "now": "2026-11-26T00:00:00Z" })
  assert_eq(@base.field(weighted, "rank"), "weighted".to_json())
  assert_eq(@base.field(weighted, "now"), "2026-11-26T00:00:00Z".to_json())
  let notes = @base.array(@base.field(weighted, "notes"))
  assert_eq(notes.length(), 1)
  assert_eq(@base.field(notes[0], "id"), old_id.to_json())
  assert_eq(@base.field(notes[0], "tier"), "core".to_json())
  let components = @base.field(notes[0], "score_components")
  assert_eq(@base.field(components, "importance"), Json::number(1.0))
  let strength = match @base.field(components, "strength") {
    Number(value, ..) => value
    _ => 0.0
  }
  assert_true(strength > 0.0 && strength <= 0.5)
  // Same request, same answer: the model reads no wall clock.
  let replay = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "workspace": test_ws(), "query": "陶瓷", "limit": 1,
    "rank": "weighted", "now": "2026-11-26T00:00:00Z" })
  assert_eq(@base.canonical(replay), @base.canonical(weighted))
  // The default path remains plain BM25 and carries no weighted components.
  let lexical = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "workspace": test_ws(), "query": "陶瓷" })
  assert_eq(@base.field(lexical, "rank"), "bm25".to_json())
  assert_eq(@base.field(lexical, "now"), Json::null())
  for note in @base.array(@base.field(lexical, "notes")) {
    match note {
      Object(fields) => assert_true(!fields.contains("score_components"))
      _ => assert_true(false)
    }
  }
  // `now` is mandatory for weighted and forbidden otherwise; neither path may
  // silently fall back to a different score.
  assert_true(refuses(() => ignore(memory_prefetch(store, @vault.load(store),
    { "op": "memory-prefetch", "workspace": test_ws(), "query": "陶瓷", "rank": "weighted" }))))
  assert_true(refuses(() => ignore(memory_prefetch(store, @vault.load(store),
    { "op": "memory-prefetch", "workspace": test_ws(), "query": "陶瓷",
    "rank": "weighted", "now": "2026-11-26" }))))
  assert_true(refuses(() => ignore(memory_prefetch(store, @vault.load(store),
    { "op": "memory-prefetch", "workspace": test_ws(), "query": "陶瓷",
    "now": "2026-11-26T00:00:00Z" }))))
  assert_true(refuses(() => ignore(memory_prefetch(store, @vault.load(store),
    { "op": "memory-prefetch", "workspace": test_ws(), "query": "陶瓷", "rank": "pagerank" }))))
  // A recent ordinary note stays visible; weighted reorders, it does not hide.
  let all = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "workspace": test_ws(), "query": "陶瓷", "limit": 10,
    "rank": "weighted", "now": "2026-11-26T00:00:00Z" })
  let ids = @base.array(@base.field(all, "notes")).map(note => @base.field(note, "id"))
  assert_true(ids.contains(recent_id.to_json()))
}

test "memory use increments a replay-safe usage count" {
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  memory_open_workspace(store)
  let note = memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "workspace": test_ws(), "kind": "fact", "scope": "project", "text": "计数检查",
    "conditions": [], "sources": [], "at": "2026-11-21T11:00:00Z", "key": "count" })
  let id = @base.text(@base.field(note, "id"))
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [id], "at": "2026-11-21T11:10:00Z" }))
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [id], "at": "2026-11-21T11:20:00Z" }))
  let used = @base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": id }), "record")
  assert_eq(@base.field(used, "use_count"), Json::number(2.0))
  let replay = memory_use(store, @vault.load(store), { "op": "memory-use", "workspace": test_ws(),
    "ids": [id], "at": "2026-11-21T11:20:00Z" })
  assert_eq(@base.field(replay, "replayed"), true.to_json())
  let still = @base.field(memory_read(store, @vault.load(store),
    { "workspace": test_ws(), "id": id }), "record")
  assert_eq(@base.field(still, "use_count"), Json::number(2.0))
}
