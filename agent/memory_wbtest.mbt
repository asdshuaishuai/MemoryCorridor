test "memory note identity is content addressed and supersede preserves history" {
  let conditions = ["规划博物馆行程时"]
  let digest = @core.memory_note_hash("preference", "workspace", "优先安排陶瓷参观时间", conditions, [], [])
  let id = @core.memory_note_id("ceramics", digest)
  assert_eq(id, @core.memory_note_id("ceramics", digest))
  // Same key and content replay; a correction derives a different id.
  let corrected = @core.memory_note_hash("preference", "workspace", "优先安排陶瓷参观时间并保留自由活动", conditions, [], [])
  assert_true(@core.memory_note_id("ceramics", corrected) != id)
  // A condition changes the identity even when the text does not.
  let reconditioned = @core.memory_note_hash("preference", "workspace", "优先安排陶瓷参观时间", ["规划城市行程时"], [], [])
  assert_true(reconditioned != digest)
  // The key participates in the record id, so two keys never share a note.
  assert_true(@core.memory_note_id("other", digest) != id)
}

test "memory note json round trip keeps nullable transition fields" {
  let body = "官窑记录来自已登记来源"
  let note : MemoryNote = {
    id: @core.memory_note_id("k", @core.memory_note_hash("fact", "workspace", body, [], [], [])),
    kind: "fact", scope: "workspace", text: body,
    conditions: [], sources: [], source_hashes: [], status: "archived", key: "k",
    created_at: "2026-10-20T09:00:00Z", updated_at: "2026-10-20T10:00:00Z",
    archived_at: Some("2026-10-20T10:00:00Z"), superseded_by: None, supersedes: None,
    pinned: false, last_used_at: None,
    note_hash: @core.memory_note_hash("fact", "workspace", body, [], [], []),
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
  let id = @core.memory_note_id("k", @core.memory_note_hash("fact", "workspace", body, [], [], []))
  let path = "state/memory/" + id + ".json"
  let entry : @core.Entry = {
    id: path, path, kind: "state", format: "json",
    sha256: "0000000000000000000000000000000000000000000000000000000000000000",
    sources: [], stale: false,
  }
  let base : Json = { "version": 1, "id": id, "kind": "fact", "scope": "workspace",
    "text": body, "conditions": [], "sources": [], "status": "active", "key": "k",
    "created_at": "2026-10-20T09:00:00Z", "updated_at": "2026-10-20T09:00:00Z",
    "archived_at": Json::null(), "superseded_by": Json::null(), "supersedes": Json::null(),
    "source_hashes": Json::array([]), "pinned": false, "last_used_at": Json::null(),
    "note_hash": @core.memory_note_hash("fact", "workspace", body, [], [], []) }
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
    "note_hash", @core.memory_note_hash("fact", "workspace", body, [], [], []).to_json())
  assert_true(refuses(() => @core.validate_record(entry, @base.canonical(self_supersede))))
}

