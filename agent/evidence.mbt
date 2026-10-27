fn evidence_entries(entries : Array[@core.Entry]) -> Array[@core.Entry] {
  let result = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/evidence/"))
  result.sort_by((a, b) => @base.compare(a.id, b.id))
  result
}

fn evidence_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  for entry in evidence_entries(entries) {
    let row = @base.parse(@vault.required(store, entry.path))
    // Replaced records remain durable history but are no longer current
    // evidence. Keeping them on disk preserves the audit trail and pack
    // roundtrips without double-counting provenance.
    if evidence_optional(row, "superseded_by") is None { rows.push(row) }
  }
  rows
}

fn evidence_integer(value : Json, field : String) -> Int raise @base.Fault {
  match value {
    Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("evidence_range_invalid: " + field)
  }
}

fn evidence_optional(value : Json, key : String) -> Json? {
  match value { Object(fields) => fields.get(key); _ => None }
}

fn evidence_claims(value : Json) -> Array[Json] raise @base.Fault {
  let claims = @base.array(value)
  if claims.length() < 1 || claims.length() > 128 { @base.fail("evidence_claims_count_invalid") }
  claims
}

fn evidence_page_entry(entries : Array[@core.Entry], page : String) -> @core.Entry raise @base.Fault {
  let entry = @core.find(entries, page)
  if !@core.is_page(entry) { @base.fail("evidence_page_invalid: " + page) }
  entry
}

fn evidence_claim_view(
  store : @vault.Storage, entries : Array[@core.Entry], page_entry : @core.Entry,
  page_body : String, claim : Json,
) -> Json raise @base.Fault {
  let source = @base.text(@base.field(claim, "source"))
  let start = evidence_integer(@base.field(claim, "body_start"), "body_start")
  let end = evidence_integer(@base.field(claim, "body_end"), "body_end")
  let quote = @base.text(@base.field(claim, "quote"))
  let page_ok = !page_entry.stale
  let source_entry = entries.iter().find_first(e => e.id == source && e.kind == "raw")
  let source_stale = match source_entry {
    None => true
    Some(entry) => entry.stale || (store.digest)(source) != Some(entry.sha256)
  }
  let range_ok = try { @base.utf8_slice(page_body, start, end) == quote } catch { _ => false }
  let source_quote_verified : Json = match (evidence_optional(claim, "source_start"), evidence_optional(claim, "source_end"), evidence_optional(claim, "source_quote")) {
    (None, None, None) => Json::null()
    (Some(start_value), Some(end_value), Some(quote_value)) => {
      let source_start = try { evidence_integer(start_value, "source_start") } catch { _ => -1 }
      let source_end = try { evidence_integer(end_value, "source_end") } catch { _ => -1 }
      let source_quote = try { @base.text(quote_value) } catch { _ => "" }
      if source_start < 0 || source_end <= source_start || source_quote.is_empty() { false.to_json() }
      else {
        let verified : Bool = try { @base.utf8_slice(@vault.required(store, source), source_start, source_end) == source_quote } catch { _ => false }
        verified.to_json()
      }
    }
    _ => false.to_json()
  }
  let source_support = source_quote_verified == Json::null() || @base.boolean(source_quote_verified)
  // This is a provenance-strength classification, not a semantic entailment
  // score. Legacy claims remain valid for compatibility but are distinguishable
  // from claims whose raw byte range was checked exactly.
  let source_anchor = if source_quote_verified == Json::null() {
    "legacy"
  } else if @base.boolean(source_quote_verified) {
    "exact"
  } else {
    "invalid"
  }
  { "source": source, "body_start": start, "body_end": end, "quote": quote,
    "body_quote_verified": range_ok,
    "source_start": evidence_optional(claim, "source_start").unwrap_or(Json::null()),
    "source_end": evidence_optional(claim, "source_end").unwrap_or(Json::null()),
    "source_quote": evidence_optional(claim, "source_quote").unwrap_or(Json::null()),
    "source_quote_verified": source_quote_verified,
    "source_anchor": source_anchor,
    "valid": page_ok && !source_stale && range_ok && source_support,
    "source_stale": source_stale, "page_stale": !page_ok }
}

