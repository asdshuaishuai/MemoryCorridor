// White-box tests for the evolution face. The store is the same in-memory
// transaction fixture the other interruption tests use, so a test may inspect
// both the catalog entries and the raw files after a crash.

fn evo_test_nan() -> Double {
  let zero = 0.0
  zero / zero
}

fn evo_test_set(value : Json, key : String, replacement : Json) -> Json {
  match value {
    Object(fields) => {
      let copy = fields.copy()
      copy[key] = replacement
      Json::object(copy)
    }
    _ => value
  }
}

fn evo_test_without(value : Json, key : String) -> Json {
  match value {
    Object(fields) => {
      let copy = fields.copy()
      copy.remove(key)
      Json::object(copy)
    }
    _ => value
  }
}

fn evo_test_replace(items : Array[Json], index : Int, value : Json) -> Array[Json] {
  let copy = items.copy()
  copy[index] = value
  copy
}

fn evo_test_object_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap_or(Json::null())
    _ => Json::null()
  }
}

fn evo_test_number_field(value : Json, key : String) -> Double {
  match evo_test_object_field(value, key) {
    Number(n, ..) => n
    _ => 0.0
  }
}

fn evo_test_text_field(value : Json, key : String) -> String {
  match evo_test_object_field(value, key) {
    String(text) => text
    _ => ""
  }
}