test "memory event dictionary rejects unknown operations and forged paths" {
  let body = "t"
  let note_id = @core.memory_note_id("k", @core.memory_note_hash("fact", "workspace", body, [], [], []))
  let note_hash = @core.memory_note_hash("fact", "workspace", body, [], [], [])
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
  assert_eq(tool("memory-submit").fields, ["kind", "scope", "text", "conditions", "sources", "at", "key"])
  assert_eq(tool("memory-supersede").fields, ["id", "text", "conditions", "sources", "at", "key"])
  assert_eq(tool("memory-archive").fields, ["id", "at"])
  assert_eq(tool("memory-restore").fields, ["id", "at"])
  assert_eq(tool("memory-list").fields, [])
  let prefetch = tool("memory-prefetch")
  assert_eq(prefetch.fields, ["query", "page", "limit", "archived", "dedup", "kinds"])
  let properties = @base.field(input_schema(prefetch), "properties")
  assert_eq(@base.field(@base.field(properties, "limit"), "maximum"), Json::number(50.0))
  assert_eq(@base.field(@base.field(properties, "limit"), "minimum"), Json::number(1.0))
  assert_eq(@base.field(@base.field(properties, "archived"), "type"), "boolean".to_json())
  let submit_properties = @base.field(input_schema(tool("memory-submit")), "properties")
  assert_eq(@base.field(@base.field(submit_properties, "conditions"), "type"), "array".to_json())
  assert_eq(@base.field(@base.field(submit_properties, "conditions"), "items"), { "type": "string" })
  assert_eq(@base.field(@base.field(submit_properties, "sources"), "type"), "array".to_json())
  assert_eq(@base.field(@base.field(submit_properties, "text"), "type"), "string".to_json())
  let optional_fields = ["conditions", "sources", "key", "limit", "archived"]
  for name in optional_fields {
    assert_true(!@base.array(@base.field(input_schema(prefetch), "required")).contains(name.to_json()))
  }
  // `query` and `page` are alternatives, so neither is required by the schema;
  // the operation enforces that exactly one is supplied.
  for name in ["query", "page"] {
    assert_true(!@base.array(@base.field(input_schema(prefetch), "required")).contains(name.to_json()))
  }
  for name in ["kind", "scope", "text", "at"] {
    assert_true(@base.array(@base.field(input_schema(tool("memory-submit")), "required")).contains(name.to_json()))
  }
  for name in ["id", "text", "at"] {
    assert_true(@base.array(@base.field(input_schema(tool("memory-supersede")), "required")).contains(name.to_json()))
  }
}

