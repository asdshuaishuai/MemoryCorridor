// Derived chunk index for the knowledge and memory collections.
//
// The authoritative stores stay in the vault. Every artifact here is
// rebuildable from page text and bound to the page hashes it was derived from;
// a per-process cache keyed by the artifact's change signal keeps warm queries
// from re-parsing the whole index on every request. A changed signal or hash
// forces a full re-read, and `verify`/`rebuild` in the agent layer remain the
// explicit audits.

pub(all) struct ChunkRef {
  id : String
  page : String
  index : Int
  text_hash : String
} derive(ToJson)
pub extend ChunkRef with ToJson::{to_json}

pub(all) struct PageBinding {
  id : String
  sha256 : String
  title : String
  // Body prefix captured at build time: vector-only hits and fallback excerpts
  // must not re-read every page on each query.
  excerpt : String
} derive(ToJson)
pub extend PageBinding with ToJson::{to_json}

pub(all) struct PageHit {
  page : String
  title : String
  score : Double
  excerpt : String
}

pub(all) struct Collection {
  index : @MoonRetrieve.SearchIndex
  chunks : Array[ChunkRef]
  pages : Array[PageBinding]
  by_id : Map[String, ChunkRef]
  // Algorithmic chunk vectors, aligned with `chunks` (chunk i <-> vectors[i]).
  vectors : Array[Array[Double]]
  dimensions : Int
}

const INDEX_PATH : String = ".corridor/fts.json"
// Chunk vectors are a sidecar: the BM25 postings alone are already close to the
// per-file write cap on a large vault, so packing 256 f32 per chunk into the
// same JSON would push it over. The envelope binds the sidecar by hash; a
// missing or mismatched sidecar is a rebuildable cache miss, never a hard fail.
const INDEX_VECTORS_PATH : String = ".corridor/fts.vectors.bin"
const INDEX_VERSION : Int = 5
const INDEX_ALGORITHM : String = "chunk-hybrid-v1"
const CHUNK_CHARS : Int = 800
const CHUNK_OVERLAP : Int = 80
const EXCERPT_CHARS : Int = 360

// The process-level cache carries the parsed index so a warm query does not
// re-parse it. Keys are (change signal, catalog fingerprint); the signal
// includes the inode, so two vaults cannot collide in one process.
let cache : Ref[(String, String, Collection)?] = @ref.new(None)

pub fn active_pages(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let pages = entries.filter(e => @core.is_page(e) && !e.stale)
  pages.sort_by((a, b) => @base.compare(a.id, b.id))
  pages
}

pub fn build(store : @vault.Storage, entries : Array[@core.Entry]) -> Collection raise @base.Fault {
  let chunker = @MoonRetrieve.Chunker::new(max_chars=CHUNK_CHARS, overlap=CHUNK_OVERLAP)
  let index = @MoonRetrieve.SearchIndex::new()
  let chunks : Array[ChunkRef] = []
  let pages : Array[PageBinding] = []
  let vectors : Array[Array[Double]] = []
  for entry in active_pages(entries) {
    let text = @vault.required(store, entry.path)
    let page = @core.parse_page(text)
    for chunk in chunker.chunk(entry.id, page.title + "\n\n" + page.body) {
      let id = entry.id + "#" + chunk.index.to_string()
      index.add(id, chunk.text)
      chunks.push({ id, page: entry.id, index: chunk.index, text_hash: @base.hex_hash(chunk.text) })
      vectors.push(features(chunk.text))
    }
    pages.push({ id: entry.id, sha256: entry.sha256, title: page.title, excerpt: excerpt(page.body) })
  }
  collection(index, chunks, pages, vectors)
}

fn collection(
  index : @MoonRetrieve.SearchIndex, chunks : Array[ChunkRef], pages : Array[PageBinding],
  vectors : Array[Array[Double]],
) -> Collection {
  let by_id : Map[String, ChunkRef] = Map([])
  for chunk in chunks { by_id[chunk.id] = chunk }
  { index, chunks, pages, by_id, vectors, dimensions: FEATURE_DIMENSIONS }
}

fn encode_vectors(vectors : Array[Array[Double]], dimensions : Int) -> Bytes raise @base.Fault {
  let bytes : Array[Byte] = []
  for vector in vectors {
    if vector.length() != dimensions { raise @base.Fault("index_corrupt_or_stale") }
    for value in vector {
      let single = Float::from_double(value)
      if single.is_nan() || single.is_inf() { raise @base.Fault("index_corrupt_or_stale") }
      let bits = single.reinterpret_as_uint()
      bytes.push((bits & 0xff).to_byte())
      bytes.push(((bits >> 8) & 0xff).to_byte())
      bytes.push(((bits >> 16) & 0xff).to_byte())
      bytes.push(((bits >> 24) & 0xff).to_byte())
    }
  }
  Bytes::from_array(bytes)
}

