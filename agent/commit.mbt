fn page_change(
  store : @vault.Storage, entries : Array[@core.Entry], order : Order,
  id : String, path : String, text : String,
) -> (@core.Entry, @vault.Change) raise @base.Fault {
  @base.path(id)
  @base.path(path)
  if !path.has_prefix("wiki/") || !path.has_suffix(".md") || ["wiki/index.md", "wiki/log.md"].contains(path) {
    @base.fail("page_path_refused: " + path)
  }
  let before = (store.read)(path)
  for e in entries {
    if e.id == id {
      if e.path != path || !@core.is_page(e) { @base.fail("entry_identity_conflict: " + id) }
      if order.page_hashes.get(id) != Some(e.sha256) { @base.fail("context_stale: call context again for " + id) }
      if before.map(@base.hex_hash) != Some(e.sha256) { @base.fail("page_changed: " + id) }
    }
  }
  if !entries.iter().any(e => e.id == id) && before is Some(_) { @base.fail("unregistered_file_conflict: " + path) }
  let page = @core.parse_page(text)
  if !page.sources.contains(order.source) { @base.fail("order_source_missing: " + id) }
  let entry : @core.Entry = {
    id, path, kind: page.kind, format: "markdown", sha256: @base.hex_hash(text), sources: page.sources, stale: false,
  }
  (entry, { path, before, after: Some(text) })
}

fn with_views(
  store : @vault.Storage, entries : Array[@core.Entry], changes : Array[@vault.Change], event_text : String,
) -> Unit raise @base.Fault {
  let rows = entries.filter(e => @core.is_page(e))
  rows.sort_by((a,b) => @base.compare(a.id, b.id))
  let directory = "# 知识目录\n\n" + rows.map(e =>
    "- [[" + e.id + "]]" + (if e.stale { " （待重编译）" } else { "" })).join("\n") + "\n"
  changes.push({ path: "wiki/index.md", before: (store.read)("wiki/index.md"), after: Some(directory) })
  let old_log = (store.read)("wiki/log.md").unwrap_or("# 摄入日志\n")
  changes.push({ path: "wiki/log.md", before: (store.read)("wiki/log.md"), after: Some(old_log + "\n" + event_text) })
}

