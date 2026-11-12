// Directories under state/ that hold durable records. A new durable-work kind
// must appear here: `validate_record` branches on these prefixes, and both the
// transaction whitelist and the pack whitelist read this same list, so a record
// directory cannot be valid in one place and refused in another.
pub fn state_directories() -> Array[String] {
  ["state/orders", "state/events", "state/reviews", "state/research",
   "state/suggestions", "state/overview", "state/evidence", "state/memory",
   "state/impacts", "state/providers", "state/provider-jobs", "state/extractions",
   "state/dreams", "state/dream-work", "state/evo"]
}

// Sidecar text is host-supplied (OCR, PDF text) and could be arbitrarily long.
// The cap counts UTF-8 bytes -- the same unit as the native/MCP 2 MiB request
// line -- so a record that passes `validate_record` is transmissible on every
// face, and one submission stays far inside the 16 MiB write ceiling instead of
// being re-hashed forever as a multi-megabyte field on every verifying read.
// `String.length()` would count UTF-16 units and let ~3x that many bytes slip
// onto a face that refuses the request line before the engine ever runs.
pub const EXTRACTION_TEXT_LIMIT : Int = 1048576

fn valid_hash(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

// kind/extractor/version name the host channel that produced an extraction.
// Bounded like a provider name: free-form so adapters are not hard-coded, but
// short and newline-free so it stays a stable provenance token.
fn extraction_token(value : String, field : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 128 || value.contains("\n") || value.contains("\r") {
    @base.fail("extraction_" + field + "_invalid")
  }
}

// Extracted text keeps newlines (paragraph layout is the point of an OCR pass)
// but never carriage returns, and is capped by EXTRACTION_TEXT_LIMIT **UTF-8
// bytes** -- CJK OCR text is three bytes per character, and a character-counted
// bound would let a record pass here yet die at the transport's 2 MiB request
// line, giving three faces two different answers to the same submission.
fn extraction_body(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || @base.utf8_size(value) > EXTRACTION_TEXT_LIMIT || value.contains("\r") {
    @base.fail("extraction_text_invalid")
  }
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

// Dream round ledger helpers (续二十八). The record binds the exact knowledge
// baseline a round was dreamed on, the declared policy and a deterministic
// metrics snapshot. Compatibility gates (lint regression / evidence loss) are
// enforced by agent/dream.mbt at decision time; this layer pins the shape and
// the open→retained|rejected state machine.
fn dream_metric_names() -> Array[String] {
  ["pages", "stale_pages", "lint_errors", "lint_warnings",
   "redundant_pages", "uncovered_sources", "sparse_topics", "missing_vectors"]
}

fn dream_metric(value : Json, field : String) -> Unit raise @base.Fault {
  match value {
    Number(n, ..) if n >= 0.0 && n <= 1000000000.0 && n == n.to_int().to_double() => ()
    _ => raise @base.Fault("dream_metric_invalid: " + field)
  }
}

fn dream_metrics_shape(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, dream_metric_names())
  for field in dream_metric_names() { dream_metric(@base.field(value, field), field) }
}

fn dream_delta(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, dream_metric_names())
  for field in dream_metric_names() {
    match @base.field(value, field) {
      Number(n, ..) if n >= -1000000000.0 && n <= 1000000000.0 && n == n.to_int().to_double() => ()
      _ => raise @base.Fault("dream_delta_invalid: " + field)
    }
  }
}

fn dream_policy(value : Json) -> Unit raise @base.Fault {
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

// The round's vector space is stored so dream-close recomputes missing_vector
// metrics against the same space the round was dreamed on.
fn dream_space_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  match value {
    Object(_) => ()
    _ => raise @base.Fault("dream_space_invalid")
  }
  let id = @base.text(@base.field(value, "id"))
  if id.is_empty() || id.length() > 512 { @base.fail("dream_space_invalid") }
  match @base.field(value, "dimensions") {
    Number(n, ..) if n >= 1.0 && n <= 8192.0 && n == n.to_int().to_double() => ()
    _ => @base.fail("dream_space_invalid")
  }
}