fn decode_vectors(encoded : Bytes, dimensions : Int, count : Int) -> Array[Array[Double]] raise @base.Fault {
  let bytes = encoded
  if bytes.length() != count * dimensions * 4 { raise @base.Fault("index_corrupt_or_stale") }
  let vectors : Array[Array[Double]] = []
  for row = 0; row < count; row = row + 1 {
    let vector : Array[Double] = []
    for column = 0; column < dimensions; column = column + 1 {
      let offset = (row * dimensions + column) * 4
      let bits = bytes[offset].to_int() | (bytes[offset + 1].to_int() << 8) |
        (bytes[offset + 2].to_int() << 16) | (bytes[offset + 3].to_int() << 24)
      let value = Float::reinterpret_from_uint(bits.reinterpret_as_uint()).to_double()
      if value.is_nan() || value.is_inf() { raise @base.Fault("index_corrupt_or_stale") }
      vector.push(value)
    }
    vectors.push(vector)
  }
  vectors
}

fn payload(collection : Collection, fingerprint : String, vectors_sha256 : String) -> Json {
  { "version": INDEX_VERSION.to_json(), "algorithm": INDEX_ALGORITHM.to_json(),
    "fingerprint": fingerprint.to_json(), "space": FEATURE_SPACE.to_json(),
    "dimensions": FEATURE_DIMENSIONS.to_json(), "pages": collection.pages.to_json(),
    "chunks": collection.chunks.to_json(), "bm25": collection.index.save().to_json(),
    "vectors_sha256": vectors_sha256.to_json() }
}

pub fn save(
  store : @vault.Storage, entries : Array[@core.Entry], collection : Collection,
) -> Unit raise @base.Fault {
  let fingerprint = @vault.fingerprint(entries)
  let blob = encode_vectors(collection.vectors, FEATURE_DIMENSIONS)
  // The sidecar lands first: a metadata envelope whose vector hash does not
  // match the file on disk is refused by `load`, so an interrupted save costs
  // one rebuild and never serves mismatched vectors.
  (store.write_bytes)(INDEX_VECTORS_PATH, blob)
  let payload = payload(collection, fingerprint, @base.sha256_hex(blob))
  let envelope : Json = { "sha256": @base.hex_hash(@base.canonical(payload)).to_json(), "payload": payload }
  (store.write)(INDEX_PATH, @base.canonical(envelope))
  match (store.stat)(INDEX_PATH) {
    Some(signature) => cache.val = Some((signature, fingerprint, collection))
    None => ()
  }
}

// Keeps a not-yet-persisted collection usable for the rest of the process. Used
// when the artifact cannot be written (for example a vault whose postings exceed
// the platform file-size cap): queries stay correct and the next process rebuilds
// instead of every request failing.
pub fn remember(store : @vault.Storage, entries : Array[@core.Entry], collection : Collection) -> Unit raise @base.Fault {
  let fingerprint = @vault.fingerprint(entries)
  match (store.stat)(INDEX_PATH) {
    Some(signature) => cache.val = Some((signature, fingerprint, collection))
    None => cache.val = Some(("", fingerprint, collection))
  }
}

