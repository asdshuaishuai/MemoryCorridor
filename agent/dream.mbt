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
    let predicate = @base.text(@base.field(violation, "predicate"))
    // Engine bookkeeping warnings (cache staleness, round anchoring) are
    // operational, not knowledge deficiencies: they stay in metrics but must
    // never become improvement tasks (writing a task would re-trigger them).
    if ["cache_missing", "cache_invalid", "dream_round_stale"].contains(predicate) { continue }
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

// Knowledge-only fingerprint: state bookkeeping (rounds, work items, events)
// must not invalidate the round's opportunity set, while page/source drift must.
fn dream_knowledge_fingerprint(entries : Array[@core.Entry]) -> String {
  @vault.fingerprint(entries.filter(e => e.kind != "state"))
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
  let knowledge = dream_knowledge_fingerprint(entries)
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
    "knowledge": knowledge,
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
    // RSI: unattended work is not consent. A round with open/claimed tasks or
    // unanswered judgments can be rejected but never retained as done.
    for work in dream_work_rows(store, entries) {
      if dream_row_text(work, "round") == id {
        let work_status = dream_row_text(work, "status")
        if work_status == "pending" || work_status == "claimed" {
          @base.fail("dream_compat_unresolved")
        }
      }
    }
  }
  let driver_set : Map[String, Bool] = Map([])
  for work in dream_work_rows(store, entries) {
    if dream_row_text(work, "round") == id {
      let name = dream_row_text(work, "driver")
      if name != "" { driver_set[name] = true }
    }
  }
  let drivers = driver_set.keys().to_array()
  drivers.sort_by(@base.compare)
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
    "knowledge": @base.text(@base.field(record, "knowledge")),
    "policy": @base.field(record, "policy"),
    "space": @base.field(record, "space"),
    "metrics": base_metrics,
    "opportunities_hash": @base.text(@base.field(record, "opportunities_hash")),
    "status": decision,
    "closed_at": at,
    "decision": decision,
    "note": note,
    "outcome": { "metrics": dream_metrics_json(current), "delta": delta,
      "drivers": drivers.to_json() },
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
  { "id": id, "status": decision, "replayed": false,
    "outcome": { "metrics": dream_metrics_json(current), "delta": delta, "drivers": drivers.to_json() } }
}

pub fn dream_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  // `policy.json` is a cadence record, not a round; listing must skip it or
  // the ledger reader would demand a `status` field it does not have.
  let rows = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/dreams/") &&
    e.path != "state/dreams/policy.json")
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
  // Compare the knowledge-only fingerprint: the round's own bookkeeping (work
  // items, events) must not make it look stale, while page/source drift must.
  let current = dream_knowledge_fingerprint(entries)
  for entry in entries {
    if entry.kind != "state" || !entry.path.has_prefix("state/dreams/") { continue }
    let row = try { @base.parse(@vault.required(store, entry.path)) } catch { _ => continue }
    let status = try { @base.text(@base.field(row, "status")) } catch { _ => continue }
    let knowledge = try { @base.text(@base.field(row, "knowledge")) } catch { _ => continue }
    if status == "open" && knowledge != current {
      lint_add(issues, "dream_round_stale", entry.id, entry.path,
        "an open dream round was dreamed on an older vault fingerprint",
        "close the round (retained/rejected) or reopen it against the current baseline", "warning")
    }
  }
}

// ---- RSI work outbox (续二十九) -------------------------------------------
// The engine refuses to judge semantics or write prose; a work item is a
// structured question the external driver answers. Claims carry leases so a
// dead driver's tasks can be taken over, and retention cannot pass while the
// round still has open work or unanswered judgments.

const DREAM_WORK_MAX_PENDING : Int = 10

fn dream_work_path(id : String) -> String {
  "state/dream-work/" + id + ".json"
}

fn dream_work_id(round : String, kind : String, subject : String) -> String {
  @base.hex_hash("dream-work-v1\n" + round + "\n" + kind + "\n" + subject)
}

fn dream_driver(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 128 || value.contains("\n") || value.contains("\r") {
    @base.fail("dream_work_driver_invalid")
  }
}

