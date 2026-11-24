// Evolution face (续三十): a local, deterministic fast loop plus a
// host-triggered slow loop. Nothing here calls a model, the network, a clock
// or a worker; the only randomness is the file-local xorshift128 stream seeded
// from (seed, generation), and the only persisted decisions are ordinary state
// records committed through @vault.commit.
//
// The fast loop turns one host observation into bounded affect/impulse drift.
// The slow loop scores a fixed window, selects, crossovers, mutates, fossilizes
// the losers and rolls back to the best checkpoint when the population falls
// too far below it. Failure is a first-class outcome: fossils are immutable and
// a rollback keeps the failed generation's record.

const EVO_INPUT : Int = 16
const EVO_HIDDEN : Int = 12
const EVO_OUTPUT : Int = 10
// 续三十二: saturation re-arms exploration when the population stops improving.
const EVO_SATURATION_PATIENCE : Int = 3
const EVO_SATURATION_BOOST : Double = 1.5
// Optional knowledge-outcome term: only active when a window carries outcomes.
const EVO_W_KNOWLEDGE : Double = 0.10

priv struct EvoParams {
  population : Int
  window : Int
  elite_ratio : Double
  protect_ratio : Double
  tournament : Int
  crossover_rate : Double
  mutation_rate : Double
  mutation_max : Double
  immigrants : Int
  regression_delta : Double
  regression_patience : Int
  auto_rollback : Bool
  fossil_max_per_gen : Int
  history : Int
  w_stability : Double
  w_responsiveness : Double
  w_growth : Double
  w_novelty : Double
  c_energy : Double
  c_impulse : Double
  c_positive : Double
  c_flatness : Double
  c_holdout : Double
}

priv struct EvoPolicy {
  exists : Bool
  enabled : Bool
  params : EvoParams
  params_json : Json
  updated_at : String
}

priv struct EvoRelation {
  subject : String
  trust : Double
  familiarity : Double
  tension : Double
}

priv struct EvoState {
  steps : Int
  window : Array[Json]
  window_sha256 : String
  emotion : Array[Double]
  impulse : Double
  body : Json
  relations : Array[EvoRelation]
  active_genome : String?
  last_observe : Json
  last_fire_step : Int?
  // The last time the agent subject was observably busy (a user turn, a host
  // report, or initialization). The proactive gate requires a long idle gap
  // after this stamp; self-monitoring observations never move it.
  last_activity_at : String?
  guard_hits : Int
  impulses : Int
  blowups : Int
  created_at : String
}

priv struct EvoMember {
  genome : String
  fitness : Double?
  breakdown : Json
  age : Int
  evaluated_generation : Int?
  status : String
}

priv struct EvoPopulation {
  generation : Int
  init : Json
  members : Array[EvoMember]
  checkpoint : Json
  history : Array[Json]
  regression_streak : Int
  no_improve_streak : Int
  saturations_total : Int
  extinct_total : Int
  fossil_total : Int
  regressions_total : Int
  rollbacks_total : Int
  last_eval : Json
  last_evolve : Json
  last_rollback : Json
}

priv struct EvoGenome {
  generation : Int
  parents : Array[String]
  weights : Array[Double]
  weights_sha256 : String
}

priv struct EvoCheckpoint {
  generation : Int
  genome : String
  fitness : Double
  scenario : Int?
}

priv struct EvoLastEval {
  generation : Int
  window_sha256 : String
  at : String
  best : Double
  mean : Double
  worst : Double
  alive : Int
}

priv struct EvoLastEvolve {
  from_generation : Int
  to_generation : Int
  window_sha256 : String
  at : String
  best : Double
  mean : Double
  worst : Double
  delta : Double
  regressed : Bool
  rolled_back : Bool
  fossils : Int
  extinct : Int
  immigrants : Int
  elite : Int
  protected_count : Int
  rng_seed : String
}

priv struct EvoLastRollback {
  at : String
  from_generation : Int
  to_generation : Int
  reason : String
  checkpoint : String
  fossils : Int
}

priv struct EvoRng {
  s0 : Ref[UInt]
  s1 : Ref[UInt]
  s2 : Ref[UInt]
  s3 : Ref[UInt]
}

priv struct EvoApply {
  emotion : Array[Double]
  impulse : Double
  fired : Bool
  action : Array[Double]
  threshold : Double
  blowup : Int
  last_fire_step : Int?
  relation_output : Double
  nonfinite : Bool
}

priv struct EvoTrajectory {
  emotion : Array[Array[Double]]
  fired : Array[Bool]
  blowups : Array[Int]
  trust_delta : Array[Double]
  has_subject : Array[Bool]
  valence : Array[Double]
  outcome : Array[Double]
  nonfinite : Bool
}

priv struct EvoSegment {
  stability : Double
  responsiveness : Double
  growth : Double
  novelty : Double
  energy_cost : Double
  impulse_blowups : Double
  positive_penalty : Double
  flatness_penalty : Double
  knowledge : Double
  has_outcome : Bool
}

priv struct EvoBatch {
  changes : Array[@vault.Change]
}

// ---- small numeric helpers ------------------------------------------------

fn evo_clamp(value : Double, low : Double, high : Double) -> Double {
  if value < low { low } else if value > high { high } else { value }
}

fn evo_clamp_int(value : Int, low : Int, high : Int) -> Int {
  if value < low { low } else if value > high { high } else { value }
}

fn evo_finite(value : Double) -> Bool {
  !value.is_nan() && !value.is_inf()
}

fn evo_all_finite(values : Array[Double]) -> Bool {
  for value in values {
    if !evo_finite(value) { return false }
  }
  true
}

// Padé approximant: no libm, identical bit-for-bit on native and wasm.
fn evo_tanh_pade(value : Double) -> Double {
  let x = evo_clamp(value, -8.0, 8.0)
  let t = x * x
  let numerator = x * (135135.0 + t * (17325.0 + t * (378.0 + t)))
  let denominator = 135135.0 + t * (62370.0 + t * (3150.0 + 28.0 * t))
  evo_clamp(numerator / denominator, -1.0, 1.0)
}

fn evo_quantize(value : Double) -> Double {
  Float::from_double(value).to_double()
}

// ---- deterministic PRNG ---------------------------------------------------

fn evo_hex_digit(code : Char) -> UInt {
  let value = code.to_int()
  if value >= 48 && value <= 57 { (value - 48).reinterpret_as_uint() }
  else if value >= 97 && value <= 102 { (value - 87).reinterpret_as_uint() }
  else { 0U }
}

fn evo_rng_seed_text(seed : Int, generation : Int) -> String {
  let digest = @base.hex_hash(seed.to_string() + ":" + generation.to_string())
  let out = StringBuilder()
  for i = 0; i < 16; i = i + 1 {
    out.write_char(digest.get_char(i).unwrap())
  }
  out.to_string()
}

fn evo_rng_word(text : String, start : Int) -> UInt {
  let mut value : UInt = 0U
  for i = start; i < start + 8; i = i + 1 {
    value = (value << 4) | evo_hex_digit(text.get_char(i).unwrap())
  }
  value | 1U
}

fn evo_rng(seed : Int, generation : Int) -> EvoRng {
  let text = @base.hex_hash(seed.to_string() + ":" + generation.to_string())
  {
    s0: { val: evo_rng_word(text, 0) },
    s1: { val: evo_rng_word(text, 8) },
    s2: { val: evo_rng_word(text, 16) },
    s3: { val: evo_rng_word(text, 24) },
  }
}

fn evo_rng_next(rng : EvoRng) -> UInt {
  let t = rng.s0.val ^ (rng.s0.val << 11)
  rng.s0.val = rng.s1.val
  rng.s1.val = rng.s2.val
  rng.s2.val = rng.s3.val
  rng.s3.val = rng.s3.val ^ (rng.s3.val >> 19) ^ t ^ (t >> 8)
  rng.s3.val
}

fn evo_rng_unit(rng : EvoRng) -> Double {
  evo_rng_next(rng).to_double() / 4294967296.0
}

// Sum of six uniforms minus three, scaled by sqrt(2): standard deviation 1,
// no sin/ln, so the stream is identical on every target.
fn evo_gaussian(rng : EvoRng) -> Double {
  let mut sum = 0.0
  for _ in 0..<6 { sum = sum + evo_rng_unit(rng) }
  (sum - 3.0) * (2.0).sqrt()
}

fn evo_xavier(rng : EvoRng) -> Array[Double] {
  let limit_x = (6.0 / 28.0).sqrt()
  let limit_o = (6.0 / 22.0).sqrt()
  let weights : Array[Double] = []
  for index = 0; index < @core.EVO_WEIGHTS; index = index + 1 {
    if (index >= 192 && index < 204) || index >= 324 {
      weights.push(0.0)
    } else {
      let limit = if index < 192 { limit_x } else { limit_o }
      weights.push(evo_quantize((2.0 * evo_rng_unit(rng) - 1.0) * limit))
    }
  }
  weights
}

// ---- policy ---------------------------------------------------------------

fn evo_defaults_json() -> Json {
  {
    "population": 16, "window": 128, "elite_ratio": 0.25, "protect_ratio": 0.10,
    "tournament": 3, "crossover_rate": 0.65, "mutation_rate": 0.12,
    "mutation_max": 0.40, "immigrants": 1, "regression_delta": 0.05,
    "regression_patience": 2, "auto_rollback": true, "fossil_max_per_gen": 4,
    "history": 16, "w_stability": 0.30, "w_responsiveness": 0.20,
    "w_growth": 0.15, "w_novelty": 0.10, "c_energy": 0.10, "c_impulse": 0.10,
    "c_positive": 0.15, "c_flatness": 0.15, "c_holdout": 0.15,
  }
}

fn evo_default_params() -> EvoParams {
  {
    population: 16, window: 128, elite_ratio: 0.25, protect_ratio: 0.10,
    tournament: 3, crossover_rate: 0.65, mutation_rate: 0.12,
    mutation_max: 0.40, immigrants: 1, regression_delta: 0.05,
    regression_patience: 2, auto_rollback: true, fossil_max_per_gen: 4,
    history: 16, w_stability: 0.30, w_responsiveness: 0.20, w_growth: 0.15,
    w_novelty: 0.10, c_energy: 0.10, c_impulse: 0.10, c_positive: 0.15,
    c_flatness: 0.15, c_holdout: 0.15,
  }
}

fn evo_param_int(value : Json, name : String) -> Int raise @base.Fault {
  match @base.field(value, name) {
    Number(n, ..) => n.to_int()
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

fn evo_param_number(value : Json, name : String) -> Double raise @base.Fault {
  match @base.field(value, name) {
    Number(n, ..) => n
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

fn evo_param_bool(value : Json, name : String) -> Bool raise @base.Fault {
  match @base.field(value, name) {
    True => true
    False => false
    _ => raise @base.Fault("evo_policy_param_invalid:" + name)
  }
}

fn evo_params_from_json(value : Json) -> EvoParams raise @base.Fault {
  @core.evo_policy_params(value)
  {
    population: evo_param_int(value, "population"),
    window: evo_param_int(value, "window"),
    elite_ratio: evo_param_number(value, "elite_ratio"),
    protect_ratio: evo_param_number(value, "protect_ratio"),
    tournament: evo_param_int(value, "tournament"),
    crossover_rate: evo_param_number(value, "crossover_rate"),
    mutation_rate: evo_param_number(value, "mutation_rate"),
    mutation_max: evo_param_number(value, "mutation_max"),
    immigrants: evo_param_int(value, "immigrants"),
    regression_delta: evo_param_number(value, "regression_delta"),
    regression_patience: evo_param_int(value, "regression_patience"),
    auto_rollback: evo_param_bool(value, "auto_rollback"),
    fossil_max_per_gen: evo_param_int(value, "fossil_max_per_gen"),
    history: evo_param_int(value, "history"),
    w_stability: evo_param_number(value, "w_stability"),
    w_responsiveness: evo_param_number(value, "w_responsiveness"),
    w_growth: evo_param_number(value, "w_growth"),
    w_novelty: evo_param_number(value, "w_novelty"),
    c_energy: evo_param_number(value, "c_energy"),
    c_impulse: evo_param_number(value, "c_impulse"),
    c_positive: evo_param_number(value, "c_positive"),
    c_flatness: evo_param_number(value, "c_flatness"),
    c_holdout: evo_param_number(value, "c_holdout"),
  }
}

fn evo_load_policy(store : @vault.Storage) -> EvoPolicy raise @base.Fault {
  // Pre-sidecar vaults keep the policy at state/evo/policy.json until the
  // migration moves it; the gate must read it there (read-only) so a legacy
  // vault is not locked out of its own enable switch.
  let path = if (store.read)("evo/policy.json") is Some(_) {
    "evo/policy.json"
  } else {
    "state/evo/policy.json"
  }
  match (store.read)(path) {
    None => {
      {
        exists: false, enabled: false, params: evo_default_params(),
        params_json: evo_defaults_json(), updated_at: "",
      }
    }
    Some(text) => {
      let record = try { @base.parse(text) } catch {
        _ => raise @base.Fault("evo_policy_corrupt")
      }
      let shaped = try { @core.evo_policy_record_shape(record); true } catch { _ => false }
      if !shaped { @base.fail("evo_policy_corrupt") }
      let params_json = @base.field(record, "params")
      {
        exists: true,
        enabled: @base.boolean(@base.field(record, "enabled")),
        params: evo_params_from_json(params_json),
        params_json,
        updated_at: @base.text(@base.field(record, "updated_at")),
      }
    }
  }
}

fn evo_policy_record(policy : EvoPolicy) -> Json {
  {
    "version": 1, "enabled": policy.enabled.to_json(),
    "params": policy.params_json, "updated_at": policy.updated_at,
  }
}

// ---- request helpers ------------------------------------------------------

fn evo_request_keys(request : Json, fields : Array[String]) -> Unit raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "progress"] + fields)
}

fn evo_optional(request : Json, key : String) -> Json? {
  match request { Object(fields) => fields.get(key); _ => None }
}

fn evo_text(request : Json, key : String) -> String raise @base.Fault {
  @base.text(@base.field(request, key))
}

fn evo_at_text(request : Json) -> String raise @base.Fault {
  let at = evo_text(request, "at")
  if at.length() < 10 || at.contains("\n") || at.contains("\r") {
    @base.fail("evo_policy_time_invalid")
  }
  at
}

fn evo_request_number(request : Json, key : String, low : Double, high : Double) -> Double raise @base.Fault {
  match @base.field(request, key) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low && n <= high => n
    _ => raise @base.Fault("evo_numeric_invalid:" + key)
  }
}

fn evo_request_int(request : Json, key : String, low : Int, high : Int) -> Int raise @base.Fault {
  match @base.field(request, key) {
    Number(n, ..) if !n.is_nan() && !n.is_inf() && n >= low.to_double() &&
      n <= high.to_double() && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("evo_step_invalid")
  }
}

fn evo_subject_arg(request : Json) -> String? raise @base.Fault {
  match evo_optional(request, "subject") {
    None => None
    Some(Null) => None
    Some(String(subject)) => {
      let size = @base.utf8_size(subject)
      if size < 1 || size > 64 || subject.contains("\n") || subject.contains("\r") {
        @base.fail("evo_subject_invalid")
      }
      Some(subject)
    }
    Some(_) => raise @base.Fault("evo_subject_invalid")
  }
}

fn evo_body_arg(request : Json) -> Json raise @base.Fault {
  let body = @base.field(request, "body")
  @base.keys(body, ["cpu", "memory", "latency", "budget"])
  for field in ["cpu", "memory", "latency", "budget"] {
    ignore(evo_request_number(body, field, 0.0, 1.0))
  }
  body
}

fn evo_body_value(body : Json, field : String) -> Double raise @base.Fault {
  match @base.field(body, field) {
    Number(n, ..) => n
    _ => raise @base.Fault("evo_numeric_invalid:" + field)
  }
}

fn evo_payload(kind : String, salience : Double, valence : Double, body : Json,
  subject : String?, outcome : Double) -> Json {
  let base : Json = {
    "kind": kind, "salience": salience, "valence": valence, "body": body,
    "subject": match subject { None => Json::null(); Some(value) => value.to_json() },
  }
  // Keep the historical payload byte-identical when no outcome is supplied, so
  // replaying a pre-upgrade step still matches its stored payload hash.
  if outcome == 0.0 {
    base
  } else {
    match base {
      Object(fields) => {
        let copy = fields.copy()
        copy["outcome"] = outcome.to_json()
        Json::object(copy)
      }
      _ => base
    }
  }
}

// ---- record parsing -------------------------------------------------------

fn evo_json_int(value : Json, key : String, code : String) -> Int raise @base.Fault {
  match @base.field(value, key) {
    Number(n, ..) => n.to_int()
    _ => raise @base.Fault(code + ":" + key)
  }
}

fn evo_json_number(value : Json, key : String, code : String) -> Double raise @base.Fault {
  match @base.field(value, key) {
    Number(n, ..) => n
    _ => raise @base.Fault(code + ":" + key)
  }
}

fn evo_json_bool(value : Json, key : String, code : String) -> Bool raise @base.Fault {
  match @base.field(value, key) {
    True => true
    False => false
    _ => raise @base.Fault(code + ":" + key)
  }
}

fn evo_relation_json(relation : EvoRelation) -> Json {
  {
    "subject": relation.subject, "trust": relation.trust,
    "familiarity": relation.familiarity, "tension": relation.tension,
  }
}

