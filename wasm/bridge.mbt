// An integer/UTF-8 ABI works on both wasm targets without runtime string layouts.
let incoming : Ref[Array[Byte]] = @ref.new([])
let outgoing : Ref[Bytes] = @ref.new(Bytes::new(0))
let overflow : Ref[Bool] = @ref.new(false)

pub fn input_reset() -> Unit {
  incoming.val = []
  outgoing.val = Bytes::new(0)
  overflow.val = false
}

pub fn input_push(byte : Int) -> Int {
  if byte < 0 || byte > 255 || incoming.val.length() >= 2097152 {
    overflow.val = true
    return -1
  }
  incoming.val.push(byte.to_byte())
  0
}

pub fn output_byte(offset : Int) -> Int {
  if offset < 0 || offset >= outgoing.val.length() { -1 } else { outgoing.val[offset].to_int() }
}

fn evaluate(request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  match op {
    "tools" => { @base.keys(request, ["op"]); @agent.describe_tools() }
    "catalog" => { @base.keys(request, ["op", "text"]); @decl.parse(@base.text(@base.field(request, "text"))).to_json() }
    "page" => { @base.keys(request, ["op", "text"]); @core.parse_page(@base.text(@base.field(request, "text"))).to_json() }
    "search" => {
      @base.keys(request, ["op", "documents", "query"])
      let docs = @base.array(@base.field(request, "documents")).map(v => @index.from_json(v))
      let seen : Map[String, Bool] = Map([])
      for d in docs { if seen.contains(d.id) { @base.fail("duplicate_document") }; seen[d.id] = true }
      @index.search_index(@index.build_index(docs), @base.text(@base.field(request, "query"))).to_json()
    }
    "vectors" => {
      @base.keys(request, ["op", "space", "values", "records"])
      let space = @index.space_from_json(@base.field(request, "space"))
      let query = @index.vector_from_json(@base.field(request, "values"))
      let records = @base.array(@base.field(request, "records")).map(v => @index.record_from_json(v))
      @index.search_vectors(space, query, records, 10).to_json()
    }
    "graph" => {
      @base.keys(request, ["op", "pages"])
      graph_snapshot(@base.field(request, "pages")).to_json()
    }
    "neighbors" => {
      @base.keys(request, ["op", "pages", "id"])
      @index.neighbors(graph_snapshot(@base.field(request, "pages")), @base.text(@base.field(request, "id"))).to_json()
    }
    "path" => {
      @base.keys(request, ["op", "pages", "from", "to"])
      @index.path(graph_snapshot(@base.field(request, "pages")), @base.text(@base.field(request, "from")), @base.text(@base.field(request, "to"))).to_json()
    }
    "weighted-path" => {
      @base.keys(request, ["op", "pages", "from", "to"])
      @index.weighted_path(graph_snapshot(@base.field(request, "pages")), @base.text(@base.field(request, "from")), @base.text(@base.field(request, "to"))).to_json()
    }
    "insights" => {
      @base.keys(request, ["op", "pages"])
      @index.insights(graph_snapshot(@base.field(request, "pages")))
    }
    "context" => {
      @base.keys(request, ["op", "candidates", "query", "budget", "dedup", "spread"])
      let dedup = context_choice(request, "dedup", "exact", ["exact", "similar"])
      let spread = context_choice(request, "spread", "ranked", ["ranked", "even"])
      @index.assemble_context(context_snapshot(@base.field(request, "candidates")),
        @base.text(@base.field(request, "query")), context_budget(@base.field(request, "budget")),
        dedup~, spread~)
    }
    "view" => {
      @base.keys(request, ["op", "text"])
      @visual.parse(@base.text(@base.field(request, "text"))).to_json()
    }
    "render-view" => render_view(request)
    "session-plan" => session_plan(request)
    "session-verify" => session_verify(request)
    _ => raise @base.Fault("unsupported_wasm_operation")
  }
}