fn evidence_row_view(
  store : @vault.Storage, entries : Array[@core.Entry], row : Json,
) -> Json raise @base.Fault {
  let page = @base.text(@base.field(row, "page"))
  let page_entry = evidence_page_entry(entries, page)
  let page_body = @vault.required(store, page_entry.path)
  let parsed_page = @core.parse_page(page_body)
  let claims = evidence_claims(@base.field(row, "claims"))
  let views = claims.map(c => evidence_claim_view(store, entries, page_entry, parsed_page.body, c))
  let mut valid = !page_entry.stale
  for view in views { if !@base.boolean(@base.field(view, "valid")) { valid = false } }
  match row {
    Object(fields) => {
      // Json object fields are mutable; copy before adding derived view data.
      // Evidence stats evaluate the same row more than once, so mutating the
      // parsed record would turn omitted optional anchors into explicit nulls
      // and make a legacy four-field claim look like a malformed partial one.
      let result = fields.copy()
      result["claims"] = views.to_json()
      result["valid"] = valid.to_json()
      Json::object(result)
    }
    _ => raise @base.Fault("invalid_evidence_record")
  }
}

pub fn evidence_for_page_checked(store : @vault.Storage, entries : Array[@core.Entry], page : String) -> Json raise @base.Fault {
  let page_entry = evidence_page_entry(entries, page)
  ignore(page_entry)
  evidence_rows_unchecked(store, entries).filter(r => @base.text(@base.field(r, "page")) == page)
    .map(r => evidence_row_view(store, entries, r)).to_json()
}

pub fn evidence_for_page(store : @vault.Storage, entries : Array[@core.Entry], page : String) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  evidence_for_page_checked(store, entries, page)
}

pub fn evidence_stats_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  let rows = evidence_rows_unchecked(store, entries)
  let mut valid = 0
  let mut valid_claims = 0
  let mut invalid_claims = 0
  let mut exact_source_claims = 0
  let mut legacy_source_claims = 0
  let mut invalid_source_claims = 0
  for row in rows {
    let view = evidence_row_view(store, entries, row)
    if @base.boolean(@base.field(view, "valid")) { valid = valid + 1 }
    for claim in @base.array(@base.field(view, "claims")) {
      if @base.boolean(@base.field(claim, "valid")) { valid_claims = valid_claims + 1 }
      else { invalid_claims = invalid_claims + 1 }
      match @base.text(@base.field(claim, "source_anchor")) {
        "exact" => exact_source_claims = exact_source_claims + 1
        "legacy" => legacy_source_claims = legacy_source_claims + 1
        _ => invalid_source_claims = invalid_source_claims + 1
      }
    }
  }
  { "records": rows.length(), "valid": valid, "invalid": rows.length() - valid,
    "claims": valid_claims + invalid_claims, "valid_claims": valid_claims,
    "invalid_claims": invalid_claims, "exact_source_claims": exact_source_claims,
    "legacy_source_claims": legacy_source_claims,
    "invalid_source_claims": invalid_source_claims,
    "coverage": evidence_coverage(store, entries, rows) }
}

priv struct EvidenceInterval {
  start : Int
  end : Int
}

// Provenance is a deterministic description of anchor verification. It says
// nothing about whether a claim is semantically entailed by its source.
fn provenance_tier(
  stale : Bool, claims : Int, valid_claims : Int,
  exact_claims : Int, legacy_claims : Int,
) -> String {
  if stale { return "invalidated" }
  if claims == 0 { return "none" }
  if valid_claims == 0 { return "invalid" }
  if exact_claims == claims && valid_claims == claims { return "exact" }
  if legacy_claims == claims && valid_claims == claims { return "legacy" }
  if exact_claims > 0 { return "mixed" }
  if legacy_claims > 0 { return "legacy_partial" }
  "invalid"
}