// A completed work item carries only structured answers: judgments the engine
// refuses to make itself, and staged page references it may never write.
fn dream_work_result_shape(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, ["judgments", "proposals"])
  let judgments = @base.field(value, "judgments")
  match judgments {
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

// ---- Evolution records (续三十) ------------------------------------------
// These helpers own only record shapes, identity derivation and the state
// machine invariants. The controller (agent/evo.mbt) never derives a hash or
// accepts a loosely-shaped record on its own: both the writer and this
// validator call the same recipe, so a stored genome cannot silently mean a
// different genome than its id claims.

pub const EVO_WEIGHTS : Int = 334

pub fn evo_policy_param_names() -> Array[String] {
  ["population", "window", "elite_ratio", "protect_ratio", "tournament",
   "crossover_rate", "mutation_rate", "mutation_max", "immigrants",
   "regression_delta", "regression_patience", "auto_rollback",
   "fossil_max_per_gen", "history", "w_stability", "w_responsiveness",
   "w_growth", "w_novelty", "c_energy", "c_impulse", "c_positive",
   "c_flatness", "c_holdout"]
}

fn evo_policy_value(params : Json, name : String) -> Json raise @base.Fault {
  match params {
    Object(fields) => match fields.get(name) {
      Some(value) => value
      None => raise @base.Fault("evo_policy_incomplete:" + name)
    }
    _ => raise @base.Fault("evo_policy_invalid")
  }
}

fn evo_policy_int(params : Json, name : String, low : Int, high : Int) -> Int raise @base.Fault {
  match evo_policy_value(params, name) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low.to_double() &&
      n <= high.to_double() && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

fn evo_policy_number(params : Json, name : String, low : Double, high : Double) -> Double raise @base.Fault {
  match evo_policy_value(params, name) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low && n <= high => n
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

fn evo_policy_bool(params : Json, name : String) -> Bool raise @base.Fault {
  match evo_policy_value(params, name) {
    True => true
    False => false
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

// The parameter table is closed and bounded. `protect_ratio <= elite_ratio`
// is the separation between "survives untouched" and "may still be a parent";
// letting it invert would protect more genomes than the elite floor keeps.
pub fn evo_policy_params(value : Json) -> Unit raise @base.Fault {
  match value {
    Object(_) => ()
    _ => raise @base.Fault("evo_policy_invalid")
  }
  @base.keys(value, evo_policy_param_names())
  ignore(evo_policy_int(value, "population", 8, 32))
  ignore(evo_policy_int(value, "window", 16, 512))
  let elite = evo_policy_number(value, "elite_ratio", 0.10, 0.50)
  let protect = evo_policy_number(value, "protect_ratio", 0.05, 0.30)
  ignore(evo_policy_int(value, "tournament", 2, 5))
  ignore(evo_policy_number(value, "crossover_rate", 0.0, 1.0))
  ignore(evo_policy_number(value, "mutation_rate", 0.01, 0.50))
  ignore(evo_policy_number(value, "mutation_max", 0.10, 0.60))
  ignore(evo_policy_int(value, "immigrants", 1, 3))
  ignore(evo_policy_number(value, "regression_delta", 0.01, 0.50))
  ignore(evo_policy_int(value, "regression_patience", 1, 8))
  ignore(evo_policy_bool(value, "auto_rollback"))
  ignore(evo_policy_int(value, "fossil_max_per_gen", 1, 8))
  ignore(evo_policy_int(value, "history", 4, 64))
  for name in ["w_stability", "w_responsiveness", "w_growth", "w_novelty",
    "c_energy", "c_impulse", "c_positive", "c_flatness", "c_holdout"] {
    ignore(evo_policy_number(value, name, 0.0, 1.0))
  }
  if protect > elite { @base.fail("evo_policy_elite_invalid") }
}

pub fn evo_policy_record_shape(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, ["version", "enabled", "params", "updated_at"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault("evo_policy_record_invalid:version")
  }
  match @base.field(value, "enabled") {
    True => ()
    False => ()
    _ => raise @base.Fault("evo_policy_record_invalid:enabled")
  }
  evo_policy_params(@base.field(value, "params"))
  let at = match @base.field(value, "updated_at") {
    String(text) => text
    _ => raise @base.Fault("evo_policy_record_invalid:updated_at")
  }
  if at.length() < 10 || at.contains("\n") || at.contains("\r") {
    @base.fail("evo_policy_record_invalid:updated_at")
  }
}

pub fn evo_policy_hash(record : Json) -> String {
  @base.hex_hash(@base.canonical(record))
}

// Weights are compared as IEEE-754 binary32 bit patterns, in index order and
// little endian. Hashing the JSON text instead would make a formatting change
// (or a lossy decimal round trip) look like a different genome.
pub fn evo_weights_validate(weights : Array[Double]) -> Unit raise @base.Fault {
  if weights.length() != EVO_WEIGHTS { @base.fail("evo_genome_weight_invalid:length") }
  for weight in weights {
    if weight.is_nan() || weight.is_inf() || weight < -4.0 || weight > 4.0 {
      @base.fail("evo_genome_weight_invalid:range")
    }
    if Float::from_double(weight).to_double() != weight {
      @base.fail("evo_genome_weight_invalid:precision")
    }
  }
}

pub fn evo_weights_sha256(weights : Array[Double]) -> String raise @base.Fault {
  evo_weights_validate(weights)
  let bytes : Array[Byte] = []
  for weight in weights {
    let bits = Float::from_double(weight).reinterpret_as_uint()
    for i = 0; i < 4; i = i + 1 {
      bytes.push(((bits >> (i * 8)) & 255U).to_byte())
    }
  }
  @base.sha256_hex(Bytes::from_array(bytes))
}

pub fn evo_weights_from_json(value : Json) -> Array[Double] raise @base.Fault {
  let items = match value {
    Array(values) => values
    _ => raise @base.Fault("evo_genome_weight_invalid:type")
  }
  if items.length() != EVO_WEIGHTS { @base.fail("evo_genome_weight_invalid:length") }
  let weights : Array[Double] = []
  for item in items {
    match item {
      Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= -4.0 && n <= 4.0 => {
        if Float::from_double(n).to_double() != n {
          @base.fail("evo_genome_weight_invalid:precision")
        }
        weights.push(n)
      }
      _ => raise @base.Fault("evo_genome_weight_invalid:range")
    }
  }
  weights
}

pub fn evo_genome_id(
  origin : String, generation : Int, parents : Array[String], weights_sha256 : String,
) -> String {
  @base.hex_hash("evo-genome-v1\n" + origin + "\n" + generation.to_string() + "\n" +
    @base.canonical(parents.to_json()) + "\n" + weights_sha256)
}

pub fn evo_fossil_id(genome : String, reason : String, died_generation : Int) -> String {
  @base.hex_hash("evo-fossil-v1\n" + genome + "\n" + reason + "\n" + died_generation.to_string())
}

pub fn evo_window_hash(window : Array[Json]) -> String {
  @base.hex_hash(@base.canonical({ "version": 1, "window": window.to_json() }))
}

fn evo_record_time(value : Json, field : String, code : String) -> String raise @base.Fault {
  match @base.field(value, field) {
    String(text) if text.length() >= 10 && !text.contains("\n") && !text.contains("\r") => text
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_int(value : Json, field : String, low : Int, high : Int, code : String) -> Int raise @base.Fault {
  match @base.field(value, field) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low.to_double() &&
      n <= high.to_double() && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_number(value : Json, field : String, low : Double, high : Double, code : String) -> Double raise @base.Fault {
  match @base.field(value, field) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low && n <= high => n
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_bool(value : Json, field : String, code : String) -> Bool raise @base.Fault {
  match @base.field(value, field) {
    True => true
    False => false
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_hash(value : Json, field : String, code : String) -> String raise @base.Fault {
  match @base.field(value, field) {
    String(text) if valid_hash(text) => text
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_array(value : Json, field : String, code : String) -> Array[Json] raise @base.Fault {
  match @base.field(value, field) {
    Array(items) => items
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_record_vector3(
  value : Json, field : String, low : Double, high : Double, code : String,
) -> Unit raise @base.Fault {
  let items = evo_record_array(value, field, code)
  if items.length() != 3 { @base.fail(code + ":" + field) }
  for item in items {
    match item {
      Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low && n <= high => ()
      _ => raise @base.Fault(code + ":" + field)
    }
  }
}

fn evo_record_subject(value : String, code : String) -> Unit raise @base.Fault {
  let size = @base.utf8_size(value)
  if size < 1 || size > 64 || value.contains("\n") || value.contains("\r") {
    @base.fail(code + ":subject")
  }
}

fn evo_optional_int(value : Json, field : String, low : Int, high : Int, code : String) -> Unit raise @base.Fault {
  match @base.field(value, field) {
    Null => ()
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low.to_double() &&
      n <= high.to_double() && n == n.to_int().to_double() => ()
    _ => raise @base.Fault(code + ":" + field)
  }
}

fn evo_window_entry_shape(value : Json) -> Int raise @base.Fault {
  let code = "evo_state_window_invalid"
  @base.keys(value, ["step", "at", "input", "emotion", "impulse", "fired", "subject"])
  let step = evo_record_int(value, "step", 1, 2147483647, code)
  ignore(evo_record_time(value, "at", code))
  let input = evo_record_array(value, "input", code)
  if input.length() != 16 { @base.fail(code + ":input") }
  for item in input {
    match item {
      Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= -1.0 && n <= 1.0 => ()
      _ => raise @base.Fault(code + ":input")
    }
  }
  evo_record_vector3(value, "emotion", -1.0, 1.0, code)
  ignore(evo_record_number(value, "impulse", 0.0, 1.0, code))
  ignore(evo_record_bool(value, "fired", code))
  match @base.field(value, "subject") {
    Null => ()
    String(subject) => evo_record_subject(subject, code)
    _ => raise @base.Fault(code + ":subject")
  }
  step
}

fn evo_relation_shape(value : Json) -> String raise @base.Fault {
  let code = "evo_state_record_invalid"
  @base.keys(value, ["subject", "trust", "familiarity", "tension"])
  let subject = match @base.field(value, "subject") {
    String(text) => text
    _ => raise @base.Fault(code + ":relation_subject")
  }
  evo_record_subject(subject, code)
  ignore(evo_record_number(value, "trust", 0.0, 1.0, code))
  ignore(evo_record_number(value, "familiarity", 0.0, 1.0, code))
  ignore(evo_record_number(value, "tension", 0.0, 1.0, code))
  subject
}

fn evo_body_shape(value : Json, code : String) -> Unit raise @base.Fault {
  @base.keys(value, ["cpu", "memory", "latency", "budget"])
  for field in ["cpu", "memory", "latency", "budget"] {
    ignore(evo_record_number(value, field, 0.0, 1.0, code))
  }
}

fn evo_last_observe_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  let code = "evo_state_record_invalid"
  @base.keys(value, ["step", "payload_sha256", "result"])
  ignore(evo_record_int(value, "step", 1, 2147483647, code))
  ignore(evo_record_hash(value, "payload_sha256", code))
  let result = @base.field(value, "result")
  @base.keys(result, ["emotion", "impulse", "fired", "action", "threshold"])
  evo_record_vector3(result, "emotion", -1.0, 1.0, code)
  ignore(evo_record_number(result, "impulse", 0.0, 1.0, code))
  ignore(evo_record_bool(result, "fired", code))
  evo_record_vector3(result, "action", -1.0, 1.0, code)
  ignore(evo_record_number(result, "threshold", 0.30, 0.95, code))
}

// Proactive request (续三十三): the affect system's structured "I want to act"
// envelope for the host driver. The engine stores it; a host-side driver claims
// it, calls the LLM and completes it. No engine module reads these records.
fn evo_proactive_record(path : String, value : Json) -> Unit raise @base.Fault {
  let code = "evo_proactive_record_invalid"
  @base.keys(value, ["version", "id", "step", "genome", "state_sha256", "reason",
    "urgency", "context", "status", "driver", "lease_until", "created_at",
    "closed_at", "delivered_at", "result", "error"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault(code + ":version")
  }
  let id = @base.text(@base.field(value, "id"))
  if !valid_hash(id) || path != "state/evo/proactive/" + id + ".json" {
    @base.fail(code + ":id")
  }
  ignore(evo_record_int(value, "step", 0, 1000000000, code))
  for field in ["genome", "state_sha256"] {
    if !valid_hash(@base.text(@base.field(value, field))) { @base.fail(code + ":" + field) }
  }
  let reason = @base.text(@base.field(value, "reason"))
  if !["impulse", "valence_high", "valence_low"].contains(reason) { @base.fail(code + ":reason") }
  match @base.field(value, "urgency") {
    Number(n, ..) if n >= 0.0 && n <= 1.0 && !n.is_nan() && !n.is_inf() => ()
    _ => raise @base.Fault(code + ":urgency")
  }
  let context = @base.field(value, "context")
  @base.keys(context, ["step", "emotion", "impulse", "body", "relations", "window_sha256", "genome"])
  ignore(evo_record_hash(context, "window_sha256", code))
  let status = @base.text(@base.field(value, "status"))
  if !["pending", "claimed", "done", "failed"].contains(status) { @base.fail(code + ":status") }
  event_time(@base.text(@base.field(value, "created_at")))
  let driver = @base.field(value, "driver")
  let lease = @base.field(value, "lease_until")
  let closed = @base.field(value, "closed_at")
  // `delivered_at` is optional so records written before the ack op remain
  // readable; a present value must be a timestamp no earlier than closed_at.
  let delivered = optional_record_field(value, "delivered_at").unwrap_or(Json::null())
  let result = @base.field(value, "result")
  let error = @base.field(value, "error")
  let driver_text = match driver {
    Null => ""
    String(text) => {
      if text.is_empty() || text.length() > 128 || text.contains("\n") || text.contains("\r") {
        @base.fail(code + ":driver")
      }
      text
    }
    _ => raise @base.Fault(code + ":driver")
  }
  if lease != Json::null() {
    event_time(@base.text(lease))
    if driver_text == "" { @base.fail(code + ":lease") }
  }
  if status == "pending" {
    if driver != Json::null() || lease != Json::null() || closed != Json::null() ||
      delivered != Json::null() || result != Json::null() || error != Json::null() {
      @base.fail(code + ":pending")
    }
  } else if status == "claimed" {
    if driver_text == "" || lease == Json::null() || closed != Json::null() ||
      delivered != Json::null() || result != Json::null() || error != Json::null() {
      @base.fail(code + ":claimed")
    }
  } else if status == "done" {
    if driver_text == "" || closed == Json::null() || error != Json::null() {
      @base.fail(code + ":done")
    }
    event_time(@base.text(closed))
    if delivered != Json::null() {
      event_time(@base.text(delivered))
      if @base.compare(@base.text(delivered), @base.text(closed)) < 0 {
        @base.fail(code + ":delivered_at")
      }
    }
    @base.keys(result, ["text", "model"])
    let text = @base.text(@base.field(result, "text"))
    if text.length() > 8192 || text.contains("\r") { @base.fail(code + ":result_text") }
    let model = @base.text(@base.field(result, "model"))
    if model.is_empty() || model.length() > 128 || model.contains("\n") { @base.fail(code + ":result_model") }
  } else {
    if driver_text == "" || closed == Json::null() || delivered != Json::null() ||
      result != Json::null() || error == Json::null() {
      @base.fail(code + ":failed")
    }
    event_time(@base.text(closed))
    let reason_text = @base.text(error)
    if reason_text.is_empty() || reason_text.length() > 1024 || reason_text.contains("\n") ||
      reason_text.contains("\r") {
      @base.fail(code + ":error")
    }
  }
}

fn evo_state_record(value : Json) -> Unit raise @base.Fault {
  let code = "evo_state_record_invalid"
  @base.keys(value, ["version", "steps", "window", "window_sha256", "emotion",
    "impulse", "body", "relations", "active_genome", "last_observe",
    "last_fire_step", "guard_hits", "impulses", "blowups", "created_at", "updated_at"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault(code + ":version")
  }
  let steps = evo_record_int(value, "steps", 0, 1000000000, code)
  let window = evo_record_array(value, "window", code)
  if window.length() > 512 || window.length() > steps { @base.fail(code + ":window") }
  let mut expected = -1
  for entry in window {
    let step = evo_window_entry_shape(entry)
    if expected >= 0 && step != expected + 1 { @base.fail("evo_state_window_invalid:step") }
    expected = step
  }
  let expected_hash = evo_window_hash(window)
  match @base.field(value, "window_sha256") {
    String(text) if valid_hash(text) && text == expected_hash => ()
    _ => raise @base.Fault("evo_state_window_hash_mismatch")
  }
  evo_record_vector3(value, "emotion", -1.0, 1.0, code)
  ignore(evo_record_number(value, "impulse", 0.0, 1.0, code))
  evo_body_shape(@base.field(value, "body"), code)
  let relations = evo_record_array(value, "relations", code)
  if relations.length() > 8 { @base.fail(code + ":relations") }
  let mut previous = ""
  let seen : Map[String, Bool] = Map([])
  for relation in relations {
    let subject = evo_relation_shape(relation)
    if seen.contains(subject) || (previous != "" && @base.compare(previous, subject) >= 0) {
      @base.fail(code + ":relations_order")
    }
    seen[subject] = true
    previous = subject
  }
  match @base.field(value, "active_genome") {
    Null => ()
    String(text) => if !valid_hash(text) { @base.fail(code + ":active_genome") }
    _ => raise @base.Fault(code + ":active_genome")
  }
  evo_last_observe_shape(@base.field(value, "last_observe"))
  evo_optional_int(value, "last_fire_step", 1, 2147483647, code)
  for field in ["guard_hits", "impulses", "blowups"] {
    ignore(evo_record_int(value, field, 0, 1000000000, code))
  }
  ignore(evo_record_time(value, "created_at", code))
  ignore(evo_record_time(value, "updated_at", code))
}

fn evo_breakdown_shape(value : Json, code : String) -> Unit raise @base.Fault {
  @base.keys(value, ["stability", "responsiveness", "growth", "novelty",
    "energy_cost", "impulse_blowups", "positive_penalty", "flatness_penalty",
    "holdout_penalty", "train", "holdout"])
  for field in ["stability", "responsiveness", "growth", "novelty", "energy_cost",
    "impulse_blowups", "positive_penalty", "flatness_penalty", "holdout_penalty"] {
    ignore(evo_record_number(value, field, 0.0, 1.0, code))
  }
  ignore(evo_record_number(value, "train", -1.0, 1.0, code))
  ignore(evo_record_number(value, "holdout", -1.0, 1.0, code))
}

fn evo_member_shape(value : Json) -> Unit raise @base.Fault {
  let code = "evo_population_record_invalid"
  @base.keys(value, ["genome", "fitness", "breakdown", "age",
    "evaluated_generation", "status"])
  ignore(evo_record_hash(value, "genome", code))
  let status = match @base.field(value, "status") {
    String(text) if text == "alive" || text == "lethal" => text
    _ => raise @base.Fault(code + ":status")
  }
  match @base.field(value, "fitness") {
    Null => if status == "lethal" { @base.fail(code + ":fitness") }
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= -1.0 && n <= 1.0 => {
      if status == "lethal" {
        if n != -1.0 { @base.fail(code + ":fitness") }
      } else if n <= -1.0 {
        @base.fail(code + ":fitness")
      }
    }
    _ => raise @base.Fault(code + ":fitness")
  }
  match @base.field(value, "breakdown") {
    Null => ()
    _ => evo_breakdown_shape(@base.field(value, "breakdown"), code)
  }
  ignore(evo_record_int(value, "age", 0, 1000000, code))
  evo_optional_int(value, "evaluated_generation", 0, 1000000000, code)
}

fn evo_checkpoint_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  let code = "evo_population_record_invalid"
  @base.keys(value, ["generation", "genome", "fitness", "at"])
  ignore(evo_record_int(value, "generation", 0, 1000000000, code))
  ignore(evo_record_hash(value, "genome", code))
  ignore(evo_record_number(value, "fitness", -1.0, 1.0, code))
  ignore(evo_record_time(value, "at", code))
}

fn evo_history_shape(value : Json) -> Unit raise @base.Fault {
  let code = "evo_population_record_invalid"
  @base.keys(value, ["generation", "window_sha256", "best", "mean", "worst",
    "delta", "regressed", "rolled_back"])
  ignore(evo_record_int(value, "generation", 0, 1000000000, code))
  ignore(evo_record_hash(value, "window_sha256", code))
  ignore(evo_record_number(value, "best", -1.0, 1.0, code))
  ignore(evo_record_number(value, "mean", -1.0, 1.0, code))
  ignore(evo_record_number(value, "worst", -1.0, 1.0, code))
  let delta = evo_record_number(value, "delta", -2.0, 2.0, code)
  ignore(evo_record_bool(value, "regressed", code))
  ignore(evo_record_bool(value, "rolled_back", code))
  // The first generation's zero delta is a controller property (tested by
  // evo_wbtest); the shape layer only bounds the value because a bounded
  // history may drop the original first entry after many rollbacks.
  ignore(delta)
}

fn evo_last_eval_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  let code = "evo_population_record_invalid"
  @base.keys(value, ["generation", "window_sha256", "at", "best", "mean", "worst", "alive"])
  ignore(evo_record_int(value, "generation", 0, 1000000000, code))
  ignore(evo_record_hash(value, "window_sha256", code))
  ignore(evo_record_time(value, "at", code))
  ignore(evo_record_number(value, "best", -1.0, 1.0, code))
  ignore(evo_record_number(value, "mean", -1.0, 1.0, code))
  ignore(evo_record_number(value, "worst", -1.0, 1.0, code))
  ignore(evo_record_int(value, "alive", 1, 32, code))
}

fn evo_last_evolve_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  let code = "evo_population_record_invalid"
  @base.keys(value, ["from_generation", "to_generation", "window_sha256", "at",
    "best", "mean", "worst", "delta", "regressed", "rolled_back", "fossils",
    "extinct", "immigrants", "elite", "protected", "rng_seed"])
  ignore(evo_record_int(value, "from_generation", 0, 1000000000, code))
  ignore(evo_record_int(value, "to_generation", 0, 1000000000, code))
  ignore(evo_record_hash(value, "window_sha256", code))
  ignore(evo_record_time(value, "at", code))
  ignore(evo_record_number(value, "best", -1.0, 1.0, code))
  ignore(evo_record_number(value, "mean", -1.0, 1.0, code))
  ignore(evo_record_number(value, "worst", -1.0, 1.0, code))
  ignore(evo_record_number(value, "delta", -2.0, 2.0, code))
  ignore(evo_record_bool(value, "regressed", code))
  ignore(evo_record_bool(value, "rolled_back", code))
  for field in ["fossils", "extinct", "immigrants", "elite", "protected"] {
    ignore(evo_record_int(value, field, 0, 1000000000, code))
  }
  match @base.field(value, "rng_seed") {
    String(text) if text.length() == 16 && text.iter().all(c =>
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) => ()
    _ => raise @base.Fault(code + ":rng_seed")
  }
}

fn evo_last_rollback_shape(value : Json) -> Unit raise @base.Fault {
  if value == Json::null() { return }
  let code = "evo_population_record_invalid"
  @base.keys(value, ["at", "from_generation", "to_generation", "reason",
    "checkpoint", "fossils"])
  ignore(evo_record_time(value, "at", code))
  let from = evo_record_int(value, "from_generation", 0, 1000000000, code)
  let to = evo_record_int(value, "to_generation", 0, 1000000000, code)
  if to > from { @base.fail(code + ":to_generation") }
  match @base.field(value, "reason") {
    String(text) if text == "manual" || text == "regression" => ()
    _ => raise @base.Fault(code + ":reason")
  }
  ignore(evo_record_hash(value, "checkpoint", code))
  ignore(evo_record_int(value, "fossils", 0, 1000000000, code))
}

fn evo_seed_shape(value : Json, code : String) -> Unit raise @base.Fault {
  match @base.field(value, "seed") {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= 0.0 && n <= 4294967295.0 &&
      n == n.to_int().to_double() => ()
    _ => raise @base.Fault(code + ":seed")
  }
}

fn evo_population_record(value : Json) -> Unit raise @base.Fault {
  let code = "evo_population_record_invalid"
  @base.keys(value, ["version", "generation", "init", "members", "checkpoint",
    "history", "regression_streak", "no_improve_streak", "saturations_total",
    "extinct_total", "fossil_total", "regressions_total", "rollbacks_total",
    "last_eval", "last_evolve", "last_rollback", "updated_at"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault(code + ":version")
  }
  ignore(evo_record_int(value, "generation", 0, 1000000000, code))
  let init = @base.field(value, "init")
  @base.keys(init, ["seed", "at", "policy_hash"])
  ignore(evo_seed_shape(init, code))
  ignore(evo_record_time(init, "at", code))
  ignore(evo_record_hash(init, "policy_hash", code))
  let members = evo_record_array(value, "members", code)
  if members.length() < 1 || members.length() > 32 { @base.fail(code + ":members") }
  for row in members { evo_member_shape(row) }
  evo_checkpoint_shape(@base.field(value, "checkpoint"))
  let history = evo_record_array(value, "history", code)
  if history.length() > 64 { @base.fail(code + ":history") }
  for entry in history { evo_history_shape(entry) }
  if history.length() == 1 {
    let first = history[0]
    let generation = evo_record_int(first, "generation", 0, 1000000000, code)
    let delta = evo_record_number(first, "delta", -2.0, 2.0, code)
    if generation == 0 && delta != 0.0 { @base.fail(code + ":history_delta") }
  }
  ignore(evo_record_int(value, "regression_streak", 0, 1000000, code))
  ignore(evo_record_int(value, "no_improve_streak", 0, 1000000, code))
  for field in ["saturations_total", "extinct_total", "fossil_total",
    "regressions_total", "rollbacks_total"] {
    ignore(evo_record_int(value, field, 0, 1000000000, code))
  }
  evo_last_eval_shape(@base.field(value, "last_eval"))
  evo_last_evolve_shape(@base.field(value, "last_evolve"))
  evo_last_rollback_shape(@base.field(value, "last_rollback"))
  ignore(evo_record_time(value, "updated_at", code))
}

fn evo_parent_list(value : Json, field : String, code : String) -> Array[String] raise @base.Fault {
  let items = evo_record_array(value, field, code)
  if items.length() > 2 { @base.fail(code + ":" + field) }
  let parents : Array[String] = []
  for item in items {
    match item {
      String(text) if valid_hash(text) => parents.push(text)
      _ => raise @base.Fault(code + ":" + field)
    }
  }
  parents
}

fn evo_genome_record(path : String, value : Json) -> Unit raise @base.Fault {
  let code = "evo_genome_record_invalid"
  @base.keys(value, ["version", "id", "generation", "parents", "origin",
    "weights", "weights_sha256", "created_at"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault(code + ":version")
  }
  let id = evo_record_hash(value, "id", code)
  if path != "state/evo/genomes/" + id + ".json" { @base.fail("evo_genome_identity_invalid:path") }
  let generation = evo_record_int(value, "generation", 0, 1000000000, code)
  let origin = match @base.field(value, "origin") {
    String(text) => text
    _ => raise @base.Fault("evo_genome_origin_invalid")
  }
  if !["seed", "crossover", "clone", "immigrant", "checkpoint_clone"].contains(origin) {
    @base.fail("evo_genome_origin_invalid")
  }
  let parents = evo_parent_list(value, "parents", code)
  let expected_parents = if ["seed", "immigrant"].contains(origin) { 0 }
    else if ["clone", "checkpoint_clone"].contains(origin) { 1 }
    else { 2 }
  if parents.length() != expected_parents { @base.fail("evo_genome_parents_invalid") }
  for parent in parents {
    if !valid_hash(parent) || parent == id { @base.fail("evo_genome_parents_invalid") }
  }
  let weights = evo_weights_from_json(@base.field(value, "weights"))
  let weights_sha256 = evo_record_hash(value, "weights_sha256", code)
  if evo_weights_sha256(weights) != weights_sha256 { @base.fail("evo_genome_weights_hash_mismatch") }
  if id != evo_genome_id(origin, generation, parents, weights_sha256) {
    @base.fail("evo_genome_identity_mismatch")
  }
  ignore(evo_record_time(value, "created_at", code))
}

fn evo_fossil_record(path : String, value : Json) -> Unit raise @base.Fault {
  let code = "evo_fossil_record_invalid"
  @base.keys(value, ["version", "id", "genome", "generation", "died_generation",
    "reason", "fitness", "breakdown", "window_sha256", "weights_sha256",
    "parents", "age", "at"])
  match @base.field(value, "version") {
    Number(n, ..) if n == 1.0 => ()
    _ => raise @base.Fault(code + ":version")
  }
  let id = evo_record_hash(value, "id", code)
  if path != "state/evo/fossils/" + id + ".json" { @base.fail("evo_fossil_identity_invalid:path") }
  let genome = evo_record_hash(value, "genome", code)
  let generation = evo_record_int(value, "generation", 0, 1000000000, code)
  let died = evo_record_int(value, "died_generation", 0, 1000000000, code)
  if generation > died { @base.fail(code + ":generation") }
  let reason = match @base.field(value, "reason") {
    String(text) => text
    _ => raise @base.Fault("evo_fossil_reason_invalid")
  }
  if !["not_selected", "lethal", "regression_rollback", "manual_rollback"].contains(reason) {
    @base.fail("evo_fossil_reason_invalid")
  }
  ignore(evo_record_number(value, "fitness", -1.0, 1.0, code))
  evo_breakdown_shape(@base.field(value, "breakdown"), code)
  ignore(evo_record_hash(value, "window_sha256", code))
  ignore(evo_record_hash(value, "weights_sha256", code))
  ignore(evo_parent_list(value, "parents", code))
  ignore(evo_record_int(value, "age", 0, 1000000000, code))
  ignore(evo_record_time(value, "at", code))
  if id != evo_fossil_id(genome, reason, died) { @base.fail("evo_fossil_identity_mismatch") }
}

pub fn validate_record(entry : Entry, text : String) -> Unit raise @base.Fault {
  let value = @base.parse(text)
  match value { Object(_) => (); _ => @base.fail("record_object_required: " + entry.path) }
  let string = key => @base.text(@base.field(value, key))
  if entry.path == "state/evo/policy.json" {
    evo_policy_record_shape(value)
  } else if entry.path == "state/evo/state.json" {
    evo_state_record(value)
  } else if entry.path == "state/evo/population.json" {
    evo_population_record(value)
  } else if entry.path.has_prefix("state/evo/genomes/") {
    evo_genome_record(entry.path, value)
  } else if entry.path.has_prefix("state/evo/fossils/") {
    evo_fossil_record(entry.path, value)
  } else if entry.path.has_prefix("state/evo/proactive/") {
    evo_proactive_record(entry.path, value)
  } else if entry.path.has_prefix("state/evo/") {
    @base.fail("evo_record_path_invalid")
  } else if entry.path.has_prefix("state/orders/") {
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
  } else if entry.path.has_prefix("state/extractions/") {
    // A host-side extraction (OCR, PDF text) pinned to the exact registered
    // bytes. The filename hash and the content `source_sha256` lock each other
    // so the record cannot be renamed onto a different source, and replay keys
    // off (source_sha256, extractor, version) instead of a separate id.
    @base.keys(value, ["source", "source_sha256", "kind", "extractor", "version", "text", "submitted_at"])
    let source = string("source")
    @base.path(source)
    if !source.has_prefix("raw/") { @base.fail("extraction_source_invalid") }
    let source_sha256 = string("source_sha256")
    if !valid_hash(source_sha256) { @base.fail("extraction_source_hash_invalid") }
    if entry.path != "state/extractions/" + source_sha256 + ".json" {
      @base.fail("extraction_record_identity_invalid")
    }
    extraction_token(string("kind"), "kind")
    extraction_token(string("extractor"), "extractor")
    extraction_token(string("version"), "version")
    extraction_body(string("text"))
    event_time(string("submitted_at"))
  } else if entry.path.has_prefix("state/dreams/") {
    if entry.path == "state/dreams/policy.json" {
      @base.keys(value, ["version", "due_after_seconds", "min_opportunities",
        "max_open_rounds", "updated_at"])
      match @base.field(value, "version") {
        Number(n, ..) if n == 1.0 => ()
        _ => raise @base.Fault("dream_policy_record_invalid:version")
      }
      match @base.field(value, "due_after_seconds") {
        Number(n, ..) if n >= 0.0 && n <= 2592000.0 && n == n.to_int().to_double() => ()
        _ => raise @base.Fault("dream_policy_record_invalid:due_after_seconds")
      }
      match @base.field(value, "min_opportunities") {
        Number(n, ..) if n >= 0.0 && n <= 500.0 && n == n.to_int().to_double() => ()
        _ => raise @base.Fault("dream_policy_record_invalid:min_opportunities")
      }
      match @base.field(value, "max_open_rounds") {
        Number(n, ..) if n >= 1.0 && n <= 8.0 && n == n.to_int().to_double() => ()
        _ => raise @base.Fault("dream_policy_record_invalid:max_open_rounds")
      }
      event_time(string("updated_at"))
    } else {
    @base.keys(value, ["id", "at", "baseline", "knowledge", "policy", "space", "metrics",
      "opportunities_hash", "status", "closed_at", "decision", "note", "outcome"])
    let id = string("id")
    let baseline = string("baseline")
    if !valid_hash(id) || !valid_hash(baseline) || !valid_hash(string("knowledge")) {
      @base.fail("dream_record_hash_invalid")
    }
    if entry.path != "state/dreams/" + id + ".json" { @base.fail("dream_record_identity_invalid") }
    if !valid_hash(string("opportunities_hash")) { @base.fail("dream_report_hash_invalid") }
    event_time(string("at"))
    dream_policy(@base.field(value, "policy"))
    dream_space_shape(@base.field(value, "space"))
    dream_metrics_shape(@base.field(value, "metrics"))
    let status = string("status")
    if !["open", "retained", "rejected"].contains(status) { @base.fail("dream_status_invalid") }
    let closed = @base.field(value, "closed_at")
    let decision = @base.field(value, "decision")
    let note = @base.field(value, "note")
    let outcome = @base.field(value, "outcome")
    if status == "open" {
      if closed != Json::null() || decision != Json::null() || outcome != Json::null() || note != Json::null() {
        @base.fail("dream_open_state_invalid")
      }
    } else {
      event_time(@base.text(closed))
      if @base.text(decision) != status { @base.fail("dream_decision_status_mismatch") }
      if outcome is Object(_) {
        @base.keys(outcome, ["metrics", "delta", "drivers"])
        dream_metrics_shape(@base.field(outcome, "metrics"))
        dream_delta(@base.field(outcome, "delta"))
        let drivers = @base.strings(@base.field(outcome, "drivers"))
        if drivers.length() > 32 { @base.fail("dream_drivers_invalid") }
        for driver in drivers {
          if driver.is_empty() || driver.length() > 128 || driver.contains("\n") || driver.contains("\r") {
            @base.fail("dream_drivers_invalid")
          }
        }
      } else {
        @base.fail("dream_outcome_invalid")
      }
      if note != Json::null() {
        let n = @base.text(note)
        if n.length() > 1024 || n.contains("\n") || n.contains("\r") { @base.fail("dream_note_invalid") }
      }
    }
  }
  } else if entry.path.has_prefix("state/dream-work/") {
    @base.keys(value, ["id", "round", "baseline", "kind", "subject", "priority", "status",
      "driver", "lease_until", "created_at", "closed_at", "result", "error"])
    let id = string("id")
    let round = string("round")
    let baseline = string("baseline")
    if !valid_hash(id) || !valid_hash(round) || !valid_hash(baseline) {
      @base.fail("dream_work_hash_invalid")
    }
    if entry.path != "state/dream-work/" + id + ".json" { @base.fail("dream_work_identity_invalid") }
    let kind = string("kind")
    if !["lint", "uncovered_source", "stale_page", "sparse_topic", "missing_vector"].contains(kind) {
      @base.fail("dream_work_kind_invalid")
    }
    let subject = string("subject")
    if subject.is_empty() || subject.length() > 1024 || subject.contains("\n") || subject.contains("\r") {
      @base.fail("dream_work_subject_invalid")
    }
    match @base.field(value, "priority") {
      Number(n, ..) if n >= 0.0 && n <= 9.0 && n == n.to_int().to_double() => ()
      _ => raise @base.Fault("dream_work_priority_invalid")
    }
    let status = string("status")
    if !["pending", "claimed", "done", "failed"].contains(status) { @base.fail("dream_work_status_invalid") }
    event_time(string("created_at"))
    let driver = @base.field(value, "driver")
    let lease = @base.field(value, "lease_until")
    let closed = @base.field(value, "closed_at")
    let result = @base.field(value, "result")
    let error = @base.field(value, "error")
    let driver_text = match driver {
      Null => ""
      String(text) => {
        if text.is_empty() || text.length() > 128 || text.contains("\n") || text.contains("\r") {
          @base.fail("dream_work_driver_invalid")
        }
        text
      }
      _ => raise @base.Fault("dream_work_driver_invalid")
    }
    if lease != Json::null() {
      event_time(@base.text(lease))
      if driver_text == "" { @base.fail("dream_work_lease_without_driver") }
    }
    if status == "pending" {
      if driver != Json::null() || lease != Json::null() || closed != Json::null() ||
        result != Json::null() || error != Json::null() {
        @base.fail("dream_work_pending_invalid")
      }
    } else if status == "claimed" {
      if driver_text == "" || lease == Json::null() || closed != Json::null() ||
        result != Json::null() || error != Json::null() {
        @base.fail("dream_work_claimed_invalid")
      }
    } else if status == "done" {
      if driver_text == "" || closed == Json::null() || result == Json::null() || error != Json::null() {
        @base.fail("dream_work_done_invalid")
      }
      event_time(@base.text(closed))
      dream_work_result_shape(result)
    } else {
      if driver_text == "" || closed == Json::null() || error == Json::null() || result != Json::null() {
        @base.fail("dream_work_failed_invalid")
      }
      event_time(@base.text(closed))
      let reason = @base.text(error)
      if reason.is_empty() || reason.length() > 1024 || reason.contains("\n") || reason.contains("\r") {
        @base.fail("dream_work_error_invalid")
      }
    }
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
      "impact-open", "impact-resolve", "extraction-submit",
      "dream-open", "dream-close", "dream-work-open", "dream-work-claim",
      "dream-work-complete", "dream-work-fail", "dream-policy", "evo-saturation",
      "evo-proactive-open", "evo-proactive-complete", "evo-proactive-fail",
      "evo-proactive-ack", "evo-proactive-reclaim",
      "evo-policy", "evo-init", "evo-evaluate", "evo-evolve", "evo-regression",
      "evo-rollback", "evo-fossilize",
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
    } else if op == "extraction-submit" {
      // One sidecar per (source sha256) is enforced at submit, so the event
      // path binds to that sha: the submission cannot be rewritten onto a
      // different source, and a replayed submission never adds a second event.
      @base.keys(value, ["op", "source", "source_sha256", "extractor", "version", "at"])
      let source = string("source")
      @base.path(source)
      if !source.has_prefix("raw/") { @base.fail("extraction_event_source_invalid") }
      let source_sha256 = string("source_sha256")
      if !valid_hash(source_sha256) { @base.fail("extraction_event_source_hash_invalid") }
      extraction_token(string("extractor"), "extractor")
      extraction_token(string("version"), "version")
      event_time(string("at"))
      let expected = "state/events/extraction-submit-" + source_sha256 + ".json"
      if entry.path != expected { @base.fail("extraction_event_identity_invalid") }
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
    } else if op == "dream-open" {
      @base.keys(value, ["op", "dream", "at"])
      let dream = string("dream")
      if !valid_hash(dream) { @base.fail("dream_event_id_invalid") }
      event_time(string("at"))
      let expected = "state/events/dream-open-" + dream + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "dream-close" {
      @base.keys(value, ["op", "dream", "decision", "at"])
      let dream = string("dream")
      if !valid_hash(dream) { @base.fail("dream_event_id_invalid") }
      let decision = string("decision")
      if !["retained", "rejected"].contains(decision) { @base.fail("dream_event_decision_invalid") }
      event_time(string("at"))
      let expected = "state/events/dream-close-" + dream + "-" +
        @base.hex_hash(decision + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "dream-work-open" {
      @base.keys(value, ["op", "work", "round", "at"])
      let work = string("work")
      let round = string("round")
      if !valid_hash(work) || !valid_hash(round) { @base.fail("dream_work_event_hash_invalid") }
      event_time(string("at"))
      let expected = "state/events/dream-work-open-" + work + "-" + @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_work_event_identity_invalid") }
    } else if op == "dream-work-claim" {
      @base.keys(value, ["op", "work", "driver", "lease_until", "at"])
      let work = string("work")
      if !valid_hash(work) { @base.fail("dream_work_event_hash_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("dream_work_event_driver_invalid")
      }
      event_time(string("lease_until"))
      event_time(string("at"))
      let expected = "state/events/dream-work-claim-" + work + "-" +
        @base.hex_hash(driver + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_work_event_identity_invalid") }
    } else if op == "dream-work-complete" {
      @base.keys(value, ["op", "work", "driver", "at"])
      let work = string("work")
      if !valid_hash(work) { @base.fail("dream_work_event_hash_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("dream_work_event_driver_invalid")
      }
      event_time(string("at"))
      let expected = "state/events/dream-work-complete-" + work + "-" +
        @base.hex_hash(driver + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_work_event_identity_invalid") }
    } else if op == "dream-policy" {
      @base.keys(value, ["op", "at", "due_after_seconds", "min_opportunities", "max_open_rounds"])
      event_time(string("at"))
      let params : Json = {
        "due_after_seconds": @base.field(value, "due_after_seconds"),
        "min_opportunities": @base.field(value, "min_opportunities"),
        "max_open_rounds": @base.field(value, "max_open_rounds"),
      }
      let expected = "state/events/dream-policy-" +
        @base.hex_hash(@base.canonical(params) + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "evo-proactive-open" {
      @base.keys(value, ["op", "proactive", "driver", "at"])
      let proactive = string("proactive")
      if !valid_hash(proactive) { @base.fail("evo_proactive_event_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("evo_proactive_event_invalid")
      }
      event_time(string("at"))
      let expected = "state/events/evo-proactive-open-" + proactive + "-" +
        @base.hex_hash(driver + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "evo-proactive-complete" || op == "evo-proactive-fail" {
      @base.keys(value, ["op", "proactive", "driver", "at"])
      let proactive = string("proactive")
      if !valid_hash(proactive) { @base.fail("evo_proactive_event_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("evo_proactive_event_invalid")
      }
      event_time(string("at"))
      let expected = "state/events/" + op + "-" + proactive + "-" +
        @base.hex_hash(driver + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "evo-proactive-ack" {
      @base.keys(value, ["op", "proactive", "at"])
      let proactive = string("proactive")
      if !valid_hash(proactive) { @base.fail("evo_proactive_event_invalid") }
      event_time(string("at"))
      let expected = "state/events/evo-proactive-ack-" + proactive + "-" +
        @base.hex_hash(string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "evo-proactive-reclaim" {
      @base.keys(value, ["op", "proactive", "driver", "at"])
      let proactive = string("proactive")
      if !valid_hash(proactive) { @base.fail("evo_proactive_event_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("evo_proactive_event_invalid")
      }
      event_time(string("at"))
      let expected = "state/events/evo-proactive-reclaim-" + proactive + "-" +
        @base.hex_hash(driver + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "evo-saturation" {
      @base.keys(value, ["op", "at", "generation", "streak", "best"])
      event_time(string("at"))
      let generation = match @base.field(value, "generation") {
        Number(n, ..) if n >= 0.0 && n == n.to_int().to_double() => n.to_int()
        _ => raise @base.Fault("evo_saturation_event_invalid")
      }
      let streak = match @base.field(value, "streak") {
        Number(n, ..) if n >= 0.0 && n == n.to_int().to_double() => n.to_int()
        _ => raise @base.Fault("evo_saturation_event_invalid")
      }
      let expected = "state/events/evo-saturation-" +
        @base.hex_hash(generation.to_string() + "\n" + streak.to_string() + "\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("dream_event_identity_invalid") }
    } else if op == "dream-work-fail" {
      @base.keys(value, ["op", "work", "driver", "reason", "at"])
      let work = string("work")
      if !valid_hash(work) { @base.fail("dream_work_event_hash_invalid") }
      let driver = string("driver")
      if driver.is_empty() || driver.length() > 128 || driver.contains("\n") {
        @base.fail("dream_work_event_driver_invalid")
      }
      let reason = string("reason")
      if reason.is_empty() || reason.length() > 1024 || reason.contains("\n") {
        @base.fail("dream_work_event_reason_invalid")
      }
      event_time(string("at"))
      let expected = "state/events/dream-work-fail-" + work + "-" +
        @base.hex_hash(driver + "\n" + string("at") + "\n" + reason) + ".json"
      if entry.path != expected { @base.fail("dream_work_event_identity_invalid") }
    } else if op == "evo-policy" {
      @base.keys(value, ["op", "at", "enabled", "params", "params_hash"])
      let at = string("at")
      event_time(at)
      let enabled = @base.boolean(@base.field(value, "enabled"))
      let params = @base.field(value, "params")
      evo_policy_params(params)
      if string("params_hash") != @base.hex_hash(@base.canonical(params)) {
        @base.fail("evo_policy_record_invalid:params_hash")
      }
      let binding : Json = { "enabled": enabled.to_json(), "params": params }
      let expected = "state/events/evo-policy-" +
        @base.hex_hash(@base.canonical(binding) + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-init" {
      @base.keys(value, ["op", "at", "seed", "policy_hash"])
      let at = string("at")
      event_time(at)
      match @base.field(value, "seed") {
        Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= 0.0 && n <= 4294967295.0 &&
          n == n.to_int().to_double() => ()
        _ => raise @base.Fault("evo_seed_invalid")
      }
      if !valid_hash(string("policy_hash")) { @base.fail("evo_event_identity_invalid:policy_hash") }
      let seed = match @base.field(value, "seed") {
        Number(n, ..) => n.to_int()
        _ => raise @base.Fault("evo_seed_invalid")
      }
      let expected = "state/events/evo-init-" +
        @base.hex_hash(seed.to_string() + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-evaluate" {
      @base.keys(value, ["op", "at", "generation", "window_sha256", "best",
        "mean", "worst", "alive"])
      let at = string("at")
      event_time(at)
      ignore(evo_record_int(value, "generation", 0, 1000000000, "evo_event_invalid"))
      if !valid_hash(string("window_sha256")) { @base.fail("evo_event_identity_invalid:window_sha256") }
      for field in ["best", "mean", "worst"] {
        ignore(evo_record_number(value, field, -1.0, 1.0, "evo_event_invalid"))
      }
      ignore(evo_record_int(value, "alive", 1, 32, "evo_event_invalid"))
      let generation = match @base.field(value, "generation") {
        Number(n, ..) => n.to_int()
        _ => raise @base.Fault("evo_event_invalid:generation")
      }
      let expected = "state/events/evo-evaluate-" +
        @base.hex_hash(generation.to_string() + "\n" + string("window_sha256") + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-evolve" {
      @base.keys(value, ["op", "at", "from_generation", "to_generation",
        "window_sha256", "best", "mean", "worst", "delta", "regressed",
        "rolled_back", "fossils", "extinct"])
      let at = string("at")
      event_time(at)
      let from = evo_record_int(value, "from_generation", 0, 1000000000, "evo_event_invalid")
      let to = evo_record_int(value, "to_generation", 0, 1000000000, "evo_event_invalid")
      let rolled_back = evo_record_bool(value, "rolled_back", "evo_event_invalid")
      if rolled_back {
        if to > from { @base.fail("evo_event_invalid:to_generation") }
      } else if to != from + 1 {
        @base.fail("evo_event_invalid:to_generation")
      }
      if !valid_hash(string("window_sha256")) { @base.fail("evo_event_identity_invalid:window_sha256") }
      for field in ["best", "mean", "worst"] {
        ignore(evo_record_number(value, field, -1.0, 1.0, "evo_event_invalid"))
      }
      ignore(evo_record_number(value, "delta", -2.0, 2.0, "evo_event_invalid"))
      ignore(evo_record_bool(value, "regressed", "evo_event_invalid"))
      for field in ["fossils", "extinct"] {
        ignore(evo_record_int(value, field, 0, 1000000000, "evo_event_invalid"))
      }
      let expected = "state/events/evo-evolve-" +
        @base.hex_hash(from.to_string() + "\n" + string("window_sha256") + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-regression" {
      @base.keys(value, ["op", "at", "generation", "window_sha256", "best",
        "checkpoint", "delta"])
      let at = string("at")
      event_time(at)
      let generation = evo_record_int(value, "generation", 0, 1000000000, "evo_event_invalid")
      if !valid_hash(string("window_sha256")) { @base.fail("evo_event_identity_invalid:window_sha256") }
      let best = evo_record_number(value, "best", -1.0, 1.0, "evo_event_invalid")
      let checkpoint = evo_record_number(value, "checkpoint", -1.0, 1.0, "evo_event_invalid")
      let delta = evo_record_number(value, "delta", -2.0, 2.0, "evo_event_invalid")
      if delta >= 0.0 || delta != best - checkpoint { @base.fail("evo_event_invalid:delta") }
      let expected = "state/events/evo-regression-" +
        @base.hex_hash(generation.to_string() + "\n" + string("window_sha256") + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-rollback" {
      @base.keys(value, ["op", "at", "from_generation", "to_generation",
        "reason", "checkpoint", "fossils"])
      let at = string("at")
      event_time(at)
      let from = evo_record_int(value, "from_generation", 0, 1000000000, "evo_event_invalid")
      let to = evo_record_int(value, "to_generation", 0, 1000000000, "evo_event_invalid")
      if to > from { @base.fail("evo_event_invalid:to_generation") }
      let reason = string("reason")
      if !["regression", "manual"].contains(reason) { @base.fail("evo_event_invalid:reason") }
      if !valid_hash(string("checkpoint")) { @base.fail("evo_event_identity_invalid:checkpoint") }
      ignore(evo_record_int(value, "fossils", 0, 1000000000, "evo_event_invalid"))
      let expected = "state/events/evo-rollback-" +
        @base.hex_hash(to.to_string() + "\n" + reason + "\n" + at) + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
    } else if op == "evo-fossilize" {
      @base.keys(value, ["op", "at", "fossil", "genome", "reason", "generation"])
      let at = string("at")
      event_time(at)
      let fossil = string("fossil")
      if !valid_hash(fossil) || !valid_hash(string("genome")) {
        @base.fail("evo_event_identity_invalid:fossil")
      }
      let reason = string("reason")
      if !["not_selected", "lethal", "regression_rollback", "manual_rollback"].contains(reason) {
        @base.fail("evo_fossil_reason_invalid")
      }
      ignore(evo_record_int(value, "generation", 0, 1000000000, "evo_event_invalid"))
      let expected = "state/events/evo-fossilize-" + fossil + ".json"
      if entry.path != expected { @base.fail("evo_event_identity_invalid") }
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
