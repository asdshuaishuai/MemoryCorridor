fn hash_valid(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

// Paths that fold to the same name on normalization- or case-insensitive file
// systems (NFC vs NFD spellings, case variants) collapse into one file on
// restore, and the later entry silently replaces the earlier one. Beyond exact
// duplicates the pack refuses such ambiguous entries: paths carrying combining
// marks are refused outright — the format wants precomposed NFC spellings —
// and the rest are detected on the lowercase fold.
fn combining_mark(code : Int) -> Bool {
  (code >= 0x0300 && code <= 0x036f) || (code >= 0x1ab0 && code <= 0x1aff) ||
    (code >= 0x1dc0 && code <= 0x1dff) || (code >= 0x20d0 && code <= 0x20ff) ||
    (code >= 0xfe20 && code <= 0xfe2f)
}

fn refuse_ambiguous(folded : Map[String, Bool], path : String) -> Unit raise @base.Fault {
  for c in path {
    if combining_mark(c.to_int()) { @base.fail("pack_path_ambiguous: " + path) }
  }
  let key = path.to_lower()
  if folded.contains(key) { @base.fail("pack_path_ambiguous: " + path) }
  folded[key] = true
}

pub fn encode(files : Array[File]) -> Bytes raise @base.Fault {
  if files.length() > 4096 { @base.fail("pack_file_count_limit") }
  let sorted = files.copy()
  sorted.sort_by((a,b) => @base.compare(a.path, b.path))
  let objects : Map[String, Bytes] = Map([])
  let paths : Map[String, Bool] = Map([])
  let folded : Map[String, Bool] = Map([])
  let manifest : Array[Json] = []
  let mut total = 0
  let mut fingerprint = ""
  for file in sorted {
    @base.path(file.path)
    if paths.contains(file.path) { @base.fail("pack_duplicate_path") }
    paths[file.path] = true
    refuse_ambiguous(folded, file.path)
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
  // The 16 MiB ceiling lives in the zip layer; preflight the exact encoded
  // byte count (local header 30 + name, central record 46 + name, 22-byte
  // EOCD) against the same constant so the caller always sees the pack-layer
  // code instead of the rejection drifting between pack and zip error codes
  // depending on where the bytes land.
  let mut encoded = 22
  for entry in entries {
    let name = @utf8.encode(entry.path).length()
    encoded = encoded + 30 + name + entry.data.length() + 46 + name
  }
  if encoded > 16777216 { @base.fail("pack_expanded_limit") }
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
  let folded : Map[String, Bool] = Map([])
  let mut total = 0
  let mut fingerprint = ""
  for row in declared {
    @base.keys(row, ["path", "sha256", "size"])
    let path = @base.text(@base.field(row, "path"))
    let hash = @base.text(@base.field(row, "sha256"))
    @base.path(path)
    if !hash_valid(hash) || paths.contains(path) { @base.fail("pack_hash_or_duplicate_path") }
    paths[path] = true
    refuse_ambiguous(folded, path)
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
