pub(all) struct Order {
  id : String
  source : String
  source_hash : String
  baseline : String
  context_version : String
  phase : String
  analysis : Json
  page_hashes : Map[String, String]
} derive(ToJson)
pub extend Order with ToJson::{to_json}

pub fn order_path(id : String) -> String raise @base.Fault {
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail("invalid_order_id")
  }
  "state/orders/" + id + ".json"
}

pub fn order_from_json(value : Json) -> Order raise @base.Fault {
  @base.keys(value, ["id", "source", "source_hash", "baseline", "context_version", "phase", "analysis", "page_hashes"])
  let hashes : Map[String, String] = Map([])
  match @base.field(value, "page_hashes") {
    Object(values) => for (key, v) in values { hashes[key] = @base.text(v) }
    _ => @base.fail("invalid_page_hashes")
  }
  { id: @base.text(@base.field(value, "id")), source: @base.text(@base.field(value, "source")),
    source_hash: @base.text(@base.field(value, "source_hash")), baseline: @base.text(@base.field(value, "baseline")),
    context_version: match optional(value, "context_version") { Some(v) => @base.text(v); None => "" },
    phase: @base.text(@base.field(value, "phase")), analysis: @base.field(value, "analysis"), page_hashes: hashes }
}

pub fn load_order(store : @vault.Storage, id : String) -> Order raise @base.Fault {
  order_from_json(@base.parse(@vault.required(store, order_path(id))))
}

pub fn order_entry(order : Order) -> @core.Entry raise @base.Fault {
  let path = order_path(order.id)
  { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(@base.canonical(order.to_json())), sources: [], stale: false }
}

pub fn upsert(entries : Array[@core.Entry], entry : @core.Entry) -> Array[@core.Entry] {
  let result = entries.filter(e => e.id != entry.id)
  result.push(entry)
  result
}

pub fn save_order(
  store : @vault.Storage, entries : Array[@core.Entry], order : Order,
) -> Unit raise @base.Fault {
  let path = order_path(order.id)
  let change : @vault.Change = { path, before: (store.read)(path), after: Some(@base.canonical(order.to_json())) }
  @vault.commit(store, @vault.fingerprint(entries), upsert(entries, order_entry(order)), [change])
}

pub fn orders(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Order] raise @base.Fault {
  let result : Array[Order] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/orders/") {
      result.push(order_from_json(@base.parse(@vault.required(store, entry.path))))
    }
  }
  result.sort_by((a,b) => @base.compare(a.id, b.id))
  result
}

pub fn scan(store : @vault.Storage, entries : Array[@core.Entry], adopt_pages? : Bool = false) -> Json raise @base.Fault {
  let mut next = entries.copy()
  let changes : Array[@vault.Change] = []
  let created : Array[String] = []
  let raw_paths = (store.files)("raw")
  for entry in entries {
    // Page/state drift is a conflict; changed raw inputs are precisely what scan registers.
    if entry.kind != "raw" {
      let text = @vault.required(store, entry.path)
      if @base.hex_hash(text) != entry.sha256 {
        if !adopt_pages || (!@core.is_page(entry) && entry.kind != "purpose") { @base.fail("content_changed: " + entry.path + "; use refresh for explicit human page edits") }
        let updated = if entry.kind == "purpose" { { ..entry, sha256: @base.hex_hash(text) } }
          else { let page = @core.parse_page(text); { ..entry, sha256: @base.hex_hash(text), kind: page.kind, sources: page.sources } }
        next = upsert(next, updated)
        changes.push({ path: entry.path, before: Some(text), after: Some(text) })
      }
    }
    if entry.kind == "raw" && !raw_paths.contains(entry.path) {
      next = upsert(next, { ..entry, stale: true })
      next = next.map(e => if e.sources.contains(entry.id) { { ..e, stale: true } } else { e })
      let event_path = "state/events/source-missing-" + @base.hex_hash(entry.id + "\n" + entry.sha256) + ".json"
      if !entries.any(e => e.path == event_path) {
        let event : Json = { "op": "source-missing", "source": entry.id, "source_hash": entry.sha256 }
        let content = @base.canonical(event)
        changes.push({ path: event_path, before: None, after: Some(content) })
        next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json",
          sha256: @base.hex_hash(content), sources: [], stale: false })
      }
    }
  }
  for path in raw_paths {
    let hash = match (store.digest)(path) {
      Some(hash) => hash
      None => raise @base.Fault("source_disappeared: " + path)
    }
    // A revoked source keeps its tombstone, and `forget` does not delete the
    // file. Matching a stale entry here is what makes the revocation sticky:
    // re-creating the identical bytes must not silently re-approve a source a
    // human revoked. Re-registering requires the content to change.
    if entries.iter().any(e => e.kind == "raw" && e.path == path && e.sha256 == hash) { continue }
    next = next.map(e => if e.sources.contains(path) { { ..e, stale: true } } else { e })
    let raw : @core.Entry = { id: path, path, kind: "raw", format: @core.format_for_path(path), sha256: hash, sources: [], stale: false }
    next = upsert(next, raw)
    let id = @base.hex_hash(path + "\n" + hash + "\n" + @vault.fingerprint(entries))
    let order : Order = { id, source: path, source_hash: hash, baseline: @vault.fingerprint(entries),
      context_version: "", phase: "pending", analysis: Json::null(), page_hashes: Map([]) }
    let opath = order_path(id)
    let before = (store.read)(opath)
    if before is None {
      changes.push({ path: opath, before, after: Some(@base.canonical(order.to_json())) })
      next = upsert(next, order_entry(order))
      created.push(id)
    }
  }
  for old_order in orders(store, entries) {
    if old_order.phase == "committed" || old_order.phase == "cancelled" { continue }
    if !next.iter().any(e => e.kind == "raw" && !e.stale && e.id == old_order.source && e.sha256 == old_order.source_hash) {
      let cancelled = { ..old_order, phase: "cancelled" }
      let path = order_path(old_order.id)
      changes.push({ path, before: (store.read)(path), after: Some(@base.canonical(cancelled.to_json())) })
      next = upsert(next, order_entry(cancelled))
    }
  }
  next = @vault.invalidate_dependents(store, next)
  if !changes.is_empty() && adopt_pages {
    let path = "state/events/" + @base.hex_hash("refresh\n" + @vault.fingerprint(entries) + "\n" + @vault.fingerprint(next)) + ".json"
    let event : Json = { "op": "refresh", "before": @vault.fingerprint(entries), "changes": changes.map(c => c.path).to_json() }
    let text = @base.canonical(event)
    changes.push({ path, before: None, after: Some(text) })
    next = upsert(next, { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(text), sources: [], stale: false })
  }
  if @vault.fingerprint(next) != @vault.fingerprint(entries) {
    @vault.commit(store, @vault.fingerprint(entries), next, changes)
  }
  { "orders": created.to_json(), "fingerprint": @vault.fingerprint(next) }
}

