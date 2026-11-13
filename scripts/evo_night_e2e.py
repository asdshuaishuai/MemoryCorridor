#!/usr/bin/env python3
"""Night queue end-to-end (续四十四).

Quiet hours do not lose the impulse: the daemon records the deferred intent,
keeps its inner life running, and speaks after the quiet window. The test uses
the simulated clock and two daemon invocations (night, then morning) so state
persistence across restarts is part of the evidence.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
DAEMON = ROOT / "scripts/evo_daemon.py"


def at(seconds: int) -> str:
    base = datetime(2026, 11, 13, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-night-") as work:
        vault = Path(work)

        def call(op, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="夜间队列端到端")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))

        step = 0
        due = None
        for _ in range(160):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
            if call("evo-proactive-due", at=at(1000 + step))["due"]:
                due = True
                break
        assert due, "affect never reached the proactive gate"

        def daemon(now):
            run = subprocess.run([sys.executable, str(DAEMON), "--vault", str(vault),
                                  "--cli", str(EXE), "--mock", "--once",
                                  "--driver", "night-a", "--now", now,
                                  "--quiet-start", "22", "--quiet-end", "7",
                                  "--reflect-every", "0", "--consolidate-every", "0"],
                                 capture_output=True, text=True, timeout=120)
            assert run.returncode == 0, (run.stdout, run.stderr)
            return json.loads(run.stdout.strip().splitlines()[-1])

        night = daemon("2026-11-13T22:00:00Z")
        assert night["speech"] == {"quiet": True, "deferred": True, "reason": night["speech"]["reason"]}, night
        assert night["speech"]["reason"] in ("impulse", "valence_high", "valence_low"), night
        assert call("evo-proactive-list")["counts"]["done"] == 0
        state = json.loads((vault / ".corridor/evo-daemon/state.json").read_text())
        assert state["deferred"] == 1 and state["last_deferred_at"] == "2026-11-13T22:00:00Z", state

        morning = daemon("2026-11-13T07:00:00Z")
        assert morning["speech"] and morning["speech"]["acked"] is True, morning
        assert morning["speech"]["woke_from_night"] is True, morning
        assert call("evo-proactive-list")["counts"]["delivered"] == 1
        state = json.loads((vault / ".corridor/evo-daemon/state.json").read_text())
        assert state["deferred"] == 0, state

    print("evo night e2e: quiet hours defer the impulse, state survives a restart, "
          "morning speaks/acks and clears the queue passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())