fn dream_kind_priority(kind : String) -> Int {
  match kind {
    "lint" => 1
    "uncovered_source" => 2
    "stale_page" => 3
    "sparse_topic" => 4
    _ => 5
  }
}

fn dream_set(row : Json, pairs : Array[(String, Json)]) -> Json {
  match row {
    Object(fields) => {
      let copy = fields.copy()
      for (key, value) in pairs { copy[key] = value }
      Json::object(copy)
    }
    _ => row
  }
}

fn dream_row_text(row : Json, key : String) -> String raise @base.Fault {
  match @base.field(row, key) {
    String(text) => text
    _ => ""
  }
}

fn dream_work_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/dream-work/") {
      rows.push(@base.parse(@vault.required(store, entry.path)))
    }
  }
  rows
}

// Mirrors core/records.mbt's dream_work_result_shape at the request boundary,
// so an invalid proposal can never reach the vault (a write that fails the
// record validator would poison every later load).
fn dream_work_result_check(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, ["judgments", "proposals"])
  match @base.field(value, "judgments") {
    Object(fields) => {
      if fields.length() > 32 { @base.fail("dream_work_judgments_too_many") }
      for (key, v) in fields {
        if key.is_empty() || key.length() > 256 || key.contains("\n") || key.contains("\r") {
          @base.fail("dream_work_judgment_key_invalid")
        }
        match v {
          Number(_) => ()
          True => ()
          False => ()
          String(text) => if text.length() > 1024 || text.contains("\r") {
            @base.fail("dream_work_judgment_value_invalid")
          }
          _ => raise @base.Fault("dream_work_judgment_value_invalid")
        }
      }
    }
    _ => raise @base.Fault("dream_work_judgments_invalid")
  }
  let items = @base.array(@base.field(value, "proposals"))
  if items.length() > 32 { @base.fail("dream_work_proposals_too_many") }
  for item in items {
    @base.keys(item, ["page", "kind", "staged_path"])
    let page = @base.text(@base.field(item, "page"))
    @base.path(page)
    if !page.has_prefix("wiki/") { @base.fail("dream_work_proposal_page_invalid") }
    let kind = @base.text(@base.field(item, "kind"))
    if kind.is_empty() || kind.length() > 64 || kind.contains("\n") || kind.contains("\r") {
      @base.fail("dream_work_proposal_kind_invalid")
    }
    let staged = @base.text(@base.field(item, "staged_path"))
    @base.path(staged)
    if !staged.has_prefix("staging/") { @base.fail("dream_work_proposal_staged_invalid") }
  }
}