fn evo_state_from_json(record : Json) -> EvoState raise @base.Fault {
  let code = "evo_state_record_invalid"
  let relations : Array[EvoRelation] = []
  for item in @base.array(@base.field(record, "relations")) {
    relations.push({
      subject: @base.text(@base.field(item, "subject")),
      trust: evo_json_number(item, "trust", code),
      familiarity: evo_json_number(item, "familiarity", code),
      tension: evo_json_number(item, "tension", code),
    })
  }
  {
    steps: evo_json_int(record, "steps", code),
    window: @base.array(@base.field(record, "window")),
    window_sha256: @base.text(@base.field(record, "window_sha256")),
    emotion: @base.array(@base.field(record, "emotion")).map(item => match item {
      Number(n, ..) => n
      _ => raise @base.Fault(code + ":emotion")
    }),
    impulse: evo_json_number(record, "impulse", code),
    body: @base.field(record, "body"),
    relations,
    active_genome: match @base.field(record, "active_genome") {
      Null => None
      String(value) => Some(value)
      _ => raise @base.Fault(code + ":active_genome")
    },
    last_observe: @base.field(record, "last_observe"),
    last_fire_step: match @base.field(record, "last_fire_step") {
      Null => None
      Number(n, ..) => Some(n.to_int())
      _ => raise @base.Fault(code + ":last_fire_step")
    },
    last_activity_at: match optional(record, "last_activity_at") {
      None => None
      Some(Null) => None
      Some(String(value)) => Some(value)
      _ => raise @base.Fault(code + ":last_activity_at")
    },
    guard_hits: evo_json_int(record, "guard_hits", code),
    impulses: evo_json_int(record, "impulses", code),
    blowups: evo_json_int(record, "blowups", code),
    created_at: @base.text(@base.field(record, "created_at")),
  }
}

