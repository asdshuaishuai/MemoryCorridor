fn export_bundle_files(
  store : @vault.Storage, entries : Array[@core.Entry], id : String, format : String,
) -> Array[@interop.File] raise @base.Fault {
  if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_bundle_id") }
  let receipt = "state/events/import-" + id + ".json"
  ignore(@core.find(entries, receipt))
  let event = @base.parse(@vault.required(store, receipt))
  if @base.field(event, "op") != "import".to_json() || @base.field(event, "version") != Json::number(1.0) || @base.field(event, "bundle") != id.to_json() { @base.fail("interop_receipt_invalid") }
  let original_format = @base.text(@base.field(event, "format"))
  let files : Array[@interop.File] = []
  for row in @base.array(@base.field(event, "files")) {
    let path = @base.text(@base.field(row, "path"))
    @base.path(path)
    let raw = "raw/imports/" + id + "/" + path
    let entry = @core.find(entries, raw)
    if entry.kind != "raw" || entry.stale || @base.field(row, "raw") != raw.to_json() || @base.field(row, "sha256") != entry.sha256.to_json() { @base.fail("interop_original_changed_or_forgotten: " + raw) }
    files.push({ path, data: required_bytes(store, raw) })
  }
  let bundle = @interop.bundle(original_format, files)
  if bundle.id != id { @base.fail("interop_original_changed") }
  let paths : Map[String, String] = Map([])
  for doc in bundle.documents { if !@interop.reserved(doc.path) { paths[native_import_id(id, doc.path)] = doc.path } }
  let result : Array[@interop.File] = []
  for file in files {
    let doc = bundle.documents.iter().find_first(d => d.path == file.path)
    if doc is Some(doc) && !@interop.reserved(doc.path) {
      let pid = native_import_id(id, doc.path)
      let entry = @core.find(entries, pid)
      if !@core.is_page(entry) || entry.stale { @base.fail("interop_page_missing_or_stale: " + pid) }
      let row = @base.array(@base.field(event, "pages")).iter().find_first(row => optional(row, "path") == Some(doc.path.to_json()))
      let original_hash = match row { None => raise @base.Fault("interop_receipt_page_missing"); Some(row) => @base.text(@base.field(row, "sha256")) }
      if entry.sha256 == original_hash && original_format == format { result.push(file); continue }
      let page = @core.parse_page(@vault.required(store, entry.path))
      let metadata = match doc.metadata {
        Object(fields) => {
          let copy = fields.copy()
          copy["title"] = page.title.to_json()
          copy["tags"] = page.tags.to_json()
          if !copy.contains("type") { copy["type"] = "Reference".to_json() }
          if entry.sha256 != original_hash && copy.get("verified") is Some(verified) {
            let mut key = "x_memorycorridor_original_verified"
            while copy.contains(key) { key = key + "_" }
            copy[key] = verified
            copy.remove("verified")
          }
          if entry.sha256 != original_hash && copy.get("generated") is Some(generated) {
            let mut key = "x_memorycorridor_original_generated"
            while copy.contains(key) { key = key + "_" }
            copy[key] = generated
            copy.remove("generated")
          }
          Json::object(copy)
        }
        _ => raise @base.Fault("interop_metadata_invalid")
      }
      result.push({ path: file.path, data: @utf8.encode(@interop.emit(metadata, @interop.okf_links(page.body, paths))) })
    } else { result.push(file) }
  }
  result
}

fn export_native_files(store : @vault.Storage, entries : Array[@core.Entry], format : String) -> Array[@interop.File] raise @base.Fault {
  let files : Array[@interop.File] = []
  let pages = entries.filter(e => @core.is_page(e) && !e.stale)
  pages.sort_by((a,b) => @base.compare(a.id, b.id))
  let paths : Map[String, String] = Map([])
  for entry in pages { paths[entry.id] = "pages/" + @base.hex_hash(entry.id) + "/page.md" }
  let resources : Map[String, Bool] = Map([])
  let links : Array[String] = []
  for entry in pages {
    let page = @core.parse_page(@vault.required(store, entry.path))
    let sources : Array[Json] = []
    for id in entry.sources {
      let source = @core.find(entries, id)
      let path = "references/" + source.sha256 + ".source"
      sources.push({ "resource": "/" + path, "id": id })
      if !resources.contains(path) { files.push({ path, data: required_bytes(store, source.path) }); resources[path] = true }
    }
    let metadata : Json = { "type": entry.kind, "title": page.title, "tags": page.tags.to_json(), "sources": sources.to_json() }
    files.push({ path: paths[entry.id], data: @utf8.encode(@interop.emit(metadata, @interop.okf_links(page.body, paths))) })
    links.push("- [" + @interop.markdown_label(page.title) + "](/" + paths[entry.id] + ")")
  }
  let metadata : Json = if format == "okf" { { "okf_version": "0.2" } } else { Json::object(Map([])) }
  files.push({ path: "index.md", data: @utf8.encode(@interop.emit(metadata, "# Knowledge\n\n" + links.join("\n") + "\n")) })
  files
}

fn export_vault(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let format = @base.text(@base.field(request, "format"))
  if !["okf", "markdown"].contains(format) { @base.fail("interop_format_unsupported") }
  let directory = bundle_directory(request, "exports")
  let files = match optional(request, "bundle") {
    None => export_native_files(store, entries, format)
    Some(value) => export_bundle_files(store, entries, @base.text(value), format)
  }
  files.sort_by((a,b) => @base.compare(a.path, b.path))
  let rows = files.map(file => {
    let value : Json = { "path": file.path, "sha256": @base.sha256_hex(file.data) }
    value
  })
  let receipt : Json = { "version": 1, "format": format, "files": rows.to_json(), "vault_fingerprint": @vault.fingerprint(entries) }
  let receipt_text = @base.canonical(receipt)
  let marker = directory + ".receipt.json"
  let paths = files.map(file => directory + "/" + file.path)
  (store.mkdirs)(directory)
  for path in (store.files)(directory) {
    if path != marker && !paths.contains(path) { @base.fail("export_directory_conflict: " + path) }
  }
  if (store.read_bytes)(marker) is Some(bytes) && bytes != @utf8.encode(receipt_text) { @base.fail("export_receipt_conflict") }
  // Identical files from an interrupted export are retryable; foreign bytes are
  // refused before writing. The receipt is the final completion marker.
  for file in files {
    if (store.read_bytes)(directory + "/" + file.path) is Some(old) && old != file.data { @base.fail("export_file_conflict: " + file.path) }
  }
  for file in files {
    let path = directory + "/" + file.path
    match (store.read_bytes)(path) {
      Some(old) => if old != file.data { @base.fail("export_file_conflict: " + file.path) }
      None => (store.write_bytes)(path, file.data)
    }
  }
  @vault.verify(store, entries)
  if @vault.fingerprint(@vault.load(store)) != @vault.fingerprint(entries) { @base.fail("export_snapshot_changed") }
  for file in files { if (store.digest)(directory + "/" + file.path) != Some(@base.sha256_hex(file.data)) { @base.fail("export_snapshot_changed") } }
  let actual = (store.files)(directory)
  if actual.length() != paths.length() || actual.any(path => !paths.contains(path)) { @base.fail("export_directory_changed") }
  if (store.read_bytes)(marker) is Some(bytes) && bytes != @utf8.encode(receipt_text) { @base.fail("export_receipt_conflict") }
  (store.write)(marker, receipt_text)
  { "directory": directory, "format": format, "files": files.length(), "receipt": marker, "fingerprint": @vault.fingerprint(entries) }
}