fn coverage_page(
  store : @vault.Storage, entries : Array[@core.Entry], page_entry : @core.Entry,
  rows : Array[Json],
) -> Json raise @base.Fault {
  let text = @vault.required(store, page_entry.path)
  let body = @core.parse_page(text).body
  let body_bytes = @base.utf8_size(body)
  let intervals : Array[EvidenceInterval] = []
  let mut claims = 0
  let mut valid_claims = 0
  let mut exact_source_claims = 0
  let mut legacy_source_claims = 0
  let mut invalid_source_claims = 0
  for row in rows {
    if @base.text(@base.field(row, "page")) != page_entry.id { continue }
    let view = evidence_row_view(store, entries, row)
    for claim in @base.array(@base.field(view, "claims")) {
      claims = claims + 1
      match @base.text(@base.field(claim, "source_anchor")) {
        "exact" => exact_source_claims = exact_source_claims + 1
        "legacy" => legacy_source_claims = legacy_source_claims + 1
        _ => invalid_source_claims = invalid_source_claims + 1
      }
      if !@base.boolean(@base.field(claim, "valid")) { continue }
      valid_claims = valid_claims + 1
      let start = evidence_integer(@base.field(claim, "body_start"), "body_start")
      let end = evidence_integer(@base.field(claim, "body_end"), "body_end")
      intervals.push({ start, end })
    }
  }
  intervals.sort_by((a, b) => if a.start != b.start { a.start.compare(b.start) } else { a.end.compare(b.end) })
  let mut covered = 0
  let mut overlap_claims = 0
  let mut current_end = -1
  for interval in intervals {
    if interval.start < current_end {
      overlap_claims = overlap_claims + 1
      if interval.end > current_end {
        covered = covered + interval.end - current_end
        current_end = interval.end
      }
    } else {
      covered = covered + interval.end - interval.start
      current_end = interval.end
    }
  }
  let basis_points = if body_bytes == 0 { 0 } else { Int::min(10000, covered * 10000 / body_bytes) }
  { "page": page_entry.id, "stale": page_entry.stale, "body_bytes": body_bytes,
    "claims": claims, "valid_claims": valid_claims,
    "exact_source_claims": exact_source_claims,
    "legacy_source_claims": legacy_source_claims,
    "invalid_source_claims": invalid_source_claims,
    "covered_bytes": covered,
    "coverage_basis_points": basis_points, "overlap_claims": overlap_claims,
    "complete": covered == body_bytes,
    "provenance": provenance_tier(page_entry.stale, claims, valid_claims,
      exact_source_claims, legacy_source_claims) }
}

fn source_coverage(
  store : @vault.Storage, entries : Array[@core.Entry], rows : Array[Json], source : @core.Entry,
) -> Json raise @base.Fault {
  let pages : Array[String] = []
  let direct_pages : Array[String] = []
  let stale_direct_pages : Array[String] = []
  for entry in entries {
    if !@core.is_page(entry) || !entry.sources.contains(source.id) { continue }
    if entry.stale { stale_direct_pages.push(entry.id) } else { direct_pages.push(entry.id) }
  }
  direct_pages.sort_by(@base.compare)
  stale_direct_pages.sort_by(@base.compare)
  let mut claims = 0
  let mut valid_claims = 0
  let mut exact_source_claims = 0
  let mut legacy_source_claims = 0
  let mut invalid_source_claims = 0
  for row in rows {
    let page = @base.text(@base.field(row, "page"))
    let view = evidence_row_view(store, entries, row)
    for claim in @base.array(@base.field(view, "claims")) {
      if @base.text(@base.field(claim, "source")) != source.id { continue }
      claims = claims + 1
      match @base.text(@base.field(claim, "source_anchor")) {
        "exact" => exact_source_claims = exact_source_claims + 1
        "legacy" => legacy_source_claims = legacy_source_claims + 1
        _ => invalid_source_claims = invalid_source_claims + 1
      }
      if @base.boolean(@base.field(claim, "valid")) {
        valid_claims = valid_claims + 1
        if !pages.contains(page) { pages.push(page) }
      }
    }
  }
  pages.sort_by(@base.compare)
  let support = if source.stale {
    "invalidated"
  } else if valid_claims > 0 {
    "evidenced"
  } else if !direct_pages.is_empty() {
    "linked"
  } else {
    "unreferenced"
  }
  { "source": source.id, "active": !source.stale, "claims": claims,
    "valid_claims": valid_claims, "exact_source_claims": exact_source_claims,
    "legacy_source_claims": legacy_source_claims,
    "invalid_source_claims": invalid_source_claims, "pages": pages.to_json(),
    "direct_pages": direct_pages.to_json(), "stale_direct_pages": stale_direct_pages.to_json(),
    "support": support,
    "provenance": provenance_tier(source.stale, claims, valid_claims,
      exact_source_claims, legacy_source_claims), "basis": "provenance_v1" }
}

