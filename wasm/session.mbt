// Pure session planner. The JavaScript host supplies a file snapshot and owns
// the final write/compile callbacks; this package decides whether publication
// is valid and returns a deterministic plan without mutating host state.
fn rows(value : Json) -> Map[String, String] raise @base.Fault {
  let result : Map[String, String] = Map([])
  for row in @base.array(value) {
    @base.keys(row, ["path", "text"])
    let path = @base.text(@base.field(row, "path"))
    @base.path(path)
    if result.contains(path) { @base.fail("session_duplicate_file: " + path) }
    result[path] = @base.text(@base.field(row, "text"))
  }
  result
}

priv enum Slot {
  Present(String)
  Missing
}

fn changes(value : Json, files : Map[String, String]) -> Map[String, Slot] raise @base.Fault {
  let result : Map[String, Slot] = Map([])
  for row in @base.array(value) {
    @base.keys(row, ["path", "before", "after"])
    let path = @base.text(@base.field(row, "path"))
    @base.path(path)
    if result.contains(path) { @base.fail("session_duplicate_change: " + path) }
    let before = match @base.field(row, "before") { Null => Missing; value => Present(@base.text(value)) }
    let before_ok = match before {
      Missing => files.get(path) is None
      Present(expected) => files.get(path) == Some(expected)
    }
    if !before_ok { @base.fail("session_write_conflict: " + path) }
    let after = match @base.field(row, "after") { Null => Missing; value => Present(@base.text(value)) }
    result[path] = after
  }
  result
}

fn verify_snapshot(files : Map[String, String], catalog : String) -> Array[@core.Entry] raise @base.Fault {
  let entries = @decl.parse(catalog)
  for entry in entries {
    if entry.kind == "raw" {
      // WASM sessions only carry UTF-8 snapshots. Binary inputs remain host-only.
      if entry.stale { continue }
    }
    match files.get(entry.path) {
      Some(text) if @base.hex_hash(text) == entry.sha256 =>
        if @core.is_page(entry) { ignore(@core.validate_page(entry, text, entries)) }
      Some(_) => @base.fail("session_content_changed: " + entry.path)
      None => @base.fail("session_file_missing: " + entry.path)
    }
  }
  entries
}

pub fn session_plan(request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "catalog", "files", "changes"])
  let old_catalog = @base.text(@base.field(request, "catalog"))
  let files = rows(@base.field(request, "files"))
  let change_map = changes(@base.field(request, "changes"), files)
  let proposed = files.copy()
  for (path, after) in change_map {
    match after { Present(text) => proposed[path] = text; Missing => proposed.remove(path) }
  }
  let new_catalog = match proposed.get("index.mbt.md") {
    Some(text) => text
    None => raise @base.Fault("session_catalog_missing")
  }
  let entries = verify_snapshot(proposed, new_catalog)
  let old_entries = verify_snapshot(files, old_catalog)
  let old_fingerprint = session_fingerprint(old_entries)
  let new_fingerprint = session_fingerprint(entries)
  if !change_map.contains("index.mbt.md") { @base.fail("session_catalog_change_required") }
  let names = proposed.keys().to_array()
  names.sort_by(@base.compare)
  let changed = change_map.keys().to_array()
  changed.sort_by(@base.compare)
  { "old_fingerprint": old_fingerprint, "new_fingerprint": new_fingerprint,
    "old_catalog_sha256": @base.hex_hash(old_catalog), "new_catalog_sha256": @base.hex_hash(new_catalog),
    "files": names.to_json(), "changes": changed.to_json() }
}

fn session_fingerprint(entries : Array[@core.Entry]) -> String {
  @base.hex_hash(@decl.generate(entries))
}

fn validate_snapshot_page_entry(entry : @core.Entry, prefix : String) -> Unit raise @base.Fault {
  @base.path(entry.id)
  @base.path(entry.path)
  if !entry.path.has_prefix("wiki/") || !entry.path.has_suffix(".md") || entry.format != "markdown" || entry.sources.is_empty() {
    @base.fail(prefix + "invalid_page_entry: " + entry.id)
  }
  if entry.sha256.length() != 64 || !entry.sha256.iter().all(c =>
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail(prefix + "invalid_sha256: " + entry.id)
  }
  let seen : Map[String, Bool] = Map([])
  for source in entry.sources {
    @base.path(source)
    if seen.contains(source) { @base.fail(prefix + "duplicate_source: " + entry.id) }
    seen[source] = true
  }
}

fn graph_snapshot(value : Json) -> @index.Graph raise @base.Fault {
  let pages : Array[(@core.Entry, @core.Page)] = []
  let seen : Map[String, Bool] = Map([])
  for row in @base.array(value) {
    @base.keys(row, ["entry", "text"])
    let entry = @core.entry_from_json(@base.field(row, "entry"))
    if !@core.is_page(entry) { @base.fail("wasm_graph_page_required: " + entry.id) }
    validate_snapshot_page_entry(entry, "wasm_graph_")
    if seen.contains(entry.id) { @base.fail("wasm_graph_duplicate_page: " + entry.id) }
    let text = @base.text(@base.field(row, "text"))
    if @base.hex_hash(text) != entry.sha256 { @base.fail("wasm_graph_content_changed: " + entry.id) }
    let page = @core.parse_page(text)
    if page.kind != entry.kind || page.sources != entry.sources {
      @base.fail("wasm_graph_page_metadata_mismatch: " + entry.id)
    }
    seen[entry.id] = true
    pages.push((entry, page))
  }
  @index.build_graph(pages)
}

fn context_snapshot(value : Json) -> Array[@index.ContextPage] raise @base.Fault {
  let candidates : Array[@index.ContextPage] = []
  for row in @base.array(value) {
    @base.keys(row, ["entry", "text", "origin"])
    let entry = @core.entry_from_json(@base.field(row, "entry"))
    if !@core.is_page(entry) { @base.fail("wasm_context_page_required: " + entry.id) }
    validate_snapshot_page_entry(entry, "wasm_context_")
    let text = @base.text(@base.field(row, "text"))
    if @base.hex_hash(text) != entry.sha256 { @base.fail("wasm_context_content_changed: " + entry.id) }
    let page = @core.parse_page(text)
    if page.kind != entry.kind || page.sources != entry.sources {
      @base.fail("wasm_context_page_metadata_mismatch: " + entry.id)
    }
    candidates.push({ entry, page, origin: @base.text(@base.field(row, "origin")) })
  }
  candidates
}

fn context_budget(value : Json) -> Int raise @base.Fault {
  match value {
    Number(n, ..) if n >= 1.0 && n <= 65536.0 && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("invalid_budget: integer 1..65536")
  }
}

fn context_choice(request : Json, key : String, default : String, allowed : Array[String]) -> String raise @base.Fault {
  let value = match request { Object(fields) => fields.get(key); _ => None }
  match value {
    None => default
    Some(String(s)) => if allowed.contains(s) { s } else {
      raise @base.Fault("invalid_choice: " + key + "=" + s + "; allowed=" + allowed.join(","))
    }
    _ => raise @base.Fault("invalid_choice: " + key)
  }
}

pub fn session_verify(request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "catalog", "files"])
  let catalog = @base.text(@base.field(request, "catalog"))
  let files = rows(@base.field(request, "files"))
  let entries = verify_snapshot(files, catalog)
  { "fingerprint": session_fingerprint(entries), "files": files.keys().to_array().sort_by(@base.compare).to_json() }
}
