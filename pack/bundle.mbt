fn hash_valid(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

pub fn encode(files : Array[File]) -> Bytes raise @base.Fault {
  if files.length() > 4096 { @base.fail("pack_file_count_limit") }
  let sorted = files.copy()
  sorted.sort_by((a,b) => @base.compare(a.path, b.path))
  let objects : Map[String, Bytes] = Map([])
  let paths : Map[String, Bool] = Map([])
  let manifest : Array[Json] = []
  let mut total = 0
  let mut fingerprint = ""
  for file in sorted {
    @base.path(file.path)
    if paths.contains(file.path) { @base.fail("pack_duplicate_path") }
    paths[file.path] = true
    total = total+file.data.length()
    if total > 16777216 { @base.fail("pack_expanded_limit") }
    let sha256 = @base.sha256_hex(file.data)
    objects[sha256] = file.data
    manifest.push({ "path": file.path, "sha256": sha256, "size": file.data.length() })
    if file.path == "index.mbt.md" { fingerprint = sha256 }
  }
  if fingerprint == "" { @base.fail("pack_index_required") }
  let value : Json = { "format": "memorycorridor-pack", "version": 1, "vault_fingerprint": fingerprint, "files": manifest.to_json() }
  let entries : Array[File] = [{ path: "manifest.json", data: @utf8.encode(@base.canonical(value)) }]
  for (hash, data) in objects { entries.push({ path: "objects/" + hash, data }) }
  zip_encode(entries)
}

pub fn decode(bytes : Bytes) -> Array[File] raise @base.Fault {
  let entries = zip_decode(bytes)
  let objects : Map[String, Bytes] = Map([])
  for e in entries { objects[e.path] = e.data }
  let manifest = match objects.get("manifest.json") {
    None => raise @base.Fault("pack_manifest_required")
    Some(data) => try @base.parse(@utf8.decode(data)) catch { _ => raise @base.Fault("pack_manifest_invalid") }
  }
  @base.keys(manifest, ["format", "version", "vault_fingerprint", "files"])
  if @base.field(manifest, "format") != "memorycorridor-pack".to_json() || @base.field(manifest, "version") != Json::number(1.0) { @base.fail("pack_version_unsupported") }
  let declared = @base.array(@base.field(manifest, "files"))
  if declared.length() > 4096 { @base.fail("pack_file_count_limit") }
  let files : Array[File] = []
  let used : Map[String, Bool] = Map([])
  let paths : Map[String, Bool] = Map([])
  let mut total = 0
  let mut fingerprint = ""
  for row in declared {
    @base.keys(row, ["path", "sha256", "size"])
    let path = @base.text(@base.field(row, "path"))
    let hash = @base.text(@base.field(row, "sha256"))
    @base.path(path)
    if !hash_valid(hash) || paths.contains(path) { @base.fail("pack_hash_or_duplicate_path") }
    paths[path] = true
    let key = "objects/" + hash
    let data = match objects.get(key) { None => raise @base.Fault("pack_object_missing"); Some(data) => data }
    if @base.sha256_hex(data) != hash || @base.field(row, "size") != data.length().to_json() { @base.fail("pack_object_hash_or_size_mismatch") }
    used[key] = true
    total = total+data.length()
    if total > 16777216 { @base.fail("pack_expanded_limit") }
    if path == "index.mbt.md" { fingerprint = hash }
    files.push({ path, data })
  }
  if fingerprint == "" || @base.field(manifest, "vault_fingerprint") != fingerprint.to_json() { @base.fail("pack_fingerprint_mismatch") }
  if objects.length() != used.length()+1 { @base.fail("pack_unreferenced_objects") }
  if encode(files) != bytes { @base.fail("pack_noncanonical_manifest") }
  files
}
