// Workspace registration (memory isolation, phase 2).
//
// A workspace is the canonical project path a host opens; its id is content
// addressed by `@core.workspace_id`, so the same path always lands in the same
// `state/workspaces/<id>.json` record. Registration is deliberately separate
// from opening files: the host normalizes the path (no symlink resolution in
// the engine), and this layer only accepts an already-canonical absolute path,
// keeping the workspace identity stable across processes.
//
// Opening a path twice is idempotent. The same `at` replays with zero writes; a
// newer `at` only refreshes `last_opened_at`; an older one is refused rather
// than silently rewinding the record.

fn workspace_record_path(id : String) -> String {
  "state/workspaces/" + id + ".json"
}

fn workspace_row_response(value : Json, replayed : Bool) -> Json raise @base.Fault {
  { "id": @base.field(value, "id"), "path": @base.field(value, "path"),
    "created_at": @base.field(value, "created_at"),
    "last_opened_at": @base.field(value, "last_opened_at"),
    "replayed": replayed.to_json() }
}

pub fn workspace_open(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "progress", "path", "at"])
  @vault.verify(store, entries)
  let path = @base.text(@base.field(request, "path"))
  @core.validate_workspace_path(path)
  let at = @base.text(@base.field(request, "at"))
  memory_time(at)
  let id = @core.workspace_id(path)
  let record_path = workspace_record_path(id)
  match (store.read)(record_path) {
    Some(existing) => {
      let value = @base.parse(existing)
      let created = @base.text(@base.field(value, "created_at"))
      let opened = @base.text(@base.field(value, "last_opened_at"))
      if at < opened { @base.fail("workspace_time_order: " + path) }
      if at == opened { return workspace_row_response(value, true) }
      let row : Json = { "version": Json::number(1.0), "id": id.to_json(),
        "path": path.to_json(), "created_at": created.to_json(), "last_opened_at": at.to_json() }
      let text = @base.canonical(row)
      let entry : @core.Entry = { id: record_path, path: record_path, kind: "state",
        format: "json", sha256: @base.hex_hash(text), sources: [], stale: false }
      @vault.commit(store, @vault.fingerprint(entries), upsert(entries, entry),
        [{ path: record_path, before: Some(existing), after: Some(text) }])
      workspace_row_response(row, false)
    }
    None => {
      let row : Json = { "version": Json::number(1.0), "id": id.to_json(),
        "path": path.to_json(), "created_at": at.to_json(), "last_opened_at": at.to_json() }
      let text = @base.canonical(row)
      let entry : @core.Entry = { id: record_path, path: record_path, kind: "state",
        format: "json", sha256: @base.hex_hash(text), sources: [], stale: false }
      @vault.commit(store, @vault.fingerprint(entries), upsert(entries, entry),
        [{ path: record_path, before: None, after: Some(text) }])
      workspace_row_response(row, false)
    }
  }
}

pub fn workspace_list(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  // Sort keys are extracted before sorting: `@base.field` raises, and a
  // comparator cannot carry an error type.
  let keyed : Array[(String, String, Json)] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/workspaces/") {
      let value = @base.parse(@vault.required(store, entry.path))
      keyed.push((@base.text(@base.field(value, "path")), @base.text(@base.field(value, "id")), value))
    }
  }
  keyed.sort_by((a, b) => {
    let cmp = @base.compare(a.0, b.0)
    if cmp != 0 { cmp } else { @base.compare(a.1, b.1) }
  })
  let rows = keyed.map(pair => pair.2)
  { "workspaces": rows.to_json(), "count": rows.length().to_json() }
}