fn memory_note(
  id : String, kind : String, text : String, conditions : Array[String], status : String,
) -> MemoryNote {
  {
    id, kind, scope: "workspace", text, conditions, sources: [], source_hashes: [],
    status, key: id,
    created_at: "2026-10-22T09:00:00Z", updated_at: "2026-10-22T09:00:00Z",
    archived_at: None, superseded_by: None, supersedes: None, pinned: false,
    last_used_at: None,
    note_hash: @core.memory_note_hash(kind, "workspace", text, conditions, [], []),
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
  assert_eq(tool("memory-conflicts").fields, [])
  let schema = input_schema(tool("memory-conflicts"))
  assert_eq(@base.field(schema, "type"), "object".to_json())
  assert_eq(@base.array(@base.field(schema, "required")).length(), 0)
}

test "memory prefetch dedup and kind filters are schema-checked" {
  let prefetch = tool("memory-prefetch")
  assert_eq(prefetch.fields, ["query", "page", "limit", "archived", "dedup", "kinds"])
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
  assert_eq(tool("memory-read").fields, ["id"])
  assert_eq(tool("memory-pin").fields, ["id", "pinned", "at"])
  let read_schema = input_schema(tool("memory-read"))
  assert_eq(@base.field(read_schema, "required"), ["id"].to_json())
  let pin_schema = input_schema(tool("memory-pin"))
  let pin_properties = @base.field(pin_schema, "properties")
  assert_eq(@base.field(@base.field(pin_properties, "pinned"), "type"), "boolean".to_json())
  for name in ["id", "pinned", "at"] {
    assert_true(@base.array(@base.field(pin_schema, "required")).contains(name.to_json()))
  }
}

test "memory pin event path binds the flag and the time" {
  let memory = @core.memory_note_id("k", @core.memory_note_hash("fact", "workspace", "t", [], [], []))
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
  let superseded = @base.hex_hash("memory-v1\nold\n" + @core.memory_note_hash("fact", "workspace", "a", [], [], []))
  let replacement = @core.memory_note_id("old", @core.memory_note_hash("fact", "workspace", "b", [], [], []))
  let event : Json = { "op": "memory-supersede", "memory": replacement, "at": at, "key": "k",
    "note_hash": @core.memory_note_hash("fact", "workspace", "b", [], [], []),
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
  assert_eq(prefetch.fields, ["query", "page", "limit", "archived", "dedup", "kinds"])
  let schema = input_schema(prefetch)
  let required = @base.array(@base.field(schema, "required"))
  // Both are optional in the schema because exactly one must be supplied; the
  // operation itself enforces the exclusivity.
  for name in ["query", "page", "limit", "archived", "dedup", "kinds"] {
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
  files["raw/a.md"] = "官窑记录：器形与釉色。\\n"
  ignore(dispatch(store, { "op": "scan" }))
  ignore(memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "fact", "scope": "workspace",
    "text": "官窑记录来自已登记来源，器形与釉色可据此核对",
    "conditions": ["核对官窑资料时"], "sources": ["raw/a.md"],
    "at": "2026-11-05T09:00:00Z", "key": "k1" }))
  let entries = @vault.load(store)
  let note = memory_rows(store, entries)[0]
  assert_eq(note.sources, ["raw/a.md"])
  assert_eq(note.source_hashes.length(), 1)
  assert_eq(note.source_hashes[0], @base.hex_hash("官窑记录：器形与釉色。\\n"))
  assert_true(@base.boolean(@base.field(memory_view(note, entries, false), "valid")))
  // Rewriting the source and re-registering it is drift, not survival.
  files["raw/a.md"] = "完全无关的内容：天气与市场行情。\\n"
  ignore(dispatch(store, { "op": "scan" }))
  let rewritten = @vault.load(store)
  let drifted = memory_rows(store, rewritten)[0]
  let view = memory_view(drifted, rewritten, false)
  assert_false(@base.boolean(@base.field(view, "valid")))
  assert_eq(@base.field(view, "drifted_sources"), ["raw/a.md"].to_json())
  assert_eq(@base.array(@base.field(view, "invalid_sources")).length(), 0)
  // Revoking the source is a different diagnosis from rewriting it.
  ignore(memory_archive(store, rewritten, { "op": "memory-archive", "id": drifted.id,
    "at": "2026-11-05T10:00:00Z" }))
  let revoked = @vault.load(store)
  let after = memory_rows(store, revoked)[0]
  assert_false(@base.boolean(@base.field(memory_view(after, revoked, false), "valid")))
}

fn memory_submit_request(source : String, key : String, text : String) -> Json {
  { "op": "memory-submit", "kind": "fact", "scope": "workspace",
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
  let rows = memory_rows(store, @vault.load(store))
  assert_eq(rows.length(), 1)
  assert_eq(memory_conflict_groups(rows).length(), 0)
  // A genuinely different judgment under the same conditions still conflicts.
  ignore(memory_submit(store, @vault.load(store),
    memory_submit_request("raw/a.md", "k3", "官窑记录只说明器形，不涉及釉色")))
  let conflicted = memory_rows(store, @vault.load(store))
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
  assert_eq(memory_rows(store, @vault.load(store)).length(), 2)
}


fn archived_note_request(key : String, at : String) -> Json {
  { "op": "memory-submit", "kind": "decision", "scope": "workspace",
    "text": "阶段性结论：先整理陶瓷资料", "conditions": ["规划资料整理范围时"],
    "sources": [], "at": at, "key": key }
}

test "an archived note does not block the same judgment" {
  // Archived notes have left the default set and stay restorable, so they must
  // not be treated as competing with a fresh submission of the same judgment.
  let (store, _broken, _files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let first = memory_submit(store, @vault.load(store),
    archived_note_request("k1", "2026-11-07T09:00:00Z"))
  let first_id = @base.text(@base.field(first, "id"))
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive",
    "id": first_id, "at": "2026-11-07T09:30:00Z" }))
  let reborn = memory_submit(store, @vault.load(store),
    archived_note_request("k2", "2026-11-07T10:00:00Z"))
  assert_eq(@base.text(@base.field(reborn, "status")), "active")
  assert_true(@base.text(@base.field(reborn, "id")) != first_id)
  let rows = memory_rows(store, @vault.load(store))
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
  let first = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "fact", "scope": "workspace",
    "text": "官窑记录可据此核对", "conditions": ["核对官窑资料时"],
    "sources": [], "at": "2026-11-11T09:00:00Z", "key": "k1" })
  let first_id = @base.text(@base.field(first, "id"))
  let second = memory_submit(store, @vault.load(store), {
    "op": "memory-submit", "kind": "decision", "scope": "workspace",
    "text": "先整理陶瓷资料", "conditions": [], "sources": [],
    "at": "2026-11-11T09:05:00Z", "key": "k2" })
  let second_id = @base.text(@base.field(second, "id"))
  assert_eq(memory_rows(store, @vault.load(store)).filter(n => n.last_used_at is None).length(), 2)
  // A batch reports many notes in one transaction.
  let used = memory_use(store, @vault.load(store), { "op": "memory-use",
    "ids": [first_id, second_id], "at": "2026-11-11T10:00:00Z" })
  assert_eq(@base.field(used, "used"), Json::number(2.0))
  let rows = memory_rows(store, @vault.load(store))
  assert_eq(rows.filter(n => n.last_used_at == Some("2026-11-11T10:00:00Z")).length(), 2)
  // The same report twice is a replay, not a second write.
  let replay = memory_use(store, @vault.load(store), { "op": "memory-use",
    "ids": [first_id, second_id], "at": "2026-11-11T10:00:00Z" })
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  assert_eq(@base.field(replay, "committed"), Json::boolean(false))
  // A later report advances the timestamp.
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use",
    "ids": [first_id], "at": "2026-11-11T11:00:00Z" }))
  let advanced = memory_rows(store, @vault.load(store)).filter(n =>
    n.last_used_at == Some("2026-11-11T11:00:00Z"))
  assert_eq(advanced.length(), 1)
  // Prefetch itself never records usage.
  ignore(memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch", "query": "陶瓷" }))
  let still = memory_rows(store, @vault.load(store)).filter(n =>
    n.last_used_at == Some("2026-11-11T11:00:00Z"))
  assert_eq(still.length(), 1)
  // Bad batches are refused without touching the vault.
  let bad : Array[Json] = [
    { "op": "memory-use", "ids": Json::array([]), "at": "2026-11-11T12:00:00Z" },
    { "op": "memory-use", "ids": [first_id, first_id], "at": "2026-11-11T12:00:00Z" },
    { "op": "memory-use", "ids": ["0".repeat(64)], "at": "2026-11-11T12:00:00Z" },
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
  let (first, second) = merge_pair_texts()
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": first, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "a" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": second, "conditions": ["撰写说明"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "b" }))
  let candidates = memory_candidates(store, @vault.load(store))
  let merge = @base.array(@base.field(candidates, "merge"))
  assert_eq(merge.length(), 1)
  let row = merge[0]
  // The keeper is the earlier id, so the pair is stable across runs.
  assert_eq(@base.text(@base.field(row, "duplicate_key")), "b")
  assert_eq(@base.text(@base.field(row, "keeper_key")), "a")
  assert_eq(@base.text(@base.field(row, "reason")), "similar_text")
  // A read operation must not claim a pending host action.
  match candidates {
    Object(fields) => assert_false(fields.contains("execution"))
    _ => assert_true(false)
  }
  // The same vault state always yields the same candidates.
  assert_eq(memory_candidates(store, @vault.load(store)), candidates)
}

