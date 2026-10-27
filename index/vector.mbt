pub(all) struct VectorSpace {
  id : String
  dimensions : Int
} derive(Eq, ToJson)
pub extend VectorSpace with Eq::{equal, not_equal}
pub extend VectorSpace with ToJson::{to_json}

pub(all) struct VectorRecord {
  page : String
  sha256 : String
  space : VectorSpace
  values : Array[Double]
} derive(ToJson)
pub extend VectorRecord with ToJson::{to_json}

pub(all) struct VectorHit {
  id : String
  score : Double
} derive(ToJson)
pub extend VectorHit with ToJson::{to_json}

// Provider implementations belong to the host. The core only defines the seam.
pub(all) struct EmbeddingProvider {
  space : VectorSpace
  embed : (Array[String]) -> Array[Array[Double]] raise @base.Fault
}

pub(all) struct VectorSearchBackend {
  search : (VectorSpace, Array[Double], Array[VectorRecord], Int) -> Array[VectorHit] raise @base.Fault
}

pub fn space_from_json(value : Json) -> VectorSpace raise @base.Fault {
  @base.keys(value, ["id", "dimensions"])
  let id = @base.text(@base.field(value, "id"))
  let dimension = match @base.field(value, "dimensions") {
    Number(n, ..) if n >= 1.0 && n <= 8192.0 && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("invalid_vector_dimension: integer 1..8192")
  }
  if id.is_empty() || id.length() > 512 { @base.fail("invalid_vector_space_id") }
  { id, dimensions: dimension }
}

pub fn vector_from_json(value : Json) -> Array[Double] raise @base.Fault {
  @base.array(value).map(v => match v {
    Number(n, ..) if !n.is_inf() && !n.is_nan() => n
    _ => raise @base.Fault("vector_nonfinite_or_nonnumeric")
  })
}

pub fn normalize(space : VectorSpace, values : Array[Double]) -> Array[Double] raise @base.Fault {
  if values.length() != space.dimensions || values.is_empty() { @base.fail("vector_dimension_mismatch") }
  let mut scale = 0.0
  for v in values {
    if v.is_nan() || v.is_inf() { @base.fail("vector_nonfinite") }
    let abs = if v < 0.0 { -v } else { v }
    if abs > scale { scale = abs }
  }
  if scale == 0.0 { @base.fail("vector_zero_norm") }
  let scaled = values.map(v => v / scale)
  let mut norm = 0.0
  for v in scaled { norm = norm + v*v }
  norm = norm.sqrt()
  scaled.map(v => v / norm)
}

pub fn record_from_json(value : Json) -> VectorRecord raise @base.Fault {
  @base.keys(value, ["page", "sha256", "space", "values"])
  let record : VectorRecord = {
    page: @base.text(@base.field(value, "page")), sha256: @base.text(@base.field(value, "sha256")),
    space: space_from_json(@base.field(value, "space")), values: vector_from_json(@base.field(value, "values")),
  }
  ignore(normalize(record.space, record.values))
  record
}

pub fn brute_force(space : VectorSpace, query : Array[Double], records : Array[VectorRecord], k : Int) -> Array[VectorHit] raise @base.Fault {
  let q = normalize(space, query)
  let hits : Array[VectorHit] = []
  for record in records {
    if record.space != space { continue }
    let vector = normalize(space, record.values)
    let mut score = 0.0
    for i = 0; i < vector.length(); i = i + 1 { score = score + vector[i]*q[i] }
    hits.push({ id: record.page, score })
  }
  hits.sort_by((a, b) => if a.score > b.score { -1 } else if a.score < b.score { 1 } else { @base.compare(a.id, b.id) })
  hits[:Int::max(0, Int::min(k, hits.length()))].to_owned()
}

pub fn default_backend() -> VectorSearchBackend {
  { search: brute_force }
}

pub fn search_vectors(
  space : VectorSpace, query : Array[Double], records : Array[VectorRecord], k : Int,
  backend? : VectorSearchBackend = default_backend(),
) -> Array[VectorHit] raise @base.Fault {
  ignore(normalize(space, query))
  let hits = (backend.search)(space, query, records, k)
  let seen : Map[String, Bool] = Map([])
  if hits.length() > k { @base.fail("backend_excess_results") }
  for hit in hits {
    if !records.iter().any(r => r.page == hit.id && r.space == space) || hit.score.is_nan() || hit.score.is_inf() || seen.contains(hit.id) {
      @base.fail("backend_invalid_candidate: " + hit.id)
    }
    seen[hit.id] = true
  }
  hits
}

// Validate ranked candidates returned by a host-owned search index. The host
// may keep its own vector store; the engine still constrains candidates to
// the active page set before fusion.
pub fn validate_external_hits(
  active_ids : Array[String], hits : Array[VectorHit], k : Int,
) -> Array[VectorHit] raise @base.Fault {
  if hits.length() > k { @base.fail("backend_excess_results") }
  let allowed : Map[String, Bool] = Map([])
  for id in active_ids { allowed[id] = true }
  let seen : Map[String, Bool] = Map([])
  for hit in hits {
    if !allowed.contains(hit.id) || hit.score.is_nan() || hit.score.is_inf() || seen.contains(hit.id) {
      @base.fail("backend_invalid_candidate: " + hit.id)
    }
    seen[hit.id] = true
  }
  hits
}

pub fn embed_texts(provider : EmbeddingProvider, texts : Array[String]) -> Array[Array[Double]] raise @base.Fault {
  let result = (provider.embed)(texts)
  if result.length() != texts.length() { @base.fail("embedding_provider_count_mismatch") }
  for vector in result { ignore(normalize(provider.space, vector)) }
  result
}
