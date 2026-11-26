// The chunk index is a derived artifact: these tests pin that it never answers
// for page bytes it was not derived from, that a tampered artifact is refused,
// and that page aggregation keeps the best chunk.

fn memory_store() -> (@vault.Storage, Map[String, String], Map[String, Bytes]) {
  let files : Map[String, String] = Map([])
  let blobs : Map[String, Bytes] = Map([])
  let store : @vault.Storage = {
    read: path => files.get(path),
    read_bytes: path => blobs.get(path),
    digest: path => files.get(path).map(@base.hex_hash),
    write: (path, text) => { files[path] = text },
    write_bytes: (path, bytes) => { blobs[path] = bytes },
    mkdirs: _ => (),
    remove: path => { files.remove(path) },
    files: prefix => files.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: _ => (),
    stat: _ => None,
    memo: @vault.VerifyMemo::new(),
  }
  (store, files, blobs)
}

fn page_entry(id : String, text : String) -> @core.Entry {
  { id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(text), sources: ["raw/a/f.md"], stale: false }
}

fn fixture() -> (@vault.Storage, Map[String, String], Map[String, Bytes], Array[@core.Entry]) {
  let (store, files, blobs) = memory_store()
  files["raw/a/f.md"] = "来源正文\n"
  let alpha = "---\ntype: concept\ntitle: \"甲\"\nsources: [\"raw/a/f.md\"]\n---\n陶窑的釉色记录，唯一标识 alpha-token-77。\n"
  let beta = "---\ntype: concept\ntitle: \"乙\"\nsources: [\"raw/a/f.md\"]\n---\n完全不同的正文，关于运输与仓储。\n"
  files["wiki/alpha.md"] = alpha
  files["wiki/beta.md"] = beta
  let entries : Array[@core.Entry] = [
    { id: "raw/a/f.md", path: "raw/a/f.md", kind: "raw", format: "markdown",
      sha256: @base.hex_hash(files["raw/a/f.md"]), sources: [], stale: false },
    page_entry("alpha", alpha),
    page_entry("beta", beta),
  ]
  (store, files, blobs, entries)
}

test "chunk index finds the page that owns a unique identifier" {
  let (store, _, _, entries) = fixture()
  let collection = build(store, entries)
  let hits = search_pages(entries, collection, "alpha-token-77", 5)
  assert_eq(hits.length(), 1)
  assert_eq(hits[0].page, "alpha")
  assert_true(hits[0].excerpt.contains("alpha-token-77"))
}

test "a saved index round-trips and refuses tampered or stale copies" {
  let (store, files, _, entries) = fixture()
  let collection = build(store, entries)
  save(store, entries, collection)
  let loaded = load(store, entries)
  assert_eq(loaded.chunks.length(), collection.chunks.length())
  assert_eq(search_pages(entries, loaded, "釉色", 5)[0].page, "alpha")
  // Stale: the page bytes moved on since derivation.
  let moved : Array[@core.Entry] = entries.map(entry => if entry.id == "alpha" {
    { ..entry, sha256: @base.hex_hash("changed") }
  } else {
    entry
  })
  assert_true(try { ignore(load(store, moved)); false } catch { _ => true })
  // Tampered payload: the envelope hash no longer matches.
  let text = files[".corridor/fts.json"]
  files[".corridor/fts.json"] = text.replace(old="\"title\":\"甲\"", new="\"title\":\"篡改\"")
  assert_true(try { ignore(load(store, entries)); false } catch { _ => true })
}

