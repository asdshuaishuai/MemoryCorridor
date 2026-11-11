// Dream face (续二十八): offline, deterministic consolidation over the
// realized knowledge state. Mapping to the three RSI works this implements
// the engine-side half of:
//
//   Dream-RSI    : "dream" cheaply inside a replay simulator built from
//                  accumulated history instead of paying for online rollouts.
//                  dream-plan is a read-only dream over the vault's own
//                  deterministic signals -- no model call, no writes.
//   RSI-Anything : an updated system is only retained after compatibility
//                  checks. dream-close refuses a "retained" decision that
//                  regressed lint or lost evidence coverage vs the round's
//                  baseline.
//   Harness²     : propose -> probe -> lesson rounds. Every round is a
//                  persisted ledger entry (state/dreams) bound to the exact
//                  fingerprint it was dreamed on, with a deterministic
//                  before/after delta available for experience extraction.
//
// The core never calls a model or the network; the host supplies whatever
// creative edits the round applies through the ordinary commit flow.

priv struct DreamMetrics {
  pages : Int
  stale_pages : Int
  lint_errors : Int
  lint_warnings : Int
  redundant_pages : Int
  uncovered_sources : Int
  sparse_topics : Int
  missing_vectors : Int
}

fn dream_metrics_json(metrics : DreamMetrics) -> Json {
  {
    "pages": metrics.pages,
    "stale_pages": metrics.stale_pages,
    "lint_errors": metrics.lint_errors,
    "lint_warnings": metrics.lint_warnings,
    "redundant_pages": metrics.redundant_pages,
    "uncovered_sources": metrics.uncovered_sources,
    "sparse_topics": metrics.sparse_topics,
    "missing_vectors": metrics.missing_vectors,
  }
}

fn dream_json_int(value : Json, field : String) -> Int raise @base.Fault {
  match @base.field(value, field) {
    Number(n, ..) if n >= 0.0 && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("dream_integer_invalid: " + field)
  }
}

