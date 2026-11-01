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
    Some(old) => {
      if old != content { @base.fail("page_archive_event_conflict") }
      // A replay reconciles with the live catalog: only a page that is still
      // archived reports the archive as effective. Retrying the original
      // request after the page was restored is a stale archive, not a success.
      if page.stale { return { "page": id, "archived": true, "replayed": true, "event": path } }
      @base.fail("page_not_active")
    }
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

// The publish-time provenance of one page version lives in its ingest event:
// it names the order that wrote the version and the page hash it published,
// and the order records the source hash the body was derived from. `commit`
// refuses to publish against drifted sources (order_source_changed); restore
// must not wave an old version past the same check. Events written before
// per-page history carry no binding and impose no constraint.
fn page_version_provenance_current(
  store : @vault.Storage, entries : Array[@core.Entry], page : String, page_hash : String,
) -> Bool raise @base.Fault {
  for entry in entries {
    if entry.kind != "state" || !entry.path.has_prefix("state/events/") { continue }
    let value = @base.parse(@vault.required(store, entry.path))
    if @base.text(@base.field(value, "op")) != "ingest" { continue }
    let pages = match optional(value, "pages") {
      Some(Object(fields)) => fields
      _ => continue
    }
    match pages.get(page) {
      Some(hash) if @base.text(hash) == page_hash => ()
      _ => continue
    }
    let order = load_order(store, @base.text(@base.field(value, "order")))
    let source = @core.find(entries, order.source)
    if source.kind != "raw" || source.stale || source.sha256 != order.source_hash ||
      (store.digest)(order.source) != Some(order.source_hash) {
      return false
    }
  }
  true
}

// Reactivate pages whose staleness was only ever propagation from the archived
// page: a stale page that carries no archive event of its own, whose sources
// are still active at the published bytes, whose links all resolve again once
// the restored closure is fresh, and that links back into what this restore
// reactivated. Explicit archives (they own their event), revoked sources and
// drifted bodies keep their stale state.
fn restore_reactivate(
  store : @vault.Storage, before : Array[@core.Entry], next : Array[@core.Entry], root : String,
) -> Array[@core.Entry] raise @base.Fault {
  let mut changed = true
  while changed {
    changed = false
    for i in 0..<next.length() {
      let entry = next[i]
      if !@core.is_page(entry) || !entry.stale || entry.id == root { continue }
      if !entry.sources.iter().all(s => next.iter().any(e => e.id == s && e.kind == "raw" && !e.stale)) { continue }
      if archive_for_page(store, next, entry.id, entry.sha256) is Some(_) { continue }
      if !page_version_provenance_current(store, next, entry.id, entry.sha256) { continue }
      let page = @core.parse_page(@vault.required(store, entry.path))
      let resolved = page.links.iter().all(l =>
        l == entry.id || next.iter().any(e => e.id == l && @core.is_page(e) && !e.stale))
      let linked_in = page.links.iter().any(l =>
        before.iter().any(e => e.id == l && e.stale) &&
        next.iter().any(e => e.id == l && @core.is_page(e) && !e.stale))
      if resolved && linked_in {
        next[i] = { ..entry, stale: false }
        changed = true
      }
    }
  }
  next
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
  // The restored body must still be derived from the bytes its source holds
  // now; a rewritten source re-registers under a new hash and the archived
  // version stays obsolete until it is republished from the new bytes.
  if !page_version_provenance_current(store, entries, id, page.sha256) {
    @base.fail("restore_source_changed: rescan and republish from the current source")
  }
  let mut next = entries.map(e => if e.id == id { { ..e, stale: false } } else { e })
  next = restore_reactivate(store, entries, next, id)
  let restored = @core.find(next, id)
  ignore(@core.validate_page(restored, text, next))
  next = @vault.invalidate_dependents(store, next)
  if @core.find(next, id).stale { @base.fail("page_dependencies_inactive") }
  let reactivated = next.filter(e => @core.is_page(e) && !e.stale &&
    entries.any(old => old.id == e.id && old.stale)).map(e => e.id)
  let event_path = "state/events/page-restore-" + @base.hex_hash(id + "\n" + page.sha256 + "\n" + archive + "\n" + at) + ".json"
  let event : Json = { "version": 1, "op": "page-restore", "page": id,
    "page_hash": page.sha256, "archive": archive, "at": at }
  let content = @base.canonical(event)
  match (store.read)(event_path) {
    Some(old) => if old == content {
      if page.stale {
        // The event survives but a later archive undid its effect; the same
        // request cannot re-apply a content-addressed event, so refuse
        // instead of reporting a restore that no longer holds.
        @base.fail("page_restore_stale: page is stale again; repeat the restore with a fresh at")
      }
      return { "page": id, "restored": true, "replayed": true, "event": event_path }
    } else { @base.fail("page_restore_event_conflict") }
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
    "reactivated": reactivated.to_json(), "fingerprint": @vault.fingerprint(next) }
}
