#!/usr/bin/env python3
"""Evolution subsystem end-to-end (续三十).

Proves the local fast loop, the offline slow loop, the checkpoint/regression
story and the isolation claims on the real CLI:
  evo-policy    default-off gate, closed parameter table, bootstrap, locks
  evo-init      seeded Xavier population bound to (seed, at, policy_hash)
  evo-observe   clamped affect/impulse drift, replay/conflict and the ring window
  evo-evaluate  full-window replay, train/held-out split, scenario rotation,
                checkpoint update
  evo-evolve    elites, tournaments, crossover, fossils, regression rollback
  evo-status    cross-record integrity and ledger reconciliation
  evo-rollback  manual checkpoint restore with immutable failure evidence
Plus record-validation branches, content-integrity failures, pack round trip
and the isolation/no-other-module static scan.
"""
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
ALLOWED = {
    "agent/evo.mbt",
    "agent/evo_wbtest.mbt",
    "agent/evo_sidecar.mbt",
    "agent/evo_sidecar_wbtest.mbt",
    "core/records.mbt",
    "agent/tools.mbt",
    "agent/schema.mbt",
    "agent/session.mbt",
}
PARAMS = {
    "population": 8,
    "window": 16,
    "elite_ratio": 0.25,
    "protect_ratio": 0.10,
    "tournament": 3,
    "crossover_rate": 0.65,
    "mutation_rate": 0.12,
    "mutation_max": 0.40,
    "immigrants": 1,
    "regression_delta": 0.05,
    "regression_patience": 1,
    "auto_rollback": True,
    "fossil_max_per_gen": 4,
    "history": 16,
    "w_stability": 0.30,
    "w_responsiveness": 0.20,
    "w_growth": 0.15,
    "w_novelty": 0.10,
    "c_energy": 0.10,
    "c_impulse": 0.10,
    "c_positive": 0.15,
    "c_flatness": 0.15,
    "c_holdout": 0.15,
}


def static_isolation():
    """No non-evo module may name or reach evolution state."""
    allowed_rel = set(ALLOWED)
    offenders = []
    literal_offenders = []
    for path in ROOT.rglob("*.mbt"):
        rel = path.relative_to(ROOT).as_posix()
        if "_build" in rel or ".mooncakes" in rel or rel.startswith("target/"):
            continue
        text = path.read_text(encoding="utf-8")
        if rel not in allowed_rel:
            for pattern in (r"state/evo", r"evo-", r"evo_", r"\bevo\b"):
                if re.search(pattern, text):
                    offenders.append((rel, pattern))
                    break
        # Tests may name record paths; production code may not. The record
        # layer is one-way: only the controller and the record schema own the
        # literal state/evo prefix.
        if not rel.endswith("_wbtest.mbt") and rel not in {
                "agent/evo.mbt", "agent/evo_sidecar.mbt", "core/records.mbt"}:
            if "state/evo" in text:
                literal_offenders.append(rel)
    # Exactly one session call site.
    for path in ROOT.rglob("*.mbt"):
        rel = path.relative_to(ROOT).as_posix()
        if "_build" in rel or ".mooncakes" in rel or rel.startswith("target/"):
            continue
        count = path.read_text(encoding="utf-8").count("evo(store, entries, request)")
        if rel == "agent/session.mbt":
            if count != 1:
                offenders.append((rel, "expected exactly one evo dispatch call"))
        elif count != 0:
            offenders.append((rel, "duplicate evo dispatch call"))
    # The controller may not reach other modules, models, networks or clocks.
    controller = (ROOT / "agent/evo.mbt").read_text(encoding="utf-8")
    # "thread" is deliberately absent: evo-thread-* are conversation threads,
    # not OS threads. Concurrency is still caught by spawn/sleep/platform imports.
    forbidden = ["dream", "lint_result", "topics(", "stats(", "embedding_plan",
                 "provider", "@platform", "@index", "@interop", "@office",
                 "@htdoc", "http", "socket", "spawn", "sleep", "time("]
    for token in forbidden:
        if token in controller:
            offenders.append(("agent/evo.mbt", "forbidden token " + token))
    if offenders or literal_offenders:
        print("evo isolation: no non-evo module reads evo state")
        for item in offenders:
            print("  offender:", item)
        for item in literal_offenders:
            print("  literal state/evo outside controller/schema:", item)
        return False
    print("evo isolation: only the controller/schema own evolution state; "
          "one dispatch call; no cross-module/model/network/clock reads")
    return True


