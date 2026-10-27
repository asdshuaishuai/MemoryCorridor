// Directories under state/ that hold durable records. A new durable-work kind
// must appear here: `validate_record` branches on these prefixes, and both the
// transaction whitelist and the pack whitelist read this same list, so a record
// directory cannot be valid in one place and refused in another.
pub fn state_directories() -> Array[String] {
  ["state/orders", "state/events", "state/reviews", "state/research",
   "state/suggestions", "state/overview", "state/evidence", "state/memory",
   "state/impacts", "state/providers", "state/provider-jobs"]
}

fn valid_hash(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

// Memory note identity is content addressed so a retried submit replays and a
// corrected note supersedes instead of forking. Core owns the recipe because
// both the writer and the record validator must derive the same digest.
// `source_hashes` pins the exact bytes each binding pointed at when the note was
// written. Without it a note stays "valid" after its source is rewritten whole,
// and the evidence behind the judgment silently becomes different material.
pub fn memory_note_hash(
  kind : String, scope : String, text : String,
  conditions : Array[String], sources : Array[String], source_hashes : Array[String],
) -> String {
  @base.hex_hash("memory-note-v2\n" + kind + "\n" + scope + "\n" + text + "\n" +
    @base.canonical(conditions.to_json()) + "\n" + @base.canonical(sources.to_json()) +
    "\n" + @base.canonical(source_hashes.to_json()))
}

// The judgment a note makes, independent of which evidence it cites. Duplicate
// detection and conflict grouping must use this rather than `note_hash`: two
// notes that say the same thing under the same conditions are duplicates even
// when they bind different sources, and must not be reported as competing.
pub fn memory_judgment_hash(
  kind : String, scope : String, text : String, conditions : Array[String],
) -> String {
  @base.hex_hash("memory-judgment-v1\n" + kind + "\n" + scope + "\n" + text + "\n" +
    @base.canonical(conditions.to_json()))
}

pub fn memory_note_id(key : String, note_hash : String) -> String {
  @base.hex_hash("memory-v1\n" + key + "\n" + note_hash)
}

// One impact record per (kind, subject, cause): it tracks the live drift state
// of a durable work item instead of accumulating a new record on every change.
pub fn impact_id(kind : String, subject : String, cause : String) -> String {
  @base.hex_hash("impact-v1\n" + kind + "\n" + subject + "\n" + cause)
}

fn impact_kind(value : String) -> Unit raise @base.Fault {
  if !["research", "overview-suggestion", "overview-synthesis"].contains(value) {
    @base.fail("impact_kind_invalid")
  }
}

fn impact_cause(value : String) -> Unit raise @base.Fault {
  if !["baseline-drift", "purpose-drift", "page-drift", "synthesis-drift"].contains(value) {
    @base.fail("impact_cause_invalid")
  }
}

fn impact_subject(value : String) -> Unit raise @base.Fault {
  @base.path(value)
  if !(value.has_prefix("state/research/") || value.has_prefix("state/overview/") ||
    value == "wiki/overview.md") {
    @base.fail("impact_subject_invalid")
  }
}

fn impact_record(value : Json, id : String) -> Unit raise @base.Fault {
  if @base.field(value, "version") != Json::number(1.0) { @base.fail("impact_version_unsupported") }
  let kind = @base.text(@base.field(value, "kind"))
  impact_kind(kind)
  let subject = @base.text(@base.field(value, "subject"))
  impact_subject(subject)
  let cause = @base.text(@base.field(value, "cause"))
  impact_cause(cause)
  for field in ["frozen", "current"] {
    if !valid_hash(@base.text(@base.field(value, field))) { @base.fail("impact_" + field + "_invalid") }
  }
  let detail = @base.text(@base.field(value, "detail"))
  if detail.is_empty() || detail.length() > 512 || detail.contains("\n") || detail.contains("\r") {
    @base.fail("impact_detail_invalid")
  }
  for field in ["created_at", "updated_at"] {
    let at = @base.text(@base.field(value, field))
    if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("impact_" + field + "_invalid") }
  }
  let status = @base.text(@base.field(value, "status"))
  if !["open", "resolved"].contains(status) { @base.fail("impact_status_invalid") }
  let resolved_at = @base.field(value, "resolved_at")
  if status == "open" {
    if resolved_at != Json::null() { @base.fail("impact_open_resolved_at_invalid") }
  } else {
    let at = @base.text(resolved_at)
    if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("impact_resolved_at_required") }
  }
  // `dismissed` is only meaningful next to a decision; an open impact has none.
  match optional_record_field(value, "dismissed") {
    None => ()
    // Null means the engine closed it because the drift disappeared; a hash
    // means a host decided against these exact inputs.
    Some(Null) => ()
    Some(value) => {
      if status != "resolved" { @base.fail("impact_dismissed_open_invalid") }
      if !valid_hash(@base.text(value)) { @base.fail("impact_dismissed_invalid") }
    }
  }
  let key = @base.text(@base.field(value, "key"))
  if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
    @base.fail("impact_key_invalid")
  }
  if id != impact_id(kind, subject, cause) { @base.fail("impact_record_identity_mismatch") }
}

fn memory_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("memory_time_invalid")
  }
}

fn memory_nullable_time(value : Json, field : String) -> Unit raise @base.Fault {
  match value {
    Null => ()
    String(text) => memory_time(text)
    _ => @base.fail("memory_" + field + "_invalid")
  }
}

fn memory_nullable_hash(value : Json, field : String, id : String) -> String? raise @base.Fault {
  match value {
    Null => None
    String(text) => {
      if !valid_hash(text) || text == id { @base.fail("memory_" + field + "_invalid") }
      Some(text)
    }
    _ => raise @base.Fault("memory_" + field + "_invalid")
  }
}

