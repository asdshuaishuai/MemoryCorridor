fn embedding_task_text(store : @vault.Storage, entry : @core.Entry) -> (String, Bool) raise @base.Fault {
  let doc = @index.document(entry, @vault.required(store, entry.path))
  let full = doc.title + "\n\n" + doc.body
  let text = StringBuilder()
  let mut used = 0
  for character in full.iter() {
    let bytes = @base.utf8_size(character.to_string())
    if used + bytes > 16384 { break }
    text.write_char(character)
    used = used + bytes
  }
  (text.to_string(), used < @base.utf8_size(full))
}

// Deterministic pick for the optional multimodal space (续二十六): the first
// non-stale `raw` image source (sorted by id, format "image" implied by the
// registered extension) is the visual content the host must embed. Pages
// without an image source are structurally unembeddable in a visual-only
// space and are skipped from the plan entirely -- they are NOT counted as a
// gap, unlike a page whose vector for its current content version is missing.
fn first_image_source(entries : Array[@core.Entry], page : @core.Entry) -> @core.Entry? {
  let sorted = page.sources.copy()
  sorted.sort()
  for id in sorted {
    let hits = entries.filter(e => e.id == id && e.kind == "raw" && !e.stale)
    if hits.length() > 0 && hits[0].format == "image" { return Some(hits[0]) }
  }
  None
}

fn embedding_plan(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let space = @index.space_from_json(@base.field(request, "space"))
  require_registered_provider(store, entries, request, "embedding", space)
  let multimodal = provider_declares(store, entries, request, "embedding", space, "embed-multimodal")
  let limit = integer(request, "limit", 8, 1, 128)
  let current : Map[String, String] = Map([])
  for entry in entries {
    if entry.kind != "vector" { continue }
    let record = @index.record_from_json(@base.parse(@vault.required(store, entry.path)))
    if record.space == space { current[record.page] = record.sha256 }
  }
  let pages = entries.filter(e => @core.is_page(e) && !e.stale && current.get(e.id) != Some(e.sha256))
  pages.sort_by((a,b) => @base.compare(a.id, b.id))
  let targets = if multimodal { pages.filter(p => first_image_source(entries, p) != None) } else { pages }
  let items : Array[Json] = []
  for entry in targets[:Int::min(limit, targets.length())] {
    if multimodal {
      let source = match first_image_source(entries, entry) {
        Some(e) => e
        None => raise @base.Fault("vector_image_source_unreachable")
      }
      items.push({ "page": entry.id, "sha256": entry.sha256, "modality": "image",
        "image": source.id, "image_sha256": source.sha256 })
    } else {
      let (text, truncated) = embedding_task_text(store, entry)
      items.push({ "page": entry.id, "sha256": entry.sha256, "text": text, "truncated": truncated })
    }
  }
  let text_recipe : Json = if multimodal { Json::null() } else { "title-body-prefix16KiB-v1".to_json() }
  let image_recipe : Json = if multimodal { "first-image-source-v1".to_json() } else { Json::null() }
  { "space": space.to_json(), "text_recipe": text_recipe, "image_recipe": image_recipe,
    "items": items.to_json(),
    "remaining": targets.length() - items.length(), "fingerprint": @vault.fingerprint(entries) }
}

pub(all) struct PreparedEmbeddings {
  entries : Array[@core.Entry]
  changes : Array[@vault.Change]
  submitted : Int
}

