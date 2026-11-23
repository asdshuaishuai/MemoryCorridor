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
}

const INDEX_PATH : String = ".corridor/fts.json"
const INDEX_VERSION : Int = 4
const INDEX_ALGORITHM : String = "chunk-bm25-v1"
const CHUNK_CHARS : Int = 800
const CHUNK_OVERLAP : Int = 80
const EXCERPT_CHARS : Int = 360

// The process-level cache carries the parsed index so a warm query does not
// re-parse it. Keys are (change signal, catalog fingerprint); the signal
// includes the inode, so two vaults cannot collide in one process.
let cache : Ref[(String, String, Collection)?] = @ref.new(None)

pub fn index_path() -> String {
  INDEX_PATH
}

pub fn clear_cache() -> Unit {
  cache.val = None
}

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
  for entry in active_pages(entries) {
    let text = @vault.required(store, entry.path)
    let page = @core.parse_page(text)
    for chunk in chunker.chunk(entry.id, page.title + "\n\n" + page.body) {
      let id = entry.id + "#" + chunk.index.to_string()
      index.add(id, chunk.text)
      chunks.push({ id, page: entry.id, index: chunk.index, text_hash: @base.hex_hash(chunk.text) })
    }
    pages.push({ id: entry.id, sha256: entry.sha256, title: page.title, excerpt: excerpt(page.body) })
  }
  collection(index, chunks, pages)
}

fn collection(index : @MoonRetrieve.SearchIndex, chunks : Array[ChunkRef], pages : Array[PageBinding]) -> Collection {
  let by_id : Map[String, ChunkRef] = Map([])
  for chunk in chunks { by_id[chunk.id] = chunk }
  { index, chunks, pages, by_id }
}

fn payload(collection : Collection, fingerprint : String) -> Json {
  { "version": INDEX_VERSION.to_json(), "algorithm": INDEX_ALGORITHM.to_json(),
    "fingerprint": fingerprint.to_json(), "pages": collection.pages.to_json(),
    "chunks": collection.chunks.to_json(), "bm25": collection.index.save().to_json() }
}

pub fn save(
  store : @vault.Storage, entries : Array[@core.Entry], collection : Collection,
) -> Unit raise @base.Fault {
  let fingerprint = @vault.fingerprint(entries)
  let payload = payload(collection, fingerprint)
  let envelope : Json = { "sha256": @base.hex_hash(@base.canonical(payload)).to_json(), "payload": payload }
  (store.write)(INDEX_PATH, @base.canonical(envelope))
  match (store.stat)(INDEX_PATH) {
    Some(signature) => cache.val = Some((signature, fingerprint, collection))
    None => ()
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
  @base.keys(payload, ["version", "algorithm", "fingerprint", "pages", "chunks", "bm25"])
  // Algorithm/version first: an artifact from another format reports why it is
  // unusable even when its envelope no longer matches this writer's rules.
  if @base.field(payload, "version") != INDEX_VERSION.to_json() ||
    @base.field(payload, "algorithm") != INDEX_ALGORITHM.to_json() {
    @base.fail("index_algorithm_changed")
  }
  if @base.text(@base.field(value, "sha256")) != @base.hex_hash(@base.canonical(payload)) { raise @base.Fault("index_corrupt_or_stale") }
  if @base.text(@base.field(payload, "fingerprint")) != fingerprint { raise @base.Fault("index_corrupt_or_stale") }
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
  let collection = collection(bm25, chunks, pages)
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
pub fn search_chunks(
  entries : Array[@core.Entry], collection : Collection, query : String, limit : Int,
  prefix? : String = "",
) -> Array[@MoonRetrieve.SearchResult] {
  let allowed = allowed_pages(entries, prefix)
  let out : Array[@MoonRetrieve.SearchResult] = []
  for hit in collection.index.search(query, top_k=Int::max(limit * 4, 40)) {
    match collection.by_id.get(hit.doc_id) {
      Some(chunk) => if allowed.get(chunk.page).unwrap_or(false) { out.push(hit) }
      None => ()
    }
    if out.length() >= limit { break }
  }
  out
}

pub fn chunk_of(collection : Collection, id : String) -> ChunkRef? {
  collection.by_id.get(id)
}

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
