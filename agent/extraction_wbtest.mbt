// White-box tests for the extraction sidecar intake. The store is the same
// crashing fixture as the transaction-safety tests; a binary source here is just
// bytes written to a `.png` path (format detection is by extension), so no real
// image decoder is involved -- the engine never parses these bytes.

fn image_store() -> (@vault.Storage, String, String) raise @base.Fault {
  // (store, source path, registered sha256) for a vault holding one image source.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  let path = "raw/窑口照片.png"
  files[path] = "PNG-bytes-\u{0000}\u{0001}\u{0002}-not-a-real-image"
  ignore(scan(store, @vault.load(store)))
  let entry = @core.find(@vault.load(store), path)
  (store, path, entry.sha256)
}

fn submit(store : @vault.Storage, source : String, extractor : String,
  version : String, text : String) -> Json raise @base.Fault {
  extraction_submit(store, @vault.load(store), {
    "op": "extraction-submit", "source": source, "kind": "image",
    "extractor": extractor, "version": version, "text": text,
    "at": "2026-11-02T09:00:00Z",
  })
}

test "extraction-submit registers a sidecar bound to the digest and serves it" {
  let (store, path, sha) = image_store()
  let result = submit(store, path, "tesseract-v5", "1", "哥窑 窑址")
  assert_eq(@base.boolean(@base.field(result, "replayed")), false)
  assert_eq(@base.text(@base.field(result, "path")), "state/extractions/" + sha + ".json")
  // The record and its event are catalog entries, not just files on disk.
  let entries = @vault.load(store)
  assert_true(entries.any(e => e.path == "state/extractions/" + sha + ".json"))
  assert_true(entries.any(e => e.path == "state/events/extraction-submit-" + sha + ".json"))
  @vault.verify(store, entries)
  // Context now supplies the sidecar text with the five-field binding object,
  // keyed to the order's own source digest.
  let order_id = orders(store, entries)[0].id
  let view = context(store, entries, order_id)
  assert_eq(@base.boolean(@base.field(view, "extraction_required")), false)
  assert_eq(@base.text(@base.field(view, "source_text")), "哥窑 窑址")
  let extraction = @base.field(view, "extraction")
  assert_eq(@base.text(@base.field(extraction, "kind")), "image")
  assert_eq(@base.text(@base.field(extraction, "extractor")), "tesseract-v5")
  assert_eq(@base.text(@base.field(extraction, "version")), "1")
  assert_eq(@base.text(@base.field(extraction, "bound_sha256")), sha)
  assert_eq(@base.text(@base.field(extraction, "source_sha256")), sha)
}

test "verbatim replay returns replayed, a different text conflicts, a new extractor exists" {
  let (store, path, sha) = image_store()
  ignore(submit(store, path, "tesseract-v5", "1", "哥窑 窑址"))
  // Same extractor/version + same text -> replay, no second write.
  let before = @vault.fingerprint(@vault.load(store))
  let replay = submit(store, path, "tesseract-v5", "1", "哥窑 窑址")
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  assert_eq(@vault.fingerprint(@vault.load(store)), before)
  // Same extractor/version, different text -> conflict, nothing overwritten.
  let conflict = try { ignore(submit(store, path, "tesseract-v5", "1", "Different text")); "none" }
  catch { @base.Fault(message) => message }
  assert_true(conflict.has_prefix("extraction_conflict"), msg=conflict)
  assert_eq(@vault.required(store, "state/extractions/" + sha + ".json"),
    @base.canonical({ "source": path, "source_sha256": sha, "kind": "image",
      "extractor": "tesseract-v5", "version": "1", "text": "哥窑 窑址",
      "submitted_at": "2026-11-02T09:00:00Z" }))
  // A different extractor/version over an active sidecar -> extraction_exists,
  // and the fault_code is the bare code before the ':' detail (risk #7).
  let exists = try { ignore(submit(store, path, "paddle-ocr", "2", "哥窑 窑址")); "none" }
  catch { @base.Fault(message) => message }
  assert_true(exists.has_prefix("extraction_exists"), msg=exists)
  assert_eq(@base.fault_code(exists), "extraction_exists")
}