pub fn dream_work_open(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "round", "at", "limit"])
  let round = @base.text(@base.field(request, "round"))
  if !dream_hash_ok(round) { @base.fail("dream_work_round_invalid") }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let limit = integer(request, "limit", DREAM_WORK_MAX_PENDING, 1, 50)
  let round_path = dream_path(round)
  let round_text = match (store.read)(round_path) {
    None => {
      @base.fail("dream_not_found: " + round)
      ""
    }
    Some(value) => value
  }
  let round_row = @base.parse(round_text)
  if dream_row_text(round_row, "status") != "open" { @base.fail("dream_work_round_closed") }
  let baseline = dream_row_text(round_row, "baseline")
  if dream_row_text(round_row, "knowledge") != dream_knowledge_fingerprint(entries) {
    @base.fail("dream_stale_baseline")
  }
  let space = dream_space_from(@base.field(round_row, "space"))
  let rows = dream_work_rows(store, entries)
  let existing : Map[String, Bool] = Map([])
  let mut pending = 0
  for row in rows {
    existing[dream_row_text(row, "id")] = true
    let status = dream_row_text(row, "status")
    if status == "pending" || status == "claimed" { pending = pending + 1 }
  }
  if pending >= DREAM_WORK_MAX_PENDING { @base.fail("dream_work_backpressure") }
  let opportunities = dream_opportunities(store, entries, space)
  let changes : Array[@vault.Change] = []
  let mut next = entries
  let created : Array[String] = []
  let mut skipped = 0
  let cap = Int::min(limit, DREAM_WORK_MAX_PENDING - pending)
  for item in opportunities {
    if created.length() >= cap { break }
    let kind = @base.text(@base.field(item, "kind"))
    let subject = @base.text(@base.field(item, "id"))
    let id = dream_work_id(round, kind, subject)
    if existing.contains(id) {
      skipped = skipped + 1
      continue
    }
    let record : Json = {
      "id": id, "round": round, "baseline": baseline, "kind": kind, "subject": subject,
      "priority": dream_kind_priority(kind), "status": "pending", "driver": Json::null(),
      "lease_until": Json::null(), "created_at": at, "closed_at": Json::null(),
      "result": Json::null(), "error": Json::null(),
    }
    let content = @base.canonical(record)
    let path = dream_work_path(id)
    let event_path = "state/events/dream-work-open-" + id + "-" + @base.hex_hash(at) + ".json"
    let event_content = @base.canonical({ "op": "dream-work-open", "work": id, "round": round, "at": at })
    changes.push({ path, before: None, after: Some(content) })
    changes.push({ path: event_path, before: None, after: Some(event_content) })
    next = upsert(upsert(next, { id: path, path, kind: "state", format: "json",
      sha256: @base.hex_hash(content), sources: [], stale: false }),
      { id: event_path, path: event_path, kind: "state", format: "json",
        sha256: @base.hex_hash(event_content), sources: [], stale: false })
    existing[id] = true
    created.push(id)
  }
  if !changes.is_empty() {
    @vault.commit(store, @vault.fingerprint(entries), next, changes)
  }
  {
    "round": round,
    "created": created.length(),
    "skipped": skipped,
    "pending": pending + created.length(),
    "max_pending": DREAM_WORK_MAX_PENDING,
    "tasks": created.to_json(),
  }
}