def main():
    if not static_isolation():
        return 1
    if not EXE.exists():
        print("missing CLI binary:", EXE)
        return 1

    with tempfile.TemporaryDirectory(prefix="corridor-evo-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            request = dict(fields, op=op, vault=str(vault))
            run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n",
                                 text=True, capture_output=True, timeout=180)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"], response
                assert error in response["error"], (op, error, response)
                return response
            assert response["ok"], (op, response)
            return response["result"]

        def raw_error_code(op, **fields):
            request = dict(fields, op=op, vault=str(vault))
            run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n",
                                 text=True, capture_output=True, timeout=180)
            response = json.loads(run.stdout)
            assert not response["ok"], response
            return response.get("error_code", "")

        def status():
            return call("evo-status")

        def fingerprint():
            return call("fingerprints")["vault"]

        def record_paths(prefix):
            return sorted(p for p in (vault / prefix).glob("*.json"))

        def read_record(rel):
            return json.loads((vault / rel).read_text(encoding="utf-8"))

        def write_record(rel, record):
            (vault / rel).write_text(
                json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")),
                encoding="utf-8")

        def tree_bytes(directory):
            base = vault / directory
            if not base.exists():
                return {}
            return {p.relative_to(vault).as_posix(): p.read_bytes()
                    for p in sorted(base.rglob("*")) if p.is_file()}

        def strip_fingerprint(value):
            if isinstance(value, dict):
                return {k: strip_fingerprint(v) for k, v in value.items() if k != "fingerprint"}
            if isinstance(value, list):
                return [strip_fingerprint(v) for v in value]
            return value

        def observe_favorable(step, at):
            return call("evo-observe", step=step, kind="social", salience=0.4,
                        valence=1.0,
                        body={"cpu": 0.2, "memory": 0.0, "latency": 0.0, "budget": 0.0},
                        subject="同伴", at=at)

        def observe_pressure(step, at):
            return call("evo-observe", step=step, kind="body", salience=1.0,
                        valence=-1.0,
                        body={"cpu": 1.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
                        at=at)

        # ---- 1-4. default off ------------------------------------------------
        call("init", purpose="进化实验端到端")
        # A raw source makes the later wiki/raw byte comparison meaningful.
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/evolution.md").write_text("进化实验的原始材料。\n", encoding="utf-8")
        scanned = call("scan")
        order = scanned["orders"][0]
        context = call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": ["进化"], "conflicts": [],
                       "summary": "进化材料"})
        drafts = call("draft-submit", order=order,
                      context_token=context["context_token"],
                      pages=[{"id": "concepts/evolution", "kind": "concept",
                              "title": "进化实验", "sources": ["raw/evolution.md"],
                              "tags": ["进化"], "body": "进化实验的原始材料。"}])
        call("commit", order=order, pages=drafts["pages"],
             at="2026-11-12T00:00:01Z")
        call("rebuild")
        index_before = (vault / "index.mbt.md").read_bytes()
        raw_before = tree_bytes("raw")
        wiki_before = tree_bytes("wiki")
        dream_before = call("dream-plan")
        redundancy_before = call("page-redundancy", space={"id": "e2e", "dimensions": 8})
        impact_before = call("impact-audit", at="2026-11-12T00:00:00Z")
        status_before = call("status")

        disabled_fp = fingerprint()
        disabled_requests = [
            ("evo-init", {"at": "2026-11-12T00:00:00Z"}),
            ("evo-observe", {"step": 1, "kind": "task", "salience": 0.5, "valence": 0.0,
                             "body": {"cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
                             "at": "2026-11-12T00:00:00Z"}),
            ("evo-evaluate", {"at": "2026-11-12T00:00:00Z"}),
            ("evo-evolve", {"at": "2026-11-12T00:00:00Z"}),
            ("evo-status", {}),
            ("evo-rollback", {"at": "2026-11-12T00:00:00Z"}),
        ]
        for op, fields in disabled_requests:
            call(op, error="evo_disabled", **fields)
        assert not (vault / "state/evo").exists(), "disabled ops created state/evo"
        assert not (vault / "evo").exists(), "disabled ops created the sidecar"
        assert not any(p.name.startswith("evo-") for p in record_paths("evo/events")), \
            "disabled ops wrote an evo event"
        assert fingerprint() == disabled_fp, "disabled ops wrote the vault"
        assert (vault / "index.mbt.md").read_bytes() == index_before
        policy = call("evo-policy")
        assert policy["default"] is True and policy["enabled"] is False
        assert policy["locked"] is False and policy["pending_human_gate"] is False
        assert set(policy["params"].keys()) == set(PARAMS.keys()), policy["params"]
        call("evo-policy", error="evo_policy_disabled_write", params=PARAMS,
             at="2026-11-12T00:00:00Z")
        noop = call("evo-policy", enabled=False, at="2026-11-12T00:00:00Z")
        assert noop["changed"] is False and noop["replayed"] is True
        assert not (vault / "state/evo").exists(), "disabled no-op wrote state"

        # ---- 5-7. parameter table and bootstrap ----------------------------
        incomplete = dict(PARAMS)
        incomplete.pop("window")
        call("evo-policy", error="evo_policy_incomplete:window", enabled=True,
             params=incomplete, at="2026-11-12T00:00:00Z")
        unknown = dict(PARAMS)
        unknown["saturation"] = 1
        call("evo-policy", error="unknown_field", enabled=True, params=unknown,
             at="2026-11-12T00:00:00Z")
        out_of_range = dict(PARAMS)
        out_of_range["population"] = 100
        call("evo-policy", error="evo_policy_param_invalid:population", enabled=True,
             params=out_of_range, at="2026-11-12T00:00:00Z")
        inverted = dict(PARAMS)
        inverted["elite_ratio"] = 0.2
        inverted["protect_ratio"] = 0.3
        call("evo-policy", error="evo_policy_elite_invalid", enabled=True,
             params=inverted, at="2026-11-12T00:00:00Z")
        assert not (vault / "state/evo").exists(), "rejected params created state/evo"

        boot = call("evo-policy", enabled=True, params=PARAMS,
                    at="2026-11-12T00:00:10Z")
        assert boot["changed"] is True and boot["replayed"] is False
        assert boot["params"] == PARAMS, boot["params"]
        init = call("evo-init", seed=7, at="2026-11-12T00:00:11Z")
        assert init["generation"] == 0 and init["population"] == 8
        assert init["genomes"] == 8 and init["replayed"] is False
        # Same seed + same at + same policy is an exact init replay: zero writes.
        init_fp = fingerprint()
        init_replay = call("evo-init", seed=7, at="2026-11-12T00:00:11Z")
        assert init_replay["replayed"] is True and init_replay["genomes"] == 8
        assert fingerprint() == init_fp, "init replay wrote state"
        seed_genomes = {p.name: p.read_bytes()
                        for p in record_paths("evo/genomes")}
        assert len(seed_genomes) == 8, len(seed_genomes)
        call("evo-policy", error="evo_policy_locked",
             params=dict(PARAMS, window=32), at="2026-11-12T00:00:12Z")
        params_before = json.dumps(read_record("evo/policy.json")["params"],
                                   sort_keys=True, separators=(",", ":"))
        off = call("evo-policy", enabled=False, at="2026-11-12T00:00:13Z")
        assert off["changed"] is True
        on = call("evo-policy", enabled=True, at="2026-11-12T00:00:14Z")
        assert on["changed"] is True
        params_after = json.dumps(read_record("evo/policy.json")["params"],
                                  sort_keys=True, separators=(",", ":"))
        assert params_before == params_after, "toggle rewrote params"
        policy_events = record_paths("evo/events")
        policy_events = [p for p in policy_events
                         if p.name.startswith("evo-policy-")]
        assert len(policy_events) == 3, [p.name for p in policy_events]

        # ---- 8. human gate --------------------------------------------------
        current_purpose = (vault / "purpose.md").read_text(encoding="utf-8").rstrip("\n")
        suggestion = call("purpose-suggest", at="2026-11-12T00:01:00Z", key="evo-gate-1")
        paused_fp = fingerprint()
        call("evo-observe", error="evo_paused_human_gate", step=1, kind="task",
             salience=0.5, valence=0.0,
             body={"cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
             at="2026-11-12T00:01:20Z")
        assert fingerprint() == paused_fp, "paused observe changed the vault"
        # The human decision itself still lands, and the gate clears.
        call("purpose-apply", id=suggestion["id"], text=current_purpose,
             at="2026-11-12T00:01:30Z")
        # A second pending item blocks enable but never the safety switch.
        second = call("purpose-suggest", at="2026-11-12T00:02:00Z", key="evo-gate-2")
        assert call("evo-policy", enabled=False, at="2026-11-12T00:02:20Z")["changed"] is True
        paused_fp = fingerprint()
        call("evo-policy", error="evo_paused_human_gate", enabled=True,
             at="2026-11-12T00:02:10Z")
        assert fingerprint() == paused_fp, "paused enable changed the vault"
        call("purpose-cancel", id=second["id"], at="2026-11-12T00:02:30Z")
        assert call("evo-policy", enabled=True, at="2026-11-12T00:02:40Z")["changed"] is True

        # ---- 9-11. fast loop and window ------------------------------------
        call("evo-observe", error="evo_step_invalid", step=2, kind="social",
             salience=0.4, valence=1.0,
             body={"cpu": 0.2, "memory": 0.0, "latency": 0.0, "budget": 0.0},
             subject="同伴", at="2026-11-12T00:03:00Z")
        first = observe_favorable(1, "2026-11-12T00:03:01Z")
        assert first["step"] == 1 and first["replayed"] is False
        assert first["window"]["have"] == 1 and first["window"]["capacity"] == 16
        replay = observe_favorable(1, "2026-11-12T00:03:02Z")
        assert replay["replayed"] is True
        for field in ["step", "emotion", "impulse", "fired", "action", "threshold", "window"]:
            assert replay[field] == first[field], (field, replay[field], first[field])
        call("evo-observe", error="evo_observe_conflict", step=1, kind="task",
             salience=0.5, valence=-0.2,
             body={"cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
             at="2026-11-12T00:03:03Z")
        for step in range(2, 11):
            observe_favorable(step, "2026-11-12T00:04:00Z")
        call("evo-evaluate", error="evo_window_incomplete", at="2026-11-12T00:05:00Z")
        for step in range(11, 17):
            observe_favorable(step, "2026-11-12T00:04:00Z")
        evaluated = call("evo-evaluate", at="2026-11-12T00:05:00Z")
        assert evaluated["checkpoint"] is not None
        assert evaluated["alive"] == 8
        observe_favorable(17, "2026-11-12T00:06:00Z")
        call("evo-evolve", error="evo_window_changed", at="2026-11-12T00:07:00Z")
        evaluated = call("evo-evaluate", at="2026-11-12T00:07:10Z")
        assert evaluated["scenario"] == 0, evaluated["scenario"]
        best_a = evaluated["checkpoint"]["fitness"]
        replay_eval = call("evo-evaluate", at="2026-11-12T00:07:20Z")
        assert replay_eval["replayed"] is True
        assert replay_eval["checkpoint"]["fitness"] == best_a, (replay_eval, best_a)
        assert replay_eval["best"] == evaluated["best"], (replay_eval, evaluated)
        assert replay_eval["scenario"] == 0, replay_eval["scenario"]

        population_before = read_record("evo/population.json")
        ranked = sorted(population_before["members"],
                        key=lambda m: (-m["fitness"], m["genome"]))
        elite_files = {}
        for member in ranked[:2]:
            rel = "evo/genomes/" + member["genome"] + ".json"
            elite_files[rel] = (vault / rel).read_bytes()
        evolved = call("evo-evolve", at="2026-11-12T00:08:00Z")
        assert evolved["generation"] == 0 and evolved["next_generation"] == 1
        assert evolved["delta"] == 0, evolved["delta"]
        assert evolved["elite"] == 2 and evolved["protected"] == 2
        assert evolved["extinct"] == 6 and len(evolved["fossils"]) >= 1
        assert evolved["rolled_back"] is False and evolved["regressed"] is False
        for rel, content in elite_files.items():
            assert (vault / rel).read_bytes() == content, "elite genome was rewritten"
        fossil_rows = [read_record(p.relative_to(vault).as_posix())
                       for p in record_paths("evo/fossils")]
        assert any(row["reason"] == "not_selected" for row in fossil_rows), fossil_rows
        first_rng_seed = evolved["rng_seed"]
        first_fossils = evolved["fossils"]
        first_population = (vault / "evo/population.json").read_bytes()
        first_genomes = {p.name: p.read_bytes()
                         for p in record_paths("evo/genomes")}

        # ---- 12-13. non-monotonic evidence: regression and rollback ---------
        # The pressure window drops fitness below the checkpoint, but the
        # regression comparison only counts when the evaluation scenario
        # matches the checkpoint's (gen 0 scored under scenario 0), so the
        # gate carries the streak through generations 1-3 and generation 4 —
        # back under scenario 0 — is where the drift is confirmed.
        for index in range(16):
            observe_pressure(18 + index, "2026-11-12T00:09:00Z")
        pressure_eval = call("evo-evaluate", at="2026-11-12T00:10:00Z")
        assert pressure_eval["scenario"] == 1, pressure_eval["scenario"]
        best_b = pressure_eval["best"]["fitness"]
        assert best_b < best_a - 0.05, (best_a, best_b)
        regressed = call("evo-evolve", at="2026-11-12T00:11:00Z")
        assert regressed["generation"] == 1
        assert regressed["window_changed"] is True
        assert regressed["delta"] < 0, regressed["delta"]
        assert regressed["regressed"] is False, regressed
        for extra in range(3):
            gen = 2 + extra
            for index in range(16):
                observe_pressure(18 + 16 * (extra + 1) + index,
                                 "2026-11-12T00:09:30Z")
            call("evo-evaluate", at=f"2026-11-12T00:10:{10 + extra:02d}Z")
            regressed = call("evo-evolve",
                             at=f"2026-11-12T00:11:{10 + extra:02d}Z")
            assert regressed["generation"] == gen, regressed
            assert regressed["regressed"] is (gen == 4), (gen, regressed)
        assert regressed["rolled_back"] is True
        assert regressed["next_generation"] == 0, regressed["next_generation"]
        regression_fossils = [read_record(p.relative_to(vault).as_posix())
                              for p in record_paths("evo/fossils")]
        assert any(row["reason"] == "regression_rollback" for row in regression_fossils)
        events = [p.name for p in record_paths("evo/events")]
        assert any(name.startswith("evo-regression-") for name in events)
        assert any(name.startswith("evo-rollback-") for name in events)
        state_status = status()
        assert state_status["generation"] == 0
        assert state_status["regressions"] >= 1 and state_status["rollbacks"] >= 1
        assert state_status["history"][-1]["delta"] < 0
        assert state_status["fossils"] == len(record_paths("evo/fossils"))
        assert state_status["regressions"] == len(
            [p for p in record_paths("evo/events") if p.name.startswith("evo-regression-")])
        assert state_status["rollbacks"] == len(
            [p for p in record_paths("evo/events") if p.name.startswith("evo-rollback-")])

        # ---- 14. manual rollback -------------------------------------------
        call("evo-rollback", error="evo_rollback_noop", at="2026-11-12T00:12:00Z")
        rollback_eval = call("evo-evaluate", at="2026-11-12T00:12:10Z")
        assert rollback_eval["scenario"] == 0, rollback_eval["scenario"]
        call("evo-evolve", at="2026-11-12T00:12:20Z")
        call("evo-evaluate", at="2026-11-12T00:12:30Z")
        rollbacks_before = status()["rollbacks"]
        manual = call("evo-rollback", at="2026-11-12T00:13:00Z")
        assert manual["rolled_back"] is True and manual["reason"] == "manual"
        assert len(manual["fossils"]) >= 1, manual
        manual_rows = [read_record(p.relative_to(vault).as_posix())
                       for p in record_paths("evo/fossils")]
        assert any(row["reason"] == "manual_rollback" for row in manual_rows)
        assert status()["rollbacks"] == rollbacks_before + 1
        replay_manual = call("evo-rollback", at="2026-11-12T00:13:00Z")
        assert replay_manual["replayed"] is True

        # ---- 15-17. records, integrity and read-only ------------------------
        call("rebuild")
        lint = call("lint")
        record_issues = [v for v in lint["violations"] if v["predicate"] == "record_invalid"]
        assert not record_issues, record_issues
        call("verify")
        status_index_before = (vault / "index.mbt.md").read_bytes()
        status_one = status()
        status_two = status()
        assert status_one == status_two
        assert (vault / "index.mbt.md").read_bytes() == status_index_before

        def tamper(rel, mutate, expected="evo_sidecar_corrupt"):
            # Sidecar records are digest-locked: an external edit fails the
            # next evo read closed and restoring the original bytes heals it.
            # The policy file is read (and semantically validated) before the
            # digest gate, so its tamper surfaces the semantic code instead.
            path = vault / rel
            original = path.read_text(encoding="utf-8")
            record = json.loads(original)
            mutate(record)
            write_record(rel, record)
            call("evo-status", error=expected)
            path.write_text(original, encoding="utf-8")
            call("evo-status")

        def set_window_zero(record):
            record["params"]["window"] = 0

        tamper("evo/policy.json", set_window_zero, "evo_policy_corrupt")
        tamper("evo/state.json",
               lambda r: r.__setitem__("window_sha256", "0" * 64))
        tamper("evo/population.json",
               lambda r: r["members"][0].__setitem__("status", "undead"))
        genome_rel = record_paths("evo/genomes")[0].relative_to(vault).as_posix()
        tamper(genome_rel, lambda r: r.__setitem__("weights_sha256", "0" * 64))
        fossil_rel = record_paths("evo/fossils")[0].relative_to(vault).as_posix()
        tamper(fossil_rel, lambda r: r.__setitem__("reason", "unknown"))
        evaluate_event = [p for p in record_paths("evo/events")
                          if p.name.startswith("evo-evaluate-")][0]
        tamper(evaluate_event.relative_to(vault).as_posix(),
               lambda r: r.__setitem__("generation", r["generation"] + 1))
        evolve_event = [p for p in record_paths("evo/events")
                        if p.name.startswith("evo-evolve-")][0]
        tamper(evolve_event.relative_to(vault).as_posix(),
               lambda r: (r.__setitem__("from_generation", 0),
                          r.__setitem__("to_generation", 5),
                          r.__setitem__("rolled_back", True)))
        rollback_event = [p for p in record_paths("evo/events")
                          if p.name.startswith("evo-rollback-")][0]
        tamper(rollback_event.relative_to(vault).as_posix(),
               lambda r: r.__setitem__("reason", "other"))
        call("rebuild")

        # Sidecar records are digest-locked by evo/index.json: any external
        # byte edit fails closed before the semantic validators are reached,
        # and the vault-level verify stays clean because evo left the catalog.
        genome_path = record_paths("evo/genomes")[0]
        original_genome = genome_path.read_bytes()
        genome_path.write_bytes(original_genome + b" ")
        call("verify")
        call("evo-status", error="evo_sidecar_corrupt")
        genome_path.write_bytes(original_genome)
        call("evo-status")
        policy_rel = "evo/policy.json"
        original_policy = (vault / policy_rel).read_bytes()
        (vault / policy_rel).write_bytes(original_policy + b"\n")
        call("evo-status", error="evo_sidecar_corrupt")
        (vault / policy_rel).write_bytes(original_policy)
        call("evo-status")

        # ---- 18. pack/unpack and cross-module isolation --------------------
        call("rebuild")
        final_status = status()
        packed = call("pack", output="exports/evo.mcpack")
        assert packed["output"].endswith("evo.mcpack"), packed
        with tempfile.TemporaryDirectory(prefix="corridor-evo-restored-") as restored_work:
            restored = Path(restored_work)
            (restored / "imports").mkdir(exist_ok=True)
            shutil.copy(vault / "exports/evo.mcpack", restored / "imports/evo.mcpack")

            def rcall(op, error=None, **fields):
                request = dict(fields, op=op, vault=str(restored))
                run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n",
                                     text=True, capture_output=True, timeout=180)
                response = json.loads(run.stdout)
                if error:
                    assert not response["ok"], response
                    assert error in response["error"], (op, error, response)
                    return response
                assert response["ok"], (op, response)
                return response["result"]

            rcall("unpack", file="imports/evo.mcpack")
            # The sidecar is deliberately not part of the pack: a restored
            # vault carries the knowledge base, not the evolution state.
            assert not (restored / "evo").exists(), "pack carried the sidecar"
            rcall("evo-status", error="evo_disabled")
            rcall("evo-observe", step=1, kind="task", salience=0.5, valence=0.0,
                  body={"cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
                  at="2026-11-12T01:00:00Z", error="evo_disabled")

        # ---- 18a2. container-level isolation acceptance ---------------------
        # A pure-evo sequence must not move the vault at all: same fingerprint,
        # byte-identical catalog, no state/evo residue, sidecar index present.
        iso_fp = fingerprint()
        index_before_iso = (vault / "index.mbt.md").read_bytes()
        iso_step = status()["window"]["steps"] + 1
        call("evo-observe", step=iso_step, kind="task", salience=0.5, valence=0.0,
             body={"cpu": 0.0, "memory": 0.0, "latency": 0.0, "budget": 0.0},
             at="2026-11-12T02:20:00Z")
        call("evo-evaluate", at="2026-11-12T02:30:00Z")
        assert fingerprint() == iso_fp, "evo activity moved the vault fingerprint"
        assert (vault / "index.mbt.md").read_bytes() == index_before_iso, \
            "evo activity rewrote the catalog"
        assert not (vault / "state/evo").exists(), "evo state left in the vault"
        assert (vault / "evo/index.json").exists(), "sidecar index missing"

        # ---- 18b. same seed, same window = same population ------------------
        # Re-run init and the first generation in a second vault. Every genome
        # record, the fossil ids and the committed population bytes must match:
        # determinism is a property of (seed, window), not of one store.
        with tempfile.TemporaryDirectory(prefix="corridor-evo-seed-replay-") as twin_work:
            twin = Path(twin_work)

            def tcall(op, error=None, **fields):
                request = dict(fields, op=op, vault=str(twin))
                run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n",
                                     text=True, capture_output=True, timeout=180)
                response = json.loads(run.stdout)
                if error:
                    assert not response["ok"], response
                    assert error in response["error"], (op, error, response)
                    return response
                assert response["ok"], (op, response)
                return response["result"]

            def tobserve(step, at):
                return tcall("evo-observe", step=step, kind="social", salience=0.4,
                             valence=1.0,
                             body={"cpu": 0.2, "memory": 0.0, "latency": 0.0,
                                   "budget": 0.0},
                             subject="同伴", at=at)

            tcall("init", purpose="同种子重放")
            tcall("evo-policy", enabled=True, params=PARAMS,
                  at="2026-11-12T00:00:10Z")
            tinit = tcall("evo-init", seed=7, at="2026-11-12T00:00:11Z")
            assert tinit["genomes"] == 8
            twin_seed = {p.name: p.read_bytes()
                         for p in sorted((twin / "evo/genomes").glob("*.json"))}
            assert twin_seed == seed_genomes, "same seed produced different genomes"
            tobserve(1, "2026-11-12T00:03:01Z")
            for step in range(2, 11):
                tobserve(step, "2026-11-12T00:04:00Z")
            tcall("evo-evaluate", error="evo_window_incomplete",
                  at="2026-11-12T00:05:00Z")
            for step in range(11, 17):
                tobserve(step, "2026-11-12T00:04:00Z")
            tcall("evo-evaluate", at="2026-11-12T00:05:00Z")
            tobserve(17, "2026-11-12T00:06:00Z")
            tcall("evo-evolve", error="evo_window_changed",
                  at="2026-11-12T00:07:00Z")
            tcall("evo-evaluate", at="2026-11-12T00:07:10Z")
            tcall("evo-evaluate", at="2026-11-12T00:07:20Z")
            tevolved = tcall("evo-evolve", at="2026-11-12T00:08:00Z")
            assert tevolved["rng_seed"] == first_rng_seed, tevolved["rng_seed"]
            assert tevolved["fossils"] == first_fossils, tevolved["fossils"]
            assert (twin / "evo/population.json").read_bytes() == first_population, \
                "same seed/window produced a different population"
            twin_genomes = {p.name: p.read_bytes()
                            for p in sorted((twin / "evo/genomes").glob("*.json"))}
            assert twin_genomes == first_genomes, "same seed/window produced different genomes"

        assert tree_bytes("raw") == raw_before, "evo lifecycle changed raw/"
        assert tree_bytes("wiki") == wiki_before, "evo lifecycle changed wiki/"
        call("rebuild")
        dream_after = call("dream-plan")
        redundancy_after = call("page-redundancy", space={"id": "e2e", "dimensions": 8})
        impact_after = call("impact-audit", at="2026-11-12T01:00:00Z")
        assert strip_fingerprint(dream_after) == strip_fingerprint(dream_before)
        assert strip_fingerprint(redundancy_after) == strip_fingerprint(redundancy_before)
        assert strip_fingerprint(impact_after) == strip_fingerprint(impact_before)
        call("rebuild")
        status_after = call("status")
        assert strip_fingerprint(status_after) == strip_fingerprint(status_before)
        assert not any("evo" in key.lower() for key in status_after), status_after.keys()
        call("rebuild")
        enabled_status = call("status")
        call("evo-policy", enabled=False, at="2026-11-12T01:10:00Z")
        call("rebuild")
        disabled_status = call("status")
        assert strip_fingerprint(disabled_status) == strip_fingerprint(enabled_status)

        # 续三十二: read-only inspection ops and the saturation surface.
        call("evo-policy", enabled=True, at="2026-11-12T01:15:00Z")
        checkpoint = call("evo-checkpoint")
        assert checkpoint["checkpoint"] is not None, checkpoint
        assert checkpoint["history"], checkpoint
        assert checkpoint["saturations"] >= 0 and checkpoint["no_improve_streak"] >= 0
        fossils = call("evo-fossils")
        assert fossils["count"] >= 1, fossils
        for row in fossils["fossils"]:
            assert {"id", "genome", "reason", "died_generation", "fitness",
                    "weights_sha256", "at"} <= set(row), row
        before = (vault / "index.mbt.md").read_bytes()
        call("evo-checkpoint")
        call("evo-fossils")
        assert (vault / "index.mbt.md").read_bytes() == before

        tools = call("list-tools")
        assert len(tools) == 129, len(tools)
        names = {tool["name"] for tool in tools}
        for name in ["evo-policy", "evo-init", "evo-observe", "evo-evaluate",
                     "evo-evolve", "evo-status", "evo-rollback",
                     "evo-checkpoint", "evo-fossils", "dream-policy", "dream-due"]:
            assert name in names, name

        # ---- 18c. legacy vault migration ------------------------------------
        # A pre-sidecar vault carries evo records in the catalog. The first
        # enabled op pulls them forward: records move to the sidecar, the
        # vault copies and their catalog lines disappear.
        with tempfile.TemporaryDirectory(prefix="corridor-evo-legacy-") as legacy_work:
            legacy = Path(legacy_work)

            def lcall(op, error=None, **fields):
                request = dict(fields, op=op, vault=str(legacy))
                run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n",
                                     text=True, capture_output=True, timeout=180)
                response = json.loads(run.stdout)
                if error:
                    assert not response["ok"], response
                    assert error in response["error"], (op, error, response)
                    return response
                assert response["ok"], (op, response)
                return response["result"]

            lcall("init", purpose="legacy migration")
            # A valid legacy policy record: reuse the live vault's own bytes.
            legacy_policy = (vault / "evo/policy.json").read_bytes()
            (legacy / "state/evo").mkdir(parents=True)
            (legacy / "state/evo/policy.json").write_bytes(legacy_policy)
            digest = hashlib.sha256(legacy_policy).hexdigest()
            index = (legacy / "index.mbt.md").read_text()
            line = ('    entry("state/evo/policy.json", "state/evo/policy.json", '
                    '"state", "json", "' + digest + '", [], false),\n')
            anchor = index.index('entry("')
            index = index[:anchor] + line + index[anchor:]
            count = re.search(r"corridor_entries\(\)\.length\(\), (\d+)\)", index)
            assert count, "catalog count declaration not found"
            index = index.replace(count.group(0),
                                  f"corridor_entries().length(), {int(count.group(1)) + 1})")
            (legacy / "index.mbt.md").write_text(index)

            lcall("evo-status")
            assert (legacy / "evo/policy.json").exists(), "migration did not land"
            assert not (legacy / "state/evo/policy.json").exists(), \
                "legacy copy survived"
            assert "state/evo/policy.json" not in (legacy / "index.mbt.md").read_text(), \
                "catalog line survived"
            # Migrated policy keeps working: visible, enabled, unlocked (the
            # legacy vault never initialized a population).
            policy_now = lcall("evo-policy")
            assert policy_now["enabled"] is True and policy_now["locked"] is False, policy_now

    print("evo e2e: default-off gate, policy bootstrap, fast-loop replay, "
          "same-seed determinism, window evaluation, scenario rotation, "
          "elite/fossil/regression/rollback evidence, digest tamper branches, "
          "sidecar isolation, legacy migration and pack exclusions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())