test "namespace filtering and best-chunk aggregation hold" {
  let (store, files, _, entries) = fixture()
  files["raw/other/x.md"] = "别的来源\n"
  let other = "---\ntype: concept\ntitle: \"丙\"\nsources: [\"raw/other/x.md\"]\n---\n釉色与运输都提到 alpha-token-77。\n"
  files["wiki/other.md"] = other
  let all = entries
  all.push({ id: "raw/other/x.md", path: "raw/other/x.md", kind: "raw", format: "markdown",
    sha256: @base.hex_hash(files["raw/other/x.md"]), sources: [], stale: false })
  all.push({ id: "other", path: "wiki/other.md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(other), sources: ["raw/other/x.md"], stale: false })
  let collection = build(store, all)
  let scoped = search_pages(all, collection, "alpha-token-77", 5, prefix="raw/a")
  assert_eq(scoped.length(), 1)
  assert_eq(scoped[0].page, "alpha")
  let wide = search_pages(all, collection, "alpha-token-77", 5)
  assert_eq(wide.length(), 2)
}

fn payload_with(payload : Json, pages : Json, chunks : Json, vectors_sha256 : Json) -> Json raise @base.Fault {
  { "version": @base.field(payload, "version"), "algorithm": @base.field(payload, "algorithm"),
    "fingerprint": @base.field(payload, "fingerprint"),
    "space": @base.field(payload, "space"), "dimensions": @base.field(payload, "dimensions"),
    "pages": pages, "chunks": chunks, "bm25": @base.field(payload, "bm25"),
    "vectors_sha256": vectors_sha256 }
}

fn rewrap(payload : Json) -> String {
  let envelope : Json = {
    "sha256": @base.hex_hash(@base.canonical(payload)),
    "payload": payload,
  }
  @base.canonical(envelope)
}

fn refuses(store : @vault.Storage, entries : Array[@core.Entry]) -> Bool {
  try { ignore(load(store, entries)); false } catch { _ => true }
}

test "a self-consistent artifact that does not match the catalog is refused" {
  let (store, files, blobs, entries) = fixture()
  save(store, entries, build(store, entries))
  let original = files[".corridor/fts.json"]
  let value = @base.parse(original)
  let payload = @base.field(value, "payload")
  let pages = @base.array(@base.field(payload, "pages"))
  let chunks = @base.array(@base.field(payload, "chunks"))
  // 1. A page binding that no longer matches the catalog.
  let broken_pages : Array[Json] = []
  for i = 0; i < pages.length(); i = i + 1 {
    let row = pages[i]
    broken_pages.push(if i == 0 {
      { "id": @base.field(row, "id"), "sha256": @base.hex_hash("wrong"),
        "title": @base.field(row, "title"), "excerpt": @base.field(row, "excerpt") }
    } else {
      row
    })
  }
  files[".corridor/fts.json"] = rewrap(payload_with(payload, broken_pages.to_json(), chunks.to_json(), @base.field(payload, "vectors_sha256")))
  assert_true(refuses(store, entries))
  // 2. A chunk id that does not follow <page>#<index>.
  let broken_chunks : Array[Json] = []
  for i = 0; i < chunks.length(); i = i + 1 {
    let row = chunks[i]
    broken_chunks.push(if i == 0 {
      { "id": "not-a-chunk-id", "page": @base.field(row, "page"),
        "index": @base.field(row, "index"), "text_hash": @base.field(row, "text_hash") }
    } else {
      row
    })
  }
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), broken_chunks.to_json(), @base.field(payload, "vectors_sha256")))
  assert_true(refuses(store, entries))
  // 3. A chunk table shorter than the index it describes.
  let short : Array[Json] = []
  for i = 0; i < chunks.length() - 1; i = i + 1 { short.push(chunks[i]) }
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), short.to_json(), @base.field(payload, "vectors_sha256")))
  assert_true(refuses(store, entries))
  // 4. The same chunk id twice, with the count kept constant.
  let twice : Array[Json] = []
  for i = 0; i < chunks.length() - 1; i = i + 1 { twice.push(chunks[i]) }
  twice.push(chunks[0])
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), twice.to_json(), @base.field(payload, "vectors_sha256")))
  assert_true(refuses(store, entries))
  let blob = blobs[".corridor/fts.vectors.bin"]
  // 5. A chunk table shortened together with its vector sidecar and envelope:
  //    only the BM25 document count can notice that the index still holds the
  //    chunk the table dropped.
  let truncated_length = (chunks.length() - 1) * FEATURE_DIMENSIONS * 4
  let truncated_bytes : Array[Byte] = []
  for i = 0; i < truncated_length; i = i + 1 { truncated_bytes.push(blob[i]) }
  let truncated = Bytes::from_array(truncated_bytes)
  blobs[".corridor/fts.vectors.bin"] = truncated
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), short.to_json(), @base.sha256_hex(truncated).to_json()))
  assert_true(refuses(store, entries))
  blobs[".corridor/fts.vectors.bin"] = blob
  // 6. A vector sidecar with more bytes than the chunk table can hold. The
  //    envelope is made self-consistent first so only the length check can
  //    reject it.
  let longer : Array[Byte] = []
  for value in blob { longer.push(value) }
  for i = 0; i < 4; i = i + 1 { longer.push(0) }
  let padded = Bytes::from_array(longer)
  blobs[".corridor/fts.vectors.bin"] = padded
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), chunks.to_json(), @base.sha256_hex(padded).to_json()))
  assert_true(refuses(store, entries))
  // 7. A sidecar whose bytes are not the ones the envelope binds.
  blobs[".corridor/fts.vectors.bin"] = blob
  files[".corridor/fts.json"] = rewrap(payload_with(payload, pages.to_json(), chunks.to_json(), @base.sha256_hex(padded).to_json()))
  assert_true(refuses(store, entries))
  // The untouched pair still loads.
  files[".corridor/fts.json"] = original
  assert_eq(load(store, entries).chunks.length(), chunks.length())
}