pub fn commit_pages(
  store : @vault.Storage, entries : Array[@core.Entry], id : String, pages : Json, at : String,
) -> Json raise @base.Fault {
  let order = load_order(store, id)
  if order.phase == "committed" { return { "order": id, "phase": "committed", "fingerprint": @vault.fingerprint(entries), "replayed": true } }
  if order.phase != "analysis-done" { @base.fail("order_phase: analysis-submit required") }
  if order.page_hashes.get("purpose.md") != Some(@base.hex_hash(@vault.required(store, "purpose.md"))) { @base.fail("purpose_conflict: refresh context and analysis") }
  if at.length() < 10 || at.contains("\n") { @base.fail("at_required: explicit ISO date/time input") }
  let source = @core.find(entries, order.source)
  if source.kind != "raw" || source.stale || source.sha256 != order.source_hash ||
    (store.digest)(order.source) != Some(order.source_hash) {
    @base.fail("order_source_changed: rescan and use new order")
  }
  let items = @base.array(pages)
  let mut next = entries.copy()
  let changes : Array[@vault.Change] = []
  let staged_paths : Array[String] = []
  // The published hash of every page this commit wrote, so a page's version
  // history is recoverable from the event log instead of being inferred.
  let published : Map[String, String] = Map([])
  for item in items {
    @base.keys(item, ["id", "path", "staged"])
    let pid = @base.text(@base.field(item, "id"))
    let path = @base.text(@base.field(item, "path"))
    let staged = @base.text(@base.field(item, "staged"))
    @base.path(staged)
    if !staged.has_prefix("staging/" + id + "/") { @base.fail("staging_order_mismatch") }
    let (entry, change) = page_change(store, entries, order, pid, path, @vault.required(store, staged))
    changes.push(change)
    staged_paths.push(staged)
    published[entry.id] = entry.sha256
    next = upsert(next, entry)
  }
  let mut has_summary = false
  for c in changes {
    if c.after is Some(text) {
      if @core.parse_page(text).kind == "source-summary" { has_summary = true }
    }
  }
  if !has_summary {
    let summary_id = "sources/" + @base.hex_hash(order.source)
    let excerpt = "---\ntype: source-summary\ntitle: " + @base.quoted(order.source) +
      "\nsources: [" + @base.quoted(order.source) + "]\n---\n" +
      "未生成语义摘要。来源：" + order.source + "\n\n源文件 SHA-256：" + order.source_hash + "\n"
    let (entry, change) = page_change(store, entries, order, summary_id, "wiki/" + summary_id + ".md", excerpt)
    changes.push(change)
    published[entry.id] = entry.sha256
    next = upsert(next, entry)
  }
  let terminal = { ..order, phase: "committed" }
  let opath = order_path(id)
  changes.push({ path: opath, before: (store.read)(opath), after: Some(@base.canonical(terminal.to_json())) })
  next = upsert(next, order_entry(terminal))
  let event_path = "state/events/" + id + ".json"
  let event : Json = { "op": "ingest", "order": id, "source": order.source, "at": at,
    "pages": published.to_json() }
  let event_content = @base.canonical(event)
  // Semantic conflicts are soft debt, recorded independently of the cache.
  for conflict in @base.strings(@base.field(order.analysis, "conflicts")) {
    let rid = @base.hex_hash(id + "\n" + conflict)
    let path = "state/reviews/" + rid + ".json"
    let review : Json = { "id": rid, "order": id, "source": order.source, "reason": conflict,
      "created_at": at, "status": "pending", "decision": Json::null() }
    let content = @base.canonical(review)
    if !next.any(e => e.path == path) {
      changes.push({ path, before: None, after: Some(content) })
      next = upsert(next, { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
    }
  }
  if (store.read)(event_path) is Some(_) { @base.fail("event_already_exists") }
  changes.push({ path: event_path, before: None, after: Some(event_content) })
  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false })
  with_views(store, next, changes, "## [" + at + "] ingest | " + order.source + "\n")
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  // Staging is recoverable input; keep it after commit for review, no dangerous broad cleanup.
  { "order": id, "phase": "committed", "fingerprint": @vault.fingerprint(next), "staged": staged_paths.to_json() }
}

pub fn forget(store : @vault.Storage, entries : Array[@core.Entry], source : String, at : String) -> Json raise @base.Fault {
  let raw = @core.find(entries, source)
  if raw.kind != "raw" { @base.fail("expected_raw_source") }
  if raw.stale { return { "source": source, "invalidated": Json::array([]), "fingerprint": @vault.fingerprint(entries), "raw_retained": true, "replayed": true } }
  let mut next = entries.map(e => if e.id == source { { ..e, stale: true } } else { e })
  next = next.map(e => if e.sources.contains(source) {
    { ..e, stale: true }
  } else { e })
  next = @vault.invalidate_dependents(store, next)
  let invalidated = next.filter(e => @core.is_page(e) && e.stale &&
    entries.any(old => old.id == e.id && !old.stale)).map(e => e.id)
  let changes : Array[@vault.Change] = []
  for order in orders(store, next) {
    if order.source == source && order.phase != "committed" && order.phase != "cancelled" {
      let cancelled = { ..order, phase: "cancelled" }
      let path = order_path(order.id)
      changes.push({ path, before: (store.read)(path), after: Some(@base.canonical(cancelled.to_json())) })
      next = upsert(next, order_entry(cancelled))
    }
  }
  let event_path = "state/events/" + @base.hex_hash("forget\n" + source + "\n" + @vault.fingerprint(entries)) + ".json"
  let event : Json = { "op": "forget", "source": source, "at": at, "invalidated": invalidated.to_json() }
  let content = @base.canonical(event)
  changes.push({ path: event_path, before: None, after: Some(content) })
  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
  with_views(store, next, changes, "## [" + at + "] forget | " + source + "\n")
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "source": source, "invalidated": invalidated.to_json(), "fingerprint": @vault.fingerprint(next), "raw_retained": true }
}