test "memory candidates groups every duplicate under one keeper" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  // Three notes with the same tokens. Two notes cannot show whether the group
  // stops after the first pair or chains n1 -> n0 and n2 -> n1, which would make
  // a host merge into a note that is itself a duplicate.
  let base_text = "官窑记录的器形与釉色特征可以据此核对，包括胎质釉层厚度与开片形态便于断代参考"
  let variants = [base_text,
    base_text.replace(old=", ", new="; "),
    base_text.replace(old=", ", new="、")]
  for index in 0..<3 {
    ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
      "kind": "fact", "scope": "workspace", "text": variants[index],
      "conditions": ["c" + index.to_string()], "sources": [],
      "at": "2026-11-12T09:0" + index.to_string() + ":00Z", "key": "n" + index.to_string() }))
  }
  let candidates = memory_candidates(store, @vault.load(store))
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
  let brief = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "query": "官窑", "dedup": "similar" })
  assert_eq(@base.array(@base.field(brief, "similar_duplicates")).length(), 2)
  assert_eq(@base.array(@base.field(brief, "notes")).length(), 1)
}

test "memory candidates never merges across kinds or scopes" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  let (first, second) = merge_pair_texts()
  // Identical tokens, different kinds: the same words are not the same judgment.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": first, "conditions": ["c1"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "fact" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "preference", "scope": "workspace", "text": second, "conditions": ["c2"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "pref" }))
  let candidates = memory_candidates(store, @vault.load(store))
  assert_eq(@base.array(@base.field(candidates, "merge")).length(), 0)
  // The same rule governs the seeded surface, so the two never disagree.
  let brief = memory_prefetch(store, @vault.load(store), { "op": "memory-prefetch",
    "query": "官窑", "dedup": "similar" })
  assert_eq(@base.array(@base.field(brief, "similar_duplicates")).length(), 0)
  // A third note of the original kind does merge.
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": second, "conditions": ["c3"],
    "sources": [], "at": "2026-11-12T09:10:00Z", "key": "fact2" }))
  let after = memory_candidates(store, @vault.load(store))
  let merge = @base.array(@base.field(after, "merge"))
  assert_eq(merge.length(), 1)
  let duplicate_key = @base.text(@base.field(merge[0], "duplicate_key"))
  let keeper_key = @base.text(@base.field(merge[0], "keeper_key"))
  assert_eq(duplicate_key, "fact")
  assert_eq(keeper_key, "fact2")
}