pub fn dream_work_claim(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "id", "driver", "lease_until", "at"])
  let id = @base.text(@base.field(request, "id"))
  if !dream_hash_ok(id) { @base.fail("dream_work_id_invalid") }
  let path = dream_work_path(id)
  let text = match (store.read)(path) {
    None => {
      @base.fail("dream_work_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let driver = @base.text(@base.field(request, "driver"))
  dream_driver(driver)
  let lease = @base.text(@base.field(request, "lease_until"))
  dream_time(lease)
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  if @base.compare(lease, at) <= 0 { @base.fail("dream_work_lease_invalid") }
  let status = dream_row_text(row, "status")
  let old_driver = dream_row_text(row, "driver")
  let old_lease = dream_row_text(row, "lease_until")
  if status == "claimed" && old_driver == driver && old_lease == lease {
    return { "id": id, "status": "claimed", "driver": driver, "lease_until": lease, "replayed": true }
  }
  if status != "pending" {
    if status == "claimed" {
      if @base.compare(at, old_lease) <= 0 { @base.fail("dream_work_lease_held") }
    } else {
      @base.fail("dream_work_terminal: " + id)
    }
  }
  let updated = dream_set(row, [
    ("status", "claimed".to_json()), ("driver", driver.to_json()), ("lease_until", lease.to_json()),
  ])
  let content = @base.canonical(updated)
  let event_path = "state/events/dream-work-claim-" + id + "-" +
    @base.hex_hash(driver + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "dream-work-claim", "work": id,
    "driver": driver, "lease_until": lease, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": "claimed", "driver": driver, "lease_until": lease, "replayed": false }
}

pub fn dream_work_complete(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "id", "driver", "at", "result"])
  let id = @base.text(@base.field(request, "id"))
  if !dream_hash_ok(id) { @base.fail("dream_work_id_invalid") }
  let path = dream_work_path(id)
  let text = match (store.read)(path) {
    None => {
      @base.fail("dream_work_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let driver = @base.text(@base.field(request, "driver"))
  dream_driver(driver)
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let result = @base.field(request, "result")
  dream_work_result_check(result)
  let status = dream_row_text(row, "status")
  if status == "done" && dream_row_text(row, "driver") == driver &&
    dream_row_text(row, "closed_at") == at && @base.field(row, "result") == result {
    return { "id": id, "status": "done", "replayed": true }
  }
  if status != "claimed" { @base.fail("dream_work_terminal: " + id) }
  if dream_row_text(row, "driver") != driver { @base.fail("dream_work_not_owner") }
  let lease = dream_row_text(row, "lease_until")
  if @base.compare(at, lease) > 0 { @base.fail("dream_work_lease_expired") }
  let updated = dream_set(row, [
    ("status", "done".to_json()), ("closed_at", at.to_json()), ("result", result),
  ])
  let content = @base.canonical(updated)
  let event_path = "state/events/dream-work-complete-" + id + "-" +
    @base.hex_hash(driver + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "dream-work-complete", "work": id,
    "driver": driver, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": "done", "replayed": false }
}

pub fn dream_work_fail(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "id", "driver", "reason", "at"])
  let id = @base.text(@base.field(request, "id"))
  if !dream_hash_ok(id) { @base.fail("dream_work_id_invalid") }
  let path = dream_work_path(id)
  let text = match (store.read)(path) {
    None => {
      @base.fail("dream_work_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let driver = @base.text(@base.field(request, "driver"))
  dream_driver(driver)
  let reason = @base.text(@base.field(request, "reason"))
  if reason.is_empty() || reason.length() > 1024 || reason.contains("\n") || reason.contains("\r") {
    @base.fail("dream_work_error_invalid")
  }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let status = dream_row_text(row, "status")
  if status == "failed" && dream_row_text(row, "driver") == driver &&
    dream_row_text(row, "closed_at") == at && dream_row_text(row, "error") == reason {
    return { "id": id, "status": "failed", "replayed": true }
  }
  if status != "claimed" { @base.fail("dream_work_terminal: " + id) }
  if dream_row_text(row, "driver") != driver { @base.fail("dream_work_not_owner") }
  let updated = dream_set(row, [
    ("status", "failed".to_json()), ("closed_at", at.to_json()), ("error", reason.to_json()),
  ])
  let content = @base.canonical(updated)
  let event_path = "state/events/dream-work-fail-" + id + "-" +
    @base.hex_hash(driver + "\n" + at + "\n" + reason) + ".json"
  let event_content = @base.canonical({ "op": "dream-work-fail", "work": id,
    "driver": driver, "reason": reason, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "id": id, "status": "failed", "replayed": false }
}

pub fn dream_work_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let keyed : Array[(String, Json)] = dream_work_rows(store, entries).map(
    row => (dream_row_text(row, "id"), row))
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  let rows = keyed.map(pair => pair.1)
  let items : Array[Json] = []
  let mut pending = 0
  let mut claimed = 0
  let mut done = 0
  let mut failed = 0
  for row in rows {
    let status = dream_row_text(row, "status")
    if status == "pending" {
      pending = pending + 1
    } else if status == "claimed" {
      claimed = claimed + 1
    } else if status == "done" {
      done = done + 1
    } else {
      failed = failed + 1
    }
    items.push({
      "id": dream_row_text(row, "id"),
      "round": dream_row_text(row, "round"),
      "kind": dream_row_text(row, "kind"),
      "subject": dream_row_text(row, "subject"),
      "priority": @base.field(row, "priority"),
      "status": status,
      "driver": @base.field(row, "driver"),
      "lease_until": @base.field(row, "lease_until"),
      "created_at": dream_row_text(row, "created_at"),
      "closed_at": @base.field(row, "closed_at"),
      "result": @base.field(row, "result"),
      "error": @base.field(row, "error"),
    })
  }
  {
    "work": items.to_json(),
    "counts": { "pending": pending, "claimed": claimed, "done": done, "failed": failed },
    "backpressure": { "max_pending": DREAM_WORK_MAX_PENDING,
      "open": pending + claimed, "at_capacity": pending + claimed >= DREAM_WORK_MAX_PENDING },
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- cadence contract (续三十一) ------------------------------------------
const DREAM_DEFAULT_DUE_AFTER : Int = 86400
const DREAM_DEFAULT_MIN_OPPORTUNITIES : Int = 1
const DREAM_DEFAULT_MAX_OPEN_ROUNDS : Int = 1

fn dream_policy_default() -> Json {
  {
    "due_after_seconds": DREAM_DEFAULT_DUE_AFTER,
    "min_opportunities": DREAM_DEFAULT_MIN_OPPORTUNITIES,
    "max_open_rounds": DREAM_DEFAULT_MAX_OPEN_ROUNDS,
  }
}

fn dream_policy_load(store : @vault.Storage) -> (Json, Bool, Json) raise @base.Fault {
  match (store.read)("state/dreams/policy.json") {
    None => (dream_policy_default(), true, Json::null())
    Some(text) => {
      let row = @base.parse(text)
      ({
        "due_after_seconds": @base.field(row, "due_after_seconds"),
        "min_opportunities": @base.field(row, "min_opportunities"),
        "max_open_rounds": @base.field(row, "max_open_rounds"),
      }, false, @base.field(row, "updated_at"))
    }
  }
}

fn dream_opt_bounded(request : Json, key : String, current : Json, low : Int, high : Int) -> Json raise @base.Fault {
  match optional(request, key) {
    None => current
    Some(value) => match value {
      Number(n, ..) if n >= low.to_double() && n <= high.to_double() && n == n.to_int().to_double() => n.to_json()
      _ => raise @base.Fault("invalid_integer: " + key + "; \{low}..\{high}")
    }
  }
}

pub fn dream_policy_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "due_after_seconds",
    "min_opportunities", "max_open_rounds", "at"])
  @vault.verify(store, entries)
  let (current, default, updated_at) = dream_policy_load(store)
  let has_arg = optional(request, "due_after_seconds") is Some(_) ||
    optional(request, "min_opportunities") is Some(_) ||
    optional(request, "max_open_rounds") is Some(_)
  if !has_arg {
    return { "policy": current, "default": default.to_json(), "updated_at": updated_at }
  }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let due = dream_opt_bounded(request, "due_after_seconds",
    @base.field(current, "due_after_seconds"), 0, 2592000)
  let min_opp = dream_opt_bounded(request, "min_opportunities",
    @base.field(current, "min_opportunities"), 0, 500)
  let max_open = dream_opt_bounded(request, "max_open_rounds",
    @base.field(current, "max_open_rounds"), 1, 8)
  let params : Json = {
    "due_after_seconds": due, "min_opportunities": min_opp, "max_open_rounds": max_open,
  }
  if @base.canonical(params) == @base.canonical(current) {
    return { "policy": params, "default": false.to_json(), "changed": false.to_json(),
      "replayed": true.to_json(), "updated_at": updated_at }
  }
  let path = "state/dreams/policy.json"
  let record : Json = {
    "version": 1, "due_after_seconds": due, "min_opportunities": min_opp,
    "max_open_rounds": max_open, "updated_at": at,
  }
  let content = @base.canonical(record)
  let event_path = "state/events/dream-policy-" +
    @base.hex_hash(@base.canonical(params) + "\n" + at) + ".json"
  let event_content = @base.canonical({
    "op": "dream-policy", "at": at, "due_after_seconds": due,
    "min_opportunities": min_opp, "max_open_rounds": max_open,
  })
  let changes : Array[@vault.Change] = [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, changes)
  { "policy": params, "default": false.to_json(), "changed": true.to_json(),
    "replayed": false.to_json(), "updated_at": at,
    "fingerprint": @vault.fingerprint(next) }
}

fn dream_digit(value : String, pos : Int) -> Int? {
  if pos >= value.length() { return None }
  let c = value[pos].to_int()
  if c >= 48 && c <= 57 { Some(c - 48) } else { None }
}

fn dream_two(value : String, pos : Int) -> Int? {
  match (dream_digit(value, pos), dream_digit(value, pos + 1)) {
    (Some(a), Some(b)) => Some(a * 10 + b)
    _ => None
  }
}

// Strict YYYY-MM-DDTHH:MM:SSZ; anything else means "no cooldown arithmetic".
fn dream_epoch(value : String) -> Int? {
  if value.length() != 20 { return None }
  if value[4].to_int() != 45 || value[7].to_int() != 45 || value[10].to_int() != 84 ||
    value[13].to_int() != 58 || value[16].to_int() != 58 || value[19].to_int() != 90 {
    return None
  }
  let year = match (dream_two(value, 0), dream_two(value, 2)) {
    (Some(a), Some(b)) => Some(a * 100 + b)
    _ => None
  }
  let month = dream_two(value, 5)
  let day = dream_two(value, 8)
  let hour = dream_two(value, 11)
  let minute = dream_two(value, 14)
  let second = dream_two(value, 17)
  match (year, month, day, hour, minute, second) {
    (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s)) => {
      if mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59 { return None }
      let yy = if mo <= 2 { y - 1 } else { y }
      let era = if yy >= 0 { yy / 400 } else { (yy - 399) / 400 }
      let yoe = yy - era * 400
      let mp = if mo > 2 { mo - 3 } else { mo + 9 }
      let doy = (153 * mp + 2) / 5 + d - 1
      let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
      let days = era * 146097 + doe - 719468
      Some(days * 86400 + h * 3600 + mi * 60 + s)
    }
    _ => None
  }
}

pub fn dream_due_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "at"])
  @vault.verify(store, entries)
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let (policy, default, updated_at) = dream_policy_load(store)
  let due_after = dream_json_int(policy, "due_after_seconds")
  let min_opp = dream_json_int(policy, "min_opportunities")
  let max_open = dream_json_int(policy, "max_open_rounds")
  let mut open_rounds = 0
  let mut last_closed = ""
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/dreams/") &&
      entry.path != "state/dreams/policy.json" {
      let row = @base.parse(@vault.required(store, entry.path))
      if dream_row_text(row, "status") == "open" { open_rounds = open_rounds + 1 }
      let closed = match optional(row, "closed_at") {
        Some(Json::String(value)) => value
        _ => ""
      }
      if closed != "" && (last_closed == "" || @base.compare(closed, last_closed) > 0) {
        last_closed = closed
      }
    }
  }
  let mut pending_work = 0
  for row in dream_work_rows(store, entries) {
    let status = dream_row_text(row, "status")
    if status == "pending" || status == "claimed" { pending_work = pending_work + 1 }
  }
  let opportunities = dream_opportunities(store, entries, None).length()
  let open_ok = open_rounds < max_open
  let opp_ok = opportunities >= min_opp
  let at_epoch = dream_epoch(at)
  let last_epoch = if last_closed == "" { None } else { dream_epoch(last_closed) }
  let cooldown_ok = match (at_epoch, last_epoch) {
    (Some(current), Some(last)) => current >= last + due_after
    _ => true
  }
  let next_due_in_seconds : Json = match (at_epoch, last_epoch) {
    (Some(current), Some(last)) => Int::max(0, last + due_after - current).to_json()
    _ => Json::null()
  }
  let reasons : Array[String] = []
  if !open_ok { reasons.push("open_rounds_capacity") }
  if !opp_ok { reasons.push("insufficient_opportunities") }
  if !cooldown_ok { reasons.push("cooldown") }
  {
    "due": (open_ok && opp_ok && cooldown_ok).to_json(),
    "reasons": reasons.to_json(),
    "open_rounds": open_rounds,
    "pending_work": pending_work,
    "opportunities": opportunities,
    "last_closed_at": if last_closed == "" { Json::null() } else { last_closed.to_json() },
    "next_due_in_seconds": next_due_in_seconds,
    "policy": policy,
    "default": default.to_json(),
    "updated_at": updated_at,
    "fingerprint": @vault.fingerprint(entries),
  }
}

pub fn dream(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  match @base.text(@base.field(request, "op")) {
    "dream-plan" => dream_plan(store, entries, request)
    "dream-open" => dream_open(store, entries, request)
    "dream-close" => dream_close(store, entries, request)
    "dream-list" => dream_list(store, entries)
    "dream-work-open" => dream_work_open(store, entries, request)
    "dream-work-claim" => dream_work_claim(store, entries, request)
    "dream-work-complete" => dream_work_complete(store, entries, request)
    "dream-work-fail" => dream_work_fail(store, entries, request)
    "dream-work-list" => dream_work_list(store, entries)
    "dream-policy" => dream_policy_op(store, entries, request)
    "dream-due" => dream_due_op(store, entries, request)
    _ => raise @base.Fault("internal_dream_dispatch")
  }
}