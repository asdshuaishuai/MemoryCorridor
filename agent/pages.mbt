fn lifecycle_time(value : String, field : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("page_lifecycle_time_invalid: " + field)
  }
}

fn lifecycle_reason(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 1024 || value.contains("\n") || value.contains("\r") {
    @base.fail("page_lifecycle_reason_invalid")
  }
}

fn archive_event_path(page : String, page_hash : String, at : String, reason : String) -> String {
  "state/events/page-archive-" + @base.hex_hash(page + "\n" + page_hash + "\n" + at + "\n" + reason) + ".json"
}

fn archive_for_page(store : @vault.Storage, entries : Array[@core.Entry], page : String, page_hash : String) -> String? raise @base.Fault {
  let paths : Array[String] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/events/page-archive-") {
      let value = @base.parse(@vault.required(store, entry.path))
      @base.keys(value, ["version", "op", "page", "page_hash", "at", "reason"])
      if @base.text(@base.field(value, "op")) != "page-archive" ||
        @base.text(@base.field(value, "page")) != page ||
        @base.text(@base.field(value, "page_hash")) != page_hash {
        continue
      }
      paths.push(entry.path)
    }
  }
  paths.sort_by(@base.compare)
  if paths.is_empty() { None } else { Some(paths[0]) }
}

pub fn archive_page(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let id = @base.text(@base.field(request, "id"))
  let at = @base.text(@base.field(request, "at"))
  let reason = @base.text(@base.field(request, "reason"))
  @base.path(id)
  lifecycle_time(at, "at")
  lifecycle_reason(reason)
  @vault.verify(store, entries)
  let page = @core.find(entries, id)
  if !@core.is_page(page) { @base.fail("not_a_page") }
  let text = @vault.required(store, page.path)
  if @base.hex_hash(text) != page.sha256 { @base.fail("page_changed") }
  let path = archive_event_path(id, page.sha256, at, reason)
  let event : Json = { "version": 1, "op": "page-archive", "page": id,
    "page_hash": page.sha256, "at": at, "reason": reason }
  let content = @base.canonical(event)
  match (store.read)(path) {
    Some(old) => if old == content { return { "page": id, "archived": true, "replayed": true, "event": path } }
      else { @base.fail("page_archive_event_conflict") }
    None => ()
  }
  if page.stale { @base.fail("page_not_active") }
  let mut next = entries.map(e => if e.id == id { { ..e, stale: true } } else { e })
  next = @vault.invalidate_dependents(store, next)
  let invalidated = next.filter(e => @core.is_page(e) && e.stale && entries.any(old => old.id == e.id && !old.stale)).map(e => e.id)
  let event_entry : @core.Entry = { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }
  next = upsert(next, event_entry)
  let changes : Array[@vault.Change] = [{ path, before: None, after: Some(content) }]
  with_views(store, next, changes, "## [" + at + "] page-archive | " + id + "\n")
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "page": id, "archived": true, "replayed": false, "event": path, "invalidated": invalidated.to_json(),
    "fingerprint": @vault.fingerprint(next) }
}

pub fn restore_page(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let id = @base.text(@base.field(request, "id"))
  let at = @base.text(@base.field(request, "at"))
  lifecycle_time(at, "at")
  @base.path(id)
  @vault.verify(store, entries)
  let page = @core.find(entries, id)
  if !@core.is_page(page) { @base.fail("not_a_page") }
  let archive = match archive_for_page(store, entries, id, page.sha256) {
    Some(path) => path
    None => raise @base.Fault("page_not_archived")
  }
  let text = @vault.required(store, page.path)
  if @base.hex_hash(text) != page.sha256 { @base.fail("page_changed") }
  for source in page.sources {
    let raw = @core.find(entries, source)
    if raw.kind != "raw" || raw.stale || (store.digest)(source) != Some(raw.sha256) {
      @base.fail("page_sources_inactive: " + source)
    }
  }
  let mut next = entries.map(e => if e.id == id { { ..e, stale: false } } else { e })
  let restored = @core.find(next, id)
  ignore(@core.validate_page(restored, text, next))
  next = @vault.invalidate_dependents(store, next)
  if @core.find(next, id).stale { @base.fail("page_dependencies_inactive") }
  let event_path = "state/events/page-restore-" + @base.hex_hash(id + "\n" + page.sha256 + "\n" + archive + "\n" + at) + ".json"
  let event : Json = { "version": 1, "op": "page-restore", "page": id,
    "page_hash": page.sha256, "archive": archive, "at": at }
  let content = @base.canonical(event)
  match (store.read)(event_path) {
    Some(old) => if old == content { return { "page": id, "restored": true, "replayed": true, "event": event_path } }
      else { @base.fail("page_restore_event_conflict") }
    None => ()
  }
  if !page.stale { @base.fail("page_already_active") }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }
  next = upsert(next, event_entry)
  let changes : Array[@vault.Change] = [{ path: event_path, before: None, after: Some(content) }]
  with_views(store, next, changes, "## [" + at + "] page-restore | " + id + "\n")
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "page": id, "restored": true, "replayed": false, "event": event_path,
    "fingerprint": @vault.fingerprint(next) }
}