test "features share grams across a truncated identifier" {
  let exact = features("alpha-token-77")
  let typo = features("alpha-token-7")
  assert_true(dot(exact, typo) > 0.5)
  let unrelated = features("运输与仓储")
  assert_true(dot(exact, unrelated) < 0.2)
}

test "host page vectors replace the algorithm lane" {
  let (store, _, _, entries) = fixture()
  let collection = build(store, entries)
  // The query matches no text token; only the host's page ranking can produce
  // vector-lane hits, in exactly the order the host supplied.
  let (hits, lanes) = search_hybrid(entries, collection, "zzzz", 5,
    system_pages=Some(["beta", "alpha"]))
  assert_eq(lanes.text, "on")
  assert_eq(lanes.vector, "system")
  assert_eq(lanes.reason, "provider_vectors")
  assert_eq(hits.length(), 2)
  assert_eq(hits[0].page, "beta")
  assert_eq(hits[0].vector_rank, 1)
  assert_eq(hits[0].text_rank, 0)
  assert_eq(hits[1].page, "alpha")
  assert_eq(hits[1].vector_rank, 2)
  // Namespace filtering also applies to host page ids.
  let (filtered, filtered_lanes) = search_hybrid(entries, collection, "zzzz", 5,
    prefix="raw/missing", system_pages=Some(["beta"]))
  assert_eq(filtered.length(), 0)
  assert_eq(filtered_lanes.vector, "system")
  assert_eq(filtered_lanes.reason, "no_matching_vectors")
  // An empty host page list is a system lane with nothing to use, not a
  // silent fallback to the algorithm lane.
  let (none, none_lanes) = search_hybrid(entries, collection, "zzzz", 5,
    system_pages=Some([]))
  assert_eq(none.length(), 0)
  assert_eq(none_lanes.vector, "system")
  assert_eq(none_lanes.reason, "no_matching_vectors")
}

test "the vector lane recovers a chunk the text lane misses" {
  let (store, files, _, entries) = fixture()
  // A single Latin run: BM25 keeps whole alphanumeric tokens, so the truncated
  // query shares no token with the corpus while their character trigrams overlap.
  let gamma = "---\ntype: concept\ntitle: \"丙\"\nsources: [\"raw/a/f.md\"]\n---\n批次编号 alphatoken77。\n"
  files["wiki/gamma.md"] = gamma
  entries.push({ id: "gamma", path: "wiki/gamma.md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(gamma), sources: ["raw/a/f.md"], stale: false })
  let collection = build(store, entries)
  assert_eq(search_pages(entries, collection, "alphatoken7", 5).length(), 0)
  let (hits, lanes) = search_hybrid(entries, collection, "alphatoken7", 5)
  assert_eq(lanes.text, "on")
  assert_eq(lanes.vector, "algo")
  assert_eq(lanes.reason, "no_system_engine")
  assert_true(hits.length() > 0)
  assert_eq(hits[0].page, "gamma")
  assert_eq(hits[0].text_rank, 0)
  assert_true(hits[0].vector_rank > 0)
  assert_eq(hits[0].text, "")
  // The exact query is found by both lanes and carries the chunk text.
  let (both, _) = search_hybrid(entries, collection, "alphatoken77", 5)
  assert_eq(both[0].page, "gamma")
  assert_true(both[0].text_rank > 0 && both[0].vector_rank > 0)
  assert_true(both[0].text.contains("alphatoken77"))
}
