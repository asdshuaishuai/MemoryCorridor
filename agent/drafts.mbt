fn context_inputs(entries : Array[@core.Entry]) -> Map[String, String] {
  let result : Map[String, String] = Map([])
  for entry in entries {
    if @core.is_page(entry) || entry.kind == "purpose" { result[entry.id] = entry.sha256 }
  }
  result
}

fn context_version(entries : Array[@core.Entry]) -> String {
  let inputs = entries.filter(e => @core.is_page(e) || e.kind == "purpose" || e.kind == "raw")
  inputs.sort_by((a,b) => @base.compare(a.id, b.id))
  @base.hex_hash(@base.canonical(inputs.to_json()))
}

fn context_token(order : Order) -> String {
  @base.hex_hash(@base.canonical({ "order": order.id, "source": order.source,
    "source_hash": order.source_hash, "pages": order.page_hashes.to_json(), "context_version": order.context_version }))
}

fn assert_context(store : @vault.Storage, entries : Array[@core.Entry], order : Order, token : String) -> Unit raise @base.Fault {
  @vault.verify(store, entries)
  if token != context_token(order) || order.page_hashes != context_inputs(entries) || order.context_version != context_version(entries) {
    @base.fail("context_stale: call context and regenerate")
  }
  let source = @core.find(entries, order.source)
  if source.stale || source.sha256 != order.source_hash || (store.digest)(order.source) != Some(order.source_hash) {
    @base.fail("order_source_changed: rescan")
  }
}

fn guard_context(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Unit raise @base.Fault {
  if optional(request, "context_token") is Some(value) {
    let order = load_order(store, @base.text(@base.field(request, "order")))
    let token = @base.text(value)
    if order.phase == "committed" && @base.text(@base.field(request, "op")) == "commit" {
      // A terminal replay publishes nothing; its original input catalog no longer exists.
      ()
    } else { assert_context(store, entries, order, token) }
  }
}

fn submit_drafts(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let order = load_order(store, @base.text(@base.field(request, "order")))
  if order.phase != "analysis-done" { @base.fail("order_phase: analysis-submit required") }
  assert_context(store, entries, order, @base.text(@base.field(request, "context_token")))
  let items = @base.array(@base.field(request, "pages"))
  if items.is_empty() || items.length() > 32 { @base.fail("draft_batch_size: 1..32") }
  let drafts : Array[(@core.Entry, @vault.Change, String)] = []
  let seen : Map[String, Bool] = Map([])
  let mut next = entries.copy()
  let mut total = 0
  for item in items {
    @base.keys(item, ["id", "kind", "title", "sources", "tags", "body"])
    let id = @base.text(@base.field(item, "id"))
    @base.path(id)
    if seen.contains(id) { @base.fail("duplicate_draft: " + id) }
    seen[id] = true
    let kind = @base.text(@base.field(item, "kind"))
    let title = @base.text(@base.field(item, "title"))
    let sources = @base.strings(@base.field(item, "sources"))
    let tags = @base.strings(@base.field(item, "tags"))
    let body = @base.text(@base.field(item, "body"))
    if title.trim().is_empty() || body.trim().is_empty() { @base.fail("draft_content_required: " + id) }
    let text = "---\ntype: " + @base.quoted(kind) + "\ntitle: " + @base.quoted(title) +
      "\nsources: " + @base.canonical(sources.to_json()) + "\ntags: " + @base.canonical(tags.to_json()) + "\n---\n" + body + "\n"
    total = total + @base.utf8_size(text)
    if total > 1048576 { @base.fail("draft_text_limit: 1MiB") }
    let path = match entries.iter().find_first(e => e.id == id) {
      Some(entry) => entry.path
      None => "wiki/" + id + ".md"
    }
    let (entry, change) = page_change(store, entries, order, id, path, text)
    if !@core.is_page(entry) { @base.fail("draft_page_kind_required: " + id) }
    let staged = "staging/" + order.id + "/generated/" + @base.hex_hash(id + "\n" + text) + ".md"
    if (store.read)(staged) is Some(old) {
      if old != text { @base.fail("draft_file_conflict: " + staged) }
    }
    drafts.push((entry, change, staged))
    next = upsert(next, entry)
  }
  @core.validate_entries(next)
  for (entry, change, _) in drafts {
    ignore(@core.validate_page(entry, change.after.unwrap(), next))
  }
  let manifest : Array[Json] = []
  for (entry, change, staged) in drafts {
    (store.write)(staged, change.after.unwrap())
    manifest.push({ "id": entry.id, "path": entry.path, "staged": staged })
  }
  { "order": order.id, "context_token": context_token(order), "pages": manifest.to_json(), "published": false }
}
