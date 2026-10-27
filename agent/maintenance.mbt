fn review_view(row : Json, current_baseline : String) -> Json raise @base.Fault {
  match row {
    Object(fields) => {
      let result = fields.copy()
      let status = match optional(row, "input_fingerprint") {
        None => "unknown"
        Some(value) => if @base.text(value) == current_baseline { "current" } else { "stale" }
      }
      result["input_status"] = status.to_json()
      Json::object(result)
    }
    _ => raise @base.Fault("invalid_review")
  }
}

// Callers that already verified the vault reuse this directly; each row
// helper verifying on its own made multi-source reads re-hash every file.
fn review_rows_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  let review_entries = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/reviews/"))
  review_entries.sort_by((a, b) => @base.compare(a.id, b.id))
  let baseline = quality_baseline(entries)
  for e in review_entries { rows.push(review_view(@base.parse(@vault.required(store, e.path)), baseline)) }
  rows
}

fn review_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  @vault.verify(store, entries)
  review_rows_unchecked(store, entries)
}

fn review_counts(rows : Array[Json]) -> Json {
  let pending = rows.filter(r => optional(r, "status") == Some("pending".to_json())).length()
  let resolved = rows.filter(r => optional(r, "status") == Some("resolved".to_json())).length()
  { "pending": pending, "resolved": resolved, "total": rows.length() }
}

fn review_at(value : String, field : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("review_time_invalid: " + field)
  }
}