pub fn load(store : @vault.Storage, entries : Array[@core.Entry]) -> Collection raise @base.Fault {
  let fingerprint = @vault.fingerprint(entries)
  let signature = match (store.stat)(INDEX_PATH) {
    Some(value) => value
    None => ""
  }
  match cache.val {
    Some((signal, cached_fingerprint, collection)) if signature != "" && signal == signature && cached_fingerprint == fingerprint => {
      return collection
    }
    _ => ()
  }
  let value = @base.parse(@vault.required(store, INDEX_PATH))
  @base.keys(value, ["sha256", "payload"])
  let payload = @base.field(value, "payload")
  @base.keys(payload, ["version", "algorithm", "fingerprint", "space", "dimensions", "pages", "chunks", "bm25", "vectors_sha256"])
  // Algorithm/version first: an artifact from another format reports why it is
  // unusable even when its envelope no longer matches this writer's rules.
  if @base.field(payload, "version") != INDEX_VERSION.to_json() ||
    @base.field(payload, "algorithm") != INDEX_ALGORITHM.to_json() {
    @base.fail("index_algorithm_changed")
  }
  if @base.text(@base.field(value, "sha256")) != @base.hex_hash(@base.canonical(payload)) { raise @base.Fault("index_corrupt_or_stale") }
  if @base.text(@base.field(payload, "fingerprint")) != fingerprint { raise @base.Fault("index_corrupt_or_stale") }
  if @base.text(@base.field(payload, "space")) != FEATURE_SPACE ||
    @base.field(payload, "dimensions") != FEATURE_DIMENSIONS.to_json() {
    @base.fail("index_algorithm_changed")
  }
  let expected = active_pages(entries)
  let pages : Array[PageBinding] = @base.array(@base.field(payload, "pages")).map(row => {
    @base.keys(row, ["id", "sha256", "title", "excerpt"])
    { id: @base.text(@base.field(row, "id")), sha256: @base.text(@base.field(row, "sha256")),
      title: @base.text(@base.field(row, "title")), excerpt: @base.text(@base.field(row, "excerpt")) }
  })
  if pages.length() != expected.length() { raise @base.Fault("index_corrupt_or_stale") }
  for i = 0; i < pages.length(); i = i + 1 {
    if pages[i].id != expected[i].id || pages[i].sha256 != expected[i].sha256 { raise @base.Fault("index_corrupt_or_stale") }
  }
  let chunks : Array[ChunkRef] = @base.array(@base.field(payload, "chunks")).map(row => {
    @base.keys(row, ["id", "page", "index", "text_hash"])
    let index = match @base.field(row, "index") {
      Number(n, ..) if n >= 0.0 && n == n.to_int().to_double() => n.to_int()
      _ => raise @base.Fault("index_corrupt_or_stale")
    }
    let page = @base.text(@base.field(row, "page"))
    let id = @base.text(@base.field(row, "id"))
    if id != page + "#" + index.to_string() { raise @base.Fault("index_corrupt_or_stale") }
    if !pages.iter().any(binding => binding.id == page) { raise @base.Fault("index_corrupt_or_stale") }
    { id, page, index, text_hash: @base.text(@base.field(row, "text_hash")) }
  })
  let seen : Map[String, Bool] = Map([])
  for chunk in chunks {
    if seen.contains(chunk.id) { raise @base.Fault("index_corrupt_or_stale") }
    seen[chunk.id] = true
  }
  let bm25 = match @MoonRetrieve.SearchIndex::try_load(@base.text(@base.field(payload, "bm25"))) {
    Ok(index) => index
    Err(_) => raise @base.Fault("index_corrupt_or_stale")
  }
  if bm25.count() != chunks.length() { raise @base.Fault("index_corrupt_or_stale") }
  let blob = match (store.read_bytes)(INDEX_VECTORS_PATH) {
    Some(value) => value
    None => raise @base.Fault("index_corrupt_or_stale")
  }
  if @base.sha256_hex(blob) != @base.text(@base.field(payload, "vectors_sha256")) {
    raise @base.Fault("index_corrupt_or_stale")
  }
  let vectors = decode_vectors(blob, FEATURE_DIMENSIONS, chunks.length())
  let collection = collection(bm25, chunks, pages, vectors)
  if signature != "" { cache.val = Some((signature, fingerprint, collection)) }
  collection
}

fn page_titles(collection : Collection) -> Map[String, String] {
  let titles : Map[String, String] = Map([])
  for binding in collection.pages { titles[binding.id] = binding.title }
  titles
}

fn allowed_pages(entries : Array[@core.Entry], prefix : String) -> Map[String, Bool] {
  let allowed : Map[String, Bool] = Map([])
  for entry in entries {
    if !@core.is_page(entry) || entry.stale { continue }
    if prefix == "" || entry.sources.iter().any(source => source.has_prefix(prefix + "/")) {
      allowed[entry.id] = true
    }
  }
  allowed
}

fn excerpt(text : String) -> String {
  if text.length() > EXCERPT_CHARS { text[:EXCERPT_CHARS].to_owned() + "…" } else { text }
}

pub fn search_pages(
  entries : Array[@core.Entry], collection : Collection, query : String, limit : Int,
  prefix? : String = "",
) -> Array[PageHit] {
  let allowed = allowed_pages(entries, prefix)
  let titles = page_titles(collection)
  let best : Map[String, (Double, String)] = Map([])
  let hits = collection.index.search(query, top_k=Int::max(limit * 8, 50))
  for hit in hits {
    let chunk = match collection.by_id.get(hit.doc_id) {
      Some(value) => value
      None => continue
    }
    if !allowed.get(chunk.page).unwrap_or(false) { continue }
    // The search returns chunks in descending score order, so the first chunk
    // per page is its best one; later chunks of the same page cannot improve it.
    if best.contains(chunk.page) { continue }
    best[chunk.page] = (hit.score, hit.text)
  }
  let rows : Array[(String, Double, String)] = []
  for pair in best.iter() {
    let (page, (score, text)) = pair
    rows.push((page, score, text))
  }
  rows.sort_by((a, b) => {
    let cmp = b.1.compare(a.1)
    if cmp != 0 { cmp } else { @base.compare(a.0, b.0) }
  })
  let out : Array[PageHit] = []
  for i = 0; i < rows.length() && i < limit; i = i + 1 {
    let (page, score, text) = rows[i]
    out.push({ page, title: titles.get(page).unwrap_or(page), score, excerpt: excerpt(text) })
  }
  out
}