fn memory_record(value : Json, id : String) -> Unit raise @base.Fault {
  if @base.field(value, "version") != Json::number(1.0) { @base.fail("memory_version_unsupported") }
  let kind = @base.text(@base.field(value, "kind"))
  if !["preference", "decision", "constraint", "fact", "goal"].contains(kind) {
    @base.fail("memory_kind_invalid")
  }
  let scope = @base.text(@base.field(value, "scope"))
  if scope != "workspace" { @base.fail("memory_scope_invalid") }
  let text = @base.text(@base.field(value, "text"))
  if text.is_empty() || text.length() > 4096 || text.contains("\r") { @base.fail("memory_text_invalid") }
  let conditions = @base.strings(@base.field(value, "conditions"))
  if conditions.length() > 16 { @base.fail("memory_conditions_count_invalid") }
  for condition in conditions {
    if condition.is_empty() || condition.length() > 256 ||
      condition.contains("\n") || condition.contains("\r") {
      @base.fail("memory_condition_invalid")
    }
  }
  let sources = @base.strings(@base.field(value, "sources"))
  if sources.length() > 32 { @base.fail("memory_sources_count_invalid") }
  let seen : Map[String, Bool] = Map([])
  for source in sources {
    @base.path(source)
    if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("memory_source_invalid") }
    seen[source] = true
  }
  let status = @base.text(@base.field(value, "status"))
  if !["active", "archived", "superseded"].contains(status) { @base.fail("memory_status_invalid") }
  let key = @base.text(@base.field(value, "key"))
  if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
    @base.fail("memory_key_invalid")
  }
  memory_time(@base.text(@base.field(value, "created_at")))
  memory_time(@base.text(@base.field(value, "updated_at")))
  memory_nullable_time(optional_record_field(value, "archived_at").unwrap_or(Json::null()), "archived_at")
  ignore(memory_nullable_hash(optional_record_field(value, "superseded_by").unwrap_or(Json::null()), "superseded_by", id))
  ignore(memory_nullable_hash(optional_record_field(value, "supersedes").unwrap_or(Json::null()), "supersedes", id))
  // A pinned note is protected from archiving, so the flag has to be explicit.
  ignore(@base.boolean(@base.field(value, "pinned")))
  let archived_at = optional_record_field(value, "archived_at").unwrap_or(Json::null())
  let superseded_by = optional_record_field(value, "superseded_by").unwrap_or(Json::null())
  if status == "active" && archived_at != Json::null() { @base.fail("memory_active_archived_at_invalid") }
  if status == "archived" && archived_at == Json::null() { @base.fail("memory_archived_at_required") }
  if status == "superseded" && superseded_by == Json::null() { @base.fail("memory_superseded_by_required") }
  let note_hash = @base.text(@base.field(value, "note_hash"))
  if !valid_hash(note_hash) { @base.fail("memory_note_hash_invalid") }
  let source_hashes = @base.strings(@base.field(value, "source_hashes"))
  if source_hashes.length() != sources.length() { @base.fail("memory_source_hashes_count_invalid") }
  for hash in source_hashes {
    if !valid_hash(hash) { @base.fail("memory_source_hash_invalid") }
  }
  if note_hash != memory_note_hash(kind, scope, text, conditions, sources, source_hashes) {
    @base.fail("memory_note_hash_mismatch")
  }
  if id != memory_note_id(key, note_hash) { @base.fail("memory_record_identity_mismatch") }
}

fn optional_record_field(value : Json, key : String) -> Json? {
  match value { Object(fields) => fields.get(key); _ => None }
}

fn event_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("event_time_invalid")
  }
}

fn event_hash(value : String, code : String) -> Unit raise @base.Fault {
  if !valid_hash(value) { @base.fail(code) }
}

fn analysis(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, ["entities", "concepts", "conflicts", "summary"])
  for key in ["entities", "concepts", "conflicts"] { ignore(@base.strings(@base.field(value, key))) }
  ignore(@base.text(@base.field(value, "summary")))
}