fn evo_test_error_code(attempt : () -> Unit raise @base.Fault) -> String {
  try {
    attempt()
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
}

fn evo_test_dispatch_code(store : @vault.Storage, request : Json) -> String {
  try {
    ignore(dispatch(store, request))
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
}

fn evo_test_params() -> Json {
  let defaults = evo_defaults_json()
  let with_population = evo_test_set(defaults, "population", (8).to_json())
  let with_window = evo_test_set(with_population, "window", (16).to_json())
  let with_patience = evo_test_set(with_window, "regression_patience", (1).to_json())
  evo_test_set(with_patience, "regression_delta", (0.05).to_json())
}

fn evo_test_seed_policy(store : @vault.Storage) -> Unit raise @base.Fault {
  ignore(initialize(store, "进化实验"))
  ignore(dispatch(store, {
    "op": "evo-policy", "enabled": true.to_json(), "params": evo_test_params(),
    "at": "2026-11-12T00:00:00Z",
  }))
}

fn evo_test_seed_initialized(store : @vault.Storage) -> Unit raise @base.Fault {
  evo_test_seed_policy(store)
  ignore(dispatch(store, {
    "op": "evo-init", "seed": 7, "at": "2026-11-12T00:00:01Z",
  }))
}

fn evo_test_store() -> (@vault.Storage, Map[String, String]) raise @base.Fault {
  let (store, _, files) = crashing(1 << 20)
  evo_test_seed_initialized(store)
  (store, files)
}

fn evo_test_entry(path : String) -> @core.Entry {
  {
    id: path, path, kind: "state", format: "json", sha256: "0".repeat(64),
    sources: [], stale: false,
  }
}

fn evo_test_observe_request(
  step : Int, kind : String, salience : Double, valence : Double, cpu : Double,
  subject : String?,
) -> Json {
  {
    "op": "evo-observe", "step": step, "kind": kind, "salience": salience,
    "valence": valence,
    "body": { "cpu": cpu, "memory": 0.0, "latency": 0.0, "budget": 0.0 },
    "subject": match subject { None => Json::null(); Some(value) => value.to_json() },
    "at": "2026-11-12T00:10:00Z",
  }
}

fn evo_test_observe(
  store : @vault.Storage, step : Int, kind : String, salience : Double,
  valence : Double, cpu : Double, subject : String?,
) -> Json raise @base.Fault {
  dispatch(store, evo_test_observe_request(step, kind, salience, valence, cpu, subject))
}

fn evo_test_observe_window(store : @vault.Storage) -> Unit raise @base.Fault {
  for i in 0..<16 {
    let valence = if i % 2 == 0 { 0.30 } else { -0.20 }
    ignore(evo_test_observe(store, i + 1, "social", 0.40, valence, 0.20,
      Some("同伴")))
  }
}

fn evo_test_sorted_members(members : Array[Json]) -> Array[Json] {
  let copy = members.copy()
  copy.sort_by((a, b) => {
    let left = evo_test_number_field(a, "fitness")
    let right = evo_test_number_field(b, "fitness")
    if left != right {
      if left > right { -1 } else { 1 }
    } else {
      @base.compare(evo_test_text_field(a, "genome"), evo_test_text_field(b, "genome"))
    }
  })
  copy
}

fn evo_test_members(store : @vault.Storage) -> Array[Json] raise @base.Fault {
  let population = @base.parse(@vault.required(store, "state/evo/population.json"))
  @base.array(@base.field(population, "members"))
}

fn evo_test_status(store : @vault.Storage) -> Json raise @base.Fault {
  dispatch(store, { "op": "evo-status" })
}

fn evo_test_fossil_rows(store : @vault.Storage) -> Array[Json] raise @base.Fault {
  let entries = @vault.load(store)
  let rows : Array[Json] = []
  for entry in entries {
    if entry.path.has_prefix("state/evo/fossils/") {
      rows.push(@base.parse(@vault.required(store, entry.path)))
    }
  }
  rows
}

fn evo_test_window(count : Int, valence : Double) -> Array[Json] {
  let window : Array[Json] = []
  for i in 0..<count {
    let input = Array::make(16, 0.0)
    input[4] = 0.5
    input[5] = valence
    window.push(evo_window_entry_json(i + 1, "2026-11-12T00:00:00Z", input,
      [0.0, 0.0, 0.0], 0.0, false, None, 0.0))
  }
  window
}

// ---- record paths ---------------------------------------------------------

test "evo directory and record paths reach their own validation branch" {
  let directories = @core.state_directories()
  assert_true(directories.contains("state/evo"))
  assert_eq(directories.length(), 15)
  let code_of = (path : String) => try {
    @core.validate_record(evo_test_entry(path), "{}")
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  let records = [
    "state/evo/policy.json", "state/evo/state.json", "state/evo/population.json",
    "state/evo/genomes/" + "0".repeat(64) + ".json",
    "state/evo/fossils/" + "1".repeat(64) + ".json",
  ]
  for path in records {
    let code = code_of(path)
    assert_true(code != "evo_record_path_invalid", msg=path + " -> " + code)
    assert_true(code != "state_record_path_unsupported", msg=path + " -> " + code)
    assert_true(code != "accepted", msg=path + " accepted empty object")
  }
  let events = [
    "state/events/evo-policy-" + "0".repeat(64) + ".json",
    "state/events/evo-init-" + "0".repeat(64) + ".json",
    "state/events/evo-evaluate-" + "0".repeat(64) + ".json",
    "state/events/evo-evolve-" + "0".repeat(64) + ".json",
    "state/events/evo-regression-" + "0".repeat(64) + ".json",
    "state/events/evo-rollback-" + "0".repeat(64) + ".json",
    "state/events/evo-fossilize-" + "0".repeat(64) + ".json",
  ]
  for path in events {
    let code = code_of(path)
    assert_true(code != "state_record_path_unsupported", msg=path)
    assert_true(code != "event_operation_unsupported", msg=path)
  }
  // Anything else under state/evo/ is refused by name, not guessed.
  assert_eq(code_of("state/evo/unknown.json"), "evo_record_path_invalid")
}

// ---- rng ------------------------------------------------------------------

test "evo rng is seeded, bounded and deterministic" {
  let left = evo_rng(11, 3)
  let right = evo_rng(11, 3)
  for _ in 0..<16 {
    assert_eq(evo_rng_next(left), evo_rng_next(right))
  }
  let other = evo_rng(12, 3)
  let first = evo_rng(11, 4)
  let mut differs = false
  for _ in 0..<8 {
    if evo_rng_next(other) != evo_rng_next(first) { differs = true }
  }
  assert_true(differs)
  let unit_source = evo_rng(5, 1)
  for _ in 0..<64 {
    let unit = evo_rng_unit(unit_source)
    assert_true(unit >= 0.0 && unit < 1.0)
  }
  let gaussian_source = evo_rng(9, 2)
  for _ in 0..<32 {
    assert_true(evo_finite(evo_gaussian(gaussian_source)))
  }
}

// ---- genome identity and weights -----------------------------------------

test "evo genome id binds origin, generation, parents and weight bits" {
  let weights = evo_xavier(evo_rng(1, 0))
  let sha = @core.evo_weights_sha256(weights)
  let base = @core.evo_genome_id("seed", 0, [], sha)
  assert_eq(base, @core.evo_genome_id("seed", 0, [], sha))
  assert_true(base != @core.evo_genome_id("clone", 0, [], sha))
  assert_true(base != @core.evo_genome_id("seed", 1, [], sha))
  assert_true(base != @core.evo_genome_id("seed", 0, ["a".repeat(64)], sha))
  assert_true(base != @core.evo_genome_id("seed", 0, [], "b".repeat(64)))
  // Weight identity is the binary32 byte stream, not the JSON text.
  let single = Array::make(@core.EVO_WEIGHTS, 0.0)
  single[0] = Float::from_double(0.1).to_double()
  let binary = @core.evo_weights_sha256(single)
  let textual = @base.hex_hash(@base.canonical(single.to_json()))
  assert_true(binary != textual)
}

test "evo policy is closed, bounded and protects the elite floor" {
  let defaults = evo_defaults_json()
  @core.evo_policy_params(defaults)
  match defaults {
    Object(fields) => assert_eq(fields.length(), 23)
    _ => @base.fail("defaults must be an object")
  }
  let incomplete = evo_test_without(defaults, "window")
  assert_eq(evo_test_error_code(() => @core.evo_policy_params(incomplete)),
    "evo_policy_incomplete")
  let over = evo_test_set(defaults, "population", (1000).to_json())
  assert_eq(evo_test_error_code(() => @core.evo_policy_params(over)),
    "evo_policy_param_invalid")
  let nan = evo_test_set(defaults, "window", Json::number(evo_test_nan()))
  assert_eq(evo_test_error_code(() => @core.evo_policy_params(nan)),
    "evo_policy_param_invalid")
  let unknown = evo_test_set(defaults, "saturation", (1).to_json())
  assert_eq(evo_test_error_code(() => @core.evo_policy_params(unknown)),
    "unknown_field")
  let inverted = evo_test_set(evo_test_set(defaults, "elite_ratio", (0.2).to_json()),
    "protect_ratio", (0.3).to_json())
  assert_eq(evo_test_error_code(() => @core.evo_policy_params(inverted)),
    "evo_policy_elite_invalid")
  // The default policy remains a valid elite floor.
  let elite = evo_test_number_field(defaults, "elite_ratio")
  let protect = evo_test_number_field(defaults, "protect_ratio")
  assert_true(protect <= elite)
}

test "evo genome weights use exactly 334 binary32 values" {
  assert_eq(@core.EVO_WEIGHTS, 334)
  let valid = evo_xavier(evo_rng(3, 0))
  let parsed = @core.evo_weights_from_json(valid.to_json())
  assert_eq(parsed.length(), 334)
  // Layout: W_x (192), b_h (12), W_o (120), b_o (10).
  for index in 192..<204 {
    assert_eq(parsed[index], 0.0)
  }
  for index in 324..<334 {
    assert_eq(parsed[index], 0.0)
  }
  let too_short = valid[:333].to_owned()
  assert_eq(evo_test_error_code(() => ignore(@core.evo_weights_from_json(too_short.to_json()))),
    "evo_genome_weight_invalid")
  let too_long = valid.copy()
  too_long.push(0.0)
  assert_eq(evo_test_error_code(() => ignore(@core.evo_weights_from_json(too_long.to_json()))),
    "evo_genome_weight_invalid")
  let out_of_range = valid.copy()
  out_of_range[0] = 4.5
  assert_eq(evo_test_error_code(() => ignore(@core.evo_weights_from_json(out_of_range.to_json()))),
    "evo_genome_weight_invalid")
  let not_f32 = valid.copy()
  not_f32[0] = 0.1
  assert_eq(evo_test_error_code(() => ignore(@core.evo_weights_from_json(not_f32.to_json()))),
    "evo_genome_weight_invalid")
  let nonfinite = valid.copy()
  nonfinite[0] = evo_test_nan()
  assert_eq(evo_test_error_code(() => ignore(@core.evo_weights_from_json(nonfinite.to_json()))),
    "evo_genome_weight_invalid")
  // Round trip through canonical text must not move the binary32 digest.
  let interesting = valid.copy()
  interesting[0] = Float::from_double(0.1).to_double()
  interesting[1] = 1.0
  interesting[2] = 3.0
  interesting[3] = Float::from_double(1.0e-7).to_double()
  interesting[4] = Float::from_double(3.9999998).to_double()
  let before = @core.evo_weights_sha256(interesting)
  let record : Json = { "weights": interesting.to_json() }
  let after = @core.evo_weights_sha256(
    @core.evo_weights_from_json(@base.field(record, "weights")))
  assert_eq(before, after)
  // The bias offsets are real: a unit bias at 192 moves hidden[0], and a unit
  // bias at 324 moves output[0] even with zero hidden activations.
  let hidden_bias = Array::make(@core.EVO_WEIGHTS, 0.0)
  hidden_bias[192] = 8.0
  let (hidden, _) = evo_forward(hidden_bias, Array::make(16, 0.0))
  assert_true(hidden[0] > 0.9 && hidden[1] == 0.0)
  let output_bias = Array::make(@core.EVO_WEIGHTS, 0.0)
  output_bias[324] = 8.0
  let (_, output) = evo_forward(output_bias, Array::make(16, 0.0))
  assert_true(output[0] > 0.9 && output[1] == 0.0)
}

// ---- controller bounds ----------------------------------------------------

test "evo controller clamps emotion and impulse under any genome" {
  let weights = Array::make(@core.EVO_WEIGHTS, 4.0)
  let mut emotion = [0.5, -0.5, 0.9]
  let mut impulse = 0.7
  let mut last : Int? = None
  for step = 1; step <= 64; step = step + 1 {
    let input = Array::make(16, 1.0)
    let result = evo_apply(weights, emotion, impulse, last, input, step)
    for dimension = 0; dimension < 3; dimension = dimension + 1 {
      assert_true(result.emotion[dimension] >= -1.0 && result.emotion[dimension] <= 1.0)
      emotion = result.emotion
    }
    assert_true(result.impulse >= 0.0 && result.impulse <= 1.0)
    assert_true(result.threshold >= 0.30 && result.threshold <= 0.95)
    impulse = result.impulse
    last = result.last_fire_step
  }
}

test "evo controller rejects non-finite host signals" {
  let (store, _files) = evo_test_store()
  let before = @vault.required(store, "state/evo/state.json")
  let bad_salience = evo_test_observe_request(1, "task", evo_test_nan(), 0.0, 0.0, None)
  assert_eq(evo_test_dispatch_code(store, bad_salience), "evo_numeric_invalid")
  let infinity = {
    let zero = 0.0
    1.0 / zero
  }
  let bad_body = evo_test_observe_request(1, "task", 0.5, 0.0, 0.0, None)
  let bad_body = evo_test_set(bad_body, "body",
    evo_test_set(evo_test_object_field(bad_body, "body"), "cpu", Json::number(infinity)))
  assert_eq(evo_test_dispatch_code(store, bad_body), "evo_numeric_invalid")
  assert_eq(@vault.required(store, "state/evo/state.json"), before)
}

test "evo impulse cooldown counts only real violations" {
  let weights = Array::make(@core.EVO_WEIGHTS, 0.0)
  weights[327] = 8.0 // b_o[3]: impulse gain
  weights[333] = -8.0 // b_o[9]: low threshold
  let input = Array::make(16, 0.0)
  input[4] = 1.0
  let first = evo_apply(weights, [0.0, 0.0, 0.0], 0.9, None, input, 1)
  assert_true(first.fired)
  assert_eq(first.blowup, 0)
  let chained = evo_apply(weights, [0.0, 0.0, 0.0], 0.9, Some(1), input, 2)
  assert_eq(chained.blowup, 1)
  let spaced = evo_apply(weights, [0.0, 0.0, 0.0], 0.9, Some(1), input, 4)
  assert_eq(spaced.blowup, 0)
  // Live observation and offline replay share one controller: the same window
  // and genome produce the same impulse and blowup counts.
  let (store, _files) = evo_test_store()
  for i in 0..<16 {
    ignore(evo_test_observe(store, i + 1, "task", 0.9, -0.4, 0.8, None))
  }
  let state = @base.parse(@vault.required(store, "state/evo/state.json"))
  let window = @base.array(@base.field(state, "window"))
  let active = evo_test_text_field(state, "active_genome")
  let entries = @vault.load(store)
  let genome = evo_load_genome(store, entries, active)
  let trajectory = evo_trajectory(genome.weights, window)
  let mut fired = 0
  let mut blowups = 0
  for value in trajectory.fired { if value { fired = fired + 1 } }
  for value in trajectory.blowups { blowups = blowups + value }
  assert_eq(fired, evo_test_number_field(state, "impulses").to_int())
  assert_eq(blowups, evo_test_number_field(state, "blowups").to_int())
}

// ---- fitness --------------------------------------------------------------

test "evo fitness punishes flat, always-positive and held-out-gap behaviour" {
  let window = evo_test_window(16, 0.0)
  let zero = Array::make(@core.EVO_WEIGHTS, 0.0)
  let flat = evo_trajectory(zero, window)
  let mean = evo_mean_trajectory([flat], 16)
  let flat_segment = evo_segment(flat, mean, 0, 16)
  assert_eq(flat_segment.flatness_penalty, 1.0)
  assert_eq(flat_segment.positive_penalty, 0.0)
  // A genome whose first emotion dimension saturates positive is charged on
  // the segment where it has already reached the cap.
  let positive = Array::make(@core.EVO_WEIGHTS, 0.0)
  positive[324] = 8.0 // b_o[0]
  positive[329] = 8.0 // b_o[5]: slow emotion decay
  let trajectory = evo_trajectory(positive, window)
  let positive_mean = evo_mean_trajectory([trajectory], 16)
  let holdout_segment = evo_segment(trajectory, positive_mean, 11, 16)
  assert_eq(holdout_segment.positive_penalty, 1.0)
  // Train far above holdout must be charged, so fitness falls below train.
  let params = evo_default_params()
  let good : EvoSegment = {
    stability: 1.0, responsiveness: 1.0, growth: 1.0, novelty: 1.0,
    energy_cost: 0.0, impulse_blowups: 0.0, positive_penalty: 0.0,
    flatness_penalty: 0.0, knowledge: 0.0, has_outcome: false,
  }
  let bad : EvoSegment = {
    stability: 0.0, responsiveness: 0.0, growth: 0.0, novelty: 0.0,
    energy_cost: 1.0, impulse_blowups: 1.0, positive_penalty: 1.0,
    flatness_penalty: 1.0, knowledge: 0.0, has_outcome: false,
  }
  let (fitness, train, _holdout, penalty) = evo_fitness_from_segments(good, bad, params)
  assert_true(penalty > 0.0)
  assert_true(fitness < train)
  // Lethal is the only way to -1.0; a living genome may not hide there.
  let (store, _files) = evo_test_store()
  let population_text = @vault.required(store, "state/evo/population.json")
  let population = @base.parse(population_text)
  let members = @base.array(@base.field(population, "members"))
  let lethal_member = evo_test_set(members[0], "status", "lethal".to_json())
  let lethal_member = evo_test_set(lethal_member, "fitness", (-0.5).to_json())
  let bad_population = evo_test_set(population, "members",
    evo_test_replace(members, 0, lethal_member).to_json())
  let bad_entry = evo_test_entry("state/evo/population.json")
  assert_true(evo_test_error_code(() => {
    @core.validate_record(bad_entry, @base.canonical(bad_population))
  }) != "accepted")
  let lethal_member = evo_test_set(lethal_member, "fitness", (-1.0).to_json())
  let lethal_population = evo_test_set(population, "members",
    evo_test_replace(members, 0, lethal_member).to_json())
  @core.validate_record(bad_entry, @base.canonical(lethal_population))
  let alive_lethal = evo_test_set(lethal_member, "status", "alive".to_json())
  let alive_population = evo_test_set(population, "members",
    evo_test_replace(members, 0, alive_lethal).to_json())
  assert_true(evo_test_error_code(() => {
    @core.validate_record(bad_entry, @base.canonical(alive_population))
  }) != "accepted")
}

// ---- selection and evolution ---------------------------------------------

test "evo elite floor keeps the top two genomes unchanged" {
  let policy = evo_default_params()
  let members : Array[EvoMember] = []
  for index in 0..<8 {
    members.push({
      genome: index.to_string().repeat(64),
      fitness: Some((8 - index).to_double()),
      breakdown: Json::null(), age: 0, evaluated_generation: Some(0),
      status: "alive",
    })
  }
  let ranked = members.copy()
  ranked.sort_by((a, b) => {
    let left = match a.fitness { None => -2.0; Some(value) => value }
    let right = match b.fitness { None => -2.0; Some(value) => value }
    if left != right { if left > right { -1 } else { 1 } } else { @base.compare(a.genome, b.genome) }
  })
  let (elites, protect, _) = evo_plan_elites(ranked, policy, ranked[7].genome)
  assert_eq(elites.length(), 3)
  assert_eq(protect, 2)
  assert_eq(elites[0].genome, ranked[0].genome)
  assert_eq(elites[1].genome, ranked[1].genome)
  assert_eq(elites[2].genome, ranked[7].genome)
  // A real evolve leaves the elite genome files byte-identical.
  let (store, files) = evo_test_store()
  evo_test_observe_window(store)
  ignore(dispatch(store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  let before = evo_test_sorted_members(evo_test_members(store))
  let top_paths = [
    "state/evo/genomes/" + evo_test_text_field(before[0], "genome") + ".json",
    "state/evo/genomes/" + evo_test_text_field(before[1], "genome") + ".json",
  ]
  let top_bytes = [files[top_paths[0]], files[top_paths[1]]]
  let evolved = dispatch(store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" })
  assert_eq(@base.field(evolved, "elite"), (2).to_json())
  assert_eq(@base.field(evolved, "protected"), (2).to_json())
  assert_eq(files[top_paths[0]], top_bytes[0])
  assert_eq(files[top_paths[1]], top_bytes[1])
}

test "evo protected elites are never mutated" {
  let policy = evo_default_params()
  let members : Array[EvoMember] = []
  for index in 0..<8 {
    members.push({
      genome: (index + 10).to_string().repeat(64),
      fitness: Some((8 - index).to_double()),
      breakdown: Json::null(), age: 0, evaluated_generation: Some(0),
      status: "alive",
    })
  }
  let ranked = members.copy()
  ranked.sort_by((a, b) => {
    let left = match a.fitness { None => -2.0; Some(value) => value }
    let right = match b.fitness { None => -2.0; Some(value) => value }
    if left != right { if left > right { -1 } else { 1 } } else { @base.compare(a.genome, b.genome) }
  })
  let (elites, protect, _) = evo_plan_elites(ranked, policy, ranked[0].genome)
  let pool = ranked[protect:].to_owned()
  assert_eq(pool.length(), 6)
  for index in 0..<Int::min(protect, elites.length()) {
    assert_true(!pool.any(row => row.genome == elites[index].genome))
  }
  // A non-protected elite is eligible as a parent and mutable.
  let candidate = pool[0]
  let weights = evo_xavier(evo_rng(2, 0))
  let mutated = evo_mutate_weights(evo_rng(2, 1), weights, 1.0, 0.40)
  assert_true(mutated != weights)
  assert_true(candidate.status == "alive")
}

test "evo tournament selection keeps the fittest of three draws" {
  let policy = evo_default_params()
  let pool : Array[EvoMember] = []
  for index in 0..<8 {
    pool.push({
      genome: (20 + index).to_string().repeat(64),
      fitness: Some(index.to_double()),
      breakdown: Json::null(), age: 0, evaluated_generation: Some(0),
      status: "alive",
    })
  }
  for seed in 41..<57 {
    let winner_rng = evo_rng(seed, 1)
    let draw_rng = evo_rng(seed, 1)
    let winner = evo_tournament(winner_rng, pool, policy.tournament)
    let mut expected = pool[0]
    for _ in 0..<policy.tournament {
      let index = (evo_rng_next(draw_rng) % pool.length().reinterpret_as_uint()).reinterpret_as_int()
      let candidate = pool[index]
      if evo_better(candidate, expected) { expected = candidate }
    }
    assert_eq(winner.genome, expected.genome)
  }
  // A tie is resolved by the smaller genome id.
  let tie_left : EvoMember = {
    genome: "f".repeat(64), fitness: Some(0.5), breakdown: Json::null(),
    age: 0, evaluated_generation: Some(0), status: "alive",
  }
  let tie_right : EvoMember = {
    genome: "0".repeat(64), fitness: Some(0.5), breakdown: Json::null(),
    age: 0, evaluated_generation: Some(0), status: "alive",
  }
  assert_true(evo_better(tie_right, tie_left))
}

test "evo mutation amplitude rises with rank" {
  let policy = evo_default_params()
  let best = evo_amplitude(policy, 0.0)
  let worst = evo_amplitude(policy, 1.0)
  assert_true((best - 0.10).abs() < 1.0e-12)
  assert_true((worst - policy.mutation_max).abs() < 1.0e-12)
  let middle = evo_amplitude(policy, 0.5)
  assert_true(middle > best && middle < worst)
  // The Gaussian sampler has unit standard deviation, so delta = g*amp/3 has
  // standard deviation amp/3.
  let rng = evo_rng(77, 2)
  let mut sum = 0.0
  let mut squares = 0.0
  for _ in 0..<2000 {
    let sample = evo_gaussian(rng)
    sum = sum + sample
    squares = squares + sample * sample
  }
  let mean = sum / 2000.0
  let variance = squares / 2000.0 - mean * mean
  let deviation = variance.sqrt()
  assert_true((deviation - 1.0).abs() < 0.20)
}

fn evo_test_store_with_rate(rate : Double) -> (@vault.Storage, Map[String, String]) raise @base.Fault {
  let (store, _, files) = crashing(1 << 20)
  ignore(initialize(store, "进化实验"))
  let params = evo_test_set(evo_test_params(), "crossover_rate", rate.to_json())
  ignore(dispatch(store, { "op": "evo-policy", "enabled": true.to_json(),
    "params": params, "at": "2026-11-12T00:00:00Z" }))
  ignore(dispatch(store, { "op": "evo-init", "seed": 7,
    "at": "2026-11-12T00:00:01Z" }))
  (store, files)
}

test "evo crossover uses two independent tournaments" {
  let (store, files) = evo_test_store_with_rate(1.0)
  evo_test_observe_window(store)
  ignore(dispatch(store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  let previous = evo_test_members(store)
  let previous_ids : Map[String, Bool] = Map([])
  for row in previous { previous_ids[evo_test_text_field(row, "genome")] = true }
  ignore(dispatch(store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" }))
  let after = evo_test_members(store)
  let mut crossovers = 0
  let mut immigrants = 0
  for row in after {
    let id = evo_test_text_field(row, "genome")
    if previous_ids.contains(id) { continue }
    let record = @base.parse(@vault.required(store,
      "state/evo/genomes/" + id + ".json"))
    match @base.field(record, "origin") {
      String("crossover") => {
        crossovers = crossovers + 1
        let parents = @base.strings(@base.field(record, "parents"))
        assert_eq(parents.length(), 2)
        for parent in parents { assert_true(previous_ids.contains(parent)) }
      }
      String("immigrant") => immigrants = immigrants + 1
      _ => @base.fail("unexpected non-crossover offspring")
    }
  }
  assert_true(crossovers > 0)
  assert_eq(immigrants, 1)
  // With crossover disabled every offspring is a one-parent clone.
  let (clone_store, _clone_files) = evo_test_store_with_rate(0.0)
  evo_test_observe_window(clone_store)
  ignore(dispatch(clone_store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  let clone_previous = evo_test_members(clone_store)
  let clone_ids : Map[String, Bool] = Map([])
  for row in clone_previous { clone_ids[evo_test_text_field(row, "genome")] = true }
  ignore(dispatch(clone_store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" }))
  let mut clones = 0
  for row in evo_test_members(clone_store) {
    let id = evo_test_text_field(row, "genome")
    if clone_ids.contains(id) { continue }
    let record = @base.parse(@vault.required(clone_store,
      "state/evo/genomes/" + id + ".json"))
    match @base.field(record, "origin") {
      String("clone") => {
        clones = clones + 1
        assert_eq(@base.strings(@base.field(record, "parents")).length(), 1)
      }
      String("immigrant") => ()
      _ => @base.fail("unexpected crossover with rate zero")
    }
  }
  assert_true(clones > 0)
  // The same seed and inputs produce the same population ledger.
  let (replay_store, _replay_files) = evo_test_store_with_rate(1.0)
  evo_test_observe_window(replay_store)
  ignore(dispatch(replay_store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  ignore(dispatch(replay_store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" }))
  assert_eq(@vault.required(store, "state/evo/population.json"),
    @vault.required(replay_store, "state/evo/population.json"))
  ignore(files)
}

test "evo regression detection needs the checkpoint gap and patience" {
  let policy = evo_default_params()
  let (regressed, streak, rollback) = evo_regression_decision(0.80, 0.78, policy, 0)
  assert_false(regressed)
  assert_eq(streak, 0)
  assert_false(rollback)
  let impatient : EvoParams = { ..policy, regression_patience: 1 }
  let (regressed, streak, rollback) = evo_regression_decision(0.80, 0.70, impatient, 0)
  assert_true(regressed)
  assert_eq(streak, 1)
  assert_true(rollback)
  // Use an explicit three-generation patience.
  let patient : EvoParams = { ..policy, regression_patience: 3 }
  let (regressed, streak, rollback) = evo_regression_decision(0.80, 0.70, patient, 0)
  assert_true(regressed && streak == 1 && !rollback)
  let (_, streak, rollback) = evo_regression_decision(0.80, 0.70, patient, streak)
  assert_true(streak == 2 && !rollback)
  let (_, streak, rollback) = evo_regression_decision(0.80, 0.70, patient, streak)
  assert_true(streak == 3 && rollback)
  let (regressed, streak, rollback) = evo_regression_decision(0.80, 0.79, patient, 3)
  assert_true(!regressed && streak == 0 && !rollback)
  // The first generation's delta is defined as exactly zero.
  @core.validate_record(evo_test_entry("state/evo/population.json"),
    @base.canonical({
      "version": 1, "generation": 0,
      "init": { "seed": 1, "at": "2026-11-12T00:00:00Z", "policy_hash": "0".repeat(64) },
      "members": [{
        "genome": "1".repeat(64), "fitness": Json::null(),
        "breakdown": Json::null(), "age": 0,
        "evaluated_generation": Json::null(), "status": "alive",
      }],
      "checkpoint": Json::null(),
      "history": [{
        "generation": 0, "window_sha256": "2".repeat(64),
        "best": 0.0, "mean": 0.0, "worst": 0.0, "delta": 0.0,
        "regressed": false, "rolled_back": false,
      }],
      "regression_streak": 0, "no_improve_streak": 0, "saturations_total": 0,
      "extinct_total": 0, "fossil_total": 0,
      "regressions_total": 0, "rollbacks_total": 0,
      "last_eval": Json::null(), "last_evolve": Json::null(),
      "last_rollback": Json::null(), "updated_at": "2026-11-12T00:00:00Z",
    }))
}

test "evo fossils record extinction with a reason" {
  let (store, files) = evo_test_store()
  evo_test_observe_window(store)
  ignore(dispatch(store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  let evolved = dispatch(store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" })
  let ids = @base.strings(@base.field(evolved, "fossils"))
  assert_true(ids.length() >= 1)
  let rows = evo_test_fossil_rows(store)
  let mut saw_not_selected = false
  let reasons : Map[String, Bool] = Map([])
  for row in rows {
    let reason = evo_test_text_field(row, "reason")
    reasons[reason] = true
    if reason == "not_selected" { saw_not_selected = true }
  }
  assert_true(saw_not_selected)
  // The fossil id binds genome, reason and death generation; a replay of the
  // same triple must not add a second file.
  let entries = @vault.load(store)
  let population = @base.parse(@vault.required(store, "state/evo/population.json"))
  let members = @base.array(@base.field(population, "members"))
  let first = evo_member_from_json(members[0])
  let batch = evo_batch(entries)
  let first_ids = evo_fossilize_members(store, entries, batch,
    [first], 8, "regression_rollback", 1, "3".repeat(64), "2026-11-12T03:00:00Z")
  assert_eq(first_ids.length(), 1)
  let again = evo_fossilize_members(store, entries, batch,
    [first], 8, "regression_rollback", 1, "3".repeat(64), "2026-11-12T03:00:00Z")
  assert_eq(again.length(), 0)
  @vault.commit(store, @vault.fingerprint(entries), batch.next.val, batch.changes)
  let lethal : EvoMember = { ..first, fitness: Some(-1.0), status: "lethal" }
  let manual : EvoMember = { ..first, fitness: Some(0.2), status: "alive" }
  let second_entries = @vault.load(store)
  let second_batch = evo_batch(second_entries)
  let lethal_ids = evo_fossilize_members(store, second_entries, second_batch,
    [lethal], 8, "lethal", 1, "3".repeat(64), "2026-11-12T03:10:00Z")
  let manual_ids = evo_fossilize_members(store, second_entries, second_batch,
    [manual], 8, "manual_rollback", 1, "3".repeat(64), "2026-11-12T03:20:00Z")
  assert_eq(lethal_ids.length(), 1)
  assert_eq(manual_ids.length(), 1)
  @vault.commit(store, @vault.fingerprint(second_entries),
    second_batch.next.val, second_batch.changes)
  // The per-generation fossil cap is applied, and all four reasons have rows.
  let third_entries = @vault.load(store)
  let third_batch = evo_batch(third_entries)
  let capped : Array[EvoMember] = []
  for index in 0..<4 {
    capped.push({ ..first, genome: evo_test_text_field(members[index], "genome") })
  }
  let capped_ids = evo_fossilize_members(store, third_entries, third_batch,
    capped, 2, "not_selected", 2, "3".repeat(64), "2026-11-12T03:30:00Z")
  assert_eq(capped_ids.length(), 2)
  @vault.commit(store, @vault.fingerprint(third_entries),
    third_batch.next.val, third_batch.changes)
  let reason_rows = evo_test_fossil_rows(store)
  for reason in ["not_selected", "lethal", "regression_rollback", "manual_rollback"] {
    assert_true(reason_rows.any(row => evo_test_text_field(row, "reason") == reason),
      msg=reason)
  }
  assert_eq(@vault.load(store).filter(entry =>
    entry.path.has_prefix("state/evo/fossils/")).length(), reason_rows.length())
  ignore(files)
}

test "evo counters match the ledger" {
  let (store, _files) = evo_test_store()
  evo_test_observe_window(store)
  ignore(dispatch(store, { "op": "evo-evaluate", "at": "2026-11-12T01:00:00Z" }))
  ignore(dispatch(store, { "op": "evo-evolve", "at": "2026-11-12T02:00:00Z" }))
  for i in 0..<16 {
    ignore(evo_test_observe(store, 17 + i, "body", 0.9, -0.5, 0.9, None))
  }
  ignore(dispatch(store, { "op": "evo-evaluate", "at": "2026-11-12T03:00:00Z" }))
  ignore(dispatch(store, { "op": "evo-rollback", "at": "2026-11-12T04:00:00Z" }))
  let entries = @vault.load(store)
  let status = evo_test_status(store)
  let fossil_files = entries.filter(entry => entry.path.has_prefix("state/evo/fossils/")).length()
  let regression_events = entries.filter(entry =>
    entry.path.has_prefix("state/events/evo-regression-")).length()
  let rollback_events = entries.filter(entry =>
    entry.path.has_prefix("state/events/evo-rollback-")).length()
  assert_eq(evo_test_number_field(status, "fossils").to_int(), fossil_files)
  assert_eq(evo_test_number_field(status, "regressions").to_int(), regression_events)
  assert_eq(evo_test_number_field(status, "rollbacks").to_int(), rollback_events)
}

test "evo population exhaustion is terminal" {
  let two : Array[EvoMember] = [
    { genome: "a".repeat(64), fitness: Some(0.1), breakdown: Json::null(),
      age: 0, evaluated_generation: Some(0), status: "alive" },
    { genome: "b".repeat(64), fitness: Some(0.0), breakdown: Json::null(),
      age: 0, evaluated_generation: Some(0), status: "alive" },
  ]
  assert_true(evo_population_exhausted(two))
  let three : Array[EvoMember] = two.copy()
  three.push({ genome: "c".repeat(64), fitness: Some(-0.1), breakdown: Json::null(),
    age: 0, evaluated_generation: Some(0), status: "alive" })
  assert_false(evo_population_exhausted(three))
  let all_lethal : Array[EvoMember] = three.copy()
  let flagged : Array[EvoMember] = []
  for row in all_lethal { flagged.push({ ..row, fitness: Some(-1.0), status: "lethal" }) }
  let population : EvoPopulation = {
    generation: 0,
    init: { "seed": 1, "at": "2026-11-12T00:00:00Z", "policy_hash": "0".repeat(64) },
    members: flagged, checkpoint: Json::null(), history: [],
    regression_streak: 0, no_improve_streak: 0, saturations_total: 0,
    extinct_total: 0, fossil_total: 0,
    regressions_total: 0, rollbacks_total: 0, last_eval: Json::null(),
    last_evolve: Json::null(), last_rollback: Json::null(),
  }
  assert_true(evo_alive_members(population).is_empty())
  // A fresh population has no checkpoint, so rollback is unavailable rather
  // than silently resurrecting a winner.
  let (store, _files) = evo_test_store()
  assert_eq(evo_test_dispatch_code(store,
    { "op": "evo-rollback", "at": "2026-11-12T05:00:00Z" }),
    "evo_rollback_unavailable")
}

// ---- tools / schema -------------------------------------------------------

test "evo tools declare the strict schema" {
  for name in ["evo-policy", "evo-init", "evo-observe", "evo-evaluate",
    "evo-evolve", "evo-status", "evo-rollback"] {
    ignore(tool(name))
  }
  let observe = input_schema(tool("evo-observe"))
  let properties = @base.field(observe, "properties")
  assert_eq(evo_test_text_field(@base.field(properties, "step"), "type"), "integer")
  assert_eq(evo_test_text_field(@base.field(properties, "salience"), "type"), "number")
  assert_eq(evo_test_text_field(@base.field(properties, "valence"), "type"), "number")
  assert_eq(evo_test_text_field(@base.field(properties, "body"), "type"), "object")
  assert_eq(evo_test_text_field(@base.field(properties, "kind"), "type"), "string")
  let required = @base.strings(@base.field(observe, "required"))
  for field in ["step", "kind", "salience", "valence", "body", "at"] {
    assert_true(required.contains(field), msg=field)
  }
  assert_false(required.contains("subject"))
  let policy = input_schema(tool("evo-policy"))
  let policy_properties = @base.field(policy, "properties")
  assert_eq(evo_test_text_field(@base.field(policy_properties, "enabled"), "type"), "boolean")
  assert_eq(evo_test_text_field(@base.field(policy_properties, "params"), "type"), "object")
  assert_true(@base.strings(@base.field(policy, "required")).is_empty())
  let init = input_schema(tool("evo-init"))
  let init_required = @base.strings(@base.field(init, "required"))
  assert_true(init_required.contains("at"))
  assert_false(init_required.contains("seed"))
  for name in ["evo-evaluate", "evo-evolve", "evo-rollback"] {
    let required = @base.strings(@base.field(input_schema(tool(name)), "required"))
    assert_eq(required, ["at"])
  }
  assert_true(@base.strings(@base.field(input_schema(tool("evo-status")), "required")).is_empty())
}

// ---- gating ---------------------------------------------------------------

test "evo disabled gate answers every op before touching state" {
  let (base, _, files) = crashing(1 << 20)
  ignore(initialize(base, "进化实验"))
  let reads : Map[String, Int] = Map([])
  let writes : Map[String, Int] = Map([])
  let store : @vault.Storage = {
    ..base,
    read: path => {
      reads[path] = reads.get(path).unwrap_or(0) + 1
      (base.read)(path)
    },
    write: (path, text) => {
      writes[path] = writes.get(path).unwrap_or(0) + 1
      (base.write)(path, text)
    },
  }
  let entries = @vault.load(base)
  let requests : Array[Json] = [
    { "op": "evo-init", "at": "2026-11-12T00:00:00Z" },
    { "op": "evo-observe", "step": 1, "kind": "task", "salience": 0.5,
      "valence": 0.0, "body": { "cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0 },
      "at": "2026-11-12T00:00:00Z" },
    { "op": "evo-evaluate", "at": "2026-11-12T00:00:00Z" },
    { "op": "evo-evolve", "at": "2026-11-12T00:00:00Z" },
    { "op": "evo-status" },
    { "op": "evo-rollback", "at": "2026-11-12T00:00:00Z" },
  ]
  for req in requests {
    let code = try {
      ignore(evo(store, entries, req))
      "accepted"
    } catch {
      @base.Fault(message) => @base.fault_code(message)
    }
    assert_eq(code, "evo_disabled")
  }
  for (path, count) in reads {
    if path != "state/evo/policy.json" {
      assert_eq(count, 0, msg="read " + path)
    }
  }
  assert_eq(writes.keys().length(), 0)
  // A pending journal is the dispatch layer's concern, not the disabled gate's:
  // direct evo leaves it alone, dispatch recovers it first.
  let index = @vault.required(store, "index.mbt.md")
  files["state/transactions/pending.json"] = @base.canonical({
    "version": 1, "changes": [], "old_index": index, "new_index": index,
  })
  let direct = try {
    ignore(evo(store, entries, { "op": "evo-status" }))
    "accepted"
  } catch {
    @base.Fault(message) => @base.fault_code(message)
  }
  assert_eq(direct, "evo_disabled")
  assert_true(files.contains("state/transactions/pending.json"))
  let code = evo_test_dispatch_code(store, { "op": "evo-status" })
  assert_eq(code, "evo_disabled")
  assert_false(files.contains("state/transactions/pending.json"))
}

test "evo human gate pauses automatic writes" {
  let (store, _, _files) = crashing(1 << 20)
  ignore(initialize(store, "进化实验"))
  ignore(dispatch(store, { "op": "evo-policy", "enabled": true.to_json(),
    "params": evo_test_params(), "at": "2026-11-12T00:00:00Z" }))
  let suggestion = dispatch(store, { "op": "purpose-suggest",
    "at": "2026-11-12T00:10:00Z", "key": "evo-gate" })
  let suggestion_id = @base.text(@base.field(suggestion, "id"))
  let before = @vault.fingerprint(@vault.load(store))
  let paused : Array[Json] = [
    { "op": "evo-init", "seed": 7, "at": "2026-11-12T00:20:00Z" },
    evo_test_observe_request(1, "task", 0.5, 0.0, 0.0, None),
    { "op": "evo-evaluate", "at": "2026-11-12T00:20:00Z" },
    { "op": "evo-evolve", "at": "2026-11-12T00:20:00Z" },
    { "op": "evo-rollback", "at": "2026-11-12T00:20:00Z" },
  ]
  for request in paused {
    assert_eq(evo_test_dispatch_code(store, request), "evo_paused_human_gate")
  }
  // A params write is also paused; the value would actually change.
  assert_eq(evo_test_dispatch_code(store, { "op": "evo-policy",
    "enabled": true.to_json(),
    "params": evo_test_set(evo_test_params(), "window", (32).to_json()),
    "at": "2026-11-12T00:20:00Z" }), "evo_paused_human_gate")
  assert_eq(@vault.fingerprint(@vault.load(store)), before)
  // The safety switch is exempt even while the gate is pending.
  let disabled = dispatch(store, { "op": "evo-policy", "enabled": false.to_json(),
    "at": "2026-11-12T00:30:00Z" })
  assert_eq(@base.boolean(@base.field(disabled, "changed")), true)
  assert_eq(evo_test_dispatch_code(store, { "op": "evo-policy",
    "enabled": true.to_json(), "at": "2026-11-12T00:40:00Z" }),
    "evo_paused_human_gate")
  // Cancelling the human-gate item restores automatic writes.
  ignore(dispatch(store, { "op": "purpose-cancel", "id": suggestion_id,
    "at": "2026-11-12T00:50:00Z" }))
  let enabled = dispatch(store, { "op": "evo-policy", "enabled": true.to_json(),
    "at": "2026-11-12T01:00:00Z" })
  assert_eq(@base.boolean(@base.field(enabled, "changed")), true)
}

test "evo policy tamper fails closed" {
  let (store, files) = evo_test_store()
  let path = "state/evo/policy.json"
  let record = @base.parse(@vault.required(store, path))
  let params = @base.field(record, "params")
  let cases = [
    evo_test_set(record, "params", evo_test_set(params, "window", (0).to_json())),
    evo_test_set(record, "params", evo_test_set(params, "population", (1000000000).to_json())),
  ]
  let entries = @vault.load(store)
  for broken in cases {
    files[path] = @base.canonical(broken)
    let writes : Map[String, Int] = Map([])
    let counting : @vault.Storage = {
      ..store,
      write: (path, text) => {
        writes[path] = writes.get(path).unwrap_or(0) + 1
        (store.write)(path, text)
      },
    }
    let request = evo_test_observe_request(1, "task", 0.5, 0.0, 0.0, None)
    let code = try {
      ignore(evo(counting, entries, request))
      "accepted"
    } catch {
      @base.Fault(message) => @base.fault_code(message)
    }
    assert_eq(code, "evo_policy_corrupt")
    assert_eq(writes.keys().length(), 0)
  }
}

// ---- interruption recovery -------------------------------------------------

test "evo init recovers from a crash at any publish point" {
  let store = each_crash_point(evo_test_seed_policy, {
    "op": "evo-init", "seed": 7, "at": "2026-11-12T00:00:01Z",
  })
  let entries = @vault.load(store)
  @vault.verify(store, entries)
  assert_true(entries.any(entry => entry.path == "state/evo/population.json"))
  assert_true(entries.any(entry => entry.path == "state/evo/state.json"))
  let population = @base.parse(@vault.required(store, "state/evo/population.json"))
  assert_eq(evo_test_number_field(population, "generation").to_int(), 0)
  assert_eq(@base.array(@base.field(population, "members")).length(), 8)
  let replay = dispatch(store, {
    "op": "evo-init", "seed": 7, "at": "2026-11-12T00:00:01Z",
  })
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
  assert_eq(evo_test_dispatch_code(store, {
    "op": "evo-init", "seed": 8, "at": "2026-11-12T00:00:01Z",
  }), "evo_already_initialized")
}

test "evo observe recovers from a crash at any publish point" {
  let request = evo_test_observe_request(1, "task", 0.5, 0.1, 0.2, Some("同伴"))
  let store = each_crash_point(evo_test_seed_initialized, request)
  let state = @base.parse(@vault.required(store, "state/evo/state.json"))
  assert_eq(evo_test_number_field(state, "steps").to_int(), 1)
  assert_eq(@base.array(@base.field(state, "window")).length(), 1)
  let replay = dispatch(store, request)
  assert_eq(@base.boolean(@base.field(replay, "replayed")), true)
}
test "evo saturation re-arms after a patience of non-improving generations" {
  match evo_no_improve_step(0.2, 5, 0) {
    (streak, saturated) => { assert_eq(streak, 0); assert_false(saturated) }
  }
  match evo_no_improve_step(0.0, 5, 0) {
    (streak, saturated) => { assert_eq(streak, 1); assert_false(saturated) }
  }
  match evo_no_improve_step(-0.3, 5, 1) {
    (streak, saturated) => { assert_eq(streak, 2); assert_false(saturated) }
  }
  match evo_no_improve_step(-0.3, 5, 2) {
    (streak, saturated) => { assert_eq(streak, 0); assert_true(saturated) }
  }
  // The first generation has no previous best to improve on; it never saturates.
  match evo_no_improve_step(0.0, 0, 2) {
    (streak, saturated) => { assert_eq(streak, 0); assert_false(saturated) }
  }
}

test "evo proactive reason follows impulse, valence and its own history" {
  assert_eq(evo_proactive_reason(0.55, 0.0, false), "impulse")
  assert_eq(evo_proactive_reason(0.54, 0.70, false), "valence_high")
  assert_eq(evo_proactive_reason(0.0, -0.50, false), "valence_low")
  assert_eq(evo_proactive_reason(0.0, 0.0, false), "")
  assert_eq(evo_proactive_reason(0.0, 0.0, true), "impulse")
}

test "evo proactive gate needs no pending, cooldown and a reason" {
  assert_true(evo_proactive_ready(0, true, "valence_high"))
  assert_false(evo_proactive_ready(1, true, "valence_high"))
  assert_false(evo_proactive_ready(0, false, "valence_high"))
  assert_false(evo_proactive_ready(0, true, ""))
}

test "evo expression maps affect to labels, posture and face tokens" {
  assert_eq(evo_emotion_label(0.6, 0.6), "excited")
  assert_eq(evo_emotion_label(0.3, 0.1), "content")
  assert_eq(evo_emotion_label(-0.6, 0.7), "distressed")
  assert_eq(evo_emotion_label(-0.3, 0.1), "low")
  assert_eq(evo_emotion_label(0.0, 0.7), "alert")
  assert_eq(evo_emotion_label(0.0, 0.1), "calm")
  assert_eq(evo_expression_posture(true, 0.0, 0.0, 0.0), "speak")
  assert_eq(evo_expression_posture(false, 0.7, 0.0, 0.0), "lean_in")
  assert_eq(evo_expression_posture(false, 0.1, 0.5, 0.0), "think")
  assert_eq(evo_expression_posture(false, 0.1, 0.0, -0.5), "still")
  assert_eq(evo_expression_posture(false, 0.1, 0.0, 0.0), "idle")
  assert_eq(evo_expression_gesture("speak"), "open_palm")
  assert_eq(evo_expression_face("calm"), "neutral")
  assert_eq(evo_expression_face("excited"), "bright")
}

test "evo knowledge alignment rewards matching valence and ignores absent outcomes" {
  let (perfect, has_perfect) = evo_knowledge_alignment([0.5, -0.5], [0.5, -0.5])
  assert_true(has_perfect)
  assert_eq(perfect, 1.0)
  let (mixed, has_mixed) = evo_knowledge_alignment([0.5, 0.5], [-0.5, 0.5])
  assert_true(has_mixed)
  assert_true(mixed < 1.0)
  let (none, has_none) = evo_knowledge_alignment([0.5], [0.0])
  assert_false(has_none)
  assert_eq(none, 0.0)
}