fn dream_hash_ok(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

fn dream_time(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") { @base.fail("dream_time_invalid") }
}

fn dream_space_from(value : Json) -> @index.VectorSpace? raise @base.Fault {
  if value == Json::null() { None } else { Some(@index.space_from_json(value)) }
}

fn dream_space(request : Json) -> @index.VectorSpace? raise @base.Fault {
  match optional(request, "space") {
    None => None
    Some(value) => dream_space_from(value)
  }
}

fn dream_space_json(space : @index.VectorSpace?) -> Json {
  match space {
    None => Json::null()
    Some(value) => value.to_json()
  }
}

// Same closed shape the record validator enforces (core/records.mbt), applied
// BEFORE the write so an invalid policy can never reach the vault.
fn dream_policy_shape(value : Json) -> Unit raise @base.Fault {
  match value {
    Object(fields) => {
      if fields.length() > 8 { @base.fail("dream_policy_invalid") }
      for (key, v) in fields {
        if key.is_empty() || key.length() > 64 || key.contains("\n") || key.contains("\r") {
          @base.fail("dream_policy_key_invalid")
        }
        match v {
          Number(_) => ()
          True => ()
          False => ()
          String(text) => if text.length() > 64 || text.contains("\n") || text.contains("\r") {
            @base.fail("dream_policy_value_invalid")
          }
          _ => raise @base.Fault("dream_policy_value_invalid")
        }
      }
    }
    _ => raise @base.Fault("dream_policy_invalid")
  }
}

fn dream_metrics(
  store : @vault.Storage, entries : Array[@core.Entry], space : @index.VectorSpace?,
) -> DreamMetrics raise @base.Fault {
  let lint = lint_result(store, (store.read)("index.mbt.md"))
  let violations = @base.array(@base.field(lint, "violations"))
  let redundant = violations.filter(v => @base.text(@base.field(v, "predicate")) == "redundant_page").length()
  let referenced : Map[String, Bool] = Map([])
  for entry in entries {
    if @core.is_page(entry) {
      for source in entry.sources { referenced[source] = true }
    }
  }
  let uncovered = entries.filter(e => e.kind == "raw" && !e.stale && !referenced.contains(e.id)).length()
  let topic_views = @base.array(@base.field(topics(store, entries), "topics"))
  let sparse = topic_views.filter(t => @base.array(@base.field(t, "links")).length() < 2).length()
  let missing = match space {
    None => 0
    Some(value) => {
      // limit 1 keeps the text/image payload minimal: the count is
      // items + remaining, exactly what embedding-plan would hand the host.
      let plan = embedding_plan(store, entries, { "space": value.to_json(), "limit": 1 })
      @base.array(@base.field(plan, "items")).length() + dream_json_int(plan, "remaining")
    }
  }
  {
    pages: entries.filter(e => @core.is_page(e) && !e.stale).length(),
    stale_pages: entries.filter(e => @core.is_page(e) && e.stale).length(),
    lint_errors: dream_json_int(lint, "errors"),
    lint_warnings: dream_json_int(lint, "warnings"),
    redundant_pages: redundant,
    uncovered_sources: uncovered,
    sparse_topics: sparse,
    missing_vectors: missing,
  }
}

// The deterministic opportunity set, sorted by (kind rank, id). Rank encodes
// the same priority the lint predicates use: errors before warnings, then
// structural gaps, then coverage nudges.
fn dream_opportunities(
  store : @vault.Storage, entries : Array[@core.Entry], space : @index.VectorSpace?,
) -> Array[Json] raise @base.Fault {
  let rows : Array[(Int, String, Json)] = []
  let lint = lint_result(store, (store.read)("index.mbt.md"))
  for violation in @base.array(@base.field(lint, "violations")) {
    let severity = @base.text(@base.field(violation, "severity"))
    let subject = @base.text(@base.field(violation, "subject"))
    let path = @base.text(@base.field(violation, "path"))
    let id = if subject != "" { subject } else { path }
    let rank = if severity == "error" { 0 } else { 1 }
    rows.push((rank, id, {
      "kind": "lint",
      "id": id,
      "severity": severity,
      "predicate": @base.text(@base.field(violation, "predicate")),
      "detail": @base.text(@base.field(violation, "detail")),
      "fix": @base.text(@base.field(violation, "fix")),
    }))
  }
  let referenced : Map[String, Bool] = Map([])
  for entry in entries {
    if @core.is_page(entry) {
      for source in entry.sources { referenced[source] = true }
    }
  }
  for entry in entries {
    if entry.kind == "raw" && !entry.stale && !referenced.contains(entry.id) {
      rows.push((2, entry.id, {
        "kind": "uncovered_source",
        "id": entry.id,
        "detail": "no page references this raw source",
      }))
    }
  }
  for entry in entries {
    if @core.is_page(entry) && entry.stale {
      rows.push((3, entry.id, {
        "kind": "stale_page",
        "id": entry.id,
        "detail": "source drift pending re-analysis",
      }))
    }
  }
  for view in @base.array(@base.field(topics(store, entries), "topics")) {
    if @base.array(@base.field(view, "links")).length() < 2 {
      let id = @base.text(@base.field(view, "id"))
      rows.push((4, id, {
        "kind": "sparse_topic",
        "id": id,
        "detail": "synthesis page links fewer than two pages; expand or merge",
      }))
    }
  }
  match space {
    None => ()
    Some(value) => {
      let plan = embedding_plan(store, entries, { "space": value.to_json(), "limit": 128 })
      for item in @base.array(@base.field(plan, "items")) {
        let id = @base.text(@base.field(item, "page"))
        rows.push((5, id, {
          "kind": "missing_vector",
          "id": id,
          "detail": "no current vector for space " + value.id,
        }))
      }
    }
  }
  rows.sort_by((a, b) => if a.0 != b.0 { a.0 - b.0 } else { @base.compare(a.1, b.1) })
  rows.map(row => row.2)
}

pub fn dream_plan(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "space", "limit"])
  let space = dream_space(request)
  let limit = integer(request, "limit", 50, 1, 500)
  let metrics = dream_metrics(store, entries, space)
  let all = dream_opportunities(store, entries, space)
  let listed = all[:Int::min(limit, all.length())]
  {
    "space": dream_space_json(space),
    "metrics": dream_metrics_json(metrics),
    "opportunities": listed.to_json(),
    "remaining": all.length() - listed.length(),
    "report_hash": @base.hex_hash(@base.canonical(all.to_json())),
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn dream_path(id : String) -> String {
  "state/dreams/" + id + ".json"
}

fn dream_id(baseline : String, policy : Json, space : Json, at : String) -> String {
  @base.hex_hash("dream-v1\n" + baseline + "\n" + @base.canonical(policy) + "\n" + @base.canonical(space) + "\n" + at)
}

pub fn dream_open(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "baseline", "policy", "space", "at"])
  let baseline = @base.text(@base.field(request, "baseline"))
  let space = dream_space(request)
  let policy = match optional(request, "policy") {
    None => {
      let empty : Map[String, Json] = Map([])
      Json::object(empty)
    }
    Some(value) => value
  }
  dream_policy_shape(policy)
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let space_json = dream_space_json(space)
  let id = dream_id(baseline, policy, space_json, at)
  let path = dream_path(id)
  // Replay is checked BEFORE the baseline comparison: opening a round writes a
  // state record and therefore moves the vault fingerprint, so the original
  // baseline never matches again. Identity (baseline, policy, space, at)
  // determines the id; an existing record means this exact round already ran.
  match (store.read)(path) {
    Some(existing) => {
      let old = @base.parse(existing)
      return { "id": id, "status": @base.text(@base.field(old, "status")), "replayed": true, "path": path }
    }
    None => ()
  }
  if baseline != @vault.fingerprint(entries) { @base.fail("dream_stale_baseline") }
  let metrics = dream_metrics(store, entries, space)
  let all = dream_opportunities(store, entries, space)
  let record : Json = {
    "id": id,
    "at": at,
    "baseline": baseline,
    "policy": policy,
    "space": dream_space_json(space),
    "metrics": dream_metrics_json(metrics),
    "opportunities_hash": @base.hex_hash(@base.canonical(all.to_json())),
    "status": "open",
    "closed_at": Json::null(),
    "decision": Json::null(),
    "note": Json::null(),
    "outcome": Json::null(),
  }
  let content = @base.canonical(record)
  let event_path = "state/events/dream-open-" + id + "-" + @base.hex_hash(at) + ".json"
  let event_content = @base.canonical({ "op": "dream-open", "dream": id, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": "open", "replayed": false, "path": path }
}

pub fn dream_close(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "id", "decision", "at", "note"])
  let id = @base.text(@base.field(request, "id"))
  if !dream_hash_ok(id) { @base.fail("dream_id_invalid") }
  let path = dream_path(id)
  let text = match (store.read)(path) {
    None => { @base.fail("dream_not_found: " + id); "" }
    Some(value) => value
  }
  let record = @base.parse(text)
  let decision = @base.text(@base.field(request, "decision"))
  if !["retained", "rejected"].contains(decision) { @base.fail("dream_decision_invalid") }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let note = match optional(request, "note") {
    None => Json::null()
    Some(value) => {
      if value == Json::null() { Json::null() } else {
        let n = @base.text(value)
        if n.length() > 1024 || n.contains("\n") || n.contains("\r") { @base.fail("dream_note_invalid") }
        n.to_json()
      }
    }
  }
  let status = @base.text(@base.field(record, "status"))
  if status != "open" {
    let same = @base.text(@base.field(record, "decision")) == decision &&
      @base.text(@base.field(record, "closed_at")) == at &&
      @base.field(record, "note") == note
    if same {
      return { "id": id, "status": status, "replayed": true }
    }
    @base.fail("dream_terminal: " + id)
  }
  let base_metrics = @base.field(record, "metrics")
  let record_space = dream_space_from(@base.field(record, "space"))
  let current = dream_metrics(store, entries, record_space)
  // Compatibility checks (RSI-Anything): retention may not regress lint or
  // lose evidence coverage relative to the round's baseline snapshot.
  if decision == "retained" {
    if current.lint_errors > dream_json_int(base_metrics, "lint_errors") { @base.fail("dream_compat_lint_regression") }
    if current.uncovered_sources > dream_json_int(base_metrics, "uncovered_sources") {
      @base.fail("dream_compat_evidence_loss")
    }
  }
  let delta : Json = {
    "pages": current.pages - dream_json_int(base_metrics, "pages"),
    "stale_pages": current.stale_pages - dream_json_int(base_metrics, "stale_pages"),
    "lint_errors": current.lint_errors - dream_json_int(base_metrics, "lint_errors"),
    "lint_warnings": current.lint_warnings - dream_json_int(base_metrics, "lint_warnings"),
    "redundant_pages": current.redundant_pages - dream_json_int(base_metrics, "redundant_pages"),
    "uncovered_sources": current.uncovered_sources - dream_json_int(base_metrics, "uncovered_sources"),
    "sparse_topics": current.sparse_topics - dream_json_int(base_metrics, "sparse_topics"),
    "missing_vectors": current.missing_vectors - dream_json_int(base_metrics, "missing_vectors"),
  }
  let updated : Json = {
    "id": id,
    "at": @base.text(@base.field(record, "at")),
    "baseline": @base.text(@base.field(record, "baseline")),
    "policy": @base.field(record, "policy"),
    "space": @base.field(record, "space"),
    "metrics": base_metrics,
    "opportunities_hash": @base.text(@base.field(record, "opportunities_hash")),
    "status": decision,
    "closed_at": at,
    "decision": decision,
    "note": note,
    "outcome": { "metrics": dream_metrics_json(current), "delta": delta },
  }
  let content = @base.canonical(updated)
  let event_path = "state/events/dream-close-" + id + "-" +
    @base.hex_hash(decision + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "dream-close", "dream": id,
    "decision": decision, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": decision, "replayed": false, "outcome": { "metrics": dream_metrics_json(current), "delta": delta } }
}