pub fn prepare_embeddings(
  store : @vault.Storage, entries : Array[@core.Entry], space_value : Json, items_value : Json, provider_value : Json,
) -> PreparedEmbeddings raise @base.Fault {
  @vault.verify(store, entries)
  let space = @index.space_from_json(space_value)
  require_registered_provider(store, entries, { "provider": provider_value }, "embedding", space)
  let items = @base.array(items_value)
  if items.is_empty() || items.length() > 128 { @base.fail("vector_batch_size: 1..128") }
  let mut next = entries.copy()
  let changes : Array[@vault.Change] = []
  for item in items {
    @base.keys(item, ["page", "sha256", "values", "values_b64"])
    let id = @base.text(@base.field(item, "page"))
    let entry = @core.find(entries, id)
    if !@core.is_page(entry) || entry.stale { @base.fail("vector_page_not_active: " + id) }
    if @base.text(@base.field(item, "sha256")) != entry.sha256 { @base.fail("vector_content_version_mismatch: " + id) }
    let values = match item {
      Object(fields) => {
        let has_json = fields.contains("values")
        let has_wire = fields.contains("values_b64")
        if has_json == has_wire { @base.fail("vector_values_encoding_exclusive") }
        if has_wire {
          @index.values_from_base64(space, @base.text(fields["values_b64"]))
        } else {
          @index.vector_from_json(fields["values"])
        }
      }
      _ => raise @base.Fault("expected_object")
    }
    ignore(@index.normalize(space, values))
    let record : @index.VectorRecord = { page: id, sha256: entry.sha256, space, values }
    let path = "vectors/" + @base.hex_hash(@base.canonical(space.to_json()) + "\n" + id) + ".json"
    let content = @base.canonical(record.to_json())
    changes.push({ path, before: (store.read)(path), after: Some(content) })
    next = upsert(next, { id: path, path, kind: "vector", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
  }
  { entries: next, changes, submitted: items.length() }
}

pub fn submit_embeddings(store : @vault.Storage, entries : Array[@core.Entry], space_value : Json, items_value : Json, provider_value : Json) -> Json raise @base.Fault {
  let prepared = prepare_embeddings(store, entries, space_value, items_value, provider_value)
  let space = @index.space_from_json(space_value)
  @vault.commit(store, @vault.fingerprint(entries), prepared.entries, prepared.changes)
  { "submitted": prepared.submitted, "space": space.to_json(), "fingerprint": @vault.fingerprint(prepared.entries) }
}

fn external_candidates(entries : Array[@core.Entry], value : Json) -> (Array[@index.VectorHit], @index.VectorSpace) raise @base.Fault {
  @base.keys(value, ["space", "hits"])
  let space = @index.space_from_json(@base.field(value, "space"))
  let active = entries.filter(e => @core.is_page(e) && !e.stale).map(e => e.id)
  let hits = @base.array(@base.field(value, "hits")).map(item => {
    @base.keys(item, ["id", "score"])
    let score = match @base.field(item, "score") {
      Number(n, ..) if !n.is_nan() && !n.is_inf() => n
      _ => raise @base.Fault("backend_score_nonfinite_or_nonnumeric")
    }
    let hit : @index.VectorHit = { id: @base.text(@base.field(item, "id")), score }
    hit
  })
  (@index.validate_external_hits(active, hits, 100), space)
}

fn keyword_rows(hits : Array[@retrieval.PageHit]) -> Array[Json] {
  let rows : Array[Json] = []
  for hit in hits {
    rows.push({ "id": hit.page.to_json(), "title": hit.title.to_json(),
      "score": hit.score.to_json(), "excerpt": hit.excerpt.to_json() })
  }
  rows
}

fn query_vector_values(vector_value : Json, space : @index.VectorSpace) -> Array[Double] raise @base.Fault {
  @base.keys(vector_value, ["space", "values", "values_b64"])
  match vector_value {
    Object(fields) => {
      let has_json = fields.contains("values")
      let has_wire = fields.contains("values_b64")
      if has_json == has_wire { @base.fail("vector_values_encoding_exclusive") }
      if has_wire {
        @index.values_from_base64(space, @base.text(fields["values_b64"]))
      } else {
        @index.vector_from_json(fields["values"])
      }
    }
    _ => raise @base.Fault("expected_object")
  }
}

// Host-supplied query vector over stored provider vectors. Used by `search`
// and by `retrieve`'s system lane; the engine never embeds the query itself.
pub fn system_page_hits(
  store : @vault.Storage, entries : Array[@core.Entry], vector_value : Json, provider_value : Json,
) -> (@index.VectorSpace, Array[@index.VectorHit]) raise @base.Fault {
  @base.keys(vector_value, ["space", "values", "values_b64"])
  // Unlike `search`, the chunk-level system lane always names the provider that
  // produced the query vector: an anonymous vector would skip registration and
  // make the lane's provenance unverifiable.
  if provider_value == Json::null() { @base.fail("retrieve_provider_required") }
  let space = @index.space_from_json(@base.field(vector_value, "space"))
  require_registered_provider(store, entries, { "provider": provider_value }, "embedding", space)
  let values = query_vector_values(vector_value, space)
  let records : Array[@index.VectorRecord] = []
  for entry in entries {
    if entry.kind == "vector" {
      let record = @index.record_from_json(@base.parse(@vault.required(store, entry.path)))
      if record.space == space &&
        entries.iter().any(e => @core.is_page(e) && !e.stale && e.id == record.page && e.sha256 == record.sha256) {
        records.push(record)
      }
    }
  }
  (space, @index.search_vectors(space, values, records, 100))
}

pub fn hybrid_search(
  store : @vault.Storage, entries : Array[@core.Entry], collection : @retrieval.Collection,
  query : String, limit : Int, vector_value : Json, candidates_value : Json, provider_value : Json,
) -> Json raise @base.Fault {
  let keyword = @retrieval.search_pages(entries, collection, query, 100)
  if vector_value != Json::null() && candidates_value != Json::null() {
    @base.fail("vector_inputs_exclusive")
  }
  if vector_value == Json::null() && candidates_value == Json::null() {
    let rows = keyword_rows(@retrieval.search_pages(entries, collection, query, limit))
    return { "hits": rows.to_json(), "vector_status": "not_provided" }
  }
  let (space, vector_hits, status) : (@index.VectorSpace, Array[@index.VectorHit], String) = if candidates_value != Json::null() {
    let (hits, external_space) = external_candidates(entries, candidates_value)
    require_registered_provider(store, entries, { "provider": provider_value }, "search", external_space)
    (external_space, hits, "external")
  } else {
    @base.keys(vector_value, ["space", "values", "values_b64"])
    let query_space = @index.space_from_json(@base.field(vector_value, "space"))
    require_registered_provider(store, entries, { "provider": provider_value }, "embedding", query_space)
    let values = query_vector_values(vector_value, query_space)
    let records : Array[@index.VectorRecord] = []
    for entry in entries {
      if entry.kind == "vector" {
        let record = @index.record_from_json(@base.parse(@vault.required(store, entry.path)))
        if record.space == query_space && entries.iter().any(e => @core.is_page(e) && !e.stale && e.id == record.page && e.sha256 == record.sha256) {
          records.push(record)
        }
      }
    }
    (query_space, @index.search_vectors(query_space, values, records, 100), if records.is_empty() { "no_matching_vectors" } else { "brute_force" })
  }
  let scores : Map[String, Double] = Map([])
  let excerpts : Map[String, String] = Map([])
  for i = 0; i < keyword.length(); i = i + 1 {
    let page = keyword[i].page
    scores[page] = scores.get(page).unwrap_or(0.0) + 1.0 / (61.0 + i.to_double())
    excerpts[page] = keyword[i].excerpt
  }
  for i = 0; i < vector_hits.length(); i = i + 1 {
    let id = vector_hits[i].id
    scores[id] = scores.get(id).unwrap_or(0.0) + 1.0 / (61.0 + i.to_double())
  }
  let rows : Array[(String, Double)] = []
  for pair in scores.iter() { rows.push(pair) }
  rows.sort_by((a, b) => if a.1 > b.1 { -1 } else if a.1 < b.1 { 1 } else { @base.compare(a.0, b.0) })
  let hits : Array[Json] = []
  for i = 0; i < rows.length() && i < limit; i = i + 1 {
    let (id, score) = rows[i]
    let excerpt = match excerpts.get(id) {
      Some(value) => value
      None => @retrieval.page_excerpt(collection, id)
    }
    hits.push({ "id": id.to_json(), "title": @retrieval.page_title(collection, id).to_json(),
      "score": score.to_json(), "excerpt": excerpt.to_json() })
  }
  { "hits": hits.to_json(), "vector_status": status, "vector_space": space.to_json() }
}
