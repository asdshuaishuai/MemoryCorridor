#!/usr/bin/env python3
"""Knowledge-outcome fitness end-to-end (续四十一).

The affect layer should evolve toward memory usefulness, not only its own mood.
This test feeds a window with host knowledge outcomes and proves `evo-evaluate`
includes a per-member alignment term:
  - outcomes ride on observations and survive the window/hash;
  - each member's breakdown reports `has_outcome` and a `knowledge` score;
  - members differ in alignment (the term is selective, not decorative);
  - the evaluation is replay-safe and rejects out-of-range outcomes.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
WINDOW = 32


def at(seconds: int) -> str:
    base = datetime(2026, 11, 12, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-outcome-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"] and error in response["error"], response
                return response
            assert response["ok"], response
            return response["result"]

        call("init", purpose="知识结果适应度端到端")
        # Keep the loop short: take the default 23-key policy and lower only the
        # window, then initialize. All other parameters keep their defaults.
        params = call("evo-policy")["params"]
        params["window"] = WINDOW
        call("evo-policy", enabled=True, params=params, at=at(0))
        call("evo-init", seed=7, at=at(1))
        call("evo-observe", step=1, kind="social", salience=1.0, valence=0.5,
             outcome=2.0, subject="user", at=at(2), error="evo_outcome_invalid")

        for step in range(1, WINDOW + 1):
            outcome = 0.5 if step <= WINDOW // 2 else -0.5
            result = call("evo-observe", step=step, kind="social", salience=1.0,
                          valence=outcome, outcome=outcome, subject="user",
                          body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                          at=at(10 + step))
            assert result["outcome"] == outcome, result
        assert call("evo-status")["window"]["steps"] == WINDOW

        evaluated = call("evo-evaluate", at=at(1000))
        members = evaluated["members"]
        alive = [m for m in members if m["status"] == "alive"]
        assert alive, evaluated
        knowledge = []
        for member in alive:
            breakdown = member["breakdown"]
            assert breakdown["has_outcome"] is True, member
            assert 0.0 <= breakdown["knowledge"] <= 1.0, member
            knowledge.append(breakdown["knowledge"])
        assert len(set(round(value, 6) for value in knowledge)) >= 2, knowledge

        again = call("evo-evaluate", at=at(1001))
        assert again["replayed"] is True and again["window_sha256"] == evaluated["window_sha256"]

    print("evo outcome e2e: knowledge outcomes enter the window, evaluate reports per-member "
          "alignment (selective), replay-safe and range-checked passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())