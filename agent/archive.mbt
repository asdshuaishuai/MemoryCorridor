fn required_bytes(store : @vault.Storage, path : String) -> Bytes raise @base.Fault {
  match (store.read_bytes)(path) { None => raise @base.Fault("file_missing: " + path); Some(bytes) => bytes }
}

fn archive_path(request : Json, key : String, directory : String) -> String raise @base.Fault {
  let path = @base.text(@base.field(request, key))
  @base.path(path)
  if !path.has_prefix(directory + "/") || !path.has_suffix(".mcpack") { @base.fail("pack_path_required: " + directory + "/*.mcpack") }
  path
}

fn pack_vault(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let output = archive_path(request, "output", "exports")
  if (store.read_bytes)(output) is Some(_) { @base.fail("export_already_exists") }
  let paths = entries.map(e => e.path)
  paths.push("index.mbt.md")
  for path in ["purpose.md", "schema.md", "wiki/index.md", "wiki/log.md"] {
    if !paths.contains(path) && (store.read_bytes)(path) is Some(_) { paths.push(path) }
  }
  let extra_paths : Array[String] = []
  for directory in ["views", "staging", "state/transactions/history"] {
    for path in (store.files)(directory) {
      if directory == "views" && (!path.has_suffix(".mbt.md") || path.contains("/_build/")) { continue }
      extra_paths.push(path)
      if !paths.contains(path) { paths.push(path) }
    }
  }
  let files : Array[@pack.File] = []
  let missing : Array[String] = []
  for path in paths {
    let bytes = (store.read_bytes)(path)
    match bytes {
      Some(data) => files.push({ path, data })
      None => if !entries.any(e => e.path == path && e.kind == "raw" && e.stale) { @base.fail("pack_file_missing: " + path) } else { missing.push(path) }
    }
  }
  let snapshot = @vault.snapshot_entries(store, files)
  if @vault.fingerprint(snapshot) != @vault.fingerprint(entries) { @base.fail("pack_catalog_changed") }
  let bytes = @pack.encode(files)
  // Re-read every included byte after encoding. Editors do not take our OS lock.
  for file in files {
    if (store.digest)(file.path) != Some(@base.sha256_hex(file.data)) { @base.fail("pack_snapshot_changed: " + file.path) }
  }
  for path in missing { if (store.read_bytes)(path) is Some(_) { @base.fail("pack_snapshot_changed: " + path) } }
  let current_extra : Array[String] = []
  for directory in ["views", "staging", "state/transactions/history"] {
    for path in (store.files)(directory) {
      if directory == "views" && (!path.has_suffix(".mbt.md") || path.contains("/_build/")) { continue }
      current_extra.push(path)
    }
  }
  extra_paths.sort_by(@base.compare)
  current_extra.sort_by(@base.compare)
  if extra_paths != current_extra { @base.fail("pack_snapshot_inventory_changed") }
  if @vault.fingerprint(@vault.load(store)) != @vault.fingerprint(entries) { @base.fail("pack_catalog_changed") }
  (store.write_bytes)(output, bytes)
  { "output": output, "files": files.length(), "bytes": bytes.length(),
    "vault_fingerprint": @vault.fingerprint(entries), "pack_fingerprint": @base.sha256_hex(bytes) }
}

fn unpack_vault(store : @vault.Storage, request : Json) -> Json raise @base.Fault {
  let input = archive_path(request, "file", "imports")
  let bytes = required_bytes(store, input)
  let fingerprint = @vault.unpack(store, bytes)
  { "vault_fingerprint": fingerprint, "pack_fingerprint": @base.sha256_hex(bytes), "restored": true }
}
