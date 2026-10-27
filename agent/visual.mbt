fn visual(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  let path = match optional(request, "view") { None => "views/library.mbt.md"; Some(v) => @base.text(v) }
  @base.path(path)
  if !path.has_prefix("views/") || !path.has_suffix(".mbt.md") { @base.fail("view_path_required") }
  if op == "view-init" {
    if (store.read)(path) is Some(_) { @base.fail("view_already_exists") }
    let text = @visual.generate(@visual.default_view())
    // Validate in cache before publishing a page source.
    (store.write)(".corridor/view-candidate.mbt.md", text)
    (store.check)(".corridor/view-candidate.mbt.md")
    (store.write)(path, text)
    return { "view": path, "source": text }
  }
  @vault.verify(store, entries)
  let text = @vault.required(store, path)
  let view = @visual.parse(text)
  (store.check)(path)
  let pages : Array[@visual.Reading] = []
  let sources : Array[@visual.Source] = []
  for e in entries {
    if @core.is_page(e) { pages.push({ entry: e, page: @core.parse_page(@vault.required(store, e.path)) }) }
    if e.kind == "raw" {
      // The catalog owns the source format. Rendering must consume the
      // verified declaration so an edited extension cannot silently change
      // the interpretation of a snapshot.
      let format = e.format
      let textual = format != "binary" && format != "image"
      let body = if e.stale { "此来源已撤销或缺失。" }
        else if textual { @vault.required(store, e.path) }
        else { "二进制资料；请使用原格式工具读取。路径：" + e.path }
      let image = if format == "image" && !e.stale {
        let bytes = required_bytes(store, e.path)
        if bytes.length() > 4194304 { "" } else { "data:" + @visual.image_mime(e.path) + ";base64," + @base64.encode(bytes) }
      } else { "" }
      sources.push({ id: e.id, path: e.path, sha256: e.sha256, text: body, format: if e.stale { "text" } else { format }, image })
    }
  }
  pages.sort_by((a,b) => @base.compare(a.entry.id, b.entry.id))
  sources.sort_by((a,b) => @base.compare(a.id, b.id))
  let fingerprint = @vault.fingerprint(entries)
  let html = @visual.render(view, pages, sources, fingerprint)
  if @vault.required(store, path) != text || @vault.fingerprint(@vault.load(store)) != fingerprint { @base.fail("view_snapshot_conflict") }
  @vault.verify(store, entries)
  (store.write)(".corridor/viewer.html", html)
  { "output": ".corridor/viewer.html", "fingerprint": fingerprint, "view_sha256": @base.hex_hash(text),
    "pages": pages.length(), "sources": sources.length() }
}