pub fn context(store : @vault.Storage, entries : Array[@core.Entry], id : String) -> Json raise @base.Fault {
  let order = load_order(store, id)
  ignore(@core.find(entries, order_path(id)))
  for active in orders(store, entries) {
    if active.id != id && (active.phase == "context-ready" || active.phase == "analysis-done") {
      @base.fail("another_order_active: " + active.id)
    }
  }
  if order.phase == "committed" || order.phase == "cancelled" { @base.fail("order_terminal") }
  if (store.digest)(order.source) != Some(order.source_hash) { @base.fail("source_changed: rescan") }
  // Text extraction follows the verified catalog format. Extension checks
  // would incorrectly hide HTML and source-language inputs from an agent.
  let source_entry = @core.find(entries, order.source)
  let textual = source_entry.format != "binary" && source_entry.format != "image"
  let source = if textual { @vault.required(store, order.source).to_json() } else { Json::null() }
  let pages : Array[Json] = []
  let hashes : Map[String, String] = Map([])
  hashes["purpose.md"] = @base.hex_hash(@vault.required(store, "purpose.md"))
  for e in entries {
    if @core.is_page(e) {
      let text = @vault.required(store, e.path)
      if @base.hex_hash(text) != e.sha256 { @base.fail("page_changed: " + e.path) }
      hashes[e.id] = e.sha256
      pages.push({ "entry": e.to_json(), "text": text })
    }
  }
  let version = context_version(entries)
  let changed = order.page_hashes != hashes || order.context_version != version
  let next = { ..order, phase: if order.phase == "pending" || changed { "context-ready" } else { order.phase },
    analysis: if changed { Json::null() } else { order.analysis },
    page_hashes: hashes, baseline: @vault.fingerprint(entries), context_version: version }
  save_order(store, entries, next)
  (store.write)("staging/" + id + "/.corridor-order", id)
  { "order": next.to_json(), "context_token": context_token(next),
    "source_summary_id": "sources/" + @base.hex_hash(order.source),
    "source_text": source, "extraction_required": !textual, "pages": pages.to_json(),
    "purpose": @vault.required(store, "purpose.md"),
    "output_schema": { "entities": "string[]", "concepts": "string[]", "conflicts": "string[]", "summary": "string" } }
}

pub fn submit_analysis(store : @vault.Storage, entries : Array[@core.Entry], id : String, analysis : Json) -> Json raise @base.Fault {
  let order = load_order(store, id)
  if order.phase == "analysis-done" && order.analysis == analysis { return order.to_json() }
  if order.phase != "context-ready" { @base.fail("order_phase: call context before analysis-submit") }
  @base.keys(analysis, ["entities", "concepts", "conflicts", "summary"])
  ignore(@base.strings(@base.field(analysis, "entities")))
  ignore(@base.strings(@base.field(analysis, "concepts")))
  ignore(@base.strings(@base.field(analysis, "conflicts")))
  ignore(@base.text(@base.field(analysis, "summary")))
  if (store.digest)(order.source) != Some(order.source_hash) { @base.fail("source_changed") }
  let next = { ..order, phase: "analysis-done", analysis }
  save_order(store, entries, next)
  next.to_json()
}
