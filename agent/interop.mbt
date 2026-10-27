fn bundle_directory(request : Json, area : String) -> String raise @base.Fault {
  let directory = @base.text(@base.field(request, "directory"))
  @base.path(directory)
  if !directory.has_prefix(area + "/") { @base.fail("interop_directory_required: " + area + "/*") }
  directory
}

fn read_bundle(store : @vault.Storage, directory : String, format : String) -> @interop.Bundle raise @base.Fault {
  let paths = (store.files)(directory)
  if paths.length() > 4096 { @base.fail("interop_file_count_limit") }
  let files : Array[@interop.File] = []
  let mut size = 0
  for path in paths {
    if !path.has_prefix(directory + "/") { @base.fail("interop_host_path_invalid") }
    let data = required_bytes(store, path)
    size = size+data.length()
    if size > 16777216 { @base.fail("interop_bytes_limit") }
    files.push({ path: path[directory.length()+1:].to_owned(), data })
  }
  @interop.bundle(format, files)
}

fn native_import_id(bundle : String, path : String) -> String {
  "imports/" + bundle + "/" + @base.hex_hash(path)
}

fn import_bundle(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let format = @base.text(@base.field(request, "format"))
  let directory = bundle_directory(request, "imports")
  let at = @base.text(@base.field(request, "at"))
  if at.length() < 10 || at.contains("\n") { @base.fail("at_required") }
  let bundle = read_bundle(store, directory, format)
  let receipt = "state/events/import-" + bundle.id + ".json"
  if entries.any(e => e.path == receipt) {
    return { "bundle": bundle.id, "replayed": true, "fingerprint": @vault.fingerprint(entries) }
  }
  let ids : Map[String, String] = Map([])
  for doc in bundle.documents {
    if !@interop.reserved(doc.path) { ids[doc.path] = native_import_id(bundle.id, doc.path) }
  }
  let mut next = entries.copy()
  let changes : Array[@vault.Change] = []
  let originals : Array[Json] = []
  for file in bundle.files {
    let raw = "raw/imports/" + bundle.id + "/" + file.path
    let sha256 = @base.sha256_hex(file.data)
    if entries.any(e => e.path == raw) { @base.fail("interop_raw_already_registered: " + raw) }
    if (store.digest)(raw) is Some(old) && old != sha256 { @base.fail("interop_raw_conflict: " + raw) }
    next = upsert(next, { id: raw, path: raw, kind: "raw", format: @core.format_for_path(file.path), sha256, sources: [], stale: false })
    originals.push({ "path": file.path, "raw": raw, "sha256": sha256 })
  }
  let pages : Array[Json] = []
  let debt : Array[Json] = []
  for doc in bundle.documents {
    if @interop.reserved(doc.path) { continue }
    let id = ids[doc.path]
    let path = "wiki/" + id + ".md"
    if entries.any(e => e.id == id || e.path == path) || (store.read_bytes)(path) is Some(_) { @base.fail("interop_page_conflict: " + path) }
    let raw = "raw/imports/" + bundle.id + "/" + doc.path
    let (body, broken) = @interop.native_links(doc, ids)
    let text = "---\ntype: concept\ntitle: " + @base.quoted(@interop.display_title(doc)) +
      "\nsources: [" + @base.quoted(raw) + "]\ntags: " + @base.canonical(@interop.tags(doc).to_json()) + "\n---\n" + body
    let sha256 = @base.hex_hash(text)
    next = upsert(next, { id, path, kind: "concept", format: "markdown", sha256, sources: [raw], stale: false })
    changes.push({ path, before: None, after: Some(text) })
    pages.push({ "path": doc.path, "id": id, "sha256": sha256 })
    for target in broken {
      debt.push({ "path": doc.path, "target": target })
      let rid = @base.hex_hash(bundle.id + "\n" + doc.path + "\n" + target)
      let rpath = "state/reviews/" + rid + ".json"
      let review : Json = { "id": rid, "order": bundle.id, "source": raw,
        "reason": "导入断链待核对：" + target, "created_at": "1970-01-01", "status": "pending", "decision": Json::null() }
      let content = @base.canonical(review)
      if entries.any(e => e.path == rpath) || (store.read_bytes)(rpath) is Some(_) { @base.fail("interop_review_conflict") }
      changes.push({ path: rpath, before: None, after: Some(content) })
      next = upsert(next, { id: rpath, path: rpath, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
    }
  }
  let event : Json = { "op": "import", "version": 1, "bundle": bundle.id, "format": format,
    "files": originals.to_json(), "pages": pages.to_json(), "broken": debt.to_json(), "at": at }
  let content = @base.canonical(event)
  if (store.read_bytes)(receipt) is Some(_) { @base.fail("interop_receipt_conflict") }
  changes.push({ path: receipt, before: None, after: Some(content) })
  next = upsert(next, { id: receipt, path: receipt, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
  with_views(store, next, changes, "## [" + at + "] import | " + bundle.id + "\n")
  // Originals are immutable input uploads, not knowledge publication. A failed
  // compiler/commit may leave identical unregistered raw bytes for a safe retry.
  for file in bundle.files {
    let raw = "raw/imports/" + bundle.id + "/" + file.path
    match (store.read_bytes)(raw) {
      Some(old) => if old != file.data { @base.fail("interop_raw_conflict: " + raw) }
      None => (store.write_bytes)(raw, file.data)
    }
  }
  let guarded : @vault.Storage = { ..store, check: path => {
    (store.check)(path)
    if read_bundle(store, directory, format).id != bundle.id { @base.fail("interop_input_changed") }
  } }
  if read_bundle(store, directory, format).id != bundle.id { @base.fail("interop_input_changed") }
  @vault.commit(guarded, @vault.fingerprint(entries), next, changes)
  { "bundle": bundle.id, "pages": pages.to_json(), "broken": debt.to_json(), "replayed": false,
    "fingerprint": @vault.fingerprint(next) }
}