fn maintenance(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let op = @base.text(@base.field(request, "op"))
  let text = key => @base.text(@base.field(request, key))
  if ["provider-register", "provider-heartbeat", "provider-unregister", "provider-list"].contains(op) {
    return provider_dispatch(store, entries, request)
  }
  if ["provider-job-open", "provider-job-claim", "provider-job-heartbeat", "provider-job-complete", "provider-job-cancel", "provider-job-fail", "provider-job-list"].contains(op) {
    return provider_job_dispatch(store, entries, request)
  }
  match op {
    "fingerprints" => { "vault": @vault.fingerprint(entries),
      "index_inputs": @base.hex_hash("text-index-v3\n" + @vault.fingerprint(entries)), "algorithm": "sha256" }
    "read-log" => {
      let events = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/events/"))
      events.sort_by((a,b) => @base.compare(a.id, b.id))
      let rows = events.map(e => @base.parse(@vault.required(store, e.path)))
      // Events are sorted by their content-addressed id. A bounded read is
      // therefore deterministic even when wall-clock timestamps collide.
      let limit = integer(request, "limit", -1, 0, 1000)
      if limit < 0 || limit >= rows.length() {
        rows.to_json()
      } else {
        rows[Int::max(0, rows.length() - limit):].to_owned().to_json()
      }
    }
    "stats" => {
      // `maintenance` verified once at the top; the aggregators below must not
      // each re-hash every file in the vault.
      let g = graph_unchecked(store, entries)
      let rows = review_rows_unchecked(store, entries)
      let research = research_rows_unchecked(store, entries)
      let suggestions = suggestion_rows_unchecked(store, entries)
      let overview_state = overview_status_unchecked(store, entries)
      let evidence = evidence_stats_unchecked(store, entries)
      let providers = provider_entries_unchecked(store, entries)
      let provider_jobs = provider_job_rows_unchecked(store, entries)
      { "pages": g.nodes.length(), "edges": g.edges.length(), "stale_pages": entries.filter(e => @core.is_page(e) && e.stale).length(),
        "active_sources": entries.filter(e => e.kind == "raw" && !e.stale).length(),
        "pending_reviews": rows.filter(r => optional(r, "status") == Some("pending".to_json())).length(),
        "review_debt": review_counts(rows),
        "pending_research": research.filter(r => optional(r, "status") == Some("proposed".to_json())).length(),
        "pending_suggestions": suggestions.filter(r => optional(r, "status") == Some("proposed".to_json())).length(),
        "overview_status": overview_state,
        "evidence": evidence,
        "memory": memory_summary(store, entries),
        "impacts": impact_summary(store, entries),
        "providers": { "total": providers.length(), "active": providers.filter(r => optional(r, "status") == Some("active".to_json())).length(),
          "revoked": providers.filter(r => optional(r, "status") == Some("revoked".to_json())).length() },
        "provider_jobs": { "total": provider_jobs.length(), "pending": provider_jobs.filter(r => optional(r, "status") == Some("pending".to_json())).length(),
          "completed": provider_jobs.filter(r => optional(r, "status") == Some("completed".to_json())).length(),
          "cancelled": provider_jobs.filter(r => optional(r, "status") == Some("cancelled".to_json())).length(),
          "failed": provider_jobs.filter(r => optional(r, "status") == Some("failed".to_json())).length() },
        "fingerprint": @vault.fingerprint(entries) }
    }
    "review-list" => review_rows(store, entries).to_json()
    "quality-audit" => quality_audit(store, entries, request)
    "research-list" => research_rows(store, entries).to_json()
    "research-topic" => research_topic(store, entries, request)
    "research-complete" => close_research(store, entries, request, true)
    "research-cancel" => close_research(store, entries, request, false)
    "purpose-suggest" => purpose_suggest(store, entries, request)
    "purpose-apply" => purpose_apply(store, entries, request)
    "suggestion-list" => suggestion_rows(store, entries).to_json()
    "purpose-cancel" => purpose_cancel(store, entries, request)
    "overview-suggest" => overview_suggest(store, entries, request)
    "overview-apply" => overview_apply(store, entries, request)
    "overview-list" => overview_rows(store, entries).to_json()
    "overview-cancel" => overview_cancel(store, entries, request)
    "review-resolve" => {
      let id = text("id")
      if id.length() != 64 || !id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) { @base.fail("invalid_review_id") }
      let action = text("action")
      if !["create-page", "research", "skip"].contains(action) { @base.fail("unsupported_review_action") }
      let note = text("note")
      let at = text("at")
      review_at(at, "at")
      let key = match optional(request, "key") {
        Some(value) => {
          let value = @base.text(value)
          if value.is_empty() || value.length() > 256 || value.contains("\n") || value.contains("\r") {
            @base.fail("review_idempotency_key_invalid")
          }
          value
        }
        None => @base.hex_hash(id + "\n" + action + "\n" + note + "\n" + at)
      }
      let path = "state/reviews/" + id + ".json"
      let entry = @core.find(entries, path)
      let before = @vault.required(store, path)
      let old = @base.parse(before)
      let decision : Json = { "action": action, "note": note, "at": at, "key": key }
      if optional(old, "status") == Some("resolved".to_json()) {
        if optional(old, "decision") == Some(decision) { return { "id": id, "replayed": true } }
        @base.fail("review_already_resolved")
      }
      let next = match old {
        Object(fields) => { fields["status"] = "resolved".to_json(); fields["decision"] = decision; Json::object(fields) }
        _ => raise @base.Fault("invalid_review")
      }
      let content = @base.canonical(next)
      let event_path = "state/events/review-" + id + "-" + @base.hex_hash(key) + ".json"
      let event : Json = { "op": "review-resolve", "review": id, "action": action, "key": key, "at": at,
        "predicate": optional(old, "predicate").unwrap_or(Json::null()),
        "subject": optional(old, "subject").unwrap_or(Json::null()),
        "page": optional(old, "page").unwrap_or(Json::null()),
        "source": optional(old, "source").unwrap_or(Json::null()),
        "input_fingerprint": optional(old, "input_fingerprint").unwrap_or(Json::null()) }
      let event_content = @base.canonical(event)
      if (store.read)(event_path) is Some(_) { @base.fail("review_event_conflict") }
      let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
      let next_entries = upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry)
      @vault.commit(store, @vault.fingerprint(entries), next_entries,
        [{ path, before: Some(before), after: Some(content) },
         { path: event_path, before: None, after: Some(event_content) }])
      { "id": id, "status": "resolved", "decision": decision, "event": event_path, "execution": "host_required" }
    }
    "backfill" => {
      let content = "# " + text("title") + "\n\n" + text("text") + "\n"
      let path = "raw/queries/" + @base.hex_hash(content) + ".md"
      match (store.read)(path) {
        Some(old) => if old != content { @base.fail("backfill_content_collision") }
        None => (store.write)(path, content)
      }
      let result = scan(store, entries)
      { "source": path, "scan": result }
    }
    _ => raise @base.Fault("unknown_maintenance")
  }
}
