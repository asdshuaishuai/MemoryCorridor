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
}

priv struct EvoBatch {
  next : Ref[Array[@core.Entry]]
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
  match (store.read)("state/evo/policy.json") {
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

fn evo_payload(kind : String, salience : Double, valence : Double, body : Json, subject : String?) -> Json {
  {
    "kind": kind, "salience": salience, "valence": valence, "body": body,
    "subject": match subject { None => Json::null(); Some(value) => value.to_json() },
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
    })
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
  "state/evo/genomes/" + id + ".json"
}

fn evo_load_genome(
  store : @vault.Storage, entries : Array[@core.Entry], id : String,
) -> EvoGenome raise @base.Fault {
  let path = evo_genome_path(id)
  if !entries.any(entry => entry.path == path) { @base.fail("evo_genome_not_found: " + id) }
  let text = match (store.read)(path) {
    None => { @base.fail("evo_genome_not_found: " + id); "" }
    Some(value) => value
  }
  evo_genome_from_json(@base.parse(text))
}

// ---- window entries -------------------------------------------------------

fn evo_window_entry_json(
  step : Int, at : String, input : Array[Double], emotion : Array[Double],
  impulse : Double, fired : Bool, subject : String?,
) -> Json {
  {
    "step": step, "at": at, "input": input.map(value => value.to_json()).to_json(),
    "emotion": emotion.map(value => value.to_json()).to_json(),
    "impulse": impulse, "fired": fired.to_json(),
    "subject": match subject { None => Json::null(); Some(value) => value.to_json() },
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

fn evo_segment(
  trajectory : EvoTrajectory, mean : Array[Array[Double]], start : Int, end : Int,
) -> EvoSegment {
  let length = if end > start { end - start } else { 1 }
  let mut unstable = 0
  let mut fired = 0
  let mut blowups = 0
  let mut growth = 0.0
  let mut subject_events = 0
  let mut novelty = 0.0
  let mut positive = 0
  let mut emotional_sum = 0.0
  for step = start; step < end; step = step + 1 {
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
  let responsiveness = evo_responsiveness(trajectory, start, end)
  let growth_score = if subject_events == 0 { 0.5 } else { evo_clamp(0.5 + 0.5 * growth, 0.0, 1.0) }
  let novelty_score = novelty / steps
  let energy = evo_clamp(fired.to_double() / 8.0, 0.0, 1.0)
  let blowup_score = evo_clamp(blowups.to_double() / 3.0, 0.0, 1.0)
  let positive_share = positive.to_double() / steps
  let positive_penalty = evo_clamp(2.0 * (positive_share - 0.5), 0.0, 1.0)
  let mean_emotion = emotional_sum / steps
  let mut variance = 0.0
  for step = start; step < end; step = step + 1 {
    let delta = trajectory.emotion[step][0] - mean_emotion
    variance = variance + delta * delta
  }
  let deviation = (variance / steps).sqrt()
  let flatness = evo_clamp(1.0 - deviation / 0.15, 0.0, 1.0)
  {
    stability, responsiveness, growth: growth_score, novelty: novelty_score,
    energy_cost: energy, impulse_blowups: blowup_score,
    positive_penalty, flatness_penalty: flatness,
  }
}

// Responsiveness measures recovery after a strong host stimulus. Arousal is
// emotion[1]; overshoot above 0.70 and a slow return both cost score.
fn evo_responsiveness(trajectory : EvoTrajectory, start : Int, end : Int) -> Double {
  let total_steps = trajectory.emotion.length()
  let mut stimuli = 0
  let mut total = 0.0
  for step = start; step < end; step = step + 1 {
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
    params.c_flatness * segment.flatness_penalty
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
  { emotion, fired, blowups, trust_delta, has_subject, valence, nonfinite }
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
  let changes : Array[@vault.Change] = []
  { next: { val: entries }, changes }
}

fn evo_add_new(batch : EvoBatch, path : String, content : String) -> Unit {
  batch.changes.push({ path, before: None, after: Some(content) })
  batch.next.val = upsert(batch.next.val, {
    id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false,
  })
}

fn evo_add_update(batch : EvoBatch, path : String, before : String, content : String) -> Unit {
  batch.changes.push({ path, before: Some(before), after: Some(content) })
  batch.next.val = upsert(batch.next.val, {
    id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false,
  })
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
  if batch.next.val.any(entry => entry.path == path) { return id }
  let record : Json = {
    "version": 1, "id": id, "generation": generation,
    "parents": parents.to_json(), "origin": origin,
    "weights": weights.map(value => value.to_json()).to_json(),
    "weights_sha256": weights_sha256, "created_at": at,
  }
  let content = @base.canonical(record)
  match (store.read)(path) {
    Some(existing) => if existing != content { @base.fail("evo_genome_conflict: " + id) }
    None => evo_add_new(batch, path, content)
  }
  id
}

fn evo_emit_event(batch : EvoBatch, path : String, event : Json) -> Unit {
  evo_add_new(batch, path, @base.canonical(event))
}

fn evo_fossil_count(entries : Array[@core.Entry]) -> Int {
  entries.iter().filter(entry => entry.path.has_prefix("state/evo/fossils/")).count()
}

fn evo_event_count(entries : Array[@core.Entry], prefix : String) -> Int {
  entries.iter().filter(entry => entry.path.has_prefix(prefix)).count()
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
  let locked = entries.any(entry =>
    entry.path == "state/evo/state.json" || entry.path == "state/evo/population.json")
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
  let event_path = "state/events/evo-policy-" +
    @base.hex_hash(@base.canonical(binding) + "\n" + at) + ".json"
  let event : Json = {
    "op": "evo-policy", "at": at, "enabled": enabled.to_json(),
    "params": new_params_json,
    "params_hash": @base.hex_hash(@base.canonical(new_params_json)),
  }
  let batch = evo_batch(entries)
  match (store.read)("state/evo/policy.json") {
    Some(before) => evo_add_update(batch, "state/evo/policy.json", before, content)
    None => evo_add_new(batch, "state/evo/policy.json", content)
  }
  evo_emit_event(batch, event_path, event)
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  let updated : EvoPolicy = {
    exists: true, enabled, params: new_params, params_json: new_params_json,
    updated_at: at,
  }
  evo_policy_response(updated, locked, gate is Some(_), true, false,
    @vault.fingerprint(batch.next.val))
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
  let population_text = (store.read)("state/evo/population.json")
  let state_text = (store.read)("state/evo/state.json")
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
    "guard_hits": 0, "impulses": 0, "blowups": 0,
    "created_at": at, "updated_at": at,
  }
  evo_add_new(batch, "state/evo/population.json", @base.canonical(population))
  evo_add_new(batch, "state/evo/state.json", @base.canonical(state))
  let event_path = "state/events/evo-init-" +
    @base.hex_hash(seed.to_string() + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-init", "at": at, "seed": seed, "policy_hash": policy_hash,
  })
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  {
    "generation": 0, "population": count, "genomes": created.keys().length(),
    "seed": seed, "replayed": false, "fingerprint": @vault.fingerprint(batch.next.val),
  }
}

// ---- observe --------------------------------------------------------------

fn evo_observe_op(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  evo_request_keys(request, ["step", "kind", "salience", "valence", "body",
    "subject", "at"])
  let policy = evo_load_policy(store)
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let at = evo_at_text(request)
  let step = evo_request_int(request, "step", 1, 2147483647)
  let kind = evo_text(request, "kind")
  if !["social", "task", "body", "novel"].contains(kind) { @base.fail("evo_kind_invalid") }
  let salience = evo_request_number(request, "salience", 0.0, 1.0)
  let valence = evo_request_number(request, "valence", -1.0, 1.0)
  let body = evo_body_arg(request)
  let subject = evo_subject_arg(request)
  let state_text = match (store.read)("state/evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  match (store.read)("state/evo/population.json") {
    None => @base.fail("evo_state_corrupt")
    Some(_) => ()
  }
  let state = evo_state_from_json(@base.parse(state_text))
  if state.active_genome is None { @base.fail("evo_genome_not_found") }
  if state.window.length() > policy.params.window { @base.fail("evo_state_corrupt") }
  let identity = evo_payload(kind, salience, valence, body, subject)
  let payload_sha256 = @base.hex_hash(@base.canonical(identity))
  if step == state.steps {
    let same = match state.last_observe {
      Object(_) => @base.text(@base.field(state.last_observe, "payload_sha256")) == payload_sha256
      _ => false
    }
    if !same { @base.fail("evo_observe_conflict") }
    let result = @base.field(state.last_observe, "result")
    return {
      "step": step,
      "emotion": @base.field(result, "emotion"),
      "impulse": @base.field(result, "impulse"),
      "fired": @base.field(result, "fired"),
      "action": @base.field(result, "action"),
      "threshold": @base.field(result, "threshold"),
      "window": { "have": state.window.length(), "capacity": policy.params.window },
      "replayed": true, "fingerprint": @vault.fingerprint(entries),
    }
  }
  if step != state.steps + 1 {
    @base.fail("evo_step_invalid: expected " + (state.steps + 1).to_string())
  }
  let genome_id = state.active_genome.unwrap()
  let genome = evo_load_genome(store, entries, genome_id)
  let relation = match subject { None => None; Some(name) => evo_relation_find(state.relations, name) }
  match subject {
    Some(_) => if relation is None && state.relations.length() >= 8 { @base.fail("evo_subject_limit") }
    None => ()
  }
  let relation_trust = match relation { None => 0.0; Some(value) => value.trust }
  let relation_familiarity = match relation { None => 0.0; Some(value) => value.familiarity }
  let relation_tension = match relation { None => 0.0; Some(value) => value.tension }
  let input : Array[Double] = [
    if kind == "social" { 1.0 } else { 0.0 },
    if kind == "task" { 1.0 } else { 0.0 },
    if kind == "body" { 1.0 } else { 0.0 },
    if kind == "novel" { 1.0 } else { 0.0 },
    salience, valence,
    evo_body_value(body, "cpu"), evo_body_value(body, "memory"),
    evo_body_value(body, "latency"), evo_body_value(body, "budget"),
    relation_trust, relation_familiarity, relation_tension,
    state.emotion[0], state.emotion[1], state.emotion[2],
  ]
  let result = evo_apply(genome.weights, state.emotion, state.impulse,
    state.last_fire_step, input, step)
  if result.nonfinite { @base.fail("evo_numeric_invalid:controller") }
  let mut relations = state.relations.copy()
  match subject {
    None => ()
    Some(name) => {
      let (trust, familiarity, tension) = evo_relation_delta(relation, result.relation_output, valence)
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
  window.push(evo_window_entry_json(step, at, input, result.emotion,
    result.impulse, result.fired, subject))
  while window.length() > policy.params.window {
    window = window[1:].to_owned()
  }
  let observation : Json = {
    "step": step, "payload_sha256": payload_sha256,
    "result": {
      "emotion": result.emotion.map(value => value.to_json()).to_json(),
      "impulse": result.impulse, "fired": result.fired.to_json(),
      "action": result.action.map(value => value.to_json()).to_json(),
      "threshold": result.threshold,
    },
  }
  let updated_state : EvoState = {
    ..state, steps: step, window, window_sha256: @core.evo_window_hash(window),
    emotion: result.emotion, impulse: result.impulse, body,
    relations, last_observe: observation, last_fire_step: result.last_fire_step,
    impulses: state.impulses + (if result.fired { 1 } else { 0 }),
    blowups: state.blowups + result.blowup,
  }
  let content = @base.canonical(evo_state_json(updated_state, at))
  let batch = evo_batch(entries)
  evo_add_update(batch, "state/evo/state.json", state_text, content)
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  {
    "step": step,
    "emotion": result.emotion.map(value => value.to_json()).to_json(),
    "impulse": result.impulse, "fired": result.fired.to_json(),
    "action": result.action.map(value => value.to_json()).to_json(),
    "threshold": result.threshold,
    "window": { "have": window.length(), "capacity": policy.params.window },
    "replayed": false, "fingerprint": @vault.fingerprint(batch.next.val),
  }
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
  let state_text = match (store.read)("state/evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("state/evo/population.json") {
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
  let trajectories : Array[EvoTrajectory] = []
  for row in alive {
    let genome = evo_load_genome(store, entries, row.genome)
    trajectories.push(evo_trajectory(genome.weights, state.window))
  }
  let mean = evo_mean_trajectory(trajectories, state.window.length())
  let train_end = Int::min(state.window.length(),
    (state.window.length().to_double() * 0.7).to_int())
  let split = if train_end < 1 { 1 } else { train_end }
  let updated_members : Array[EvoMember] = []
  let mut best_genome = ""
  let mut best_fitness = -2.0
  let mut worst_fitness = 2.0
  let mut total = 0.0
  for index = 0; index < alive.length(); index = index + 1 {
    let row = alive[index]
    let trajectory = trajectories[index]
    let segment = evo_segment(trajectory, mean, 0, split)
    let holdout_segment = evo_segment(trajectory, mean, split, state.window.length())
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
  evo_add_update(batch, "state/evo/population.json", population_text,
    @base.canonical(evo_population_json(updated_population, at)))
  evo_add_update(batch, "state/evo/state.json", state_text,
    @base.canonical(evo_state_json(updated_state, at)))
  let event_path = "state/events/evo-evaluate-" + @base.hex_hash(
    population.generation.to_string() + "\n" + state.window_sha256 + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-evaluate", "at": at, "generation": population.generation,
    "window_sha256": state.window_sha256, "best": best_fitness,
    "mean": mean_fitness, "worst": worst_fitness, "alive": alive.length(),
  })
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  {
    "generation": population.generation, "window_sha256": state.window_sha256,
    "alive": alive.length(), "best": { "genome": best_genome, "fitness": best_fitness },
    "mean": mean_fitness, "worst": worst_fitness, "checkpoint": checkpoint_json,
    "train_mean": evo_mean_breakdown(updated_population.members, true),
    "holdout_mean": evo_mean_breakdown(updated_population.members, false),
    "members": members.map(evo_member_json).to_json(),
    "replayed": false, "fingerprint": @vault.fingerprint(batch.next.val),
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
  let path = "state/evo/fossils/" + id + ".json"
  if batch.next.val.any(entry => entry.path == path) { return None }
  let fitness = match row.fitness { None => -1.0; Some(value) => value }
  let breakdown = match row.breakdown {
    Object(_) => row.breakdown
    _ => {
      let segment : EvoSegment = {
        stability: 0.0, responsiveness: 0.0, growth: 0.0, novelty: 0.0,
        energy_cost: 0.0, impulse_blowups: 0.0, positive_penalty: 0.0,
        flatness_penalty: 0.0,
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
    "state/events/evo-fossilize-" + id + ".json", {
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
    fossil_total: evo_fossil_count(entries) + fossil_ids.length(),
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
  let state_text = match (store.read)("state/evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("state/evo/population.json") {
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
  let (regressed, streak, rollback) = evo_regression_decision(
    checkpoint_fitness, best, policy.params, population.regression_streak)
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
      fossil_total: evo_fossil_count(entries) + fossils.length(),
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
  let event_path = "state/events/evo-evolve-" + @base.hex_hash(
    population.generation.to_string() + "\n" + state.window_sha256 + "\n" + at) + ".json"
  evo_emit_event(batch, event_path, {
    "op": "evo-evolve", "at": at, "from_generation": population.generation,
    "to_generation": next_generation, "window_sha256": state.window_sha256,
    "best": best, "mean": mean, "worst": worst, "delta": delta,
    "regressed": regressed.to_json(), "rolled_back": rolled_back.to_json(),
    "fossils": fossils.length(), "extinct": extinct,
  })
  if saturated {
    let saturation_path = "state/events/evo-saturation-" + @base.hex_hash(
      population.generation.to_string() + "\n" + EVO_SATURATION_PATIENCE.to_string() +
        "\n" + at) + ".json"
    evo_emit_event(batch, saturation_path, {
      "op": "evo-saturation", "at": at, "generation": population.generation,
      "streak": EVO_SATURATION_PATIENCE, "best": best,
    })
  }
  if regressed {
    let regression_path = "state/events/evo-regression-" + @base.hex_hash(
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
    let rollback_path = "state/events/evo-rollback-" + @base.hex_hash(
      next_generation.to_string() + "\nregression\n" + at) + ".json"
    evo_emit_event(batch, rollback_path, {
      "op": "evo-rollback", "at": at, "from_generation": population.generation,
      "to_generation": next_generation, "reason": "regression",
      "checkpoint": checkpoint.genome, "fossils": fossils.length(),
    })
    updated = { ..updated,
      rollbacks_total: population.rollbacks_total + 1 }
  }
  evo_add_update(batch, "state/evo/population.json", population_text,
    @base.canonical(evo_population_json(updated, at)))
  if rolled_back {
    let refreshed_state : EvoState = { ..state,
      active_genome: match evo_checkpoint(updated.checkpoint) {
        None => state.active_genome
        Some(value) => Some(value.genome)
      },
    }
    evo_add_update(batch, "state/evo/state.json", state_text,
      @base.canonical(evo_state_json(refreshed_state, at)))
  }
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
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
    "fingerprint": @vault.fingerprint(batch.next.val),
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
  for entry in entries {
    if !entry.path.has_prefix("state/evo/fossils/") { continue }
    let record = @base.parse(@vault.required(store, entry.path))
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
  let state_text = (store.read)("state/evo/state.json")
  let population_text = (store.read)("state/evo/population.json")
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
    let init_event_path = "state/events/evo-init-" +
      @base.hex_hash(init_seed.to_string() + "\n" + init_at) + ".json"
    if !entries.any(entry => entry.path == init_event_path) {
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
    if population.fossil_total != evo_fossil_count(entries) ||
      population.regressions_total != evo_event_count(entries, "state/events/evo-regression-") ||
      population.rollbacks_total != evo_event_count(entries, "state/events/evo-rollback-") {
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
  let state_text = match (store.read)("state/evo/state.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let population_text = match (store.read)("state/evo/population.json") {
    None => { @base.fail("evo_not_initialized"); "" }
    Some(value) => value
  }
  let state = evo_state_from_json(@base.parse(state_text))
  let population = evo_population_from_json(@base.parse(population_text))
  let last_rollback = evo_last_rollback(population.last_rollback)
  match last_rollback {
    Some(last) => if last.at == at && last.reason == "manual" {
      let ids : Array[String] = []
      for entry in entries {
        if !entry.path.has_prefix("state/evo/fossils/") { continue }
        let record = @base.parse(@vault.required(store, entry.path))
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
  evo_add_update(batch, "state/evo/population.json", population_text,
    @base.canonical(evo_population_json(rebuilt, at)))
  evo_add_update(batch, "state/evo/state.json", state_text,
    @base.canonical(evo_state_json({ ..state,
      active_genome: Some(checkpoint.genome) }, at)))
  let rollback_path = "state/events/evo-rollback-" + @base.hex_hash(
    checkpoint.generation.to_string() + "\nmanual\n" + at) + ".json"
  evo_emit_event(batch, rollback_path, {
    "op": "evo-rollback", "at": at, "from_generation": population.generation,
    "to_generation": checkpoint.generation, "reason": "manual",
    "checkpoint": checkpoint.genome, "fossils": ids.length(),
  })
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  {
    "rolled_back": true.to_json(), "reason": "manual",
    "from_generation": population.generation,
    "to_generation": checkpoint.generation, "checkpoint": checkpoint.genome,
    "fossils": ids.to_json(), "replayed": false,
    "fingerprint": @vault.fingerprint(batch.next.val),
  }
}

// ---- dispatch -------------------------------------------------------------

// ---- read-only inspection ops (续三十二) ----------------------------------
fn evo_checkpoint_op(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  evo_pause_if_pending(store, entries)
  let text = match (store.read)("state/evo/population.json") {
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
  let rows = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/evo/fossils/"))
  let keyed : Array[(String, @core.Entry)] = rows.map(entry => {
    let row = @base.parse(@vault.required(store, entry.path))
    (@base.text(@base.field(row, "id")), entry)
  })
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  let fossils : Array[Json] = []
  for pair in keyed {
    let row = @base.parse(@vault.required(store, pair.1.path))
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

pub fn evo(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  let policy = evo_load_policy(store)
  if op != "evo-policy" && !policy.enabled { @base.fail("evo_disabled") }
  match op {
    "evo-policy" => evo_policy_op(store, entries, request)
    "evo-init" => evo_init_op(store, entries, request)
    "evo-observe" => evo_observe_op(store, entries, request)
    "evo-evaluate" => evo_evaluate_op(store, entries, request)
    "evo-evolve" => evo_evolve_op(store, entries, request)
    "evo-status" => evo_status_op(store, entries, request)
    "evo-rollback" => evo_rollback_op(store, entries, request)
    "evo-checkpoint" => evo_checkpoint_op(store, entries)
    "evo-fossils" => evo_fossils_op(store, entries)
    _ => raise @base.Fault("operation_not_implemented: " + op)
  }
}