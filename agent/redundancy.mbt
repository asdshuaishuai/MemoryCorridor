// Semantic page-redundancy detection (续二十三). Propose-only: this op never
// writes the vault and never merges anything -- surfacing "these active pages
// look redundant" is a signal the host acts on through the existing
// commit/edit flow. This mirrors `memory_candidates`: report, don't decide.
//
// Why a vector path at all: the token-level `similar_merge` (index/context.mbt)
// only folds formatting-only variants (identical token sequences); a genuine
// paraphrase has different tokens and can never merge there. The only signal
// that catches "same meaning, reworded" is cosine over page embeddings, and
// page vectors already persist per (space, page) with a content-version lock.
// This op pairs pages through that existing primitive; it adds no new math.
//
// Determinism: keepers are chosen by page id order and the output is stably
// sorted, so the same vault yields byte-identical proposals. Vectors are read
// only for the requested space and only when a page's vector sha256 equals the
// current page hash (a rewritten page's stale vector must not nominate it).

// Default cosine tier (bge-text tuned); page-redundancy's optional
// cosine_floor request field overrides it for other modalities.
const REDUNDANCY_COSINE_FLOOR : Double = 0.92
const REDUNDANCY_SHARED_OVERLAP_FLOOR : Double = 0.5

///|
pub fn page_redundancy(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let space = @index.space_from_json(@base.field(request, "space"))
  let limit = integer(request, "limit", 200, 1, 1000)
  // 续二十七: the cosine line is a CALIBRATION, not a truth constant. 0.92 is
  // tuned for bge-style text spaces; visual spaces (flat images sit ~0.925
  // apart by color, identical content sits ~1.0) must nominate at the top of
  // the range. The host declares its tier explicitly; the engine stays
  // model-agnostic -- no space-name special cases, the applied floor is
  // echoed in the response so every proposal set is auditable.
  let cosine_floor = bounded_double(request, "cosine_floor", REDUNDANCY_COSINE_FLOOR, 0.0, 1.0)
  // Active pages only: a stale/archived page is already on its way out, and
  // proposing it would ask the host to re-decide a settled thing.
  let pages = entries.filter(e => @core.is_page(e) && !e.stale)
  pages.sort_by((a, b) => @base.compare(a.id, b.id))
  // Vectors for this space whose page is active and whose content version
  // still matches (the same lock hybrid_search applies to query results).
  let vectors : Map[String, @index.VectorRecord] = Map([])
  for entry in entries {
    if entry.kind != "vector" { continue }
    let record = @index.record_from_json(@base.parse(@vault.required(store, entry.path)))
    if record.space == space &&
      pages.iter().any(p => p.id == record.page && p.sha256 == record.sha256) {
      vectors[record.page] = record
    }
  }
  // Precompute the token sequence and body per page once.
  let texts : Map[String, Array[String]] = Map([])
  let bodies : Map[String, String] = Map([])
  for p in pages {
    let doc = @index.document(p, @vault.required(store, p.path))
    texts[p.id] = @index.similar_tokens(doc.title + "\n\n" + doc.body)
    bodies[p.id] = doc.body
  }
  // Keeper-forest: walk pages in id order; a page redundant with an existing
  // keeper is filed under it, otherwise it becomes a new keeper.
  let keepers : Array[@core.Entry] = []
  // (keeper, duplicate, reason, score, signals) -- kept as tuples so the sort
  // comparator never calls a raising accessor.
  let found : Array[(String, String, String, Double, Array[String])] = []
  for page in pages {
    match find_keeper(page, keepers, texts, bodies, vectors, cosine_floor) {
      Some((kept_id, reason, score, signals)) =>
        found.push((kept_id, page.id, reason, score, signals))
      None => keepers.push(page)
    }
  }
  found.sort_by((a, b) => {
    let ka = a.0 + "\u0000" + a.1
    let kb = b.0 + "\u0000" + b.1
    @base.compare(ka, kb)
  })
  let candidates = found[:Int::min(limit, found.length())].map(
    c => {
      "keeper": c.0.to_json(), "duplicate": c.1.to_json(), "reason": c.2.to_json(),
      "score": c.3.to_json(), "signals": c.4.to_json(),
    }.to_json(),
  )
  let vector_pages = pages.filter(p => vectors.contains(p.id)).length()
  {
    "space": space.to_json(),
    "candidates": candidates.to_json(),
    "cosine_floor": cosine_floor.to_json(),
    "counts": {
      "pages": pages.length(),
      "keepers": keepers.length(),
      "candidates": found.length(),
      "with_vectors": vector_pages,
    },
    "fingerprint": @vault.fingerprint(entries),
  }
}

