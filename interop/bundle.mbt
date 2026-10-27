pub(all) struct File {
  path : String
  data : Bytes
}

pub(all) struct Bundle {
  format : String
  id : String
  files : Array[File]
  documents : Array[Document]
}

// Input paths are relative to the bundle, independent of host filesystem paths.
pub fn bundle(format : String, input : Array[File]) -> Bundle raise @base.Fault {
  if !["okf", "markdown"].contains(format) { @base.fail("interop_format_unsupported") }
  if input.is_empty() || input.length() > 4096 { @base.fail("interop_file_count_limit") }
  let files = input.copy()
  files.sort_by((a,b) => @base.compare(a.path, b.path))
  let seen : Map[String, Bool] = Map([])
  let documents : Array[Document] = []
  let rows : Array[Json] = []
  let mut size = 0
  for file in files {
    @base.path(file.path)
    if seen.contains(file.path) { @base.fail("interop_duplicate_path") }
    seen[file.path] = true
    size = size+file.data.length()
    if size > 16777216 { @base.fail("interop_bytes_limit") }
    rows.push({ "path": file.path, "sha256": @base.sha256_hex(file.data) })
    if file.path.has_suffix(".md") {
      let text = try @utf8.decode(file.data) catch { _ => raise @base.Fault("interop_utf8_required: " + file.path) }
      documents.push(parse(file.path, text, format))
    }
  }
  if !documents.any(d => !reserved(d.path)) { @base.fail("interop_concept_required") }
  let identity : Json = { "format": format, "files": rows.to_json() }
  { format, id: @base.hex_hash(@base.canonical(identity)), files, documents }
}