// Render a verified, host-supplied snapshot without giving WASM any filesystem
// or network capability. The host remains responsible for loading the files;
// this boundary re-parses all declarations and content before rendering.
fn render_view(request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "text", "pages", "sources", "fingerprint"])
  let view = @visual.parse(@base.text(@base.field(request, "text")))
  let readings : Array[@visual.Reading] = []
  let sources : Array[@visual.Source] = []
  let entries : Array[@core.Entry] = []
  let seen : Map[String, Bool] = Map([])
  for row in @base.array(@base.field(request, "pages")) {
    @base.keys(row, ["entry", "text"])
    let entry = @core.entry_from_json(@base.field(row, "entry"))
    if !@core.is_page(entry) { @base.fail("wasm_render_page_required: " + entry.id) }
    if seen.contains(entry.id) { @base.fail("wasm_render_duplicate_entry: " + entry.id) }
    let text = @base.text(@base.field(row, "text"))
    let page = @core.parse_page(text)
    if page.kind != entry.kind || page.sources != entry.sources {
      @base.fail("wasm_render_page_metadata_mismatch: " + entry.id)
    }
    if @base.hex_hash(text) != entry.sha256 { @base.fail("wasm_render_content_changed: " + entry.id) }
    seen[entry.id] = true
    entries.push(entry)
    readings.push({ entry, page })
  }
  for row in @base.array(@base.field(request, "sources")) {
    @base.keys(row, ["entry", "text", "image"])
    let entry = @core.entry_from_json(@base.field(row, "entry"))
    if entry.kind != "raw" { @base.fail("wasm_render_source_required: " + entry.id) }
    if seen.contains(entry.id) { @base.fail("wasm_render_duplicate_entry: " + entry.id) }
    let text = @base.text(@base.field(row, "text"))
    if !entry.stale && entry.format != "binary" && entry.format != "image" && @base.hex_hash(text) != entry.sha256 {
      @base.fail("wasm_render_content_changed: " + entry.id)
    }
    let image = @base.text(@base.field(row, "image"))
    verify_source_payload(entry, text, image)
    let display_text = if entry.stale { "此来源已撤销或缺失。" }
      else if entry.format == "binary" || entry.format == "image" {
        "二进制资料；请使用原格式工具读取。路径：" + entry.path
      } else { text }
    seen[entry.id] = true
    entries.push(entry)
    sources.push({ id: entry.id, path: entry.path, sha256: entry.sha256,
      text: display_text, format: if entry.stale { "text" } else { entry.format }, image })
  }
  @core.validate_entries(entries)
  for entry in entries {
    for source in entry.sources {
      if !entries.iter().any(e => e.id == source && e.kind == "raw" && !e.stale) && !entry.stale {
        @base.fail("wasm_render_source_unresolved: " + entry.id + " -> " + source)
      }
    }
  }
  for reading in readings {
    if !reading.entry.stale {
      for link in reading.page.links {
        if !entries.iter().any(e => e.id == link && @core.is_page(e) && !e.stale) {
          @base.fail("wasm_render_wikilink_unresolved: " + reading.entry.id + " -> " + link)
        }
      }
    }
  }
  readings.sort_by((a, b) => @base.compare(a.entry.id, b.entry.id))
  sources.sort_by((a, b) => @base.compare(a.id, b.id))
  let fingerprint = @base.text(@base.field(request, "fingerprint"))
  if fingerprint.length() != 64 || !fingerprint.iter().all(c =>
    (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
    @base.fail("wasm_render_fingerprint_invalid")
  }
  let html = @visual.render(view, readings, sources, fingerprint)
  { "html": html, "fingerprint": fingerprint, "view_sha256": @base.hex_hash(@base.text(@base.field(request, "text"))),
    "pages": readings.length(), "sources": sources.length() }
}

fn verify_source_payload(entry : @core.Entry, text : String, image : String) -> Unit raise @base.Fault {
  if entry.stale {
    if !image.is_empty() { @base.fail("wasm_render_stale_image") }
    return
  }
  if entry.format == "image" {
    let prefix = "data:" + @visual.image_mime(entry.path) + ";base64,"
    if !image.has_prefix(prefix) { @base.fail("wasm_render_image_data_required: " + entry.id) }
    let bytes = try @base64.decode(image[prefix.length():]) catch {
      _ => raise @base.Fault("wasm_render_image_invalid: " + entry.id)
    }
    if bytes.length() > 4194304 { @base.fail("wasm_render_image_too_large: " + entry.id) }
    if @base.sha256_hex(bytes) != entry.sha256 { @base.fail("wasm_render_image_changed: " + entry.id) }
  } else if !image.is_empty() {
    @base.fail("wasm_render_image_unexpected: " + entry.id)
  } else if entry.format == "binary" {
    // Binary bytes cannot cross this text-only ABI; the host must use a
    // separate resource transport and the renderer only receives metadata.
    ignore(text)
  }
}

pub fn execute() -> Int {
  let result : Json = try {
    if overflow.val { @base.fail("input_overflow") }
    let text = try @utf8.decode(Bytes::from_array(incoming.val)) catch { _ => raise @base.Fault("invalid_utf8") }
    { "ok": true, "result": evaluate(@base.parse(text)) }
  } catch {
    @base.Fault(message) => { "ok": false, "error": message }
  }
  outgoing.val = @utf8.encode(@base.canonical(result))
  outgoing.val.length()
}