fn evidence_coverage(
  store : @vault.Storage, entries : Array[@core.Entry], rows : Array[Json],
) -> Json raise @base.Fault {
  let pages = entries.filter(e => @core.is_page(e)).map(e => coverage_page(store, entries, e, rows))
  let sources = entries.filter(e => e.kind == "raw").map(e => source_coverage(store, entries, rows, e))
  { "pages": pages.to_json(), "sources": sources.to_json() }
}

pub fn evidence_list(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let page = @base.text(@base.field(request, "page"))
  evidence_for_page_checked(store, entries, page)
}

fn evidence_submit_with_previous(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json, previous : String?,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let page = @base.text(@base.field(request, "page"))
  let page_hash = @base.text(@base.field(request, "page_hash"))
  let page_entry = evidence_page_entry(entries, page)
  if page_entry.stale || page_entry.sha256 != page_hash { @base.fail("evidence_page_version_mismatch") }
  let page_text = @vault.required(store, page_entry.path)
  if @base.hex_hash(page_text) != page_hash { @base.fail("evidence_page_changed") }
  let body = @core.parse_page(page_text).body
  let input_claims = evidence_claims(@base.field(request, "items"))
  // A single raw source may support several independent excerpts. Reject
  // only an exact duplicate claim so repeated submissions remain canonical.
  let seen : Map[String, Bool] = Map([])
  let claims : Array[Json] = []
  for item in input_claims {
    @base.keys(item, ["source", "body_start", "body_end", "quote", "source_start", "source_end", "source_quote"])
    let source = @base.text(@base.field(item, "source"))
    @base.path(source)
    if !source.has_prefix("raw/") { @base.fail("evidence_source_invalid: " + source) }
    let source_entry = entries.iter().find_first(e => e.id == source && e.kind == "raw")
    match source_entry {
      Some(entry) if !entry.stale && (store.digest)(source) == Some(entry.sha256) => ()
      _ => @base.fail("evidence_source_not_active: " + source)
    }
    let start = evidence_integer(@base.field(item, "body_start"), "body_start")
    let end = evidence_integer(@base.field(item, "body_end"), "body_end")
    let quote = @base.text(@base.field(item, "quote"))
    if quote.is_empty() || quote.length() > 65536 || quote.contains("\r") { @base.fail("evidence_quote_invalid") }
    if @base.utf8_slice(body, start, end) != quote { @base.fail("evidence_quote_mismatch") }
    let source_binding = match (evidence_optional(item, "source_start"), evidence_optional(item, "source_end"), evidence_optional(item, "source_quote")) {
      (None, None, None) => None
      (Some(start_value), Some(end_value), Some(quote_value)) => {
        let source_start = evidence_integer(start_value, "source_start")
        let source_end = evidence_integer(end_value, "source_end")
        let source_quote = @base.text(quote_value)
        if source_end <= source_start { @base.fail("evidence_source_range_invalid") }
        if source_quote.is_empty() || source_quote.length() > 65536 || source_quote.contains("\r") {
          @base.fail("evidence_source_quote_invalid")
        }
        let source_text = try { @vault.required(store, source) } catch { _ => raise @base.Fault("evidence_source_text_invalid: " + source) }
        if @base.utf8_slice(source_text, source_start, source_end) != source_quote {
          @base.fail("evidence_source_quote_mismatch")
        }
        Some((source_start, source_end, source_quote))
      }
      _ => raise @base.Fault("evidence_source_binding_required")
    }
    let claim : Json = match source_binding {
      None => { "source": source, "body_start": start, "body_end": end, "quote": quote }
      Some((source_start, source_end, source_quote)) => {
        { "source": source, "body_start": start, "body_end": end, "quote": quote,
          "source_start": source_start, "source_end": source_end, "source_quote": source_quote }
      }
    }
    let key = @base.canonical(claim)
    if seen.contains(key) { @base.fail("evidence_duplicate_claim") }
    seen[key] = true
    claims.push(claim)
  }
  let claims_json = claims.to_json()
  let content_seed : Json = { "page": page, "page_hash": page_hash, "claims": claims_json }
  let id = @base.hex_hash("evidence-v1\n" + @base.canonical(content_seed))
  let path = "state/evidence/" + id + ".json"
  let record : Json = { "id": id, "page": page, "page_hash": page_hash, "claims": claims_json }
  let content = @base.canonical(record)
  let previous_update : (String, String, @core.Entry)? = match previous {
    None => None
    Some(previous_id) => {
      if previous_id.length() != 64 || !previous_id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
        @base.fail("invalid_evidence_id")
      }
      if previous_id == id { @base.fail("evidence_replace_same_record") }
      let previous_path = "state/evidence/" + previous_id + ".json"
      let previous_entry = @core.find(entries, previous_path)
      let previous_text = @vault.required(store, previous_path)
      let previous_row = @base.parse(previous_text)
      if @base.text(@base.field(previous_row, "page")) != page ||
        @base.text(@base.field(previous_row, "page_hash")) != page_hash {
        @base.fail("evidence_replace_target_mismatch")
      }
      match evidence_optional(previous_row, "superseded_by") {
        Some(value) if value == id.to_json() => None
        Some(_) => { @base.fail("evidence_already_replaced"); None }
        None => {
          let updated = match previous_row {
            Object(fields) => { fields["superseded_by"] = id.to_json(); Json::object(fields) }
            _ => raise @base.Fault("invalid_evidence_record")
          }
          Some((previous_path, @base.canonical(updated), previous_entry))
        }
      }
    }
  }
  match (store.read)(path) {
    Some(existing) => if existing == content {
      return { "id": id, "path": path, "page": page, "replayed": true,
        "replaced": previous is Some(_), "record": evidence_row_view(store, entries, @base.parse(existing)) }
    } else { @base.fail("evidence_record_conflict") }
    None => ()
  }
  let event_path = "state/events/evidence-" + (if previous is Some(_) { "replace-" } else { "" }) + id + ".json"
  let event : Json = match previous {
    None => { "op": "evidence-submit", "evidence": id, "page": page, "page_hash": page_hash }
    Some(previous_id) => { "op": "evidence-replace", "evidence": id, "previous": previous_id, "page": page, "page_hash": page_hash }
  }
  let event_content = @base.canonical(event)
  if (store.read)(event_path) is Some(_) { @base.fail("evidence_event_conflict") }
  let record_entry : @core.Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false }
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let mut next = upsert(upsert(entries, record_entry), event_entry)
  let changes : Array[@vault.Change] = [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  match previous_update {
    None => ()
    Some((previous_path, previous_content, previous_entry)) => {
      changes.push({ path: previous_path, before: Some(@vault.required(store, previous_path)), after: Some(previous_content) })
      next = upsert(next, { ..previous_entry, sha256: @base.hex_hash(previous_content) })
    }
  }
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "path": path, "page": page, "replayed": false,
    "replaced": previous is Some(_), "record": evidence_row_view(store, next, record) }
}

pub fn evidence_submit(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  evidence_submit_with_previous(store, entries, request, None)
}

pub fn evidence_replace(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let previous = @base.text(@base.field(request, "previous"))
  evidence_submit_with_previous(store, entries, request, Some(previous))
}

pub fn evidence_stats(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  evidence_stats_unchecked(store, entries)
}