// The first keeper this page is redundant with, by id order, or None.
fn find_keeper(
  page : @core.Entry, keepers : Array[@core.Entry],
  texts : Map[String, Array[String]], bodies : Map[String, String],
  vectors : Map[String, @index.VectorRecord], cosine_floor : Double,
) -> (String, String, Double, Array[String])? raise @base.Fault {
  for kept in keepers {
    match redundancy_pair(page, kept, texts, bodies, vectors, cosine_floor) {
      Some((reason, score, signals)) => return Some((kept.id, reason, score, signals))
      None => ()
    }
  }
  None
}

// The strongest signal for a page pair, or None when they are not redundant.
// Priority: exact-token near-dup (definitely the same words) > vector cosine
// (same meaning, reworded) > shared-source + term overlap (weak nomination).
// Returns (primary reason, score, all fired signals).
fn redundancy_pair(
  page : @core.Entry, kept : @core.Entry,
  texts : Map[String, Array[String]], bodies : Map[String, String],
  vectors : Map[String, @index.VectorRecord], cosine_floor : Double,
) -> (String, Double, Array[String])? raise @base.Fault {
  let signals : Array[String] = []
  let mut primary : (String, Double)? = None
  // 1. token near-duplicate (formatting-only): both must clear the byte gate.
  if @index.similar_eligible(bodies[page.id]) && @index.similar_eligible(bodies[kept.id]) {
    if @index.similar_merge(texts[page.id], texts[kept.id]) {
      signals.push("similar_text")
      primary = Some(("similar_text", 1.0))
    }
  }
  // 2. vector cosine (semantic paraphrase): both pages have a current vector.
  match (vectors.get(page.id), vectors.get(kept.id)) {
    (Some(a), Some(b)) => {
      let hits = @index.brute_force(a.space, a.values, [b], 1)
      if !hits.is_empty() {
        let cos = hits[0].score
        if cos >= cosine_floor {
          signals.push("vector_cosine")
          if primary is None { primary = Some(("vector_cosine", cos)) }
        }
      }
    }
    _ => ()
  }
  // 3. shared source + high term overlap: a weak nomination only, and only
  // when nothing stronger already fired (two pages citing one source are
  // often complementary, so this never overrides a real signal).
  let shared = page.sources.iter().any(s => kept.sources.iter().any(k => k == s))
  if shared && primary is None && signals.is_empty() {
    if term_overlap(bodies[page.id], bodies[kept.id]) >= REDUNDANCY_SHARED_OVERLAP_FLOOR {
      signals.push("shared_source")
      primary = Some(("shared_source", 0.0))
    }
  }
  match primary {
    Some((reason, score)) => Some((reason, score, signals))
    None => None
  }
}

// Fraction of the shorter page's distinct tokens that the longer one also
// carries. Deterministic, no external model.
fn term_overlap(a : String, b : String) -> Double {
  let ta = distinct_tokens(@index.similar_tokens(a))
  let tb = distinct_tokens(@index.similar_tokens(b))
  if ta.is_empty() || tb.is_empty() { return 0.0 }
  let (small, big) = if ta.length() <= tb.length() { (ta, tb) } else { (tb, ta) }
  let mut hit = 0
  for token in small {
    if big.iter().any(x => x == token) { hit = hit + 1 }
  }
  hit.to_double() / small.length().to_double()
}

fn distinct_tokens(tokens : Array[String]) -> Array[String] {
  let out : Array[String] = []
  for t in tokens {
    if !out.iter().any(x => x == t) { out.push(t) }
  }
  out
}