pub fn validate_record(entry : Entry, text : String) -> Unit raise @base.Fault {
  let value = @base.parse(text)
  match value { Object(_) => (); _ => @base.fail("record_object_required: " + entry.path) }
  let string = key => @base.text(@base.field(value, key))
  if entry.path.has_prefix("state/orders/") {
    @base.keys(value, ["id", "source", "source_hash", "baseline", "context_version", "phase", "analysis", "page_hashes"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/orders/" + id + ".json" || !valid_hash(string("source_hash")) || !valid_hash(string("baseline")) { @base.fail("order_record_identity_invalid") }
    if value is Object(fields) {
      if fields.get("context_version") is Some(v) {
        let version = @base.text(v)
        if version != "" && !valid_hash(version) { @base.fail("order_context_version_invalid") }
      }
    }
    @base.path(string("source"))
    if !string("source").has_prefix("raw/") { @base.fail("order_record_source_invalid") }
    let phase = string("phase")
    if !["pending", "context-ready", "analysis-done", "committed", "cancelled"].contains(phase) { @base.fail("order_record_phase_invalid") }
    let data = @base.field(value, "analysis")
    if phase == "analysis-done" || phase == "committed" || data != Json::null() { analysis(data) }
    match @base.field(value, "page_hashes") {
      Object(hashes) => for (id, hash) in hashes { @base.path(id); if !valid_hash(@base.text(hash)) { @base.fail("order_record_page_hash_invalid") } }
      _ => @base.fail("order_record_page_hashes_invalid")
    }
  } else if entry.path.has_prefix("state/reviews/") {
    @base.keys(value, ["id", "order", "predicate", "subject", "page", "source", "reason", "input_fingerprint", "created_at", "status", "decision"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/reviews/" + id + ".json" || !valid_hash(string("order")) { @base.fail("review_record_identity_invalid") }
    @base.path(string("source")); ignore(string("reason"))
    if optional_record_field(value, "predicate") is Some(predicate) {
      let text = @base.text(predicate)
      if text.is_empty() || text.contains("\n") || text.contains("\r") { @base.fail("review_predicate_invalid") }
    }
    if optional_record_field(value, "subject") is Some(subject) { ignore(@base.text(subject)) }
    if optional_record_field(value, "page") is Some(page) { @base.path(@base.text(page)) }
    if optional_record_field(value, "input_fingerprint") is Some(fingerprint) && !valid_hash(@base.text(fingerprint)) {
      @base.fail("review_input_fingerprint_invalid")
    }
    let created_at = string("created_at")
    if created_at.length() < 10 || created_at.contains("\n") || created_at.contains("\r") { @base.fail("review_created_at_invalid") }
    let status = string("status")
    let decision = @base.field(value, "decision")
    if status == "pending" { if decision != Json::null() { @base.fail("review_pending_decision_invalid") } }
    else if status == "resolved" {
      @base.keys(decision, ["action", "note", "at", "key"])
      if !["research", "create-page", "skip"].contains(@base.text(@base.field(decision, "action"))) { @base.fail("review_action_invalid") }
      ignore(@base.text(@base.field(decision, "note")))
      let at = @base.text(@base.field(decision, "at"))
      let key = @base.text(@base.field(decision, "key"))
      if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("review_decision_at_invalid") }
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("review_idempotency_key_invalid") }
    } else { @base.fail("review_status_invalid") }
  } else if entry.path.has_prefix("state/research/") {
    @base.keys(value, ["id", "topic", "queries", "baseline", "inputs_hash", "created_at", "status", "key", "closed_at", "sources"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/research/" + id + ".json" || !valid_hash(string("baseline")) {
      @base.fail("research_record_identity_invalid")
    }
    if !valid_hash(string("inputs_hash")) { @base.fail("research_inputs_hash_invalid") }
    let topic = string("topic")
    if topic.is_empty() || topic.length() > 512 || topic.contains("\n") || topic.contains("\r") {
      @base.fail("research_topic_invalid")
    }
    let queries = @base.strings(@base.field(value, "queries"))
    if queries.length() < 1 || queries.length() > 16 { @base.fail("research_queries_count_invalid") }
    for query in queries {
      if query.is_empty() || query.length() > 256 || query.contains("\n") || query.contains("\r") {
        @base.fail("research_query_invalid")
      }
    }
    let created_at = string("created_at")
    if created_at.length() < 10 || created_at.contains("\n") || created_at.contains("\r") { @base.fail("research_created_at_invalid") }
    let status = string("status")
    let closed_at = @base.field(value, "closed_at")
    let sources = @base.strings(@base.field(value, "sources"))
    if status == "proposed" {
      if closed_at != Json::null() || !sources.is_empty() { @base.fail("research_open_record_invalid") }
    } else if status == "completed" {
      let closed = @base.text(closed_at)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") || sources.is_empty() { @base.fail("research_completed_record_invalid") }
      let seen : Map[String, Bool] = Map([])
      for source in sources {
        @base.path(source)
        if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("research_source_invalid") }
        seen[source] = true
      }
    } else if status == "cancelled" {
      let closed = @base.text(closed_at)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") || !sources.is_empty() { @base.fail("research_cancelled_record_invalid") }
    } else { @base.fail("research_status_invalid") }
    let key = string("key")
    if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("research_idempotency_key_invalid") }
  } else if entry.path.has_prefix("state/suggestions/") {
    @base.keys(value, ["id", "kind", "baseline", "purpose_hash", "created_at", "status", "key", "closed_at", "result_hash"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/suggestions/" + id + ".json" ||
      !valid_hash(string("baseline")) || !valid_hash(string("purpose_hash")) {
      @base.fail("suggestion_record_identity_invalid")
    }
    if string("kind") != "purpose" { @base.fail("suggestion_kind_invalid") }
    let created_at = string("created_at")
    if created_at.length() < 10 || created_at.contains("\n") || created_at.contains("\r") { @base.fail("suggestion_created_at_invalid") }
    let status = string("status")
    let closed_at = @base.field(value, "closed_at")
    let result_hash = @base.field(value, "result_hash")
    if status == "proposed" {
      if closed_at != Json::null() || result_hash != Json::null() { @base.fail("suggestion_open_record_invalid") }
    } else if status == "applied" {
      let closed = @base.text(closed_at)
      let result = @base.text(result_hash)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") || !valid_hash(result) { @base.fail("suggestion_applied_record_invalid") }
    } else if status == "cancelled" {
      let closed = @base.text(closed_at)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") ||
        result_hash != Json::null() {
        @base.fail("suggestion_cancelled_record_invalid")
      }
    } else { @base.fail("suggestion_status_invalid") }
    let key = string("key")
    if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("suggestion_idempotency_key_invalid") }
  } else if entry.path.has_prefix("state/overview/") {
    @base.keys(value, ["id", "baseline", "purpose_hash", "page_hashes", "created_at", "status", "key", "closed_at", "result_hash"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/overview/" + id + ".json" ||
      !valid_hash(string("baseline")) || !valid_hash(string("purpose_hash")) {
      @base.fail("overview_record_identity_invalid")
    }
    match @base.field(value, "page_hashes") {
      Object(hashes) => for (page, hash) in hashes { @base.path(page); if !valid_hash(@base.text(hash)) { @base.fail("overview_page_hash_invalid") } }
      _ => @base.fail("overview_page_hashes_invalid")
    }
    let created_at = string("created_at")
    if created_at.length() < 10 || created_at.contains("\n") || created_at.contains("\r") { @base.fail("overview_created_at_invalid") }
    let status = string("status")
    let closed_at = @base.field(value, "closed_at")
    let result_hash = @base.field(value, "result_hash")
    if status == "proposed" {
      if closed_at != Json::null() || result_hash != Json::null() { @base.fail("overview_open_record_invalid") }
    } else if status == "applied" {
      let closed = @base.text(closed_at)
      let result = @base.text(result_hash)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") || !valid_hash(result) { @base.fail("overview_applied_record_invalid") }
    } else if status == "cancelled" {
      let closed = @base.text(closed_at)
      if closed.length() < 10 || closed.contains("\n") || closed.contains("\r") ||
        result_hash != Json::null() {
        @base.fail("overview_cancelled_record_invalid")
      }
    } else { @base.fail("overview_status_invalid") }
    let key = string("key")
    if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("overview_idempotency_key_invalid") }
  } else if entry.path.has_prefix("state/evidence/") {
    @base.keys(value, ["id", "page", "page_hash", "claims", "superseded_by"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/evidence/" + id + ".json" {
      @base.fail("evidence_record_identity_invalid")
    }
    match optional_record_field(value, "superseded_by") {
      None => ()
      Some(value) => if !valid_hash(@base.text(value)) || @base.text(value) == id {
        @base.fail("evidence_superseded_by_invalid")
      }
    }
    let page = string("page")
    @base.path(page)
    let page_hash = string("page_hash")
    if page.is_empty() || !valid_hash(page_hash) { @base.fail("evidence_page_invalid") }
    let claims = @base.array(@base.field(value, "claims"))
    let identity = @base.hex_hash("evidence-v1\n" + @base.canonical({ "page": page, "page_hash": page_hash, "claims": claims.to_json() }))
    if id != identity { @base.fail("evidence_record_identity_mismatch") }
    if claims.length() < 1 || claims.length() > 128 { @base.fail("evidence_claims_count_invalid") }
    // Multiple ranges from one raw source are valid; exact duplicate claims
    // are rejected to keep the content-addressed record canonical.
    let seen : Map[String, Bool] = Map([])
    for claim in claims {
      @base.keys(claim, ["source", "body_start", "body_end", "quote", "source_start", "source_end", "source_quote"])
      let source = @base.text(@base.field(claim, "source"))
      @base.path(source)
      if !source.has_prefix("raw/") { @base.fail("evidence_source_invalid") }
      let bound = value => match value {
        Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()
        _ => raise @base.Fault("evidence_range_invalid")
      }
      let start = bound(@base.field(claim, "body_start"))
      let end = bound(@base.field(claim, "body_end"))
      if end <= start { @base.fail("evidence_range_invalid") }
      let quote = @base.text(@base.field(claim, "quote"))
      if quote.is_empty() || quote.length() > 65536 || quote.contains("\r") { @base.fail("evidence_quote_invalid") }
      let source_start = optional_record_field(claim, "source_start")
      let source_end = optional_record_field(claim, "source_end")
      let source_quote = optional_record_field(claim, "source_quote")
      match (source_start, source_end, source_quote) {
        (None, None, None) => ()
        (Some(start_value), Some(end_value), Some(quote_value)) => {
          let source_start = match start_value {
            Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()
            _ => raise @base.Fault("evidence_source_range_invalid")
          }
          let source_end = match end_value {
            Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()
            _ => raise @base.Fault("evidence_source_range_invalid")
          }
          if source_end <= source_start { @base.fail("evidence_source_range_invalid") }
          let source_quote = @base.text(quote_value)
          if source_quote.is_empty() || source_quote.length() > 65536 || source_quote.contains("\r") {
            @base.fail("evidence_source_quote_invalid")
          }
        }
        _ => @base.fail("evidence_source_binding_required")
      }
      let key = @base.canonical(claim)
      if seen.contains(key) { @base.fail("evidence_duplicate_claim") }
      seen[key] = true
    }
  } else if entry.path.has_prefix("state/memory/") {
    @base.keys(value, ["version", "id", "kind", "scope", "text", "conditions", "sources",
      "source_hashes", "status", "key", "created_at", "updated_at", "archived_at",
      "superseded_by", "supersedes", "pinned", "last_used_at", "note_hash"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/memory/" + id + ".json" {
      @base.fail("memory_record_identity_invalid")
    }
    memory_record(value, id)
  } else if entry.path.has_prefix("state/impacts/") {
    @base.keys(value, ["version", "id", "kind", "subject", "cause", "frozen", "current",
      "detail", "created_at", "updated_at", "status", "resolved_at", "dismissed", "key"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/impacts/" + id + ".json" {
      @base.fail("impact_record_identity_invalid")
    }
    impact_record(value, id)
  } else if entry.path.has_prefix("state/provider-jobs/") {
    @base.keys(value, ["id", "provider", "kind", "space", "key", "request", "request_hash", "status", "created_at", "updated_at", "closed_at", "result", "result_hash", "error", "worker", "lease_until"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/provider-jobs/" + id + ".json" { @base.fail("provider_job_record_identity_invalid") }
    let provider = string("provider")
    if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_job_name_invalid") }
    let kind = string("kind")
    if !["embedding", "search"].contains(kind) { @base.fail("provider_job_kind_invalid") }
    let space = @base.field(value, "space")
    @base.keys(space, ["id", "dimensions"])
    let space_id = @base.text(@base.field(space, "id"))
    if space_id.is_empty() || space_id.length() > 512 { @base.fail("provider_job_space_invalid") }
    match @base.field(space, "dimensions") {
      Number(n, ..) if n >= 1.0 && n <= 8192.0 && n == n.to_int().to_double() => ()
      _ => @base.fail("provider_job_dimensions_invalid")
    }
    let key = string("key")
    if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("provider_job_key_invalid") }
    let request = @base.field(value, "request")
    if kind == "embedding" {
      @base.keys(request, ["items", "text_recipe"])
      let items = @base.array(@base.field(request, "items"))
      if items.is_empty() || items.length() > 128 { @base.fail("provider_job_items_invalid") }
      for item in items {
        @base.keys(item, ["page", "sha256", "text", "truncated"])
        let page = @base.text(@base.field(item, "page"))
        let sha = @base.text(@base.field(item, "sha256"))
        let text = @base.text(@base.field(item, "text"))
        if page.is_empty() || page.length() > 1024 || !valid_hash(sha) || text.length() > 16384 { @base.fail("provider_job_embedding_item_invalid") }
        ignore(@base.boolean(@base.field(item, "truncated")))
      }
      if @base.text(@base.field(request, "text_recipe")) != "title-body-prefix16KiB-v1" { @base.fail("provider_job_text_recipe_invalid") }
    } else {
      @base.keys(request, ["query", "limit"])
      if @base.text(@base.field(request, "query")).length() > 4096 { @base.fail("provider_job_query_too_large") }
      match @base.field(request, "limit") {
        Number(n, ..) if n >= 1.0 && n <= 100.0 && n == n.to_int().to_double() => ()
        _ => @base.fail("provider_job_limit_invalid")
      }
    }
    let request_hash = string("request_hash")
    if !valid_hash(request_hash) || request_hash != @base.hex_hash(@base.canonical(request)) { @base.fail("provider_job_request_hash_invalid") }
    let status = string("status")
    if !["pending", "completed", "cancelled", "failed"].contains(status) { @base.fail("provider_job_status_invalid") }
    for field in ["created_at", "updated_at"] {
      let at = string(field)
      if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("provider_job_time_invalid: " + field) }
    }
    let closed = @base.field(value, "closed_at")
    let result = @base.field(value, "result")
    let result_hash = @base.field(value, "result_hash")
    let error = match value {
      Object(fields) => fields.get("error").unwrap_or(Json::null())
      _ => Json::null()
    }
    let worker = match value {
      Object(fields) => fields.get("worker").unwrap_or(Json::null())
      _ => Json::null()
    }
    let lease_until = match value {
      Object(fields) => fields.get("lease_until").unwrap_or(Json::null())
      _ => Json::null()
    }
    if (worker == Json::null()) != (lease_until == Json::null()) { @base.fail("provider_job_lease_pair_invalid") }
    if worker != Json::null() {
      let owner = @base.text(worker)
      if owner.is_empty() || owner.length() > 256 || owner.contains("\n") || owner.contains("\r") { @base.fail("provider_job_worker_invalid") }
      let lease = @base.text(lease_until)
      if lease.length() < 10 || lease.contains("\n") || lease.contains("\r") { @base.fail("provider_job_time_invalid: lease_until") }
    }
    if status == "pending" {
      if closed != Json::null() || result != Json::null() || result_hash != Json::null() || error != Json::null() { @base.fail("provider_job_pending_invalid") }
    } else {
      let closed_at = @base.text(closed)
      if closed_at.length() < 10 || closed_at.contains("\n") || closed_at.contains("\r") { @base.fail("provider_job_closed_at_invalid") }
      if status == "completed" {
        if result == Json::null() || error != Json::null() || !valid_hash(@base.text(result_hash)) || @base.text(result_hash) != @base.hex_hash(@base.canonical(result)) { @base.fail("provider_job_result_invalid") }
      } else if status == "cancelled" {
        if result != Json::null() || result_hash != Json::null() || error != Json::null() { @base.fail("provider_job_cancelled_result") }
      } else {
        if result != Json::null() || result_hash != Json::null() { @base.fail("provider_job_failed_result") }
        let failure = @base.text(error)
        if failure.is_empty() || failure.length() > 4096 || failure.contains("\n") || failure.contains("\r") { @base.fail("provider_job_error_invalid") }
      }
    }
  } else if entry.path.has_prefix("state/providers/") {
    @base.keys(value, ["id", "provider", "kind", "space", "capabilities", "protocol", "registered_at", "last_seen", "status", "closed_at"])
    let id = string("id")
    if !valid_hash(id) || entry.path != "state/providers/" + id + ".json" { @base.fail("provider_record_identity_invalid") }
    let provider = string("provider")
    if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_name_invalid") }
    let kind = string("kind")
    if !["embedding", "search"].contains(kind) { @base.fail("provider_kind_invalid") }
    let space = @base.field(value, "space")
    @base.keys(space, ["id", "dimensions"])
    let space_id = @base.text(@base.field(space, "id"))
    if space_id.is_empty() || space_id.length() > 512 { @base.fail("provider_space_invalid") }
    match @base.field(space, "dimensions") {
      Number(n, ..) if n >= 1.0 && n <= 8192.0 && n == n.to_int().to_double() => ()
      _ => @base.fail("provider_dimensions_invalid")
    }
    let capabilities = @base.strings(@base.field(value, "capabilities"))
    if capabilities.is_empty() || capabilities.length() > 16 { @base.fail("provider_capabilities_invalid") }
    let seen : Map[String, Bool] = Map([])
    for capability in capabilities {
      if capability.is_empty() || capability.length() > 64 || capability.contains("\n") || seen.contains(capability) { @base.fail("provider_capability_invalid") }
      seen[capability] = true
    }
    if kind == "embedding" && !capabilities.contains("embed") { @base.fail("provider_embed_capability_required") }
    if kind == "search" && !capabilities.contains("search") { @base.fail("provider_search_capability_required") }
    if string("protocol") != "memorycorridor-provider-v1" { @base.fail("provider_protocol_invalid") }
    for field in ["registered_at", "last_seen"] {
      let at = string(field)
      if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("provider_time_invalid: " + field) }
    }
    let status = string("status")
    let closed = @base.field(value, "closed_at")
    if status == "active" {
      if closed != Json::null() { @base.fail("provider_active_closed") }
    } else if status == "revoked" {
      let at = @base.text(closed)
      if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("provider_closed_at_invalid") }
    } else { @base.fail("provider_status_invalid") }
  } else if entry.path.has_prefix("state/events/") {
    let op = string("op")
    if op.is_empty() { @base.fail("event_operation_required") }
    let supported = [
      "source-missing", "page-archive", "page-restore", "provider-job-open",
      "provider-job-claim", "provider-job-heartbeat", "provider-job-completed",
      "provider-job-cancelled", "provider-job-failed", "import", "purpose-suggest",
      "purpose-apply", "purpose-cancel", "overview-apply", "overview-cancel",
      "quality-audit", "evidence-submit", "evidence-replace",
      "provider-register", "provider-unregister", "refresh", "review-resolve",
      "research-topic", "research-completed", "research-cancelled", "overview-suggest",
      "overview-apply", "ingest", "forget", "memory-submit", "memory-supersede",
      "memory-archive", "memory-restore", "memory-pin", "memory-use",
      "impact-open", "impact-resolve",
    ]
    if !supported.contains(op) { @base.fail("event_operation_unsupported: " + op) }
    if op == "source-missing" {
      @base.keys(value, ["op", "source", "source_hash"])
      let source = string("source")
      @base.path(source)
      if !source.has_prefix("raw/") || !valid_hash(string("source_hash")) { @base.fail("source_missing_event_invalid") }
      let expected = "state/events/source-missing-" + @base.hex_hash(source + "\n" + string("source_hash")) + ".json"
      if entry.path != expected { @base.fail("source_missing_event_identity_invalid") }
    } else if op == "page-archive" {
      @base.keys(value, ["version", "op", "page", "page_hash", "at", "reason"])
      if @base.field(value, "version") != Json::number(1.0) { @base.fail("page_archive_event_version_invalid") }
      let page = string("page")
      @base.path(page)
      let page_hash = string("page_hash")
      if !valid_hash(page_hash) { @base.fail("page_archive_event_hash_invalid") }
      let at = string("at")
      let reason = string("reason")
      if at.length() < 10 || at.contains("\n") || at.contains("\r") || reason.is_empty() || reason.length() > 1024 || reason.contains("\n") || reason.contains("\r") {
        @base.fail("page_archive_event_metadata_invalid")
      }
      let expected = "state/events/page-archive-" + @base.hex_hash(page + "\n" + page_hash + "\n" + at + "\n" + reason) + ".json"
      if entry.path != expected { @base.fail("page_archive_event_identity_invalid") }
    } else if op == "page-restore" {
      @base.keys(value, ["version", "op", "page", "page_hash", "archive", "at"])
      if @base.field(value, "version") != Json::number(1.0) { @base.fail("page_restore_event_version_invalid") }
      let page = string("page")
      @base.path(page)
      let page_hash = string("page_hash")
      if !valid_hash(page_hash) { @base.fail("page_restore_event_hash_invalid") }
      let archive = string("archive")
      @base.path(archive)
      if !archive.has_prefix("state/events/page-archive-") || !archive.has_suffix(".json") { @base.fail("page_restore_event_archive_invalid") }
      let at = string("at")
      if at.length() < 10 || at.contains("\n") || at.contains("\r") { @base.fail("page_restore_event_time_invalid") }
      let expected = "state/events/page-restore-" + @base.hex_hash(page + "\n" + page_hash + "\n" + archive + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("page_restore_event_identity_invalid") }
    } else if op == "provider-job-open" {
      @base.keys(value, ["op", "id", "provider", "kind", "at"])
      let id = string("id")
      event_hash(id, "provider_job_event_id_invalid")
      let provider = string("provider")
      if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_job_event_provider_invalid") }
      if !["embedding", "search"].contains(string("kind")) { @base.fail("provider_job_event_kind_invalid") }
      event_time(string("at"))
      let expected = "state/events/provider-job-open-" + id + ".json"
      if entry.path != expected { @base.fail("provider_job_event_identity_invalid") }
    } else if op == "provider-job-claim" || op == "provider-job-heartbeat" {
      @base.keys(value, ["op", "id", "worker", "lease_until", "at"])
      let id = string("id")
      event_hash(id, "provider_job_event_id_invalid")
      for field in ["worker", "lease_until", "at"] {
        let text = string(field)
        if text.is_empty() || text.contains("\n") || text.contains("\r") { @base.fail("provider_job_event_field_invalid: " + field) }
      }
      event_time(string("lease_until"))
      event_time(string("at"))
      let kind = if op == "provider-job-claim" { "claim" } else { "heartbeat" }
      let expected = "state/events/provider-job-" + kind + "-" + @base.hex_hash(string("worker") + "\n" + string("at") + "\n" + string("lease_until")) + "-" + id + ".json"
      if entry.path != expected { @base.fail("provider_job_event_identity_invalid") }
    } else if op == "provider-job-completed" || op == "provider-job-cancelled" {
      @base.keys(value, ["op", "id", "provider", "at"])
      let id = string("id")
      event_hash(id, "provider_job_event_id_invalid")
      let provider = string("provider")
      if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_job_event_provider_invalid") }
      event_time(string("at"))
      let kind = if op == "provider-job-completed" { "completed" } else { "cancelled" }
      let expected = "state/events/provider-job-" + kind + "-" + id + ".json"
      if entry.path != expected { @base.fail("provider_job_event_identity_invalid") }
    } else if op == "provider-job-failed" {
      @base.keys(value, ["op", "id", "error", "at"])
      let id = string("id")
      event_hash(id, "provider_job_event_id_invalid")
      let error = string("error")
      if error.is_empty() || error.length() > 4096 || error.contains("\n") || error.contains("\r") { @base.fail("provider_job_event_error_invalid") }
      event_time(string("at"))
      let expected = "state/events/provider-job-failed-" + id + ".json"
      if entry.path != expected { @base.fail("provider_job_event_identity_invalid") }
    } else if op == "import" {
      @base.keys(value, ["op", "version", "bundle", "format", "files", "pages", "broken", "at"])
      if @base.field(value, "version") != Json::number(1.0) { @base.fail("import_event_version_invalid") }
      let bundle = string("bundle")
      event_hash(bundle, "import_event_bundle_invalid")
      let format = string("format")
      if format.is_empty() || format.contains("\n") || format.contains("\r") { @base.fail("import_event_format_invalid") }
      ignore(@base.array(@base.field(value, "files")))
      ignore(@base.array(@base.field(value, "pages")))
      ignore(@base.array(@base.field(value, "broken")))
      event_time(string("at"))
      let expected = "state/events/import-" + bundle + ".json"
      if entry.path != expected { @base.fail("import_event_identity_invalid") }
    } else if op == "purpose-suggest" {
      @base.keys(value, ["op", "suggestion", "at", "key", "baseline", "purpose_hash"])
      let suggestion = string("suggestion")
      event_hash(suggestion, "purpose_event_suggestion_invalid")
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("purpose_event_key_invalid") }
      event_hash(string("baseline"), "purpose_event_baseline_invalid")
      event_hash(string("purpose_hash"), "purpose_event_hash_invalid")
      let expected = "state/events/purpose-suggest-" + suggestion + ".json"
      if entry.path != expected { @base.fail("purpose_event_identity_invalid") }
    } else if op == "purpose-apply" {
      @base.keys(value, ["op", "suggestion", "at", "result_hash"])
      let suggestion = string("suggestion")
      let result_hash = string("result_hash")
      event_hash(suggestion, "purpose_event_suggestion_invalid")
      event_time(string("at"))
      event_hash(result_hash, "purpose_event_result_invalid")
      let expected = "state/events/purpose-apply-" + suggestion + "-" + result_hash + ".json"
      if entry.path != expected { @base.fail("purpose_event_identity_invalid") }
    } else if op == "quality-audit" {
      @base.keys(value, ["op", "id", "at", "fingerprint", "issues", "reviews"])
      let id = string("id")
      event_hash(id, "quality_event_id_invalid")
      event_time(string("at"))
      event_hash(string("fingerprint"), "quality_event_fingerprint_invalid")
      ignore(@base.array(@base.field(value, "issues")))
      ignore(@base.array(@base.field(value, "reviews")))
      let expected = "state/events/quality-audit-" + id + ".json"
      if entry.path != expected { @base.fail("quality_event_identity_invalid") }
    } else if op == "evidence-submit" {
      @base.keys(value, ["op", "evidence", "page", "page_hash"])
      let evidence = string("evidence")
      event_hash(evidence, "evidence_event_id_invalid")
      @base.path(string("page"))
      event_hash(string("page_hash"), "evidence_event_page_hash_invalid")
      let expected = "state/events/evidence-" + evidence + ".json"
      if entry.path != expected { @base.fail("evidence_event_identity_invalid") }
    } else if op == "evidence-replace" {
      @base.keys(value, ["op", "evidence", "previous", "page", "page_hash"])
      let evidence = string("evidence")
      event_hash(evidence, "evidence_event_id_invalid")
      event_hash(string("previous"), "evidence_event_previous_invalid")
      @base.path(string("page"))
      event_hash(string("page_hash"), "evidence_event_page_hash_invalid")
      let expected = "state/events/evidence-replace-" + evidence + ".json"
      if entry.path != expected { @base.fail("evidence_event_identity_invalid") }
    } else if op == "provider-register" {
      @base.keys(value, ["op", "provider", "kind", "space", "at"])
      let provider = string("provider")
      if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_event_name_invalid") }
      if !["embedding", "search"].contains(string("kind")) { @base.fail("provider_event_kind_invalid") }
      let space = @base.field(value, "space")
      @base.keys(space, ["id", "dimensions"])
      let space_id = @base.text(@base.field(space, "id"))
      if space_id.is_empty() || space_id.length() > 512 || space_id.contains("\n") || space_id.contains("\r") { @base.fail("provider_event_space_invalid") }
      ignore(@base.field(space, "dimensions"))
      event_time(string("at"))
      let id = @base.hex_hash("provider-v1\n" + provider)
      let expected = "state/events/provider-register-" + id + ".json"
      if entry.path != expected { @base.fail("provider_event_identity_invalid") }
    } else if op == "provider-unregister" {
      @base.keys(value, ["op", "provider", "at"])
      let provider = string("provider")
      if provider.is_empty() || provider.length() > 128 || provider.contains("\n") || provider.contains("\r") { @base.fail("provider_event_name_invalid") }
      event_time(string("at"))
      let expected = "state/events/provider-revoke-" + @base.hex_hash(provider + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("provider_event_identity_invalid") }
    } else if op == "refresh" {
      @base.keys(value, ["op", "before", "changes"])
      event_hash(string("before"), "refresh_event_baseline_invalid")
      ignore(@base.strings(@base.field(value, "changes")))
    } else if op == "review-resolve" {
      @base.keys(value, ["op", "review", "action", "key", "at", "predicate", "subject", "page", "source", "input_fingerprint"])
      event_hash(string("review"), "review_event_id_invalid")
      if !["create-page", "research", "skip"].contains(string("action")) { @base.fail("review_event_action_invalid") }
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("review_event_key_invalid") }
      event_time(string("at"))
      let nullable_text = field => match @base.field(value, field) {
        Null => ()
        String(text) => if text.contains("\n") || text.contains("\r") { @base.fail("review_event_field_invalid: " + field) }
        _ => @base.fail("review_event_field_invalid: " + field)
      }
      nullable_text("predicate")
      nullable_text("subject")
      match @base.field(value, "page") { Null => (); String(page) => @base.path(page); _ => @base.fail("review_event_page_invalid") }
      match @base.field(value, "source") { Null => (); String(source) => @base.path(source); _ => @base.fail("review_event_source_invalid") }
      match @base.field(value, "input_fingerprint") { Null => (); String(hash) => event_hash(hash, "review_event_fingerprint_invalid"); _ => @base.fail("review_event_fingerprint_invalid") }
      let expected = "state/events/review-" + string("review") + "-" + @base.hex_hash(key) + ".json"
      if entry.path != expected { @base.fail("review_event_identity_invalid") }
    } else if op == "research-topic" {
      @base.keys(value, ["op", "research", "topic", "queries", "at", "key"])
      let research = string("research")
      event_hash(research, "research_event_id_invalid")
      let topic = string("topic")
      if topic.is_empty() || topic.length() > 512 || topic.contains("\n") || topic.contains("\r") { @base.fail("research_event_topic_invalid") }
      let queries = @base.strings(@base.field(value, "queries"))
      if queries.is_empty() || queries.length() > 16 { @base.fail("research_event_queries_invalid") }
      for query in queries { if query.is_empty() || query.length() > 256 || query.contains("\n") || query.contains("\r") { @base.fail("research_event_query_invalid") } }
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("research_event_key_invalid") }
      let expected = "state/events/research-" + research + ".json"
      if entry.path != expected { @base.fail("research_event_identity_invalid") }
    } else if op == "research-completed" || op == "research-cancelled" {
      @base.keys(value, ["op", "research", "at", "sources"])
      let research = string("research")
      event_hash(research, "research_event_id_invalid")
      event_time(string("at"))
      let sources = @base.strings(@base.field(value, "sources"))
      if op == "research-completed" && sources.is_empty() { @base.fail("research_event_sources_required") }
      let seen : Map[String, Bool] = Map([])
      for source in sources {
        @base.path(source)
        if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("research_event_source_invalid") }
        seen[source] = true
      }
      let target = if op == "research-completed" { "completed" } else { "cancelled" }
      let expected = "state/events/research-" + target + "-" + research + "-" + @base.hex_hash(string("at") + "\n" + @base.canonical(sources.to_json())) + ".json"
      if entry.path != expected { @base.fail("research_event_identity_invalid") }
    } else if op == "overview-suggest" {
      @base.keys(value, ["op", "suggestion", "at", "key", "baseline", "purpose_hash"])
      let suggestion = string("suggestion")
      event_hash(suggestion, "overview_event_suggestion_invalid")
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") { @base.fail("overview_event_key_invalid") }
      event_hash(string("baseline"), "overview_event_baseline_invalid")
      event_hash(string("purpose_hash"), "overview_event_purpose_hash_invalid")
      let expected = "state/events/overview-suggest-" + suggestion + ".json"
      if entry.path != expected { @base.fail("overview_event_identity_invalid") }
    } else if op == "purpose-cancel" {
      @base.keys(value, ["op", "suggestion", "at"])
      let suggestion = string("suggestion")
      event_hash(suggestion, "purpose_event_suggestion_invalid")
      event_time(string("at"))
      let expected = "state/events/purpose-cancel-" + suggestion + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("purpose_event_identity_invalid") }
    } else if op == "overview-cancel" {
      @base.keys(value, ["op", "suggestion", "at"])
      let suggestion = string("suggestion")
      event_hash(suggestion, "overview_event_suggestion_invalid")
      event_time(string("at"))
      let expected = "state/events/overview-cancel-" + suggestion + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("overview_event_identity_invalid") }
    } else if op == "overview-apply" {
      @base.keys(value, ["op", "suggestion", "at", "result_hash", "sources"])
      let suggestion = string("suggestion")
      let result_hash = string("result_hash")
      event_hash(suggestion, "overview_event_suggestion_invalid")
      event_time(string("at"))
      event_hash(result_hash, "overview_event_result_invalid")
      let sources = @base.strings(@base.field(value, "sources"))
      let seen : Map[String, Bool] = Map([])
      for source in sources { @base.path(source); if !source.has_prefix("raw/") || seen.contains(source) { @base.fail("overview_event_source_invalid") }; seen[source] = true }
      let expected = "state/events/overview-apply-" + suggestion + "-" + result_hash + ".json"
      if entry.path != expected { @base.fail("overview_event_identity_invalid") }
    } else if op == "memory-submit" {
      @base.keys(value, ["op", "memory", "at", "key", "note_hash", "supersedes"])
      let memory = string("memory")
      event_hash(memory, "memory_event_id_invalid")
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
        @base.fail("memory_event_key_invalid")
      }
      event_hash(string("note_hash"), "memory_event_note_hash_invalid")
      ignore(memory_nullable_hash(@base.field(value, "supersedes"), "supersedes", memory))
      let expected = "state/events/memory-submit-" + memory + ".json"
      if entry.path != expected { @base.fail("memory_event_identity_invalid") }
    } else if op == "memory-supersede" {
      // The writer shares one event shape with memory-submit and carries the
      // replaced note in `supersedes`; the path binds both ids.
      @base.keys(value, ["op", "memory", "at", "key", "note_hash", "supersedes"])
      let memory = string("memory")
      event_hash(memory, "memory_event_id_invalid")
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
        @base.fail("memory_event_key_invalid")
      }
      event_hash(string("note_hash"), "memory_event_note_hash_invalid")
      let replaced = match memory_nullable_hash(@base.field(value, "supersedes"), "supersedes", memory) {
        None => raise @base.Fault("memory_event_previous_invalid")
        Some(value) => value
      }
      let expected = "state/events/memory-supersede-" + replaced + "-" + memory + ".json"
      if entry.path != expected { @base.fail("memory_event_identity_invalid") }
    } else if op == "memory-archive" || op == "memory-restore" {
      @base.keys(value, ["op", "memory", "at"])
      let memory = string("memory")
      event_hash(memory, "memory_event_id_invalid")
      event_time(string("at"))
      let expected = "state/events/" + op + "-" + memory + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("memory_event_identity_invalid") }
    } else if op == "impact-open" {
      @base.keys(value, ["op", "impact", "at", "key", "kind", "subject", "cause", "frozen", "current"])
      let impact = string("impact")
      event_hash(impact, "impact_event_id_invalid")
      event_time(string("at"))
      let key = string("key")
      if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
        @base.fail("impact_event_key_invalid")
      }
      let kind = string("kind")
      impact_kind(kind)
      impact_subject(string("subject"))
      impact_cause(string("cause"))
      event_hash(string("frozen"), "impact_event_frozen_invalid")
      event_hash(string("current"), "impact_event_current_invalid")
      if impact != impact_id(kind, string("subject"), string("cause")) {
        @base.fail("impact_event_identity_invalid")
      }
      let expected = "state/events/impact-open-" + impact + "-" +
        @base.hex_hash(key + "\n" + string("current") + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("impact_event_path_invalid") }
    } else if op == "impact-resolve" {
      @base.keys(value, ["op", "impact", "at"])
      let impact = string("impact")
      event_hash(impact, "impact_event_id_invalid")
      event_time(string("at"))
      let expected = "state/events/impact-resolve-" + impact + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("impact_event_path_invalid") }
    } else if op == "memory-pin" {
      @base.keys(value, ["op", "memory", "at", "pinned"])
      let memory = string("memory")
      event_hash(memory, "memory_event_id_invalid")
      event_time(string("at"))
      let pinned = @base.boolean(@base.field(value, "pinned"))
      ignore(pinned)
      let expected = "state/events/memory-pin-" + memory + "-" +
        @base.hex_hash(pinned.to_string() + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("memory_event_identity_invalid") }
    } else if op == "ingest" {
      @base.keys(value, ["op", "order", "source", "at", "pages"])
      let order = string("order")
      event_hash(order, "ingest_event_order_invalid")
      @base.path(string("source"))
      if !string("source").has_prefix("raw/") { @base.fail("ingest_event_source_invalid") }
      event_time(string("at"))
      // `pages` is optional: commits recorded before publication hashes were
      // logged simply have no per-page history, and must stay readable.
      match optional_record_field(value, "pages") {
        None => ()
        Some(Object(hashes)) => for (page, hash) in hashes {
          @base.path(page)
          if !valid_hash(@base.text(hash)) { @base.fail("ingest_event_page_hash_invalid") }
        }
        Some(_) => @base.fail("ingest_event_pages_invalid")
      }
      let expected = "state/events/" + order + ".json"
      if entry.path != expected { @base.fail("ingest_event_identity_invalid") }
    } else if op == "forget" {
      @base.keys(value, ["op", "source", "at", "invalidated"])
      @base.path(string("source"))
      if !string("source").has_prefix("raw/") { @base.fail("forget_event_source_invalid") }
      event_time(string("at"))
      let invalidated = @base.strings(@base.field(value, "invalidated"))
      for page in invalidated { @base.path(page) }
    }
  } else if entry.kind == "vector" {
    @base.keys(value, ["page", "sha256", "space", "values"])
    @base.path(string("page"))
    if !valid_hash(string("sha256")) { @base.fail("vector_record_hash_invalid") }
    let space = @base.field(value, "space")
    @base.keys(space, ["id", "dimensions"])
    let id = @base.text(@base.field(space, "id"))
    if id.is_empty() || id.length() > 512 { @base.fail("vector_record_space_invalid") }
    let count = match @base.field(space, "dimensions") {
      Number(n, ..) if n >= 1.0 && n <= 8192.0 && n == n.to_int().to_double() => n.to_int()
      _ => raise @base.Fault("vector_record_dimensions_invalid")
    }
    let values = @base.array(@base.field(value, "values"))
    if values.length() != count { @base.fail("vector_record_dimensions_mismatch") }
    let mut nonzero = false
    for v in values {
      match v {
        Number(n, ..) if !n.is_inf() && !n.is_nan() => if n != 0.0 { nonzero = true }
        _ => @base.fail("vector_record_nonfinite")
      }
    }
    if !nonzero { @base.fail("vector_record_zero_norm") }
  } else { @base.fail("state_record_path_unsupported") }
}