fn evo_state_json(state : EvoState, updated_at : String) -> Json {
  {
    "version": 1, "steps": state.steps, "window": state.window.to_json(),
    "window_sha256": state.window_sha256,
    "emotion": state.emotion.map(value => value.to_json()).to_json(),
    "impulse": state.impulse, "body": state.body,
    "relations": state.relations.map(evo_relation_json).to_json(),
    "active_genome": match state.active_genome {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "last_observe": state.last_observe,
    "last_fire_step": match state.last_fire_step {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "last_activity_at": match state.last_activity_at {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "guard_hits": state.guard_hits, "impulses": state.impulses,
    "blowups": state.blowups, "created_at": state.created_at,
    "updated_at": updated_at,
  }
}

fn evo_member_json(row : EvoMember) -> Json {
  {
    "genome": row.genome,
    "fitness": match row.fitness { None => Json::null(); Some(value) => value.to_json() },
    "breakdown": row.breakdown,
    "age": row.age,
    "evaluated_generation": match row.evaluated_generation {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "status": row.status,
  }
}

fn evo_member_from_json(row : Json) -> EvoMember raise @base.Fault {
  let code = "evo_population_record_invalid"
  {
    genome: @base.text(@base.field(row, "genome")),
    fitness: match @base.field(row, "fitness") {
      Null => None
      Number(n, ..) => Some(n)
      _ => raise @base.Fault(code + ":fitness")
    },
    breakdown: @base.field(row, "breakdown"),
    age: evo_json_int(row, "age", code),
    evaluated_generation: match @base.field(row, "evaluated_generation") {
      Null => None
      Number(n, ..) => Some(n.to_int())
      _ => raise @base.Fault(code + ":evaluated_generation")
    },
    status: @base.text(@base.field(row, "status")),
  }
}

fn evo_population_from_json(record : Json) -> EvoPopulation raise @base.Fault {
  let code = "evo_population_record_invalid"
  let members : Array[EvoMember] = []
  for row in @base.array(@base.field(record, "members")) {
    members.push(evo_member_from_json(row))
  }
  {
    generation: evo_json_int(record, "generation", code),
    init: @base.field(record, "init"),
    members,
    checkpoint: @base.field(record, "checkpoint"),
    history: @base.array(@base.field(record, "history")),
    regression_streak: evo_json_int(record, "regression_streak", code),
    no_improve_streak: evo_json_int(record, "no_improve_streak", code),
    saturations_total: evo_json_int(record, "saturations_total", code),
    extinct_total: evo_json_int(record, "extinct_total", code),
    fossil_total: evo_json_int(record, "fossil_total", code),
    regressions_total: evo_json_int(record, "regressions_total", code),
    rollbacks_total: evo_json_int(record, "rollbacks_total", code),
    last_eval: @base.field(record, "last_eval"),
    last_evolve: @base.field(record, "last_evolve"),
    last_rollback: @base.field(record, "last_rollback"),
  }
}

fn evo_population_json(population : EvoPopulation, updated_at : String) -> Json {
  {
    "version": 1, "generation": population.generation, "init": population.init,
    "members": population.members.map(evo_member_json).to_json(),
    "checkpoint": population.checkpoint,
    "history": population.history.to_json(),
    "regression_streak": population.regression_streak,
    "no_improve_streak": population.no_improve_streak,
    "saturations_total": population.saturations_total,
    "extinct_total": population.extinct_total,
    "fossil_total": population.fossil_total,
    "regressions_total": population.regressions_total,
    "rollbacks_total": population.rollbacks_total,
    "last_eval": population.last_eval, "last_evolve": population.last_evolve,
    "last_rollback": population.last_rollback, "updated_at": updated_at,
  }
}

fn evo_checkpoint(value : Json) -> EvoCheckpoint? raise @base.Fault {
  match value {
    Null => None
    _ => Some({
      generation: evo_json_int(value, "generation", "evo_population_record_invalid"),
      genome: @base.text(@base.field(value, "genome")),
      fitness: evo_json_number(value, "fitness", "evo_population_record_invalid"),
      scenario: match evo_optional(value, "scenario") {
        Some(Number(n, ..)) => Some(n.to_int())
        _ => None
      },
    })
  }
}

// Regression evidence counts only when the evaluation scenario matches the
// checkpoint's: a fitness drop across a scenario rotation is the rotation's
// noise, not drift. A pre-rotation checkpoint (no scenario) is gated off
// until it is replaced under a known scenario.
fn evo_scenario_gate(checkpoint : EvoCheckpoint?, generation : Int) -> Bool {
  match checkpoint {
    Some(value) => value.scenario == Some(evo_scenario(generation))
    None => false
  }
}

fn evo_last_eval(value : Json) -> EvoLastEval? raise @base.Fault {
  match value {
    Null => None
    _ => Some({
      generation: evo_json_int(value, "generation", "evo_population_record_invalid"),
      window_sha256: @base.text(@base.field(value, "window_sha256")),
      at: @base.text(@base.field(value, "at")),
      best: evo_json_number(value, "best", "evo_population_record_invalid"),
      mean: evo_json_number(value, "mean", "evo_population_record_invalid"),
      worst: evo_json_number(value, "worst", "evo_population_record_invalid"),
      alive: evo_json_int(value, "alive", "evo_population_record_invalid"),
    })
  }
}

fn evo_last_evolve(value : Json) -> EvoLastEvolve? raise @base.Fault {
  match value {
    Null => None
    _ => Some({
      from_generation: evo_json_int(value, "from_generation", "evo_population_record_invalid"),
      to_generation: evo_json_int(value, "to_generation", "evo_population_record_invalid"),
      window_sha256: @base.text(@base.field(value, "window_sha256")),
      at: @base.text(@base.field(value, "at")),
      best: evo_json_number(value, "best", "evo_population_record_invalid"),
      mean: evo_json_number(value, "mean", "evo_population_record_invalid"),
      worst: evo_json_number(value, "worst", "evo_population_record_invalid"),
      delta: evo_json_number(value, "delta", "evo_population_record_invalid"),
      regressed: evo_json_bool(value, "regressed", "evo_population_record_invalid"),
      rolled_back: evo_json_bool(value, "rolled_back", "evo_population_record_invalid"),
      fossils: evo_json_int(value, "fossils", "evo_population_record_invalid"),
      extinct: evo_json_int(value, "extinct", "evo_population_record_invalid"),
      immigrants: evo_json_int(value, "immigrants", "evo_population_record_invalid"),
      elite: evo_json_int(value, "elite", "evo_population_record_invalid"),
      protected_count: evo_json_int(value, "protected", "evo_population_record_invalid"),
      rng_seed: @base.text(@base.field(value, "rng_seed")),
    })
  }
}

fn evo_last_rollback(value : Json) -> EvoLastRollback? raise @base.Fault {
  match value {
    Null => None
    _ => Some({
      at: @base.text(@base.field(value, "at")),
      from_generation: evo_json_int(value, "from_generation", "evo_population_record_invalid"),
      to_generation: evo_json_int(value, "to_generation", "evo_population_record_invalid"),
      reason: @base.text(@base.field(value, "reason")),
      checkpoint: @base.text(@base.field(value, "checkpoint")),
      fossils: evo_json_int(value, "fossils", "evo_population_record_invalid"),
    })
  }
}

fn evo_genome_from_json(record : Json) -> EvoGenome raise @base.Fault {
  {
    generation: evo_json_int(record, "generation", "evo_genome_record_invalid"),
    parents: @base.array(@base.field(record, "parents")).map(item => @base.text(item)),
    weights: @core.evo_weights_from_json(@base.field(record, "weights")),
    weights_sha256: @base.text(@base.field(record, "weights_sha256")),
  }
}

fn evo_genome_path(id : String) -> String {
  "evo/genomes/" + id + ".json"
}

fn evo_load_genome(
  store : @vault.Storage, entries : Array[@core.Entry], id : String,
) -> EvoGenome raise @base.Fault {
  ignore(entries)
  let path = evo_genome_path(id)
  let text = match (store.read)(path) {
    None => { @base.fail("evo_genome_not_found: " + id); "" }
    Some(value) => value
  }
  evo_genome_from_json(@base.parse(text))
}

// ---- window entries -------------------------------------------------------

fn evo_window_entry_json(
  step : Int, at : String, input : Array[Double], emotion : Array[Double],
  impulse : Double, fired : Bool, subject : String?, outcome : Double,
) -> Json {
  {
    "step": step, "at": at, "input": input.map(value => value.to_json()).to_json(),
    "emotion": emotion.map(value => value.to_json()).to_json(),
    "impulse": impulse, "fired": fired.to_json(),
    "subject": match subject { None => Json::null(); Some(value) => value.to_json() },
    "outcome": outcome,
  }
}

fn evo_window_input(entry : Json) -> Array[Double] raise @base.Fault {
  @base.array(@base.field(entry, "input")).map(item => match item {
    Number(n, ..) => n
    _ => raise @base.Fault("evo_state_window_invalid:input")
  })
}

fn evo_window_subject(entry : Json) -> String? raise @base.Fault {
  match @base.field(entry, "subject") {
    Null => None
    String(value) => Some(value)
    _ => raise @base.Fault("evo_state_window_invalid:subject")
  }
}

fn evo_window_step(entry : Json) -> Int raise @base.Fault {
  match @base.field(entry, "step") {
    Number(n, ..) => n.to_int()
    _ => raise @base.Fault("evo_state_window_invalid:step")
  }
}

// ---- controller -----------------------------------------------------------

fn evo_forward(weights : Array[Double], input : Array[Double]) -> (Array[Double], Array[Double]) {
  let hidden = Array::make(EVO_HIDDEN, 0.0)
  for row = 0; row < EVO_HIDDEN; row = row + 1 {
    let mut sum = weights[192 + row]
    for column = 0; column < EVO_INPUT; column = column + 1 {
      sum = sum + weights[row * EVO_INPUT + column] * input[column]
    }
    hidden[row] = evo_tanh_pade(sum)
  }
  let output = Array::make(EVO_OUTPUT, 0.0)
  for row = 0; row < EVO_OUTPUT; row = row + 1 {
    let mut sum = weights[324 + row]
    for column = 0; column < EVO_HIDDEN; column = column + 1 {
      sum = sum + weights[204 + row * EVO_HIDDEN + column] * hidden[column]
    }
    output[row] = evo_tanh_pade(sum)
  }
  (hidden, output)
}

fn evo_apply(
  weights : Array[Double], old_emotion : Array[Double], old_impulse : Double,
  last_fire_step : Int?, input : Array[Double], step : Int,
) -> EvoApply {
  let (_, output) = evo_forward(weights, input)
  let fatigue = (input[6] + input[9]) / 2.0
  let gain = evo_clamp(0.10 + 0.10 * output[3], 0.02, 0.20)
  let decay_impulse = evo_clamp(0.88 - 0.08 * output[4], 0.70, 0.96)
  let decay_emotion = evo_clamp(0.90 + 0.08 * output[5], 0.72, 0.98)
  let threshold = evo_clamp(
    0.55 + 0.30 * (1.0 - fatigue) + 0.10 * output[9], 0.30, 0.95)
  let emotion = Array::make(3, 0.0)
  for dimension = 0; dimension < 3; dimension = dimension + 1 {
    emotion[dimension] = evo_clamp(
      old_emotion[dimension] * decay_emotion + 0.15 * output[dimension], -1.0, 1.0)
  }
  let drive = (if output[3] > 0.0 { output[3] } else { 0.0 }) * (0.5 + 0.5 * input[4])
  let mut impulse = evo_clamp(old_impulse * decay_impulse + gain * drive, 0.0, 1.0)
  let mut blowup = 0
  match last_fire_step {
    Some(previous) => if step - previous < 3 { blowup = 1 }
    None => ()
  }
  let mut fired = false
  let mut last = last_fire_step
  if impulse >= threshold {
    fired = true
    impulse = 0.0
    last = Some(step)
  }
  let action = [output[6], output[7], output[8]]
  let nonfinite = !evo_all_finite(output) || !evo_all_finite(emotion) ||
    !evo_finite(impulse) || !evo_finite(threshold) || !evo_finite(gain) ||
    !evo_finite(decay_impulse) || !evo_finite(decay_emotion)
  {
    emotion, impulse, fired, action, threshold, blowup, last_fire_step: last,
    relation_output: output[6], nonfinite,
  }
}

fn evo_relation_delta(old : EvoRelation?, output : Double, valence : Double) -> (Double, Double, Double) {
  let trust = match old { None => 0.0; Some(value) => value.trust }
  let familiarity = match old { None => 0.0; Some(value) => value.familiarity }
  let tension = match old { None => 0.0; Some(value) => value.tension }
  let new_trust = evo_clamp(trust + 0.10 * output + 0.05 * valence, 0.0, 1.0)
  let new_familiarity = evo_clamp(familiarity + 0.05 * (1.0 - familiarity), 0.0, 1.0)
  let new_tension = evo_clamp(tension + 0.08 * (if valence < 0.0 { -valence } else { 0.0 }) - 0.05, 0.0, 1.0)
  (new_trust, new_familiarity, new_tension)
}

fn evo_relation_find(relations : Array[EvoRelation], subject : String) -> EvoRelation? {
  for relation in relations {
    if relation.subject == subject { return Some(relation) }
  }
  None
}

fn evo_relations_sort(relations : Array[EvoRelation]) -> Array[EvoRelation] {
  let sorted = relations.copy()
  sorted.sort_by((a, b) => @base.compare(a.subject, b.subject))
  sorted
}

// ---- fitness --------------------------------------------------------------

// Knowledge alignment: only steps with a non-zero host outcome count. A member
// whose emotional valence tracks the outcome (same sign, close magnitude) is
// rewarded; members are otherwise free to differ in their affect trajectory.
fn evo_knowledge_alignment(valence : Array[Double], outcome : Array[Double]) -> (Double, Bool) {
  let count = Int::min(valence.length(), outcome.length())
  let mut scored = 0
  let mut total = 0.0
  for index = 0; index < count; index = index + 1 {
    let observed = outcome[index]
    if observed != 0.0 {
      scored = scored + 1
      let diff = (valence[index] - observed).abs()
      total = total + (1.0 - evo_clamp(diff / 2.0, 0.0, 1.0))
    }
  }
  if scored == 0 { (0.0, false) } else { (total / scored.to_double(), true) }
}

// Deterministic seeded holdout (续五十六): the split is a Fisher-Yates shuffle of
// the window indices seeded by the window hash, so every member of a generation
// is evaluated on the same train/holdout sets and the result replays byte for
// byte. It is deliberately NOT a time suffix: overfitting detection must not
// depend on observation order.
fn evo_split_indices(length : Int, window_sha256 : String) -> (Array[Int], Array[Int]) {
  let digest = @base.hex_hash("evo-holdout-v1\n" + window_sha256)
  let mut s0 = evo_rng_word(digest, 0)
  let mut s1 = evo_rng_word(digest, 8)
  let mut s2 = evo_rng_word(digest, 16)
  let mut s3 = evo_rng_word(digest, 24)
  let indices = Array::make(length, 0)
  for i = 0; i < length; i = i + 1 { indices[i] = i }
  let mut i = length
  while i > 1 {
    let t = s0 ^ (s0 << 11)
    s0 = s1
    s1 = s2
    s2 = s3
    s3 = s3 ^ (s3 >> 19) ^ t ^ (t >> 8)
    let unit = s3.to_double() / 4294967296.0
    let j = (unit * i.to_double()).to_int()
    let tmp = indices[i - 1]
    indices[i - 1] = indices[j]
    indices[j] = tmp
    i = i - 1
  }
  let train_count = Int::max(1, (length.to_double() * 0.7).to_int())
  (indices[:train_count].to_owned(), indices[train_count:].to_owned())
}

// 续五十八: scenario rotation. The same window is re-scored under a rotated
// environment every generation (event distribution, body stress, relationship
// objects), so a champion fitted to one condition can fail outright once the
// scenario turns — the mechanismized "good days do not last". The scenario is
// a pure function of the generation, so evaluation stays deterministic and a
// replay of the same (window, generation) always sees the same drift.
const EVO_SCENARIO_COUNT : Int = 4

fn evo_scenario(generation : Int) -> Int {
  generation % EVO_SCENARIO_COUNT
}

fn evo_row_set(row : Json, key : String, value : Json) -> Json {
  match row {
    Object(fields) => {
      let copy = fields.copy()
      copy[key] = value
      Json::object(copy)
    }
    _ => row
  }
}

// Returns a transformed *copy* of one window row. The stored window, its hash
// and the holdout split seed stay on the raw rows; only the controller sees
// the drifted condition.
fn evo_scenario_row(row : Json, scenario : Int) -> Json raise @base.Fault {
  if scenario == 0 { return row }
  let input = evo_window_input(row)
  let next = input.copy()
  if scenario == 1 {
    // body stress: every vitals channel is pushed toward its ceiling
    for i = 6; i <= 9; i = i + 1 { next[i] = evo_clamp(next[i] * 1.5, 0.0, 1.0) }
  } else if scenario == 2 {
    // event skew: the host's affect turns hostile
    next[5] = evo_clamp(next[5] - 0.5, -1.0, 1.0)
  } else if scenario == 3 {
    // subject churn: the relationship object withdraws
    for i = 10; i <= 12; i = i + 1 { next[i] = 0.0 }
  }
  let updated = evo_row_set(row, "input", next.map(value => value.to_json()).to_json())
  if scenario == 3 { evo_row_set(updated, "subject", Json::null()) } else { updated }
}

fn evo_segment(
  trajectory : EvoTrajectory, mean : Array[Array[Double]], indices : Array[Int],
) -> EvoSegment {
  let length = if indices.length() > 0 { indices.length() } else { 1 }
  let mut unstable = 0
  let mut fired = 0
  let mut blowups = 0
  let mut growth = 0.0
  let mut subject_events = 0
  let mut novelty = 0.0
  let mut positive = 0
  let mut emotional_sum = 0.0
  for step in indices {
    if trajectory.nonfinite { unstable = unstable + 1 }
    if trajectory.fired[step] { fired = fired + 1 }
    blowups = blowups + trajectory.blowups[step]
    if trajectory.has_subject[step] {
      subject_events = subject_events + 1
      growth = growth + trajectory.trust_delta[step]
    }
    let mut distance = 0.0
    for dimension = 0; dimension < 3; dimension = dimension + 1 {
      distance = distance + (trajectory.emotion[step][dimension] - mean[step][dimension]).abs()
    }
    novelty = novelty + distance / 6.0
    if trajectory.emotion[step][0] >= 0.75 { positive = positive + 1 }
    emotional_sum = emotional_sum + trajectory.emotion[step][0]
  }
  let steps = length.to_double()
  let stability = 1.0 - evo_clamp((unstable + blowups).to_double() / steps, 0.0, 1.0)
  let responsiveness = evo_responsiveness(trajectory, indices)
  let growth_score = if subject_events == 0 { 0.5 } else { evo_clamp(0.5 + 0.5 * growth, 0.0, 1.0) }
  let novelty_score = novelty / steps
  let energy = evo_clamp(fired.to_double() / 8.0, 0.0, 1.0)
  let blowup_score = evo_clamp(blowups.to_double() / 3.0, 0.0, 1.0)
  let positive_share = positive.to_double() / steps
  let positive_penalty = evo_clamp(2.0 * (positive_share - 0.5), 0.0, 1.0)
  let mean_emotion = emotional_sum / steps
  let mut variance = 0.0
  for step in indices {
    let delta = trajectory.emotion[step][0] - mean_emotion
    variance = variance + delta * delta
  }
  let deviation = (variance / steps).sqrt()
  let flatness = evo_clamp(1.0 - deviation / 0.15, 0.0, 1.0)
  // The member's *output* emotion, not the host input valence: the same window
  // must be able to rank members by how their affect tracks the outcome.
  let member_valence = trajectory.emotion.map(row => row[0])
  let (knowledge, has_outcome) = evo_knowledge_alignment(member_valence, trajectory.outcome)
  {
    stability, responsiveness, growth: growth_score, novelty: novelty_score,
    energy_cost: energy, impulse_blowups: blowup_score,
    positive_penalty, flatness_penalty: flatness,
    knowledge, has_outcome,
  }
}

// Responsiveness measures recovery after a strong host stimulus. Arousal is
// emotion[1]; overshoot above 0.70 and a slow return both cost score.
fn evo_responsiveness(trajectory : EvoTrajectory, indices : Array[Int]) -> Double {
  let total_steps = trajectory.emotion.length()
  let mut stimuli = 0
  let mut total = 0.0
  for step in indices {
    if trajectory.valence[step].abs() < 0.5 { continue }
    stimuli = stimuli + 1
    let mut peak = 0.0
    for offset = 0; offset < 3; offset = offset + 1 {
      let at = step + offset
      if at < total_steps {
        let arousal = trajectory.emotion[at][1].abs()
        if arousal > peak { peak = arousal }
      }
    }
    let mut recover = 8
    for offset = 0; offset < 8; offset = offset + 1 {
      let at = step + offset
      if at < total_steps && trajectory.emotion[at][1].abs() <= 0.25 {
        recover = offset
        break
      }
    }
    let overshoot = if peak > 0.70 { (peak - 0.70) / 0.30 } else { 0.0 }
    total = total + evo_clamp(1.0 - 0.10 * recover.to_double(), 0.0, 1.0) *
      evo_clamp(1.0 - overshoot, 0.0, 1.0)
  }
  if stimuli == 0 { 0.5 } else { total / stimuli.to_double() }
}

fn evo_segment_score(segment : EvoSegment, params : EvoParams) -> Double {
  params.w_stability * segment.stability +
    params.w_responsiveness * segment.responsiveness +
    params.w_growth * segment.growth +
    params.w_novelty * segment.novelty -
    params.c_energy * segment.energy_cost -
    params.c_impulse * segment.impulse_blowups -
    params.c_positive * segment.positive_penalty -
    params.c_flatness * segment.flatness_penalty +
    (if segment.has_outcome { EVO_W_KNOWLEDGE * segment.knowledge } else { 0.0 })
}

// Fitness is trained on the temporal prefix and charged for a large gap to the
// held-out suffix. The exact penalty formula lives here so the evaluation
// controller and its behavioural test read the same arithmetic.
fn evo_fitness_from_segments(
  segment : EvoSegment, holdout_segment : EvoSegment, params : EvoParams,
) -> (Double, Double, Double, Double) {
  let train = evo_segment_score(segment, params)
  let holdout = evo_segment_score(holdout_segment, params)
  let hold_gap = if train - holdout > 0.0 { train - holdout } else { 0.0 }
  let holdout_penalty = evo_clamp(hold_gap / 0.25, 0.0, 1.0)
  let fitness = evo_clamp(train - params.c_holdout * holdout_penalty, -0.999, 1.0)
  (fitness, train, holdout, holdout_penalty)
}

fn evo_segment_breakdown(segment : EvoSegment, train : Double, holdout : Double) -> Json {
  {
    "stability": segment.stability, "responsiveness": segment.responsiveness,
    "growth": segment.growth, "novelty": segment.novelty,
    "energy_cost": segment.energy_cost, "impulse_blowups": segment.impulse_blowups,
    "positive_penalty": segment.positive_penalty,
    "flatness_penalty": segment.flatness_penalty,
    "knowledge": segment.knowledge, "has_outcome": segment.has_outcome.to_json(),
    "holdout_penalty": 0.0, "train": train, "holdout": holdout,
  }
}

fn evo_breakdown_train(value : Json) -> Double {
  match value {
    Object(fields) => match fields.get("train") { Some(Number(n, ..)) => n; _ => 0.0 }
    _ => 0.0
  }
}

fn evo_breakdown_holdout(value : Json) -> Double {
  match value {
    Object(fields) => match fields.get("holdout") { Some(Number(n, ..)) => n; _ => 0.0 }
    _ => 0.0
  }
}

fn evo_trajectory(
  weights : Array[Double], window : Array[Json],
) -> EvoTrajectory raise @base.Fault {
  let emotion : Array[Array[Double]] = []
  let fired : Array[Bool] = []
  let blowups : Array[Int] = []
  let trust_delta : Array[Double] = []
  let has_subject : Array[Bool] = []
  let valence : Array[Double] = []
  let outcome : Array[Double] = []
  let trust : Map[String, Double] = Map([])
  let mut vitals = [0.0, 0.0, 0.0]
  let mut impulse = 0.0
  let mut last : Int? = None
  let mut nonfinite = false
  for entry in window {
    let step = evo_window_step(entry)
    let input = evo_window_input(entry)
    let subject = evo_window_subject(entry)
    valence.push(input[5])
    outcome.push(match evo_optional(entry, "outcome") {
      Some(Number(n, ..)) => n
      _ => 0.0
    })
    let result = evo_apply(weights, vitals, impulse, last, input, step)
    if result.nonfinite { nonfinite = true }
    vitals = result.emotion
    impulse = result.impulse
    last = result.last_fire_step
    emotion.push(result.emotion)
    fired.push(result.fired)
    blowups.push(result.blowup)
    match subject {
      None => {
        has_subject.push(false)
        trust_delta.push(0.0)
      }
      Some(name) => {
        has_subject.push(true)
        let old = trust.get(name)
        let previous = match old { None => 0.0; Some(value) => value }
        let triple = evo_relation_delta(
          match old { None => None; Some(value) => Some({ subject: name, trust: value, familiarity: 0.0, tension: 0.0 }) },
          result.relation_output, input[5])
        trust_delta.push(triple.0 - previous)
        trust[name] = triple.0
      }
    }
  }
  { emotion, fired, blowups, trust_delta, has_subject, valence, outcome, nonfinite }
}

fn evo_mean_trajectory(trajectories : Array[EvoTrajectory], count : Int) -> Array[Array[Double]] {
  let mean : Array[Array[Double]] = []
  for step = 0; step < count; step = step + 1 {
    mean.push([0.0, 0.0, 0.0])
  }
  if trajectories.is_empty() { return mean }
  for trajectory in trajectories {
    for step = 0; step < count; step = step + 1 {
      for dimension = 0; dimension < 3; dimension = dimension + 1 {
        mean[step][dimension] = mean[step][dimension] +
          trajectory.emotion[step][dimension] / trajectories.length().to_double()
      }
    }
  }
  mean
}

// ---- batch helpers --------------------------------------------------------

fn evo_batch(entries : Array[@core.Entry]) -> EvoBatch {
  ignore(entries)
  let changes : Array[@vault.Change] = []
  { changes, }
}

fn evo_add_new(batch : EvoBatch, path : String, content : String) -> Unit {
  batch.changes.push({ path, before: None, after: Some(content) })
}

fn evo_add_update(batch : EvoBatch, path : String, before : String, content : String) -> Unit {
  batch.changes.push({ path, before: Some(before), after: Some(content) })
}

fn evo_emit_genome(
  store : @vault.Storage, batch : EvoBatch, created : Map[String, Bool], origin : String,
  generation : Int, parents : Array[String], weights : Array[Double], at : String,
) -> String raise @base.Fault {
  let weights_sha256 = @core.evo_weights_sha256(weights)
  let id = @core.evo_genome_id(origin, generation, parents, weights_sha256)
  if created.contains(id) { return id }
  created[id] = true
  let path = evo_genome_path(id)
  let record : Json = {
    "version": 1, "id": id, "generation": generation,
    "parents": parents.to_json(), "origin": origin,
    "weights": weights.map(value => value.to_json()).to_json(),
    "weights_sha256": weights_sha256, "created_at": at,
  }
  let content = @base.canonical(record)
  // The id binds origin/generation/parents/weights, so a record already on
  // disk IS this genome; only created_at may differ between rebuilds, and a
  // repeated rebuild must reuse the existing record instead of conflicting.
  if (store.read)(path) is Some(_) { return id }
  evo_add_new(batch, path, content)
  id
}

fn evo_emit_event(batch : EvoBatch, path : String, event : Json) -> Unit {
  evo_add_new(batch, path, @base.canonical(event))
}

fn evo_fossil_count(store : @vault.Storage) -> Int raise @base.Fault {
  evo_sidecar_records(store, "evo/fossils/").length()
}

fn evo_event_count(store : @vault.Storage, prefix : String) -> Int raise @base.Fault {
  evo_sidecar_records(store, prefix).length()
}

// ---- human gate -----------------------------------------------------------

fn evo_pending_gate(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> String? {
  let paths : Array[String] = []
  for entry in entries {
    if entry.kind != "state" { continue }
    if !(entry.path.has_prefix("state/suggestions/") || entry.path.has_prefix("state/overview/")) {
      continue
    }
    // A damaged pending record must never block the SAFE switch. Parse faults
    // are treated as a pending gate (fail-closed for enabling), and the disable
    // path below ignores the gate entirely.
    let row = try { Some(@base.parse(@vault.required(store, entry.path))) } catch { _ => None }
    match row {
      None => paths.push(entry.path)
      Some(value) => match evo_optional(value, "status") {
        Some(status) => if status == "proposed".to_json() { paths.push(entry.path) }
        None => ()
      }
    }
  }
  paths.sort_by(@base.compare)
  if paths.is_empty() { None } else { Some(paths[0]) }
}

fn evo_pause_if_pending(store : @vault.Storage, entries : Array[@core.Entry]) -> Unit raise @base.Fault {
  match evo_pending_gate(store, entries) {
    None => ()
    Some(path) => @base.fail("evo_paused_human_gate:" + path)
  }
}

// ---- policy op ------------------------------------------------------------

fn evo_policy_response(
  policy : EvoPolicy, locked : Bool, pending : Bool, changed : Bool,
  replayed : Bool, fingerprint : String,
) -> Json {
  {
    "enabled": policy.enabled.to_json(), "params": policy.params_json,
    "locked": locked.to_json(),
    "updated_at": if policy.exists { policy.updated_at.to_json() } else { Json::null() },
    "pending_human_gate": pending.to_json(), "changed": changed.to_json(),
    "replayed": replayed.to_json(), "fingerprint": fingerprint,
  }
}

fn evo_policy_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["enabled", "params", "at"])
  let policy = evo_load_policy(store)
  let locked = (store.read)("evo/state.json") is Some(_) ||
    (store.read)("evo/population.json") is Some(_)
  let gate = evo_pending_gate(store, entries)
  let enabled_arg = evo_optional(request, "enabled")
  let params_arg = evo_optional(request, "params")
  if enabled_arg is None && params_arg is None {
    return {
      "enabled": policy.enabled.to_json(), "params": policy.params_json,
      "default": (!policy.exists).to_json(), "locked": locked.to_json(),
      "updated_at": if policy.exists { policy.updated_at.to_json() } else { Json::null() },
      "pending_human_gate": (gate is Some(_)).to_json(),
    }
  }
  let at = evo_at_text(request)
  let enabled = match enabled_arg {
    None => policy.enabled
    Some(True) => true
    Some(False) => false
    Some(_) => raise @base.Fault("evo_policy_invalid:enabled")
  }
  let new_params_json = match params_arg {
    None => policy.params_json
    Some(value) => {
      @core.evo_policy_params(value)
      value
    }
  }
  let new_params = evo_params_from_json(new_params_json)
  if params_arg is Some(_) {
    if locked { @base.fail("evo_policy_locked") }
    if !enabled { @base.fail("evo_policy_disabled_write") }
  }
  let same = enabled == policy.enabled &&
    @base.canonical(new_params_json) == @base.canonical(policy.params_json)
  if same {
    return evo_policy_response(policy, locked, gate is Some(_), false, true,
      @vault.fingerprint(entries))
  }
  // Disabling never consults the human gate: the safe switch must stay
  // available even when other records are damaged.
  match gate {
    Some(path) => if enabled || params_arg is Some(_) {
      @base.fail("evo_paused_human_gate:" + path)
    }
    None => ()
  }
  let record : Json = {
    "version": 1, "enabled": enabled.to_json(),
    "params": new_params_json, "updated_at": at,
  }
  let content = @base.canonical(record)
  let binding : Json = { "enabled": enabled.to_json(), "params": new_params_json }
  let event_path = "evo/events/evo-policy-" +
    @base.hex_hash(@base.canonical(binding) + "\n" + at) + ".json"
  let event : Json = {
    "op": "evo-policy", "at": at, "enabled": enabled.to_json(),
    "params": new_params_json,
    "params_hash": @base.hex_hash(@base.canonical(new_params_json)),
  }
  let batch = evo_batch(entries)
  match (store.read)("evo/policy.json") {
    Some(before) => evo_add_update(batch, "evo/policy.json", before, content)
    None => evo_add_new(batch, "evo/policy.json", content)
  }
  evo_emit_event(batch, event_path, event)
  evo_sidecar_commit(store, batch.changes)
  let updated : EvoPolicy = {
    exists: true, enabled, params: new_params, params_json: new_params_json,
    updated_at: at,
  }
  evo_policy_response(updated, locked, gate is Some(_), true, false,
    @vault.fingerprint(entries))
}

// ---- init -----------------------------------------------------------------

fn evo_seed_arg(request : Json) -> Int raise @base.Fault {
  match evo_optional(request, "seed") {
    None => 0
    Some(Number(n, ..)) if !n.is_nan() && !n.is_inf() && n >= 0.0 &&
      n <= 4294967295.0 && n == n.to_int().to_double() => n.to_int()
    Some(_) => raise @base.Fault("evo_seed_invalid")
  }
}

fn evo_init_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["seed", "at"])
  let seed = evo_seed_arg(request)
  let at = evo_at_text(request)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let policy = evo_load_policy(store)
  let policy_hash = @core.evo_policy_hash(evo_policy_record(policy))
  let population_text = (store.read)("evo/population.json")
  let state_text = (store.read)("evo/state.json")
  match population_text {
    Some(text) => {
      match state_text {
        None => @base.fail("evo_state_corrupt")
        Some(_) => ()
      }
      let population = evo_population_from_json(@base.parse(text))
      let init_seed = evo_json_int(population.init, "seed", "evo_population_record_invalid")
      let init_at = @base.text(@base.field(population.init, "at"))
      let init_hash = @base.text(@base.field(population.init, "policy_hash"))
      if init_seed == seed && init_at == at && init_hash == policy_hash {
        return {
          "generation": 0, "population": population.members.length(),
          "genomes": population.members.length(), "seed": seed,
          "replayed": true, "fingerprint": @vault.fingerprint(entries),
        }
      }
      @base.fail("evo_already_initialized")
    }
    None => ()
  }
  if state_text is Some(_) { @base.fail("evo_state_corrupt") }
  let batch = evo_batch(entries)
  let created : Map[String, Bool] = Map([])
  let members : Array[EvoMember] = []
  let rng = evo_rng(seed, 0)
  let count = policy.params.population
  for _ in 0..<count {
    let weights = evo_xavier(rng)
    let id = evo_emit_genome(store, batch, created, "seed", 0, [], weights, at)
    members.push({
      genome: id, fitness: None, breakdown: Json::null(), age: 0,
      evaluated_generation: None, status: "alive",
    })
  }
  let empty_window : Array[Json] = []
  let empty_history : Array[Json] = []
  let empty_relations : Array[EvoRelation] = []
  let population : Json = {
    "version": 1, "generation": 0,
    "init": { "seed": seed, "at": at, "policy_hash": policy_hash },
    "members": members.map(evo_member_json).to_json(),
    "checkpoint": Json::null(), "history": empty_history.to_json(),
    "regression_streak": 0, "no_improve_streak": 0, "saturations_total": 0,
    "extinct_total": 0, "fossil_total": 0, "regressions_total": 0,
    "rollbacks_total": 0, "last_eval": Json::null(),
    "last_evolve": Json::null(), "last_rollback": Json::null(),
    "updated_at": at,
  }
  let state : Json = {
    "version": 1, "steps": 0, "window": empty_window.to_json(),
    "window_sha256": @core.evo_window_hash(empty_window),
    "emotion": [0.0, 0.0, 0.0].map(value => value.to_json()).to_json(),
    "impulse": 0.0, "body": { "cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0 },
    "relations": empty_relations.map(evo_relation_json).to_json(),
    "active_genome": members[0].genome,
    "last_observe": Json::null(), "last_fire_step": Json::null(),
    "last_activity_at": at.to_json(),
    "guard_hits": 0, "impulses": 0, "blowups": 0,
    "created_at": at, "updated_at": at,
  }
  evo_add_new(batch, "evo/population.json", @base.canonical(population))
  evo_add_new(batch, "evo/state.json", @base.canonical(state))
  let event_path = "evo/events/evo-init-" +
    @base.hex_hash(seed.to_string() + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-init", "at": at, "seed": seed, "policy_hash": policy_hash,
  })
  evo_sidecar_commit(store, batch.changes)
  {
    "generation": 0, "population": count, "genomes": created.keys().length(),
    "seed": seed, "replayed": false, "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- observe --------------------------------------------------------------

// 续五十九: the observe tick is factored out so a host may apply a burst of
// observations in one atomic call. Identity, replay and step semantics are the
// single-row semantics applied in order; any invalid row fails the whole batch
// before the single commit, so a batch is byte-identical to applying its rows
// one by one.
const EVO_OBSERVE_BATCH_MAX : Int = 64

priv struct EvoObserveArgs {
  step : Int
  kind : String
  salience : Double
  valence : Double
  outcome : Double
  body : Json
  subject : String?
  at : String
}

priv struct EvoObserveTick {
  state : EvoState
  emotion : Json
  impulse : Double
  fired : Bool
  action : Json
  threshold : Double
  outcome : Double
  replayed : Bool
}

fn evo_stored_number(row : Json, key : String) -> Double raise @base.Fault {
  match @base.field(row, key) {
    Number(n, ..) => n
    _ => { @base.fail("evo_state_corrupt"); 0.0 }
  }
}

fn evo_stored_bool(row : Json, key : String) -> Bool raise @base.Fault {
  match @base.field(row, key) {
    True => true
    False => false
    _ => { @base.fail("evo_state_corrupt"); false }
  }
}

fn evo_observe_args(source : Json) -> EvoObserveArgs raise @base.Fault {
  evo_request_keys(source, ["step", "kind", "salience", "valence", "body",
    "subject", "outcome", "at"])
  let at = evo_at_text(source)
  let step = evo_request_int(source, "step", 1, 2147483647)
  let kind = evo_text(source, "kind")
  if !["social", "task", "body", "novel"].contains(kind) { @base.fail("evo_kind_invalid") }
  let salience = evo_request_number(source, "salience", 0.0, 1.0)
  let valence = evo_request_number(source, "valence", -1.0, 1.0)
  let outcome = match evo_optional(source, "outcome") {
    None => 0.0
    Some(Number(n, ..)) if n >= -1.0 && n <= 1.0 && !n.is_nan() && !n.is_inf() => n
    Some(_) => raise @base.Fault("evo_outcome_invalid")
  }
  let body = evo_body_arg(source)
  let subject = evo_subject_arg(source)
  { step, kind, salience, valence, outcome, body, subject, at }
}

// A replay of the last applied row: same step, same identity. Returns None
// when the row is not a replay; a same-step different-identity row is a
// conflict, not a fresh apply.
fn evo_observe_replay(
  state : EvoState, args : EvoObserveArgs,
) -> EvoObserveTick? raise @base.Fault {
  if args.step != state.steps { return None }
  let identity = evo_payload(args.kind, args.salience, args.valence, args.body,
    args.subject, args.outcome)
  let payload_sha256 = @base.hex_hash(@base.canonical(identity))
  let same = match state.last_observe {
    Object(_) => @base.text(@base.field(state.last_observe, "payload_sha256")) == payload_sha256
    _ => false
  }
  if !same { @base.fail("evo_observe_conflict") }
  let result = @base.field(state.last_observe, "result")
  Some({
    state,
    emotion: @base.field(result, "emotion"),
    impulse: evo_stored_number(result, "impulse"),
    fired: evo_stored_bool(result, "fired"),
    action: @base.field(result, "action"),
    threshold: evo_stored_number(result, "threshold"),
    outcome: match evo_optional(result, "outcome") { Some(Number(n, ..)) => n; _ => 0.0 },
    replayed: true,
  })
}

fn evo_observe_apply(
  params : EvoParams, weights : Array[Double], state : EvoState, args : EvoObserveArgs,
) -> EvoObserveTick raise @base.Fault {
  if args.step != state.steps + 1 {
    @base.fail("evo_step_invalid: expected " + (state.steps + 1).to_string())
  }
  let identity = evo_payload(args.kind, args.salience, args.valence, args.body,
    args.subject, args.outcome)
  let payload_sha256 = @base.hex_hash(@base.canonical(identity))
  let relation = match args.subject { None => None; Some(name) => evo_relation_find(state.relations, name) }
  match args.subject {
    Some(_) => if relation is None && state.relations.length() >= 8 { @base.fail("evo_subject_limit") }
    None => ()
  }
  let relation_trust = match relation { None => 0.0; Some(value) => value.trust }
  let relation_familiarity = match relation { None => 0.0; Some(value) => value.familiarity }
  let relation_tension = match relation { None => 0.0; Some(value) => value.tension }
  let input : Array[Double] = [
    if args.kind == "social" { 1.0 } else { 0.0 },
    if args.kind == "task" { 1.0 } else { 0.0 },
    if args.kind == "body" { 1.0 } else { 0.0 },
    if args.kind == "novel" { 1.0 } else { 0.0 },
    args.salience, args.valence,
    evo_body_value(args.body, "cpu"), evo_body_value(args.body, "memory"),
    evo_body_value(args.body, "latency"), evo_body_value(args.body, "budget"),
    relation_trust, relation_familiarity, relation_tension,
    state.emotion[0], state.emotion[1], state.emotion[2],
  ]
  let result = evo_apply(weights, state.emotion, state.impulse,
    state.last_fire_step, input, args.step)
  if result.nonfinite { @base.fail("evo_numeric_invalid:controller") }
  let mut relations = state.relations.copy()
  match args.subject {
    None => ()
    Some(name) => {
      let (trust, familiarity, tension) = evo_relation_delta(relation, result.relation_output, args.valence)
      let updated : EvoRelation = { subject: name, trust, familiarity, tension }
      let kept : Array[EvoRelation] = []
      for item in relations {
        if item.subject != name { kept.push(item) }
      }
      kept.push(updated)
      relations = evo_relations_sort(kept)
    }
  }
  let mut window : Array[Json] = []
  for entry in state.window { window.push(entry) }
  window.push(evo_window_entry_json(args.step, args.at, input, result.emotion,
    result.impulse, result.fired, args.subject, args.outcome))
  while window.length() > params.window {
    window = window[1:].to_owned()
  }
  let observation : Json = {
    "step": args.step, "payload_sha256": payload_sha256,
    "result": {
      "emotion": result.emotion.map(value => value.to_json()).to_json(),
      "impulse": result.impulse, "fired": result.fired.to_json(),
      "action": result.action.map(value => value.to_json()).to_json(),
      "threshold": result.threshold, "outcome": args.outcome,
    },
  }
  let updated_state : EvoState = {
    ..state, steps: args.step, window, window_sha256: @core.evo_window_hash(window),
    emotion: result.emotion, impulse: result.impulse, body: args.body,
    relations, last_observe: observation, last_fire_step: result.last_fire_step,
    impulses: state.impulses + (if result.fired { 1 } else { 0 }),
    blowups: state.blowups + result.blowup,
  }
  {
    state: updated_state,
    emotion: result.emotion.map(value => value.to_json()).to_json(),
    impulse: result.impulse, fired: result.fired,
    action: result.action.map(value => value.to_json()).to_json(),
    threshold: result.threshold, outcome: args.outcome, replayed: false,
  }
}

fn evo_observe_response(tick : EvoObserveTick, capacity : Int, fingerprint : String) -> Json {
  {
    "step": tick.state.steps,
    "emotion": tick.emotion,
    "impulse": tick.impulse, "fired": tick.fired.to_json(),
    "action": tick.action,
    "threshold": tick.threshold, "outcome": tick.outcome,
    "window": { "have": tick.state.window.length(), "capacity": capacity },
    "replayed": tick.replayed.to_json(), "fingerprint": fingerprint,
  }
}

fn evo_observe_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["step", "kind", "salience", "valence", "body",
    "subject", "outcome", "at"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let args = evo_observe_args(request)
  let state_text = match (store.read)("evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  match (store.read)("evo/population.json") {
    None => @base.fail("evo_state_corrupt")
    Some(_) => ()
  }
  let state = evo_state_from_json(@base.parse(state_text))
  if state.active_genome is None { @base.fail("evo_genome_not_found") }
  if state.window.length() > policy.params.window { @base.fail("evo_state_corrupt") }
  match evo_observe_replay(state, args) {
    Some(tick) => {
      return evo_observe_response(tick, policy.params.window,
        @vault.fingerprint(entries))
    }
    None => ()
  }
  let genome = evo_load_genome(store, entries, state.active_genome.unwrap())
  let tick = evo_observe_apply(policy.params, genome.weights, state, args)
  let content = @base.canonical(evo_state_json(tick.state, args.at))
  let batch = evo_batch(entries)
  evo_add_update(batch, "evo/state.json", state_text, content)
  evo_sidecar_commit(store, batch.changes)
  evo_observe_response(tick, policy.params.window, @vault.fingerprint(entries))
}

fn evo_observe_batch_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["rows"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let rows = match @base.field(request, "rows") {
    Array(items) => items
    _ => { @base.fail("evo_batch_invalid:rows"); [] }
  }
  if rows.length() == 0 || rows.length() > EVO_OBSERVE_BATCH_MAX {
    @base.fail("evo_batch_invalid: count 1.." + EVO_OBSERVE_BATCH_MAX.to_string())
  }
  let state_text = match (store.read)("evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  match (store.read)("evo/population.json") {
    None => @base.fail("evo_state_corrupt")
    Some(_) => ()
  }
  let mut current = evo_state_from_json(@base.parse(state_text))
  if current.active_genome is None { @base.fail("evo_genome_not_found") }
  if current.window.length() > policy.params.window { @base.fail("evo_state_corrupt") }
  let genome = evo_load_genome(store, entries, current.active_genome.unwrap())
  let mut applied = 0
  let mut replays = 0
  let mut last_at = ""
  let mut last_tick : EvoObserveTick? = None
  for row in rows {
    let args = evo_observe_args(row)
    let tick = match evo_observe_replay(current, args) {
      Some(value) => { replays = replays + 1; value }
      None => {
        applied = applied + 1
        last_at = args.at
        evo_observe_apply(policy.params, genome.weights, current, args)
      }
    }
    current = tick.state
    last_tick = Some(tick)
  }
  let tick = last_tick.unwrap()
  let fingerprint = if applied > 0 {
    let content = @base.canonical(evo_state_json(current, last_at))
    let batch = evo_batch(entries)
    evo_add_update(batch, "evo/state.json", state_text, content)
    evo_sidecar_commit(store, batch.changes)
    @vault.fingerprint(entries)
  } else {
    @vault.fingerprint(entries)
  }
  let response = evo_observe_response(tick, policy.params.window, fingerprint)
  evo_row_set(evo_row_set(response, "applied", applied.to_json()),
    "replays", replays.to_json())
}

// ---- evaluate -------------------------------------------------------------

fn evo_alive_members(population : EvoPopulation) -> Array[EvoMember] {
  let alive : Array[EvoMember] = []
  for row in population.members {
    if row.status == "alive" { alive.push(row) }
  }
  alive.sort_by((a, b) => {
    let left = match a.fitness { None => -2.0; Some(value) => value }
    let right = match b.fitness { None => -2.0; Some(value) => value }
    if left != right { if left > right { -1 } else { 1 } } else { @base.compare(a.genome, b.genome) }
  })
  alive
}

fn evo_mean_breakdown(members : Array[EvoMember], train : Bool) -> Double {
  let mut count = 0
  let mut total = 0.0
  for row in members {
    if row.status != "alive" { continue }
    total = total + (if train {
      evo_breakdown_train(row.breakdown)
    } else {
      evo_breakdown_holdout(row.breakdown)
    })
    count = count + 1
  }
  if count == 0 { 0.0 } else { total / count.to_double() }
}

fn evo_evaluate_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["at"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let state_text = match (store.read)("evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("evo/population.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let population = evo_population_from_json(@base.parse(population_text))
  if state.window.length() != policy.params.window {
    @base.fail("evo_window_incomplete: have=" + state.window.length().to_string() +
      " need=" + policy.params.window.to_string())
  }
  if @core.evo_window_hash(state.window) != state.window_sha256 { @base.fail("evo_state_corrupt") }
  let replay = evo_last_eval(population.last_eval)
  match replay {
    Some(last) => {
      if last.window_sha256 == state.window_sha256 && last.generation == population.generation {
        return evo_evaluate_response(population, last, true, @vault.fingerprint(entries))
      }
    }
    None => ()
  }
  match evo_checkpoint(population.checkpoint) {
    None => ()
    Some(value) => {
      let alive_checkpoint = population.members.any(row =>
        row.genome == value.genome && row.status == "alive")
      if !alive_checkpoint { @base.fail("evo_state_corrupt") }
    }
  }
  let alive = evo_alive_members(population)
  if alive.is_empty() { @base.fail("evo_population_exhausted") }
  let scenario = evo_scenario(population.generation)
  let rows : Array[Json] = []
  for row in state.window { rows.push(evo_scenario_row(row, scenario)) }
  let trajectories : Array[EvoTrajectory] = []
  for row in alive {
    let genome = evo_load_genome(store, entries, row.genome)
    trajectories.push(evo_trajectory(genome.weights, rows))
  }
  let mean = evo_mean_trajectory(trajectories, rows.length())
  let (train_steps, holdout_steps) = evo_split_indices(state.window.length(),
    state.window_sha256)
  let updated_members : Array[EvoMember] = []
  let mut best_genome = ""
  let mut best_fitness = -2.0
  let mut worst_fitness = 2.0
  let mut total = 0.0
  for index = 0; index < alive.length(); index = index + 1 {
    let row = alive[index]
    let trajectory = trajectories[index]
    let segment = evo_segment(trajectory, mean, train_steps)
    let holdout_segment = evo_segment(trajectory, mean, holdout_steps)
    let (raw, train, holdout, holdout_penalty) = evo_fitness_from_segments(
      segment, holdout_segment, policy.params)
    let lethal = trajectory.nonfinite || !evo_finite(raw)
    let fitness = if lethal { -1.0 } else { raw }
    let breakdown = if lethal {
      evo_segment_breakdown(segment, -1.0, -1.0)
    } else {
      let base = evo_segment_breakdown(segment, train, holdout)
      match base {
        Object(fields) => {
          let copy = fields.copy()
          copy["holdout_penalty"] = holdout_penalty.to_json()
          Json::object(copy)
        }
        _ => base
      }
    }
    let updated : EvoMember = {
      ..row, fitness: Some(fitness), breakdown,
      evaluated_generation: Some(population.generation),
      status: if lethal { "lethal" } else { "alive" },
    }
    updated_members.push(updated)
    total = total + fitness
    if fitness > best_fitness || (fitness == best_fitness &&
      @base.compare(row.genome, best_genome) < 0) {
      best_fitness = fitness
      best_genome = row.genome
    }
    if fitness < worst_fitness { worst_fitness = fitness }
  }
  let updated_by_genome : Map[String, EvoMember] = Map([])
  for updated in updated_members {
    updated_by_genome[updated.genome] = updated
  }
  let members : Array[EvoMember] = []
  for row in population.members {
    if row.status == "alive" {
      match updated_by_genome.get(row.genome) {
        Some(updated) => members.push({
          ..row, fitness: updated.fitness, breakdown: updated.breakdown,
          evaluated_generation: updated.evaluated_generation, status: updated.status,
        })
        None => members.push(row)
      }
    } else {
      members.push(row)
    }
  }
  let mean_fitness = total / alive.length().to_double()
  let current_checkpoint = evo_checkpoint(population.checkpoint)
  let mut checkpoint_json = population.checkpoint
  let mut active_genome = state.active_genome
  let mut has_best = false
  for row in updated_members {
    if row.genome == best_genome && row.status == "alive" { has_best = true }
  }
  if has_best {
    let replace = match current_checkpoint {
      None => true
      Some(value) => best_fitness > value.fitness
    }
    if replace {
      let record : Json = {
        "generation": population.generation, "genome": best_genome,
        "fitness": best_fitness, "at": at,
        "scenario": scenario.to_json(),
      }
      checkpoint_json = record
      active_genome = Some(best_genome)
    }
  }
  let last : EvoLastEval = {
    generation: population.generation, window_sha256: state.window_sha256,
    at, best: best_fitness, mean: mean_fitness, worst: worst_fitness,
    alive: alive.length(),
  }
  let last_json : Json = {
    "generation": last.generation, "window_sha256": last.window_sha256,
    "at": last.at, "best": last.best, "mean": last.mean, "worst": last.worst,
    "alive": last.alive,
  }
  let updated_population : EvoPopulation = {
    ..population, members, checkpoint: checkpoint_json, last_eval: last_json,
  }
  let updated_state : EvoState = { ..state, active_genome, }
  let batch = evo_batch(entries)
  evo_add_update(batch, "evo/population.json", population_text,
    @base.canonical(evo_population_json(updated_population, at)))
  evo_add_update(batch, "evo/state.json", state_text,
    @base.canonical(evo_state_json(updated_state, at)))
  let event_path = "evo/events/evo-evaluate-" + @base.hex_hash(
    population.generation.to_string() + "\n" + state.window_sha256 + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-evaluate", "at": at, "generation": population.generation,
    "window_sha256": state.window_sha256, "best": best_fitness,
    "mean": mean_fitness, "worst": worst_fitness, "alive": alive.length(),
  })
  evo_sidecar_commit(store, batch.changes)
  {
    "generation": population.generation, "window_sha256": state.window_sha256,
    "alive": alive.length(), "best": { "genome": best_genome, "fitness": best_fitness },
    "mean": mean_fitness, "worst": worst_fitness, "checkpoint": checkpoint_json,
    "train_mean": evo_mean_breakdown(updated_population.members, true),
    "holdout_mean": evo_mean_breakdown(updated_population.members, false),
    "members": members.map(evo_member_json).to_json(),
    "scenario": scenario.to_json(),
    "replayed": false, "fingerprint": @vault.fingerprint(entries),
  }
}

fn evo_evaluate_response(
  population : EvoPopulation, last : EvoLastEval, replayed : Bool, fingerprint : String,
) -> Json {
  let alive = evo_alive_members(population)
  let best = if alive.is_empty() { "" } else { alive[0].genome }
  let best_fitness = if alive.is_empty() { last.best } else {
    match alive[0].fitness { None => last.best; Some(value) => value }
  }
  {
    "generation": last.generation, "window_sha256": last.window_sha256,
    "alive": last.alive, "best": { "genome": best, "fitness": best_fitness },
    "mean": last.mean, "worst": last.worst, "checkpoint": population.checkpoint,
    "train_mean": evo_mean_breakdown(population.members, true),
    "holdout_mean": evo_mean_breakdown(population.members, false),
    "members": population.members.map(evo_member_json).to_json(),
    "scenario": evo_scenario(last.generation).to_json(),
    "replayed": replayed, "fingerprint": fingerprint,
  }
}

// ---- evolution ------------------------------------------------------------

fn evo_rank(ranked : Array[EvoMember], genome : String) -> Int {
  for index = 0; index < ranked.length(); index = index + 1 {
    if ranked[index].genome == genome { return index }
  }
  0
}

fn evo_better(left : EvoMember, right : EvoMember) -> Bool {
  match (left.fitness, right.fitness) {
    (Some(a), Some(b)) => if a != b { a > b } else { @base.compare(left.genome, right.genome) < 0 }
    (Some(_), None) => true
    (None, Some(_)) => false
    (None, None) => @base.compare(left.genome, right.genome) < 0
  }
}

fn evo_tournament(rng : EvoRng, pool : Array[EvoMember], draws : Int) -> EvoMember {
  let mut winner = pool[0]
  for _ in 0..<draws {
    let candidate = pool[(evo_rng_next(rng) % pool.length().reinterpret_as_uint()).reinterpret_as_int()]
    if evo_better(candidate, winner) { winner = candidate }
  }
  winner
}

fn evo_amplitude(policy : EvoParams, rank_ratio : Double) -> Double {
  let amplitude = 0.10 + (policy.mutation_max - 0.10) * rank_ratio
  amplitude
}

fn evo_mutate_weights(
  rng : EvoRng, base : Array[Double], rate : Double, amplitude : Double,
) -> Array[Double] {
  let weights : Array[Double] = []
  for weight in base {
    let mut value = weight
    if evo_rng_unit(rng) < rate {
      let delta = evo_gaussian(rng) * amplitude / 3.0
      value = evo_clamp(value + delta, -4.0, 4.0)
    }
    weights.push(evo_quantize(value))
  }
  weights
}

fn evo_child_weights(
  rng : EvoRng, left : Array[Double], right : Array[Double], crossover : Bool,
  rate : Double, amplitude : Double,
) -> Array[Double] {
  let base : Array[Double] = []
  for index = 0; index < @core.EVO_WEIGHTS; index = index + 1 {
    let value = if crossover {
      if evo_rng_unit(rng) < 0.5 { left[index] } else { right[index] }
    } else {
      left[index]
    }
    base.push(value)
  }
  evo_mutate_weights(rng, base, rate, amplitude)
}

fn evo_population_exhausted(alive : Array[EvoMember]) -> Bool {
  alive.length() < 3
}

fn evo_history_entry(
  generation : Int, window_sha256 : String, best : Double, mean : Double,
  worst : Double, delta : Double, regressed : Bool, rolled_back : Bool,
) -> Json {
  {
    "generation": generation, "window_sha256": window_sha256, "best": best,
    "mean": mean, "worst": worst, "delta": delta,
    "regressed": regressed.to_json(), "rolled_back": rolled_back.to_json(),
  }
}

fn evo_history_append(
  history : Array[Json], entry : Json, max : Int,
) -> Array[Json] {
  let mut result : Array[Json] = []
  for item in history { result.push(item) }
  if result.length() >= max { result = result[1:].to_owned() }
  result.push(entry)
  result
}

fn evo_member_sort_by_genome(members : Array[EvoMember]) -> Array[EvoMember] {
  let sorted = members.copy()
  sorted.sort_by((a, b) => @base.compare(a.genome, b.genome))
  sorted
}

fn evo_emit_fossil(
  store : @vault.Storage, batch : EvoBatch, created : Map[String, Bool],
  entries : Array[@core.Entry], row : EvoMember, reason : String,
  died_generation : Int, window_sha256 : String, at : String,
) -> String? raise @base.Fault {
  let genome = evo_load_genome(store, entries, row.genome)
  let id = @core.evo_fossil_id(row.genome, reason, died_generation)
  if created.contains(id) { return None }
  created[id] = true
  let path = "evo/fossils/" + id + ".json"
  if batch.changes.any(change => change.path == path) { return None }
  if (store.read)(path) is Some(_) { return None }
  let fitness = match row.fitness { None => -1.0; Some(value) => value }
  let breakdown = match row.breakdown {
    Object(_) => row.breakdown
    _ => {
      let segment : EvoSegment = {
        stability: 0.0, responsiveness: 0.0, growth: 0.0, novelty: 0.0,
        energy_cost: 0.0, impulse_blowups: 0.0, positive_penalty: 0.0,
        flatness_penalty: 0.0, knowledge: 0.0, has_outcome: false,
      }
      evo_segment_breakdown(segment, 0.0, 0.0)
    }
  }
  let record : Json = {
    "version": 1, "id": id, "genome": row.genome,
    "generation": genome.generation, "died_generation": died_generation,
    "reason": reason, "fitness": fitness, "breakdown": breakdown,
    "window_sha256": window_sha256, "weights_sha256": genome.weights_sha256,
    "parents": genome.parents.to_json(), "age": row.age, "at": at,
  }
  evo_add_new(batch, path, @base.canonical(record))
  evo_emit_event(batch,
    "evo/events/evo-fossilize-" + id + ".json", {
      "op": "evo-fossilize", "at": at, "fossil": id, "genome": row.genome,
      "reason": reason, "generation": genome.generation,
    })
  Some(id)
}

fn evo_fossilize_members(
  store : @vault.Storage, entries : Array[@core.Entry], batch : EvoBatch,
  candidates : Array[EvoMember], limit : Int, reason : String,
  died_generation : Int, window_sha256 : String, at : String,
) -> Array[String] raise @base.Fault {
  let created : Map[String, Bool] = Map([])
  let ids : Array[String] = []
  let mut remaining = limit
  for row in candidates {
    if remaining <= 0 { break }
    match evo_emit_fossil(store, batch, created, entries, row, reason,
      died_generation, window_sha256, at) {
      Some(id) => {
        ids.push(id)
        remaining = remaining - 1
      }
      None => ()
    }
  }
  ids
}

fn evo_sort_fossil_candidates(candidates : Array[EvoMember], descending : Bool) -> Array[EvoMember] {
  let ordered = candidates.copy()
  ordered.sort_by((a, b) => {
    let left = match a.fitness { None => -2.0; Some(value) => value }
    let right = match b.fitness { None => -2.0; Some(value) => value }
    if left != right {
      if descending {
        if left > right { -1 } else { 1 }
      } else {
        if left < right { -1 } else { 1 }
      }
    } else {
      @base.compare(a.genome, b.genome)
    }
  })
  ordered
}

fn evo_rebuild_from_checkpoint(
  store : @vault.Storage, entries : Array[@core.Entry], batch : EvoBatch,
  population : EvoPopulation, policy : EvoParams, from : Int, at : String,
  reason : String, streak : Int, window_sha256 : String,
) -> (EvoPopulation, Array[String], Int) raise @base.Fault {
  let checkpoint = match evo_checkpoint(population.checkpoint) {
    None => raise @base.Fault("evo_rollback_unavailable")
    Some(value) => value
  }
  let seed = evo_json_int(population.init, "seed", "evo_population_record_invalid")
  let dying = evo_sort_fossil_candidates(population.members, true)
  let fossil_reason = if reason == "manual" { "manual_rollback" } else { "regression_rollback" }
  let fossil_ids = evo_fossilize_members(store, entries, batch, dying,
    policy.fossil_max_per_gen, fossil_reason, from, window_sha256, at)
  let checkpoint_genome = evo_load_genome(store, entries, checkpoint.genome)
  let created : Map[String, Bool] = Map([])
  let rng = evo_rng(seed, from)
  let members : Array[EvoMember] = [{
    genome: checkpoint.genome, fitness: Some(checkpoint.fitness),
    breakdown: Json::null(), age: 0, evaluated_generation: None, status: "alive",
  }]
  for _ in 1..<policy.population {
    let weights = evo_mutate_weights(rng, checkpoint_genome.weights,
      policy.mutation_rate, policy.mutation_max)
    let id = evo_emit_genome(store, batch, created, "checkpoint_clone",
      checkpoint.generation, [checkpoint.genome], weights, at)
    members.push({
      genome: id, fitness: None, breakdown: Json::null(), age: 0,
      evaluated_generation: None, status: "alive",
    })
  }
  let last_rollback : Json = {
    "at": at, "from_generation": from, "to_generation": checkpoint.generation,
    "reason": reason, "checkpoint": checkpoint.genome, "fossils": fossil_ids.length(),
  }
  let updated : EvoPopulation = {
    ..population, generation: checkpoint.generation,
    members: evo_member_sort_by_genome(members),
    extinct_total: population.extinct_total + dying.length(),
    fossil_total: evo_fossil_count(store) + fossil_ids.length(),
    rollbacks_total: population.rollbacks_total + 1,
    regression_streak: if reason == "regression" { 0 } else { streak },
    no_improve_streak: 0,
    saturations_total: population.saturations_total,
    last_eval: Json::null(),
    last_rollback,
  }
  (updated, fossil_ids, dying.length())
}

fn evo_fossil_limit(policy : EvoParams, dying : Array[EvoMember]) -> Int {
  let fossil_n = Int::min(policy.fossil_max_per_gen, dying.length())
  fossil_n
}

fn evo_regression_decision(
  checkpoint_fitness : Double, best : Double, policy : EvoParams, streak : Int,
) -> (Bool, Int, Bool) {
  let regressed = checkpoint_fitness - best > policy.regression_delta
  let next = if regressed { streak + 1 } else { 0 }
  let rollback = regressed && next >= policy.regression_patience && policy.auto_rollback
  (regressed, next, rollback)
}

fn evo_plan_elites(
  ranked : Array[EvoMember], policy : EvoParams, checkpoint_genome : String,
) -> (Array[EvoMember], Int, Int) {
  let alive = ranked.length()
  let elite_count = evo_clamp_int((alive.to_double() * policy.elite_ratio).to_int(),
    2, alive / 2)
  let protect_count = evo_clamp_int((alive.to_double() * policy.protect_ratio).to_int(),
    2, elite_count)
  let elites = ranked[:elite_count]
  let chosen = elites.to_owned()
  if checkpoint_genome != "" {
    let mut present = false
    for row in chosen {
      if row.genome == checkpoint_genome { present = true }
    }
    if !present {
      for row in ranked {
        if row.genome == checkpoint_genome && row.status == "alive" {
          chosen.push(row)
          break
        }
      }
    }
  }
  (chosen, protect_count, elite_count)
}

// Pure saturation step: a patience of non-improving generations re-arms
// exploration (streak resets to 0 when it fires). Generation 0 never saturates.
fn evo_no_improve_step(delta : Double, generation : Int, streak : Int) -> (Int, Bool) {
  let next = if delta <= 0.0 && generation > 0 { streak + 1 } else { 0 }
  let saturated = next >= EVO_SATURATION_PATIENCE
  if saturated { (0, true) } else { (next, false) }
}

fn evo_evolve_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["at"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let state_text = match (store.read)("evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("evo/population.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let population = evo_population_from_json(@base.parse(population_text))
  let last_eval = evo_last_eval(population.last_eval)
  let previous = evo_last_evolve(population.last_evolve)
  match previous {
    Some(last) => {
      if last.from_generation == population.generation - 1 &&
        last.window_sha256 == state.window_sha256 && last.at == at {
        return evo_evolve_replay(store, population, last, entries)
      }
    }
    None => ()
  }
  let alive = evo_alive_members(population)
  let evaluated = alive.iter().all(row => row.evaluated_generation == Some(population.generation))
  if last_eval is None || !evaluated { @base.fail("evo_not_evaluated") }
  let last = last_eval.unwrap()
  if last.generation != population.generation { @base.fail("evo_not_evaluated") }
  if last.window_sha256 != state.window_sha256 { @base.fail("evo_window_changed") }
  if evo_population_exhausted(alive) { @base.fail("evo_population_exhausted") }
  let alive_sorted = alive
  let best_member = alive_sorted[0]
  let best = match best_member.fitness { None => last.best; Some(value) => value }
  let mean = last.mean
  let worst = last.worst
  let checkpoint = evo_checkpoint(population.checkpoint)
  let checkpoint_fitness = match checkpoint { None => -1.0; Some(value) => value.fitness }
  let (regressed, streak, rollback) = if evo_scenario_gate(checkpoint,
    population.generation) {
    evo_regression_decision(checkpoint_fitness, best, policy.params,
      population.regression_streak)
  } else {
    // Scenario mismatch: neither confirm nor refute the streak.
    (false, population.regression_streak, false)
  }
  let mut delta = if population.history.is_empty() { 0.0 } else {
    best - evo_json_number(population.history[population.history.length() - 1],
      "best", "evo_population_record_invalid")
  }
  let window_changed = !population.history.is_empty() &&
    @base.text(@base.field(population.history[population.history.length() - 1],
      "window_sha256")) != last.window_sha256
  let (no_improve_streak, saturated) = evo_no_improve_step(
    delta, population.generation, population.no_improve_streak)
  let batch = evo_batch(entries)
  let rng_seed = evo_rng_seed_text(evo_json_int(population.init, "seed",
    "evo_population_record_invalid"), population.generation)
  let mut updated = population
  let mut fossils : Array[String] = []
  let mut extinct = 0
  let mut elite = 0
  let mut protected_count = 0
  let mut offspring = 0
  let mut immigrants = 0
  let mut rolled_back = false
  let mut next_generation = population.generation + 1
  if rollback {
    let (rebuilt, ids, dropped) = evo_rebuild_from_checkpoint(store, entries, batch,
      population, policy.params, population.generation, at, "regression", streak,
      state.window_sha256)
    updated = rebuilt
    fossils = ids
    extinct = dropped
    rolled_back = true
    next_generation = rebuilt.generation
    delta = best - checkpoint_fitness
    let history = evo_history_append(updated.history,
      evo_history_entry(population.generation, state.window_sha256, best, mean,
        worst, delta, true, true), policy.params.history)
    updated = { ..updated, history }
  } else {
    let ranked = alive_sorted
    let checkpoint_genome = match checkpoint { None => ""; Some(value) => value.genome }
    let (elites, protect_count, _) = evo_plan_elites(
      ranked, policy.params, checkpoint_genome)
    let elite_ids : Map[String, Bool] = Map([])
    for row in elites { elite_ids[row.genome] = true }
    let dying : Array[EvoMember] = []
    for row in ranked {
      if !elite_ids.contains(row.genome) { dying.push(row) }
    }
    for row in population.members {
      if row.status == "lethal" { dying.push(row) }
    }
    extinct = dying.length()
    let fossil_n = evo_fossil_limit(policy.params, dying)
    let lethal_candidates = evo_sort_fossil_candidates(
      dying.filter(row => row.status == "lethal"), false)
    let normal_candidates = evo_sort_fossil_candidates(
      dying.filter(row => row.status != "lethal"), false)
    let lethal_ids = evo_fossilize_members(store, entries, batch, lethal_candidates,
      fossil_n, "lethal", population.generation, state.window_sha256, at)
    let remaining = fossil_n - lethal_ids.length()
    let normal_ids = evo_fossilize_members(store, entries, batch, normal_candidates,
      remaining, "not_selected", population.generation, state.window_sha256, at)
    for id in lethal_ids { fossils.push(id) }
    for id in normal_ids { fossils.push(id) }
    let immigrant_count = Int::min(
      policy.params.immigrants + (if saturated { 1 } else { 0 }),
      Int::max(0, alive.length() - elites.length() - 1))
    let offspring_count = Int::max(0, alive.length() - elites.length() - immigrant_count)
    let parent_pool = if ranked.length() > protect_count {
      ranked[protect_count:].to_owned()
    } else {
      ranked
    }
    let new_members : Array[EvoMember] = []
    for row in elites {
      new_members.push({ ..row, age: row.age + 1, evaluated_generation: None })
    }
    let created : Map[String, Bool] = Map([])
    let rng = evo_rng(evo_json_int(population.init, "seed",
      "evo_population_record_invalid"), population.generation)
    for _ in 0..<offspring_count {
      let left = evo_tournament(rng, parent_pool, policy.params.tournament)
      let right = evo_tournament(rng, parent_pool, policy.params.tournament)
      let crossover = evo_rng_unit(rng) < policy.params.crossover_rate
      let left_genome = evo_load_genome(store, entries, left.genome)
      let right_weights = if crossover {
        let right_genome = evo_load_genome(store, entries, right.genome)
        right_genome.weights
      } else {
        left_genome.weights
      }
      let rank_ratio = if alive.length() <= 1 { 0.0 } else {
        let left_rank = evo_rank(ranked, left.genome)
        let right_rank = if crossover { evo_rank(ranked, right.genome) } else { left_rank }
        let worse = Int::max(left_rank, right_rank)
        worse.to_double() / (alive.length() - 1).to_double()
      }
      let amplitude = evo_amplitude(policy.params, rank_ratio) *
        (if saturated { EVO_SATURATION_BOOST } else { 1.0 })
      let weights = evo_child_weights(rng, left_genome.weights, right_weights,
        crossover, policy.params.mutation_rate, amplitude)
      let parents : Array[String] = if crossover {
        [left.genome, right.genome]
      } else {
        [left.genome]
      }
      let id = evo_emit_genome(store, batch, created,
        if crossover { "crossover" } else { "clone" },
        population.generation + 1, parents, weights, at)
      new_members.push({
        genome: id, fitness: None, breakdown: Json::null(), age: 0,
        evaluated_generation: None, status: "alive",
      })
    }
    for _ in 0..<immigrant_count {
      let weights = evo_xavier(rng)
      let id = evo_emit_genome(store, batch, created, "immigrant",
        population.generation + 1, [], weights, at)
      new_members.push({
        genome: id, fitness: None, breakdown: Json::null(), age: 0,
        evaluated_generation: None, status: "alive",
      })
    }
    let history = evo_history_append(population.history,
      evo_history_entry(population.generation, state.window_sha256, best, mean,
        worst, delta, regressed, false), policy.params.history)
    updated = {
      ..population, generation: population.generation + 1,
      members: evo_member_sort_by_genome(new_members),
      history,
      extinct_total: population.extinct_total + extinct,
      fossil_total: evo_fossil_count(store) + fossils.length(),
      regressions_total: population.regressions_total + (if regressed { 1 } else { 0 }),
      regression_streak: streak,
      no_improve_streak,
      saturations_total: population.saturations_total + (if saturated { 1 } else { 0 }),
      last_evolve: Json::null(),
    }
    elite = elites.length()
    protected_count = protect_count
    offspring = offspring_count
    immigrants = immigrant_count
  }
  let last_evolve_json : Json = {
    "from_generation": population.generation,
    "to_generation": next_generation, "window_sha256": state.window_sha256,
    "at": at, "best": best, "mean": mean, "worst": worst, "delta": delta,
    "regressed": regressed.to_json(), "rolled_back": rolled_back.to_json(),
    "fossils": fossils.length(), "extinct": extinct, "immigrants": immigrants,
    "elite": elite, "protected": protected_count, "rng_seed": rng_seed,
  }
  updated = { ..updated, last_evolve: last_evolve_json }
  let event_path = "evo/events/evo-evolve-" + @base.hex_hash(
    population.generation.to_string() + "\n" + state.window_sha256 + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-evolve", "at": at, "from_generation": population.generation,
    "to_generation": next_generation, "window_sha256": state.window_sha256,
    "best": best, "mean": mean, "worst": worst, "delta": delta,
    "regressed": regressed.to_json(), "rolled_back": rolled_back.to_json(),
    "fossils": fossils.length(), "extinct": extinct,
  })
  if saturated {
    let saturation_path = "evo/events/evo-saturation-" + @base.hex_hash(
      population.generation.to_string() + "\n" + EVO_SATURATION_PATIENCE.to_string() +
        "\n" + at) + ".json"
    evo_emit_event(batch, saturation_path, {
      "op": "evo-saturation", "at": at, "generation": population.generation,
      "streak": EVO_SATURATION_PATIENCE, "best": best,
    })
  }
  if regressed {
    let regression_path = "evo/events/evo-regression-" + @base.hex_hash(
      population.generation.to_string() + "\n" + state.window_sha256 + "\n" + at) + ".json"
    evo_emit_event(batch, regression_path, {
      "op": "evo-regression", "at": at, "generation": population.generation,
      "window_sha256": state.window_sha256, "best": best,
      "checkpoint": checkpoint_fitness, "delta": best - checkpoint_fitness,
    })
    updated = { ..updated,
      regressions_total: population.regressions_total + 1 }
  }
  if rollback {
    let checkpoint = evo_checkpoint(population.checkpoint).unwrap()
    let rollback_path = "evo/events/evo-rollback-" + @base.hex_hash(
      next_generation.to_string() + "\nregression\n" + at) + ".json"
    evo_emit_event(batch, rollback_path, {
      "op": "evo-rollback", "at": at, "from_generation": population.generation,
      "to_generation": next_generation, "reason": "regression",
      "checkpoint": checkpoint.genome, "fossils": fossils.length(),
    })
    updated = { ..updated,
      rollbacks_total: population.rollbacks_total + 1 }
  }
  evo_add_update(batch, "evo/population.json", population_text,
    @base.canonical(evo_population_json(updated, at)))
  if rolled_back {
    let refreshed_state : EvoState = { ..state,
      active_genome: match evo_checkpoint(updated.checkpoint) {
        None => state.active_genome
        Some(value) => Some(value.genome)
      },
    }
    evo_add_update(batch, "evo/state.json", state_text,
      @base.canonical(evo_state_json(refreshed_state, at)))
  }
  evo_sidecar_commit(store, batch.changes)
  {
    "generation": population.generation, "next_generation": next_generation,
    "best": best, "mean": mean, "worst": worst, "delta": delta,
    "window_changed": window_changed.to_json(), "regressed": regressed.to_json(),
    "regression_streak": updated.regression_streak,
    "rolled_back": rolled_back.to_json(), "elite": elite, "protected": protected_count,
    "offspring": offspring, "immigrants": immigrants, "extinct": extinct,
    "saturated": saturated.to_json(),
    "no_improve_streak": updated.no_improve_streak,
    "fossils": fossils.to_json(), "rng_seed": rng_seed, "replayed": false,
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn evo_evolve_replay(
  store : @vault.Storage, population : EvoPopulation, last : EvoLastEvolve,
  entries : Array[@core.Entry],
) -> Json raise @base.Fault {
  let history = population.history
  let previous_window = match evo_last_eval(population.last_eval) {
    None => ""
    Some(value) => value.window_sha256
  }
  let window_changed = if history.length() >= 2 {
    @base.text(@base.field(history[history.length() - 2], "window_sha256")) != previous_window
  } else {
    false
  }
  // Fossil ids are rebuilt from the immutable fossil records themselves: the
  // evolve ledger stores only their count, and the records are never rewritten.
  let ids : Array[String] = []
  for pair in evo_sidecar_records(store, "evo/fossils/") {
    let record = @base.parse(pair.1)
    match @base.field(record, "died_generation") {
      Number(n, ..) => if n.to_int() == last.from_generation {
        match @base.field(record, "id") {
          String(id) => ids.push(id)
          _ => ()
        }
      }
      _ => ()
    }
  }
  ids.sort_by(@base.compare)
  if ids.length() != last.fossils { @base.fail("evo_state_corrupt") }
  let offspring = if last.rolled_back { 0 } else {
    Int::max(0, population.members.length() - last.elite - last.immigrants)
  }
  {
    "generation": last.from_generation, "next_generation": last.to_generation,
    "best": last.best, "mean": last.mean, "worst": last.worst,
    "delta": last.delta, "window_changed": window_changed.to_json(),
    "regressed": last.regressed.to_json(),
    "regression_streak": population.regression_streak,
    "rolled_back": last.rolled_back.to_json(), "elite": last.elite,
    "protected": last.protected_count, "offspring": offspring,
    "immigrants": last.immigrants, "extinct": last.extinct,
    "fossils": ids.to_json(), "rng_seed": last.rng_seed, "replayed": true,
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- status ---------------------------------------------------------------

fn evo_status_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, [])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  let gate = evo_pending_gate(store, entries)
  let state_text = (store.read)("evo/state.json")
  let population_text = (store.read)("evo/population.json")
  let initialized = state_text is Some(_) && population_text is Some(_)
  if (state_text is Some(_)) != (population_text is Some(_)) {
    @base.fail("evo_state_corrupt")
  }
  let mut generation = 0
  let mut size = 0
  let mut alive_count = 0
  let mut lethal_count = 0
  let mut checkpoint_json = Json::null()
  let mut history : Array[Json] = []
  let mut last_json = Json::null()
  let mut delta_json = Json::null()
  let mut fossils = 0
  let mut extinctions = 0
  let mut regressions = 0
  let mut rollbacks = 0
  let mut active_genome = Json::null()
  let empty_relations : Array[EvoRelation] = []
  let mut state_json : Json = {
    "emotion": [0.0, 0.0, 0.0].map(value => value.to_json()).to_json(),
    "impulse": 0.0,
    "body": { "cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0 },
    "relations": empty_relations.map(evo_relation_json).to_json(),
  }
  let mut steps = 0
  let mut have = 0
  if initialized {
    let state = evo_state_from_json(@base.parse(state_text.unwrap()))
    let population = evo_population_from_json(@base.parse(population_text.unwrap()))
    if @core.evo_window_hash(state.window) != state.window_sha256 {
      @base.fail("evo_state_corrupt")
    }
    // population.init is the single init identity; the event binds the same
    // (seed, at, policy_hash), so a desynchronised pair is corrupt state.
    let init_seed = evo_json_int(population.init, "seed", "evo_population_record_invalid")
    let init_at = @base.text(@base.field(population.init, "at"))
    let init_hash = @base.text(@base.field(population.init, "policy_hash"))
    let init_event_path = "evo/events/evo-init-" +
      @base.hex_hash(init_seed.to_string() + "\n" + init_at) + ".json"
    if (store.read)(init_event_path) is None {
      @base.fail("evo_state_corrupt")
    }
    let init_event = @base.parse(@vault.required(store, init_event_path))
    if @base.text(@base.field(init_event, "policy_hash")) != init_hash {
      @base.fail("evo_state_corrupt")
    }
    generation = population.generation
    size = population.members.length()
    for row in population.members {
      if row.status == "alive" {
        alive_count = alive_count + 1
      } else {
        lethal_count = lethal_count + 1
      }
    }
    checkpoint_json = population.checkpoint
    history = population.history
    last_json = population.last_eval
    delta_json = if history.is_empty() { Json::null() } else {
      @base.field(history[history.length() - 1], "delta")
    }
    fossils = population.fossil_total
    extinctions = population.extinct_total
    regressions = population.regressions_total
    rollbacks = population.rollbacks_total
    active_genome = match state.active_genome {
      None => Json::null()
      Some(value) => value.to_json()
    }
    steps = state.steps
    have = state.window.length()
    state_json = {
      "emotion": state.emotion.map(value => value.to_json()).to_json(),
      "impulse": state.impulse, "body": state.body,
      "relations": state.relations.map(evo_relation_json).to_json(),
    }
    let checkpoint = evo_checkpoint(population.checkpoint)
    match checkpoint {
      None => ()
      Some(value) => {
        ignore(evo_load_genome(store, entries, value.genome))
        let mut found = false
        for row in population.members {
          if row.genome == value.genome && row.status == "alive" { found = true }
        }
        if !found { @base.fail("evo_state_corrupt") }
      }
    }
    match state.active_genome {
      None => ()
      Some(value) => {
        ignore(evo_load_genome(store, entries, value))
      }
    }
    if population.fossil_total != evo_fossil_count(store) ||
      population.regressions_total != evo_event_count(store, "evo/events/evo-regression-") ||
      population.rollbacks_total != evo_event_count(store, "evo/events/evo-rollback-") {
      @base.fail("evo_population_corrupt")
    }
  }
  let checkpoint_out : Json = match checkpoint_json {
    Object(_) => Json::object(Map([
      ("generation", @base.field(checkpoint_json, "generation")),
      ("genome", @base.field(checkpoint_json, "genome")),
      ("fitness", @base.field(checkpoint_json, "fitness")),
    ]))
    _ => Json::null()
  }
  let last_out : Json = match last_json {
    Object(_) => Json::object(Map([
      ("best", @base.field(last_json, "best")),
      ("mean", @base.field(last_json, "mean")),
      ("worst", @base.field(last_json, "worst")),
      ("delta", delta_json),
    ]))
    _ => Json::null()
  }
  {
    "enabled": true.to_json(), "initialized": initialized.to_json(),
    "policy": policy.params_json, "generation": generation,
    "population": { "size": size, "alive": alive_count, "lethal": lethal_count },
    "checkpoint": checkpoint_out,
    "last": last_out, "delta": delta_json, "history": history.to_json(),
    "window": { "capacity": policy.params.window, "have": have, "steps": steps },
    "fossils": fossils, "extinctions": extinctions, "regressions": regressions,
    "rollbacks": rollbacks, "pending_human_gate": (gate is Some(_)).to_json(),
    "pending_gate_path": match gate { None => Json::null(); Some(value) => value.to_json() },
    "active_genome": active_genome, "state": state_json,
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- manual rollback ------------------------------------------------------

fn evo_rollback_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["at"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let state_text = match (store.read)("evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("evo/population.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let population = evo_population_from_json(@base.parse(population_text))
  let last_rollback = evo_last_rollback(population.last_rollback)
  match last_rollback {
    Some(last) => if last.at == at && last.reason == "manual" {
      let ids : Array[String] = []
      for pair in evo_sidecar_records(store, "evo/fossils/") {
        let record = @base.parse(pair.1)
        let match_at = match @base.field(record, "at") {
          String(value) => value == last.at
          _ => false
        }
        let match_reason = match @base.field(record, "reason") {
          String(value) => value == "manual_rollback"
          _ => false
        }
        let match_generation = match @base.field(record, "died_generation") {
          Number(n, ..) => n.to_int() == last.from_generation
          _ => false
        }
        if match_at && match_reason && match_generation {
          match @base.field(record, "id") {
            String(id) => ids.push(id)
            _ => ()
          }
        }
      }
      ids.sort_by(@base.compare)
      if ids.length() != last.fossils { @base.fail("evo_state_corrupt") }
      return {
        "rolled_back": true.to_json(), "reason": "manual",
        "from_generation": last.from_generation,
        "to_generation": last.to_generation, "checkpoint": last.checkpoint,
        "fossils": ids.to_json(), "replayed": true,
        "fingerprint": @vault.fingerprint(entries),
      }
    }
    None => ()
  }
  let checkpoint = match evo_checkpoint(population.checkpoint) {
    None => { @base.fail("evo_rollback_unavailable"); abort("") }
    Some(value) => value
  }
  let mut evaluated = false
  for row in population.members {
    if row.evaluated_generation is Some(_) { evaluated = true }
  }
  match last_rollback {
    Some(last) => if last.to_generation == checkpoint.generation &&
      population.generation == checkpoint.generation && !evaluated {
      @base.fail("evo_rollback_noop")
    }
    None => ()
  }
  let batch = evo_batch(entries)
  let (rebuilt, ids, _) = evo_rebuild_from_checkpoint(store, entries, batch,
    population, policy.params, population.generation, at, "manual",
    population.regression_streak, state.window_sha256)
  evo_add_update(batch, "evo/population.json", population_text,
    @base.canonical(evo_population_json(rebuilt, at)))
  evo_add_update(batch, "evo/state.json", state_text,
    @base.canonical(evo_state_json({ ..state,
      active_genome: Some(checkpoint.genome) }, at)))
  let rollback_path = "evo/events/evo-rollback-" + @base.hex_hash(
    checkpoint.generation.to_string() + "\nmanual\n" + at) + ".json"
  evo_emit_event(batch, rollback_path, {
    "op": "evo-rollback", "at": at, "from_generation": population.generation,
    "to_generation": checkpoint.generation, "reason": "manual",
    "checkpoint": checkpoint.genome, "fossils": ids.length(),
  })
  evo_sidecar_commit(store, batch.changes)
  {
    "rolled_back": true.to_json(), "reason": "manual",
    "from_generation": population.generation,
    "to_generation": checkpoint.generation, "checkpoint": checkpoint.genome,
    "fossils": ids.to_json(), "replayed": false,
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- dispatch -------------------------------------------------------------

// ---- anthropomorphic expression (续三十九) --------------------------------
// The engine emits structured tokens only; wording/voice/rendering stay in the
// host. Thresholds are deterministic so an expression frame can be replayed.
fn evo_emotion_label(valence : Double, arousal : Double) -> String {
  if valence >= 0.55 && arousal >= 0.55 {
    "excited"
  } else if valence >= 0.25 {
    "content"
  } else if valence <= -0.55 && arousal >= 0.55 {
    "distressed"
  } else if valence <= -0.25 {
    "low"
  } else if arousal >= 0.60 {
    "alert"
  } else {
    "calm"
  }
}

fn evo_expression_posture(will_initiate : Bool, arousal : Double, impulse : Double,
  valence : Double) -> String {
  if will_initiate {
    "speak"
  } else if arousal >= 0.60 {
    "lean_in"
  } else if impulse >= 0.35 {
    "think"
  } else if valence <= -0.35 {
    "still"
  } else {
    "idle"
  }
}

fn evo_expression_gesture(posture : String) -> String {
  if posture == "speak" {
    "open_palm"
  } else if posture == "lean_in" {
    "tilt_head"
  } else if posture == "think" {
    "still"
  } else if posture == "still" {
    "look_down"
  } else {
    "none"
  }
}

fn evo_expression_face(label : String) -> String {
  if label == "excited" {
    "bright"
  } else if label == "content" {
    "soft_smile"
  } else if label == "distressed" {
    "tense"
  } else if label == "low" {
    "subdued"
  } else if label == "alert" {
    "focused"
  } else {
    "neutral"
  }
}

fn evo_body_level(body : Json) -> Double raise @base.Fault {
  let mut sum = 0.0
  for key in ["cpu", "memory", "latency", "budget"] {
    sum = sum + (match @base.field(body, key) {
      Number(n, ..) => n
      _ => 0.0
    })
  }
  evo_clamp(sum / 4.0, 0.0, 1.0)
}

pub fn evo_expression_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "at"])
  @vault.verify(store, entries)
  let at = evo_at_text(request)
  let state_text = match (store.read)("evo/state.json") {
    None => {
      @base.fail("evo_not_initialized")
      ""
    }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let due = evo_proactive_due_state(store, entries, at)
  let valence = if state.emotion.length() > 0 { state.emotion[0] } else { 0.0 }
  let arousal = if state.emotion.length() > 1 { state.emotion[1] } else { 0.0 }
  let dominance = if state.emotion.length() > 2 { state.emotion[2] } else { 0.0 }
  let energy = evo_clamp(1.0 - evo_body_level(state.body), 0.0, 1.0)
  let label = evo_emotion_label(valence, arousal)
  let will_initiate = due.due
  let posture = evo_expression_posture(will_initiate, arousal, state.impulse, valence)
  {
    "posture": posture,
    "emotion": state.emotion.map(v => v.to_json()).to_json(),
    "emotion_label": label,
    "prosody": {
      "rate": evo_clamp(0.85 + arousal * 0.30, 0.5, 1.5),
      "pitch": evo_clamp(0.90 + valence * 0.15, 0.5, 1.5),
      "volume": evo_clamp(0.80 + dominance * 0.15 + energy * 0.05, 0.5, 1.0),
    },
    "gesture": evo_expression_gesture(posture),
    "expression": evo_expression_face(label),
    "will_initiate": will_initiate.to_json(),
    "reason": due.reason,
    "next_in_steps": due.next_in_steps,
    "impulse": state.impulse,
    "energy": energy,
    "pending": due.pending,
    "expired": due.expired,
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- read-only inspection ops (续三十二) ----------------------------------
fn evo_checkpoint_op(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let text = match (store.read)("evo/population.json") {
    None => {
      @base.fail("evo_not_initialized")
      ""
    }
    Some(value) => value
  }
  let population = evo_population_from_json(@base.parse(text))
  {
    "generation": population.generation,
    "checkpoint": population.checkpoint,
    "history": population.history.to_json(),
    "regressions": population.regressions_total,
    "rollbacks": population.rollbacks_total,
    "saturations": population.saturations_total,
    "no_improve_streak": population.no_improve_streak,
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn evo_fossils_op(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let keyed = evo_sidecar_records(store, "evo/fossils/")
  let fossils : Array[Json] = []
  for pair in keyed {
    let row = @base.parse(pair.1)
    fossils.push({
      "id": @base.text(@base.field(row, "id")),
      "genome": @base.text(@base.field(row, "genome")),
      "reason": @base.text(@base.field(row, "reason")),
      "died_generation": @base.field(row, "died_generation"),
      "fitness": @base.field(row, "fitness"),
      "weights_sha256": @base.text(@base.field(row, "weights_sha256")),
      "at": @base.text(@base.field(row, "at")),
    })
  }
  {
    "fossils": fossils.to_json(),
    "count": fossils.length(),
    "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- proactive outbox (续三十三) ------------------------------------------
// When the emotion/personality subsystem is enabled, its own affect state is
// allowed to initiate an LLM call: the engine publishes a structured request,
// a host-side driver claims it, calls the model and completes it. The engine
// never calls a model and no other engine module reads these records.
const EVO_PROACTIVE_COOLDOWN_STEPS : Int = 8
const EVO_PROACTIVE_MIN_IMPULSE : Double = 0.55
// Proactive speech needs both an emotional impulse and a long idle gap since
// the agent subject was last busy. Thirty minutes is the product floor; the due
// response reports the exact requirement and the measured gap.
const EVO_PROACTIVE_IDLE_SECONDS : Int = 1800

priv struct EvoProactiveDue {
  due : Bool
  reason : String
  urgency : Double
  context : Json
  pending : Int
  expired : Int
  next_in_steps : Int
  idle_ok : Bool
  idle_seconds : Int?
  last_activity_at : String?
}

fn evo_proactive_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  ignore(entries)
  let rows : Array[Json] = []
  for pair in evo_sidecar_records(store, "evo/proactive/") {
    rows.push(@base.parse(pair.1))
  }
  rows
}

// The activity stamp is monotonic: a report older than the recorded one never
// rewinds the idle gate. `None` means the vault cannot prove idleness, so the
// gate fails closed until the host reports activity once.
fn evo_activity_change(
  store : @vault.Storage, at : String,
) -> (@vault.Change?, String?) raise @base.Fault {
  match (store.read)("evo/state.json") {
    None => raise @base.Fault("evo_not_initialized")
    Some(text) => {
      let state = evo_state_from_json(@base.parse(text))
      let last = state.last_activity_at
      let newer = match last {
        Some(existing) => @base.compare(at, existing) > 0
        None => true
      }
      if !newer { (None, last) } else {
        let content = @base.canonical(evo_state_json({ ..state, last_activity_at: Some(at) }, at))
        (Some({ path: "evo/state.json", before: Some(text), after: Some(content) }), Some(at))
      }
    }
  }
}

pub fn evo_activity_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let (change, current) = evo_activity_change(store, at)
  match change {
    Some(value) => evo_sidecar_commit(store, [value])
    None => ()
  }
  {
    "reported": true.to_json(),
    "replayed": change is None,
    "last_activity_at": match current {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn evo_proactive_id(step : Int, genome : String, window_sha256 : String) -> String {
  @base.hex_hash("evo-proactive-v1\n" + step.to_string() + "\n" + genome + "\n" + window_sha256)
}

// Pure gates, kept separate so the "when may it speak" contract is testable
// without a vault. Valence alone never authorizes a proactive turn: the
// subsystem must actually want to speak. `fired_since` means the impulse
// network crossed its threshold after the most recent proactive request, i.e.
// an unexpressed impulse exists even when the scalar has since decayed.
fn evo_proactive_reason(impulse : Double, fired_since : Bool) -> String {
  if fired_since || impulse >= EVO_PROACTIVE_MIN_IMPULSE { "impulse" } else { "" }
}

fn evo_proactive_ready(pending : Int, cooldown_ok : Bool, reason : String) -> Bool {
  pending == 0 && cooldown_ok && reason != ""
}

// Seconds since the last observable agent activity. `None` means the vault has
// no activity stamp (a pre-field state record); the gate fails closed then,
// because it cannot prove the system has been idle.
fn evo_proactive_idle_seconds(last_activity : String?, at : String) -> Int? {
  let now = match @base.utc_epoch(at) {
    Some(value) => value
    None => return None
  }
  match last_activity {
    Some(value) => match @base.utc_epoch(value) {
      Some(last) => Some(Int::max(0, now - last))
      None => None
    }
    None => None
  }
}

fn evo_proactive_idle_ok(seconds : Int?) -> Bool {
  match seconds {
    Some(value) => value >= EVO_PROACTIVE_IDLE_SECONDS
    None => false
  }
}

// An expired claim no longer blocks the outbox: it is the takeover candidate.
fn evo_proactive_lease_expired(row : Json, at : String) -> Bool raise @base.Fault {
  match evo_optional(row, "lease_until") {
    Some(value) => value != Json::null() && @base.compare(@base.text(value), at) <= 0
    None => false
  }
}

fn evo_proactive_due_state(store : @vault.Storage, entries : Array[@core.Entry], at : String) -> EvoProactiveDue raise @base.Fault {
  let state_text = match (store.read)("evo/state.json") {
    None => {
      @base.fail("evo_not_initialized")
      ""
    }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let genome = match state.active_genome {
    None => {
      @base.fail("evo_genome_not_found")
      ""
    }
    Some(value) => value
  }
  ignore(evo_load_genome(store, entries, genome))
  let rows = evo_proactive_rows(store, entries)
  let mut pending = 0
  let mut expired = 0
  let mut last_step = -1
  for row in rows {
    let status = @base.text(@base.field(row, "status"))
    if status == "pending" {
      pending = pending + 1
    } else if status == "claimed" {
      if evo_proactive_lease_expired(row, at) {
        expired = expired + 1
      } else {
        pending = pending + 1
      }
    }
    let step = match @base.field(row, "step") {
      Number(n, ..) => n.to_int()
      _ => 0
    }
    if step > last_step { last_step = step }
  }
  let steps = state.steps
  let valence = if state.emotion.length() > 0 { state.emotion[0] } else { 0.0 }
  let fired_since = match state.last_fire_step {
    Some(fire) => fire > last_step
    None => false
  }
  let reason = evo_proactive_reason(state.impulse, fired_since)
  let idle_seconds = evo_proactive_idle_seconds(state.last_activity_at, at)
  let idle_ok = evo_proactive_idle_ok(idle_seconds)
  let abs_valence = if valence < 0.0 { -valence } else { valence }
  let urgency = evo_clamp(if state.impulse > abs_valence { state.impulse } else { abs_valence }, 0.0, 1.0)
  let context : Json = {
    "step": steps, "emotion": state.emotion.map(v => v.to_json()).to_json(),
    "impulse": state.impulse, "body": state.body,
    "relations": state.relations.map(evo_relation_json).to_json(),
    "window_sha256": state.window_sha256, "genome": genome,
  }
  let cooldown_ok = steps - last_step >= EVO_PROACTIVE_COOLDOWN_STEPS
  {
    due: evo_proactive_ready(pending, cooldown_ok, reason) && idle_ok,
    reason,
    urgency,
    context,
    pending,
    expired,
    next_in_steps: if cooldown_ok { 0 } else { EVO_PROACTIVE_COOLDOWN_STEPS - (steps - last_step) },
    idle_ok,
    idle_seconds,
    last_activity_at: state.last_activity_at,
  }
}

fn evo_proactive_expired_row(store : @vault.Storage, entries : Array[@core.Entry], at : String) -> Json? raise @base.Fault {
  let keyed : Array[(String, Json)] = evo_proactive_rows(store, entries).map(
    row => (@base.text(@base.field(row, "id")), row))
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  for pair in keyed {
    if @base.text(@base.field(pair.1, "status")) == "claimed" &&
      evo_proactive_lease_expired(pair.1, at) {
      return Some(pair.1)
    }
  }
  None
}

// Local copies of the generic state-record primitives: the evo controller is
// one-way isolated and must not reach into other subsystems' helpers.
fn evo_proactive_stamp(value : String) -> Unit raise @base.Fault {
  if value.length() < 10 || value.contains("\n") || value.contains("\r") {
    @base.fail("evo_proactive_stamp_invalid")
  }
}

fn evo_proactive_driver(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 128 || value.contains("\n") || value.contains("\r") {
    @base.fail("evo_proactive_driver_invalid")
  }
}

fn evo_proactive_hash_ok(value : String) -> Bool {
  value.length() == 64 && value.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
}

fn evo_proactive_set(row : Json, pairs : Array[(String, Json)]) -> Json {
  match row {
    Object(fields) => {
      let copy = fields.copy()
      for (key, value) in pairs { copy[key] = value }
      Json::object(copy)
    }
    _ => row
  }
}

fn evo_proactive_lease(value : String, at : String) -> Unit raise @base.Fault {
  evo_proactive_stamp(value)
  if @base.compare(value, at) <= 0 { @base.fail("evo_proactive_lease_invalid") }
}

pub fn evo_proactive_due_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let due = evo_proactive_due_state(store, entries, at)
  {
    "due": due.due.to_json(),
    "reason": due.reason.to_json(),
    "urgency": due.urgency,
    "context": due.context,
    "pending": due.pending,
    "expired": due.expired,
    "next_in_steps": due.next_in_steps,
    "cooldown_steps": EVO_PROACTIVE_COOLDOWN_STEPS,
    "idle": {
      "ok": due.idle_ok.to_json(),
      "seconds_since_activity": match due.idle_seconds {
        None => Json::null()
        Some(value) => value.to_json()
      },
      "required_seconds": EVO_PROACTIVE_IDLE_SECONDS.to_json(),
      "last_activity_at": match due.last_activity_at {
        None => Json::null()
        Some(value) => value.to_json()
      },
    },
    "fingerprint": @vault.fingerprint(entries),
  }
}

pub fn evo_proactive_open_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "driver", "lease_until", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let driver = @base.text(@base.field(request, "driver"))
  evo_proactive_driver(driver)
  let lease = @base.text(@base.field(request, "lease_until"))
  let at = evo_at_text(request)
  evo_proactive_lease(lease, at)
  let due = evo_proactive_due_state(store, entries, at)
  if due.pending > 0 { @base.fail("evo_proactive_backpressure") }
  if !due.due { @base.fail("evo_proactive_not_due") }
  if due.expired > 0 {
    let expired_row = match evo_proactive_expired_row(store, entries, at) {
      Some(row) => row
      None => {
        @base.fail("evo_proactive_state_corrupt")
        Json::null()
      }
    }
    let expired_id = @base.text(@base.field(expired_row, "id"))
    let expired_path = "evo/proactive/" + expired_id + ".json"
    let expired_text = @vault.required(store, expired_path)
    let updated = evo_proactive_set(expired_row, [
      ("driver", driver.to_json()), ("lease_until", lease.to_json()),
    ])
    let content = @base.canonical(updated)
    let event_path = "evo/events/evo-proactive-reclaim-" + expired_id + "-" +
      @base.hex_hash(driver + "\n" + at) + ".json"
    let event_content = @base.canonical({
      "op": "evo-proactive-reclaim", "proactive": expired_id, "driver": driver, "at": at,
    })
    let changes : Array[@vault.Change] = [
      { path: expired_path, before: Some(expired_text), after: Some(content) },
      { path: event_path, before: None, after: Some(event_content) },
    ]
      evo_sidecar_commit(store, changes)
    return {
      "id": expired_id, "reclaimed": true.to_json(),
      "step": @base.field(expired_row, "step"),
      "reason": @base.text(@base.field(expired_row, "reason")),
      "urgency": @base.field(expired_row, "urgency"),
      "context": @base.field(expired_row, "context"),
      "driver": driver, "lease_until": lease,
      "fingerprint": @vault.fingerprint(entries),
    }
  }
  let state_text = match (store.read)("evo/state.json") {
    None => {
      @base.fail("evo_not_initialized")
      ""
    }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let genome = match state.active_genome {
    None => {
      @base.fail("evo_genome_not_found")
      ""
    }
    Some(value) => value
  }
  let id = evo_proactive_id(state.steps, genome, state.window_sha256)
  let path = "evo/proactive/" + id + ".json"
  let record : Json = {
    "version": 1, "id": id, "step": state.steps, "genome": genome,
    "state_sha256": @base.hex_hash(state_text), "reason": due.reason,
    "urgency": due.urgency, "context": due.context, "status": "claimed",
    "driver": driver.to_json(), "lease_until": lease.to_json(), "created_at": at,
    "closed_at": Json::null(), "delivered_at": Json::null(),
    "result": Json::null(), "error": Json::null(),
    "parent": Json::null(), "turn": 0, "user_text": Json::null(),
  }
  let content = @base.canonical(record)
  let event_path = "evo/events/evo-proactive-open-" + id + "-" +
    @base.hex_hash(driver + "\n" + at) + ".json"
  let event_content = @base.canonical({
    "op": "evo-proactive-open", "proactive": id, "driver": driver, "at": at,
  })
  let changes : Array[@vault.Change] = [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  {
    "id": id, "reclaimed": false.to_json(),
    "step": state.steps, "reason": due.reason, "urgency": due.urgency,
    "context": due.context, "driver": driver, "lease_until": lease,
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn evo_proactive_result(value : Json) -> Unit raise @base.Fault {
  @base.keys(value, ["text", "model"])
  let text = @base.text(@base.field(value, "text"))
  if text.length() > 8192 || text.contains("\r") { @base.fail("evo_proactive_result_invalid") }
  let model = @base.text(@base.field(value, "model"))
  if model.is_empty() || model.length() > 128 || model.contains("\n") || model.contains("\r") {
    @base.fail("evo_proactive_result_invalid")
  }
}

pub fn evo_proactive_complete_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "driver", "at", "result"])
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(id) { @base.fail("evo_proactive_id_invalid") }
  let path = "evo/proactive/" + id + ".json"
  let text = match (store.read)(path) {
    None => {
      @base.fail("evo_proactive_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let driver = @base.text(@base.field(request, "driver"))
  evo_proactive_driver(driver)
  let at = evo_at_text(request)
  let result = @base.field(request, "result")
  evo_proactive_result(result)
  let status = @base.text(@base.field(row, "status"))
  if status == "done" && @base.text(@base.field(row, "driver")) == driver &&
    @base.text(@base.field(row, "closed_at")) == at && @base.field(row, "result") == result {
    return { "id": id, "status": "done", "replayed": true }
  }
  if status != "claimed" { @base.fail("evo_proactive_terminal: " + id) }
  if @base.text(@base.field(row, "driver")) != driver { @base.fail("evo_proactive_not_owner") }
  let lease = @base.text(@base.field(row, "lease_until"))
  if @base.compare(at, lease) > 0 { @base.fail("evo_proactive_lease_expired") }
  let updated = evo_proactive_set(row, [
    ("status", "done".to_json()), ("closed_at", at.to_json()), ("result", result),
  ])
  let content = @base.canonical(updated)
  let event_path = "evo/events/evo-proactive-complete-" + id + "-" +
    @base.hex_hash(driver + "\n" + at) + ".json"
  let event_content = @base.canonical({
    "op": "evo-proactive-complete", "proactive": id, "driver": driver, "at": at,
  })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  { "id": id, "status": "done", "replayed": false }
}

pub fn evo_proactive_fail_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "driver", "reason", "at"])
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(id) { @base.fail("evo_proactive_id_invalid") }
  let path = "evo/proactive/" + id + ".json"
  let text = match (store.read)(path) {
    None => {
      @base.fail("evo_proactive_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let driver = @base.text(@base.field(request, "driver"))
  evo_proactive_driver(driver)
  let reason = @base.text(@base.field(request, "reason"))
  if reason.is_empty() || reason.length() > 1024 || reason.contains("\n") || reason.contains("\r") {
    @base.fail("evo_proactive_error_invalid")
  }
  let at = evo_at_text(request)
  let status = @base.text(@base.field(row, "status"))
  if status == "failed" && @base.text(@base.field(row, "driver")) == driver &&
    @base.text(@base.field(row, "closed_at")) == at &&
    @base.text(@base.field(row, "error")) == reason {
    return { "id": id, "status": "failed", "replayed": true }
  }
  if status != "claimed" { @base.fail("evo_proactive_terminal: " + id) }
  if @base.text(@base.field(row, "driver")) != driver { @base.fail("evo_proactive_not_owner") }
  let updated = evo_proactive_set(row, [
    ("status", "failed".to_json()), ("closed_at", at.to_json()), ("error", reason.to_json()),
  ])
  let content = @base.canonical(updated)
  let event_path = "evo/events/evo-proactive-fail-" + id + "-" +
    @base.hex_hash(driver + "\n" + at) + ".json"
  let event_content = @base.canonical({
    "op": "evo-proactive-fail", "proactive": id, "driver": driver, "at": at,
  })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  { "id": id, "status": "failed", "replayed": false }
}

pub fn evo_proactive_list_op(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let rows = evo_proactive_rows(store, entries)
  let keyed : Array[(String, Json)] = rows.map(row => (@base.text(@base.field(row, "id")), row))
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  let items : Array[Json] = []
  let mut pending = 0
  let mut claimed = 0
  let mut done = 0
  let mut failed = 0
  let mut delivered_count = 0
  let mut undelivered = 0
  for pair in keyed {
    let status = @base.text(@base.field(pair.1, "status"))
    let delivered = match evo_optional(pair.1, "delivered_at") {
      None => Json::null()
      Some(value) => value
    }
    if status == "pending" {
      pending = pending + 1
    } else if status == "claimed" {
      claimed = claimed + 1
    } else if status == "done" {
      done = done + 1
      if delivered == Json::null() { undelivered = undelivered + 1 } else { delivered_count = delivered_count + 1 }
    } else {
      failed = failed + 1
    }
    let parent_value : Json = match evo_optional(pair.1, "parent") {
      None => Json::null()
      Some(value) => value
    }
    let turn_value : Json = match evo_optional(pair.1, "turn") {
      Some(Number(n, ..)) => n.to_int().to_json()
      _ => (0 : Int).to_json()
    }
    let user_value : Json = match evo_optional(pair.1, "user_text") {
      None => Json::null()
      Some(value) => value
    }
    items.push({
      "id": pair.0, "step": @base.field(pair.1, "step"),
      "reason": @base.text(@base.field(pair.1, "reason")),
      "urgency": @base.field(pair.1, "urgency"),
      "status": status, "driver": @base.field(pair.1, "driver"),
      "lease_until": @base.field(pair.1, "lease_until"),
      "created_at": @base.text(@base.field(pair.1, "created_at")),
      "closed_at": @base.field(pair.1, "closed_at"),
      "delivered_at": delivered,
      "parent": parent_value,
      "turn": turn_value,
      "user_text": user_value,
      "result": @base.field(pair.1, "result"),
      "error": @base.field(pair.1, "error"),
    })
  }
  {
    "proactive": items.to_json(),
    "counts": { "pending": pending, "claimed": claimed, "done": done, "failed": failed,
      "delivered": delivered_count, "undelivered": undelivered },
    "fingerprint": @vault.fingerprint(entries),
  }
}

// At-least-once delivery: the host acknowledges a completed reply only after it
// has actually handed it to the user. Replaying the same ack is a no-op; a
// second delivery of the same reply is refused.
pub fn evo_proactive_ack_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "at"])
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(id) { @base.fail("evo_proactive_id_invalid") }
  let path = "evo/proactive/" + id + ".json"
  let text = match (store.read)(path) {
    None => {
      @base.fail("evo_proactive_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(text)
  let at = evo_at_text(request)
  let status = @base.text(@base.field(row, "status"))
  if status != "done" { @base.fail("evo_proactive_not_deliverable: " + id) }
  let delivered = match evo_optional(row, "delivered_at") {
    None => Json::null()
    Some(value) => value
  }
  if delivered != Json::null() {
    if @base.text(delivered) == at {
      return { "id": id, "status": "acknowledged", "delivered_at": at, "replayed": true }
    }
    @base.fail("evo_proactive_already_delivered: " + id)
  }
  let closed = @base.text(@base.field(row, "closed_at"))
  if @base.compare(at, closed) < 0 { @base.fail("evo_proactive_ack_time_invalid") }
  let updated = evo_proactive_set(row, [("delivered_at", at.to_json())])
  let content = @base.canonical(updated)
  let event_path = "evo/events/evo-proactive-ack-" + id + "-" +
    @base.hex_hash(at) + ".json"
  let event_content = @base.canonical({ "op": "evo-proactive-ack", "proactive": id, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  { "id": id, "status": "acknowledged", "delivered_at": at, "replayed": false }
}

// A user reply to a delivered proactive message (续五十一). The host creates a
// follow-up request in the same chain; it bypasses the affect due gate but not
// the one-in-flight backpressure, delivery requirement or depth limit.
pub fn evo_proactive_followup_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "user_text", "driver", "lease_until", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let parent_id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(parent_id) { @base.fail("evo_proactive_id_invalid") }
  let parent_path = "evo/proactive/" + parent_id + ".json"
  let parent_text = match (store.read)(parent_path) {
    None => {
      @base.fail("evo_proactive_not_found: " + parent_id)
      ""
    }
    Some(value) => value
  }
  let parent_row = @base.parse(parent_text)
  if @base.text(@base.field(parent_row, "status")) != "done" {
    @base.fail("evo_proactive_parent_not_delivered")
  }
  let delivered = match evo_optional(parent_row, "delivered_at") {
    None => Json::null()
    Some(value) => value
  }
  if delivered == Json::null() { @base.fail("evo_proactive_parent_not_delivered") }
  let parent_turn = match evo_optional(parent_row, "turn") {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
  let turn = parent_turn + 1
  if turn > 8 { @base.fail("evo_proactive_followup_depth") }
  let user_text = @base.text(@base.field(request, "user_text"))
  if user_text.is_empty() || user_text.length() > 4096 || user_text.contains("\r") {
    @base.fail("evo_proactive_user_text_invalid")
  }
  let driver = @base.text(@base.field(request, "driver"))
  evo_proactive_driver(driver)
  let lease = @base.text(@base.field(request, "lease_until"))
  let at = evo_at_text(request)
  evo_proactive_lease(lease, at)
  let mut inflight = 0
  for row in evo_proactive_rows(store, entries) {
    let status = @base.text(@base.field(row, "status"))
    if status == "pending" || status == "claimed" { inflight = inflight + 1 }
  }
  if inflight > 0 { @base.fail("evo_proactive_backpressure") }
  let due = evo_proactive_due_state(store, entries, at)
  let state_text = match (store.read)("evo/state.json") {
    None => {
      @base.fail("evo_not_initialized")
      ""
    }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let genome = match state.active_genome {
    None => {
      @base.fail("evo_genome_not_found")
      ""
    }
    Some(value) => value
  }
  let id = @base.hex_hash("evo-proactive-followup-v1\n" + parent_id + "\n" +
    turn.to_string() + "\n" + at)
  let path = "evo/proactive/" + id + ".json"
  let record : Json = {
    "version": 1, "id": id, "step": state.steps, "genome": genome,
    "state_sha256": @base.hex_hash(state_text), "reason": "followup",
    "urgency": 0.6, "context": due.context, "status": "claimed",
    "driver": driver.to_json(), "lease_until": lease.to_json(), "created_at": at,
    "closed_at": Json::null(), "delivered_at": Json::null(),
    "result": Json::null(), "error": Json::null(),
    "parent": parent_id.to_json(), "turn": turn, "user_text": user_text.to_json(),
  }
  let content = @base.canonical(record)
  let event_path = "evo/events/evo-proactive-followup-" + id + "-" +
    @base.hex_hash(parent_id + "\n" + driver + "\n" + at) + ".json"
  let event_content = @base.canonical({
    "op": "evo-proactive-followup", "proactive": id, "parent": parent_id,
    "driver": driver, "at": at,
  })
  let changes : Array[@vault.Change] = [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  // The user answered the previous proactive message: that is activity.
  let (activity, _) = evo_activity_change(store, at)
  match activity {
    Some(change) => changes.push(change)
    None => ()
  }
  evo_sidecar_commit(store, changes)
  {
    "id": id, "parent": parent_id, "turn": turn, "reason": "followup",
    "user_text": user_text, "context": due.context, "driver": driver,
    "lease_until": lease, "fingerprint": @vault.fingerprint(entries),
  }
}

// ---- conversation threads (续五十五) --------------------------------------
// User turns enter the engine as state, not as knowledge: a thread starts from a
// delivered proactive reply and stays open until the host closes it.
fn evo_thread_text(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 4096 || value.contains("\r") {
    @base.fail("evo_thread_text_invalid")
  }
}

fn evo_thread_turn(role : String, text : String, at : String) -> Json {
  { "role": role.to_json(), "text": text.to_json(), "at": at,
    "proactive": Json::null() }
}

pub fn evo_thread_open_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "proactive", "text", "driver", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let proactive = @base.text(@base.field(request, "proactive"))
  if !evo_proactive_hash_ok(proactive) { @base.fail("evo_thread_proactive_invalid") }
  let text = @base.text(@base.field(request, "text"))
  evo_thread_text(text)
  let driver = @base.text(@base.field(request, "driver"))
  evo_proactive_driver(driver)
  let at = evo_at_text(request)
  let parent_path = "evo/proactive/" + proactive + ".json"
  let parent_text = match (store.read)(parent_path) {
    None => {
      @base.fail("evo_proactive_not_found: " + proactive)
      ""
    }
    Some(value) => value
  }
  let parent_row = @base.parse(parent_text)
  if @base.text(@base.field(parent_row, "status")) != "done" {
    @base.fail("evo_thread_parent_not_done")
  }
  let delivered = match evo_optional(parent_row, "delivered_at") {
    None => Json::null()
    Some(value) => value
  }
  if delivered == Json::null() { @base.fail("evo_thread_parent_not_delivered") }
  let id = @base.hex_hash("evo-thread-v1\n" + proactive + "\n" + at)
  let path = "evo/threads/" + id + ".json"
  match (store.read)(path) {
    Some(existing) => {
      let old = @base.parse(existing)
      let turns = @base.array(@base.field(old, "turns"))
      let first = turns[0]
      if turns.length() == 1 &&
        @base.text(@base.field(first, "role")) == "agent" &&
        @base.text(@base.field(first, "text")) == text &&
        @base.text(@base.field(first, "at")) == at {
        return { "id": id, "status": "open", "turns": 1, "replayed": true,
          "fingerprint": @vault.fingerprint(entries) }
      }
      @base.fail("evo_thread_already_open")
    }
    None => ()
  }
  let turn = evo_thread_turn("agent", text, at)
  let record : Json = {
    "version": 1, "id": id, "created_at": at, "updated_at": at, "status": "open",
    "max_turns": 16, "turns": [turn], "last_proactive": proactive.to_json(),
  }
  let content = @base.canonical(record)
  let event_path = "evo/events/evo-thread-open-" + id + "-" +
    @base.hex_hash(driver + "\n" + proactive + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "evo-thread-open", "thread": id,
    "agent": driver, "proactive": proactive, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: (store.read)(path), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  { "id": id, "status": "open", "turns": 1, "last_proactive": proactive,
    "replayed": false, "fingerprint": @vault.fingerprint(entries) }
}

pub fn evo_thread_append_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "role", "text", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(id) { @base.fail("evo_thread_id_invalid") }
  let role = @base.text(@base.field(request, "role"))
  if !["agent", "user"].contains(role) { @base.fail("evo_thread_role_invalid") }
  let text = @base.text(@base.field(request, "text"))
  evo_thread_text(text)
  let at = evo_at_text(request)
  let path = "evo/threads/" + id + ".json"
  let row_text = match (store.read)(path) {
    None => {
      @base.fail("evo_thread_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(row_text)
  if @base.text(@base.field(row, "status")) != "open" {
    @base.fail("evo_thread_closed: " + id)
  }
  let turns = @base.array(@base.field(row, "turns"))
  let max_turns = match @base.field(row, "max_turns") {
    Number(n, ..) => n.to_int()
    _ => raise @base.Fault("evo_thread_max_turns_invalid")
  }
  if turns.length() >= max_turns { @base.fail("evo_thread_turn_limit") }
  let last = turns[turns.length() - 1]
  if @base.text(@base.field(last, "role")) == role &&
    @base.text(@base.field(last, "text")) == text &&
    @base.text(@base.field(last, "at")) == at {
    return { "id": id, "role": role, "turns": turns.length(), "replayed": true,
      "fingerprint": @vault.fingerprint(entries) }
  }
  let next_turns : Array[Json] = []
  for turn in turns { next_turns.push(turn) }
  next_turns.push(evo_thread_turn(role, text, at))
  let updated = evo_proactive_set(row, [
    ("turns", next_turns.to_json()),
    ("updated_at", at.to_json()),
  ])
  let content = @base.canonical(updated)
  let event_path = "evo/events/evo-thread-append-" + id + "-" +
    @base.hex_hash(role + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "evo-thread-append", "thread": id,
    "role": role, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(row_text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  // A user turn is observable agent activity: it resets the proactive idle
  // window in the same transaction. Agent turns do not (the subsystem is
  // speaking, not the subject being busy).
  if role == "user" {
    let (change, _) = evo_activity_change(store, at)
    match change {
      Some(value) => changes.push(value)
      None => ()
    }
  }
  evo_sidecar_commit(store, changes)
  { "id": id, "role": role, "turns": turns.length() + 1, "replayed": false,
    "fingerprint": @vault.fingerprint(entries) }
}

pub fn evo_thread_close_op(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  @base.keys(request, ["op", "vault", "request_id", "id", "at"])
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let id = @base.text(@base.field(request, "id"))
  if !evo_proactive_hash_ok(id) { @base.fail("evo_thread_id_invalid") }
  let at = evo_at_text(request)
  let path = "evo/threads/" + id + ".json"
  let row_text = match (store.read)(path) {
    None => {
      @base.fail("evo_thread_not_found: " + id)
      ""
    }
    Some(value) => value
  }
  let row = @base.parse(row_text)
  if @base.text(@base.field(row, "status")) == "closed" &&
    @base.text(@base.field(row, "updated_at")) == at {
    return { "id": id, "status": "closed", "replayed": true,
      "fingerprint": @vault.fingerprint(entries) }
  }
  if @base.text(@base.field(row, "status")) != "open" {
    @base.fail("evo_thread_terminal: " + id)
  }
  let updated = evo_proactive_set(row, [("status", "closed".to_json()), ("updated_at", at.to_json())])
  let content = @base.canonical(updated)
  let event_path = "evo/events/evo-thread-close-" + id + "-" +
    @base.hex_hash(at) + ".json"
  let event_content = @base.canonical({ "op": "evo-thread-close", "thread": id, "at": at })
  let changes : Array[@vault.Change] = [
    { path, before: Some(row_text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ]
  evo_sidecar_commit(store, changes)
  { "id": id, "status": "closed", "replayed": false,
    "fingerprint": @vault.fingerprint(entries) }
}

pub fn evo_thread_list_op(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let keyed : Array[(String, Json)] = []
  for pair in evo_sidecar_records(store, "evo/threads/") {
    let row = @base.parse(pair.1)
    keyed.push((@base.text(@base.field(row, "id")), row))
  }
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  let items : Array[Json] = []
  let mut open = 0
  let mut closed = 0
  for pair in keyed {
    let status = @base.text(@base.field(pair.1, "status"))
    if status == "open" { open = open + 1 } else { closed = closed + 1 }
    items.push({
      "id": pair.0, "status": status,
      "turns": @base.field(pair.1, "turns"),
      "max_turns": @base.field(pair.1, "max_turns"),
      "last_proactive": @base.field(pair.1, "last_proactive"),
      "updated_at": @base.text(@base.field(pair.1, "updated_at")),
    })
  }
  { "threads": items.to_json(), "counts": { "open": open, "closed": closed },
    "fingerprint": @vault.fingerprint(entries) }
}

pub fn evo(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  let policy = evo_load_policy(store)
  if op != "evo-policy" && !policy.enabled { @base.fail("evo_disabled") }
  // Sidecar face (续六十二 slice 2): recover any interrupted transaction and
  // verify every indexed record before the op reads, then pull pre-sidecar
  // vault records forward so the vault fingerprint stops tracking evo.
  ignore(evo_sidecar_load(store))
  let entries = evo_migrate_legacy(store, entries)
  match op {
    "evo-policy" => evo_policy_op(store, entries, request)
    "evo-init" => evo_init_op(store, entries, request)
    "evo-observe" => evo_observe_op(store, entries, request)
    "evo-observe-batch" => evo_observe_batch_op(store, entries, request)
    "evo-evaluate" => evo_evaluate_op(store, entries, request)
    "evo-evolve" => evo_evolve_op(store, entries, request)
    "evo-status" => evo_status_op(store, entries, request)
    "evo-rollback" => evo_rollback_op(store, entries, request)
    "evo-checkpoint" => evo_checkpoint_op(store, entries)
    "evo-fossils" => evo_fossils_op(store, entries)
    "evo-activity" => evo_activity_op(store, entries, request)
    "evo-proactive-due" => evo_proactive_due_op(store, entries, request)
    "evo-proactive-open" => evo_proactive_open_op(store, entries, request)
    "evo-proactive-complete" => evo_proactive_complete_op(store, entries, request)
    "evo-proactive-fail" => evo_proactive_fail_op(store, entries, request)
    "evo-proactive-ack" => evo_proactive_ack_op(store, entries, request)
    "evo-proactive-followup" => evo_proactive_followup_op(store, entries, request)
    "evo-thread-open" => evo_thread_open_op(store, entries, request)
    "evo-thread-append" => evo_thread_append_op(store, entries, request)
    "evo-thread-close" => evo_thread_close_op(store, entries, request)
    "evo-thread-list" => evo_thread_list_op(store, entries)
    "evo-expression" => evo_expression_op(store, entries, request)
    "evo-proactive-list" => evo_proactive_list_op(store, entries)
    _ => raise @base.Fault("operation_not_implemented: " + op)
  }
}