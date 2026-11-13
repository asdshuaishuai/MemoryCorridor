#!/usr/bin/env python3
"""Daemon schedule end-to-end (续四十三).

A simulated clock proves the two periodic inner-life passes are scheduled, not
run every tick: reflection (dream-retro -> evo-observe) and consolidation
(dream-due -> RSI driver). The engine still owns no clock; the host daemon does.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
DAEMON = ROOT / "scripts/evo_daemon.py"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-schedule-") as work:
        vault = Path(work)

        def call(op, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="daemon 周期调度端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/b.md").write_text("未引用证据乙。\n", encoding="utf-8")
        call("scan")
        call("rebuild")
        call("evo-policy", enabled=True, at="2026-11-13T00:00:00Z")
        call("evo-init", seed=7, at="2026-11-13T00:00:01Z")
        call("dream-policy", due_after_seconds=0, min_opportunities=0,
             max_open_rounds=1, at="2026-11-13T00:00:02Z")

        run = subprocess.run([sys.executable, str(DAEMON), "--vault", str(vault),
                              "--cli", str(EXE), "--mock", "--with-rsi",
                              "--driver", "schedule-a", "--limit", "1",
                              "--ticks", "3", "--now", "2026-11-13T10:00:00Z",
                              "--tick-seconds", "60", "--reflect-every", "120",
                              "--consolidate-every", "120"],
                             capture_output=True, text=True, timeout=300)
        assert run.returncode == 0, (run.stdout, run.stderr)
        summaries = [json.loads(line) for line in run.stdout.splitlines()
                     if line.startswith("{")]
        assert len(summaries) == 3, summaries
        assert summaries[0]["reflection"] is not None, summaries[0]
        assert summaries[1]["reflection"] is None, summaries[1]
        assert summaries[2]["reflection"] is not None, summaries[2]
        assert summaries[0]["rsi"] is not None, summaries[0]
        assert summaries[1]["rsi"] is None, summaries[1]
        assert summaries[2]["rsi"] is not None, summaries[2]
        assert summaries[0]["at"] == "2026-11-13T10:00:00Z", summaries[0]
        assert summaries[2]["at"] == "2026-11-13T10:02:00Z", summaries[2]
        state = json.loads((vault / ".corridor/evo-daemon/state.json").read_text())
        assert state["cycles"] == 3, state
        assert state["last_reflect"] == "2026-11-13T10:02:00Z", state
        assert state["last_consolidate"] == "2026-11-13T10:02:00Z", state

    print("evo schedule e2e: simulated clock, reflection/consolidation cadence, "
          "state timestamps passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())