pub fn dream_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let rows = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/dreams/"))
  rows.sort_by((a, b) => @base.compare(a.id, b.id))
  let dreams : Array[Json] = []
  let mut open = 0
  let mut retained = 0
  let mut rejected = 0
  for entry in rows {
    let record = @base.parse(@vault.required(store, entry.path))
    let status = @base.text(@base.field(record, "status"))
    if status == "open" {
      open = open + 1
    } else if status == "retained" {
      retained = retained + 1
    } else {
      rejected = rejected + 1
    }
    dreams.push({
      "id": @base.text(@base.field(record, "id")),
      "at": @base.text(@base.field(record, "at")),
      "status": status,
      "baseline": @base.text(@base.field(record, "baseline")),
      "metrics": @base.field(record, "metrics"),
      "decision": @base.field(record, "decision"),
      "closed_at": @base.field(record, "closed_at"),
      "outcome": @base.field(record, "outcome"),
    })
  }
  {
    "dreams": dreams.to_json(),
    "counts": { "open": open, "retained": retained, "rejected": rejected },
    "fingerprint": @vault.fingerprint(entries),
  }
}

// Cross-record lint (extending.md step 10): an open round whose baseline no
// longer matches the vault was dreamed on older bytes -- close it or reopen
// it against the current fingerprint instead of leaving it dangling.
fn lint_dream_rounds(store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  let current = @vault.fingerprint(entries)
  for entry in entries {
    if entry.kind != "state" || !entry.path.has_prefix("state/dreams/") { continue }
    let row = try { @base.parse(@vault.required(store, entry.path)) } catch { _ => continue }
    let status = try { @base.text(@base.field(row, "status")) } catch { _ => continue }
    let baseline = try { @base.text(@base.field(row, "baseline")) } catch { _ => continue }
    if status == "open" && baseline != current {
      lint_add(issues, "dream_round_stale", entry.id, entry.path,
        "an open dream round was dreamed on an older vault fingerprint",
        "close the round (retained/rejected) or reopen it against the current baseline", "warning")
    }
  }
}

pub fn dream(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  match @base.text(@base.field(request, "op")) {
    "dream-plan" => dream_plan(store, entries, request)
    "dream-open" => dream_open(store, entries, request)
    "dream-close" => dream_close(store, entries, request)
    "dream-list" => dream_list(store, entries)
    _ => raise @base.Fault("internal_dream_dispatch")
  }
}