test "extraction-submit refuses an office source (override) and a textual source" {
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  // format gate fires before any byte parsing, so the .docx need not be a real
  // archive -- extraction_override proves the engine's own channel is protected.
  files["raw/记录.docx"] = "not-a-zip"
  ignore(scan(store, @vault.load(store)))
  let office = try { ignore(submit(store, "raw/记录.docx", "ext", "1", "x")); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(office, "extraction_override")
  // A textual source already serves its own bytes; no sidecar channel.
  files["raw/笔记.md"] = "正文"
  ignore(scan(store, @vault.load(store)))
  let textual = try { ignore(submit(store, "raw/笔记.md", "ext", "1", "x")); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(textual, "extraction_source_textual")
}

test "a revoked source stops the sidecar applying (lint predicate)" {
  let (store, path, _sha) = image_store()
  ignore(submit(store, path, "tesseract-v5", "1", "哥窑 窑址"))
  // Forget propagates: the raw entry goes stale; the sidecar still references it.
  ignore(forget(store, @vault.load(store), path, "2026-11-02T10:00:00Z"))
  let violations = @base.array(@base.field(lint_result(store, (store.read)("index.mbt.md")), "violations"))
  assert_true(has_lint_predicate(violations, "extraction_source_stale"))
}

fn sidecar_entry(path : String) -> @core.Entry {
  { id: path, path, kind: "state", format: "json",
    sha256: "0".repeat(64), sources: [], stale: false }
}

test "validate_record binds the sidecar filename hash to the content digest" {
  // Direct calls to the target branch (extending.md self-check): an earlier
  // check must not shadow the identity lock. These records never reach verify
  // via an operation, only through hand edits or a rename.
  let entry = sidecar_entry
  let sha = "a".repeat(64)
  let good = @base.canonical({ "source": "raw/x.png", "source_sha256": sha, "kind": "image",
    "extractor": "e", "version": "1", "text": "t", "submitted_at": "2026-11-02T00:00:00Z" })
  // Filename digest differs from the content digest -> identity fault.
  let renamed = "state/extractions/" + ("b".repeat(64)) + ".json"
  let fault = try { ignore(@core.validate_record(entry(renamed), good)); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(fault, "extraction_record_identity_invalid")
  // A source_sha256 that is not 64 lowercase hex is refused, so the derived
  // filename cannot smuggle a path-traversal or non-content-addressed name.
  let bad_sha = "Z".repeat(64)
  let bad_record = @base.canonical({ "source": "raw/x.png", "source_sha256": bad_sha,
    "kind": "image", "extractor": "e", "version": "1", "text": "t",
    "submitted_at": "2026-11-02T00:00:00Z" })
  let fault2 = try { ignore(@core.validate_record(entry("state/extractions/" + bad_sha + ".json"), bad_record)); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(fault2, "extraction_source_hash_invalid")
  // The correct pairing validates.
  ignore(@core.validate_record(entry("state/extractions/" + sha + ".json"), good))
  // The text length cap has a real boundary, not an unbounded field (risk #2).
  let huge = "x".repeat(@core.EXTRACTION_TEXT_LIMIT + 1)
  let over = @base.canonical({ "source": "raw/x.png", "source_sha256": sha, "kind": "image",
    "extractor": "e", "version": "1", "text": huge, "submitted_at": "2026-11-02T00:00:00Z" })
  let fault3 = try { ignore(@core.validate_record(entry("state/extractions/" + sha + ".json"), over)); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(fault3, "extraction_text_invalid")
  // The cap counts UTF-8 BYTES, the transport's unit (finding: the native/MCP
  // request line is 2 MiB bytes; a character-counted bound would accept ~3 MiB
  // of CJK that the CLI then refuses as invalid_json before the engine runs).
  // 349,526 CJK characters are 1,048,578 bytes -- over the limit -- while
  // `String.length()` would call them under it.
  let too_many_bytes = "陶".repeat(349526)
  assert_true(too_many_bytes.length() < @core.EXTRACTION_TEXT_LIMIT)
  assert_eq(@base.utf8_size(too_many_bytes), 1048578)
  let cjk_over = @base.canonical({ "source": "raw/x.png", "source_sha256": sha, "kind": "image",
    "extractor": "e", "version": "1", "text": too_many_bytes, "submitted_at": "2026-11-02T00:00:00Z" })
  let fault4 = try { ignore(@core.validate_record(entry("state/extractions/" + sha + ".json"), cjk_over)); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(fault4, "extraction_text_invalid")
  // Exactly 1 MiB UTF-8 bytes fits; one byte more does not.
  let exact = "陶".repeat(349525) + "a"
  assert_eq(@base.utf8_size(exact), @core.EXTRACTION_TEXT_LIMIT)
  ignore(@core.validate_record(entry("state/extractions/" + sha + ".json"), @base.canonical({
    "source": "raw/x.png", "source_sha256": sha, "kind": "image", "extractor": "e",
    "version": "1", "text": exact, "submitted_at": "2026-11-02T00:00:00Z" })))
}

test "the sidecar event path binds the source digest" {
  let sha = "c".repeat(64)
  let event = @base.canonical({ "op": "extraction-submit", "source": "raw/x.png",
    "source_sha256": sha, "extractor": "e", "version": "1", "at": "2026-11-02T00:00:00Z" })
  let wrong = "state/events/wrong-name.json"
  let fault = try {
    ignore(@core.validate_record(
      { id: wrong, path: wrong, kind: "state", format: "json", sha256: "0".repeat(64),
        sources: [], stale: false }, event))
    "none"
  } catch { @base.Fault(message) => message }
  assert_eq(fault, "extraction_event_identity_invalid")
  // The correct name validates.
  let right = "state/events/extraction-submit-" + sha + ".json"
  ignore(@core.validate_record(
    { id: right, path: right, kind: "state", format: "json", sha256: "0".repeat(64),
      sources: [], stale: false }, event))
}

test "context binds the sidecar to the current digest via the catalog, not a bare path" {
  // Two sources with different bytes -> different digests -> different sidecars.
  // sidecar_for must return the record whose source_sha256 equals the queried
  // digest, and only when that record is registered in the catalog. A mutation
  // that reads the path directly (bypassing registration) or matches any
  // extractions file would let an unregistered/host-dropped record inject text,
  // or serve one source's text for another -- both are caught here.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  files["raw/a.png"] = "bytes-A"
  files["raw/b.png"] = "bytes-B"
  ignore(scan(store, @vault.load(store)))
  let sha_a = @core.find(@vault.load(store), "raw/a.png").sha256
  let sha_b = @core.find(@vault.load(store), "raw/b.png").sha256
  ignore(submit(store, "raw/a.png", "e", "1", "text A"))
  ignore(submit(store, "raw/b.png", "e", "1", "text B"))
  let entries = @vault.load(store)
  match sidecar_for(store, entries, sha_a) {
    Some(record) => {
      assert_eq(@base.text(@base.field(record, "source_sha256")), sha_a)
      assert_eq(@base.text(@base.field(record, "text")), "text A")
    }
    None => { assert_true(false, msg="sidecar_for missed a registered record") }
  }
  match sidecar_for(store, entries, sha_b) {
    Some(record) => assert_eq(@base.text(@base.field(record, "text")), "text B")
    None => { assert_true(false, msg="sidecar_for missed the second record") }
  }
  // An unregistered file at a valid sidecar path must not be served: catalog
  // registration is the gate, not the presence of bytes on disk.
  let foreign = "f".repeat(64)
  files["state/extractions/" + foreign + ".json"] = @base.canonical({
    "source": "raw/a.png", "source_sha256": foreign, "kind": "image",
    "extractor": "e", "version": "1", "text": "injected", "submitted_at": "2026-11-02T00:00:00Z" })
  assert_true(sidecar_for(store, @vault.load(store), foreign) is None)
}

test "the operation-level source gates all fire: not-raw, stale, stray event" {
  // `expected_raw_source` reads a registered non-raw id, `extraction_source_stale`
  // reads a revoked one, and `extraction_event_conflict` reads a stray event file
  // with no registered sidecar -- each a distinct early refusal before any write.
  let (store, path, sha) = image_store()
  let not_raw = try { ignore(submit(store, "purpose.md", "e", "1", "x")); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(not_raw, "expected_raw_source")
  ignore(submit(store, path, "e", "1", "正文"))
  ignore(forget(store, @vault.load(store), path, "2026-11-02T10:00:00Z"))
  let stale = try { ignore(submit(store, path, "e", "1", "正文")); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(stale, "extraction_source_stale")
  // A stray event file on disk without a registered sidecar is a conflict: the
  // audit trail says something was submitted, the catalog disagrees.
  let (fresh, _b2, files) = crashing(-1)
  ignore(initialize(fresh, "研究陶瓷"))
  files["raw/plate.png"] = "PNG-plate-bytes"
  ignore(scan(fresh, @vault.load(fresh)))
  let plate_sha = @core.find(@vault.load(fresh), "raw/plate.png").sha256
  files["state/events/extraction-submit-" + plate_sha + ".json"] = "{}"
  let stray = try { ignore(submit(fresh, "raw/plate.png", "e", "1", "x")); "none" }
  catch { @base.Fault(message) => message }
  assert_eq(stray, "extraction_event_conflict")
  ignore(sha)
}

test "sidecar and event validation reject a non-raw source and a malformed digest" {
  // These three branches guard the record shape itself, reached by a hand edit
  // that never passes through the operation (which checks the source first).
  // Direct calls to validate_record prove each named branch fires, matching the
  // table-driven coverage record_validation_e2e.py keeps for every other kind.
  let check = (path : String, value : Json) => try {
    ignore(@core.validate_record(sidecar_entry(path), @base.canonical(value))); "accepted"
  } catch { @base.Fault(message) => message }
  let sha = "a".repeat(64)
  // Sidecar whose `source` is not a raw path.
  assert_eq(check("state/extractions/" + sha + ".json", { "source": "wiki/overview",
    "source_sha256": sha, "kind": "image", "extractor": "e", "version": "1", "text": "t",
    "submitted_at": "2026-11-02T00:00:00Z" }), "extraction_source_invalid")
  // Event whose `source` is not a raw path.
  assert_eq(check("state/events/extraction-submit-" + sha + ".json", { "op": "extraction-submit",
    "source": "wiki/overview", "source_sha256": sha, "extractor": "e", "version": "1",
    "at": "2026-11-02T00:00:00Z" }), "extraction_event_source_invalid")
  // Event whose `source_sha256` is not 64 lowercase hex.
  assert_eq(check("state/events/extraction-submit-" + sha + ".json", { "op": "extraction-submit",
    "source": "raw/x.png", "source_sha256": "nope", "extractor": "e", "version": "1",
    "at": "2026-11-02T00:00:00Z" }), "extraction_event_source_hash_invalid")
}

test "a shared-digest sidecar never overrides a textual source's own bytes" {
  // Two paths, identical bytes -> one content hash (sidecars are content
  // addressed). The image path legitimately serves the sidecar; the markdown
  // path must keep serving its own registered text, because textual sources
  // already have a byte channel and the sidecar stands in only when there is
  // none. Without the `!textual` gate the image sidecar would win for both.
  let (store, _broken, files) = crashing(-1)
  ignore(initialize(store, "研究陶瓷"))
  files["raw/twin.png"] = "same bytes"
  files["raw/twin.md"] = "same bytes"
  ignore(scan(store, @vault.load(store)))
  ignore(submit(store, "raw/twin.png", "e", "1", "sidecar text"))
  let entries = @vault.load(store)
  let md_order = orders(store, entries).filter(o => o.source == "raw/twin.md")[0].id
  let md_view = context(store, entries, md_order)
  assert_eq(@base.text(@base.field(md_view, "source_text")), "same bytes")
  assert_eq(@base.boolean(@base.field(md_view, "extraction_required")), false)
  assert_true(@base.field(md_view, "extraction") == Json::null())
  // The image order legitimately serves the sidecar once the md slot is free.
  ignore(dispatch(store, { "op": "cancel", "order": md_order }))
  let png_order = orders(store, @vault.load(store)).filter(o => o.source == "raw/twin.png")[0].id
  let png_view = context(store, @vault.load(store), png_order)
  assert_eq(@base.text(@base.field(png_view, "source_text")), "sidecar text")
  assert_eq(@base.boolean(@base.field(png_view, "extraction_required")), false)
}

test "extraction-submit is advertised with six required string fields" {
  // schema.mbt auto-derives from tools().fields, but a field accidentally added
  // to the optional list or the integer branch would advertise it wrongly to MCP
  // (extending.md:27) -- pin the full shape.
  let t = tool("extraction-submit")
  assert_eq(t.fields, ["source", "kind", "extractor", "version", "text", "at"])
  let schema = input_schema(t)
  let required = @base.array(@base.field(schema, "required")).map(v => @base.text(v))
  for name in t.fields { assert_true(required.contains(name), msg="required misses " + name) }
  let properties = @base.field(schema, "properties")
  for name in t.fields {
    assert_eq(@base.field(@base.field(properties, name), "type"), "string".to_json())
  }
}