test "memory candidates excludes conflicted notes from merging and pruning" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  // Both sides carry the same conditions, so they conflict; both carry the same
  // tokens, so they WOULD merge if the conflict guard did not come first. A pair
  // whose tokens differ proves nothing, because it never merges either way.
  let (first, second) = merge_pair_texts()
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": first, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:00:00Z", "key": "x" }))
  ignore(memory_submit(store, @vault.load(store), { "op": "memory-submit",
    "kind": "fact", "scope": "workspace", "text": second, "conditions": ["核对釉色"],
    "sources": [], "at": "2026-11-12T09:05:00Z", "key": "y" }))
  let candidates = memory_candidates(store, @vault.load(store))
  // Dropping one side would hide the competing judgment the host must confirm.
  assert_eq(@base.array(@base.field(candidates, "merge")).length(), 0)
  assert_eq(@base.array(@base.field(candidates, "prune")).length(), 0)
  assert_eq(@base.field(@base.field(candidates, "counts"), "conflicted"),
            Json::number(2.0))
}

fn unused_note_request(key : String, at : String, suffix : String, condition : String) -> Json {
  { "op": "memory-submit", "kind": "preference", "scope": "workspace",
    "text": "偏好安排：" + suffix + "。这条记录足够长以通过门槛并且从未被使用过。",
    "conditions": [condition], "sources": [], "at": at, "key": key }
}

test "memory candidates never proposes a pinned or already-settled note" {
  let (store, _, _) = crashing(1 << 20)
  ignore(initialize(store, "研究陶瓷"))
  let pinned_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("pinned", "2026-11-12T09:00:00Z", "上午参观", "保护项")), "id"))
  let used_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("used", "2026-11-12T09:05:00Z", "下午参观", "常用项")), "id"))
  let archived_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("archived", "2026-11-12T09:10:00Z", "傍晚参观", "归档项")), "id"))
  let fresh_id = @base.text(@base.field(memory_submit(store, @vault.load(store),
    unused_note_request("fresh", "2026-11-12T09:15:00Z", "夜间参观", "待定项")), "id"))
  ignore(memory_protect(store, @vault.load(store), { "op": "memory-pin", "id": pinned_id,
    "pinned": true, "at": "2026-11-12T09:20:00Z" }))
  ignore(memory_use(store, @vault.load(store), { "op": "memory-use", "ids": [used_id],
    "at": "2026-11-12T09:25:00Z" }))
  ignore(memory_archive(store, @vault.load(store), { "op": "memory-archive",
    "id": archived_id, "at": "2026-11-12T09:30:00Z" }))
  let candidates = memory_candidates(store, @vault.load(store))
  let prune = @base.array(@base.field(candidates, "prune"))
  // Only the untouched note is a candidate: pinning, a reported use and an
  // archive are all decisions the engine must not second-guess.
  assert_eq(prune.length(), 1)
  assert_eq(@base.text(@base.field(prune[0], "id")), fresh_id)
  assert_eq(@base.text(@base.field(prune[0], "reason")), "never_used")
  assert_true(@base.field(prune[0], "last_used_at") == Json::null())
  assert_false(@base.boolean(@base.field(prune[0], "pinned")))
}