// Chunk-level view for `retrieve` and for callers that want lane diagnostics.
pub fn page_title(collection : Collection, page : String) -> String {
  for binding in collection.pages {
    if binding.id == page { return binding.title }
  }
  page
}

pub fn page_excerpt(collection : Collection, page : String) -> String {
  for binding in collection.pages {
    if binding.id == page { return binding.excerpt }
  }
  ""
}

pub(all) struct ChunkHit {
  id : String
  page : String
  score : Double
  text : String
  text_rank : Int
  vector_rank : Int
}

pub(all) struct LaneInfo {
  text : String
  vector : String
  reason : String
}

// RRF over the BM25 lane and the algorithmic vector lane. Ranks start at 1; a
// chunk absent from a lane contributes nothing from it. Ties break by chunk id,
// so repeated queries are byte-identical.
pub fn search_hybrid(
  entries : Array[@core.Entry], collection : Collection, query : String, limit : Int,
  prefix? : String = "", rrf_k? : Int = 60,
  // When the host supplies provider page hits, the vector lane is page-level:
  // each page contributes its first chunk (`<page>#0`) at the host's rank. The
  // engine never embeds the query; the host supplies the vector and its
  // provider registration is checked in the agent layer.
  system_pages? : Array[String]? = None,
) -> (Array[ChunkHit], LaneInfo) {
  let allowed = allowed_pages(entries, prefix)
  let text_hits : Array[@MoonRetrieve.SearchResult] = []
  for hit in collection.index.search(query, top_k=100) {
    match collection.by_id.get(hit.doc_id) {
      Some(chunk) => if allowed.get(chunk.page).unwrap_or(false) { text_hits.push(hit) }
      None => ()
    }
  }
  let vector_rows : Array[(String, Double)] = match system_pages {
    None => {
      let query_vector = features(query)
      let rows : Array[(String, Double)] = []
      for i = 0; i < collection.chunks.length(); i = i + 1 {
        let chunk = collection.chunks[i]
        if !allowed.get(chunk.page).unwrap_or(false) { continue }
        let score = dot(query_vector, collection.vectors[i])
        if score > 0.0 { rows.push((chunk.id, score)) }
      }
      rows
    }
    Some(pages) => {
      let rows : Array[(String, Double)] = []
      for i = 0; i < pages.length(); i = i + 1 {
        let page = pages[i]
        if !allowed.get(page).unwrap_or(false) { continue }
        let id = page + "#0"
        if collection.by_id.contains(id) {
          rows.push((id, 1.0 / (i + 1).to_double()))
        }
      }
      rows
    }
  }
  vector_rows.sort_by((a, b) => {
    let cmp = b.1.compare(a.1)
    if cmp != 0 { cmp } else { @base.compare(a.0, b.0) }
  })
  let fused : Map[String, (Double, Int, Int)] = Map([])
  for i = 0; i < text_hits.length(); i = i + 1 {
    let id = text_hits[i].doc_id
    fused[id] = (1.0 / (rrf_k.to_double() + (i + 1).to_double()), i + 1, 0)
  }
  let vector_limit = Int::min(vector_rows.length(), 100)
  for i = 0; i < vector_limit; i = i + 1 {
    let (id, _) = vector_rows[i]
    let weight = 1.0 / (rrf_k.to_double() + (i + 1).to_double())
    match fused.get(id) {
      Some((score, text_rank, _)) => fused[id] = (score + weight, text_rank, i + 1)
      None => fused[id] = (weight, 0, i + 1)
    }
  }
  let texts : Map[String, String] = Map([])
  for hit in text_hits { texts[hit.doc_id] = hit.text }
  let rows : Array[(String, (Double, Int, Int))] = []
  for pair in fused.iter() { rows.push(pair) }
  rows.sort_by((a, b) => {
    let cmp = b.1.0.compare(a.1.0)
    if cmp != 0 { cmp } else { @base.compare(a.0, b.0) }
  })
  let hits : Array[ChunkHit] = []
  for i = 0; i < rows.length() && i < limit; i = i + 1 {
    let (id, (score, text_rank, vector_rank)) = rows[i]
    let chunk = match collection.by_id.get(id) {
      Some(value) => value
      None => continue
    }
    hits.push({ id, page: chunk.page, score, text: texts.get(id).unwrap_or(""),
      text_rank, vector_rank })
  }
  let (vector_lane, vector_reason) = match system_pages {
    None => ("algo", "no_system_engine")
    Some(_) =>
      if vector_rows.is_empty() {
        ("system", "no_matching_vectors")
      } else {
        ("system", "provider_vectors")
      }
  }
  (hits, { text: "on", vector: vector_lane, reason: vector_reason })
}
