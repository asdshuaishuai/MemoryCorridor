#!/usr/bin/env python3
"""RSI host driver end-to-end (续三十四).

Proves the autonomous RSI loop through the real CLI and the reference host:
  - policy makes the vault due; the driver opens a round from the exact plan
    fingerprint, opens structured work, answers it with mock LLM judgments,
    completes the tasks and closes the round;
  - the round ledger records the driver in outcome.drivers and the work result
    carries the judgments; a second pass with no due opportunity is a no-op;
  - a compatibility failure downgrades retention to rejection instead of
    claiming a round succeeded.

No network: `--mock` replaces the LLM. The engine itself never calls a model.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
DRIVER = ROOT / "scripts/rsi_agent_driver.py"


def at(hour: int, minute: int = 0) -> str:
    return f"2026-11-12T{hour:02d}:{minute:02d}:00Z"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-rsi-driver-") as work:
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

        def seed():
            call("init", purpose="RSI 主动驱动端到端")
            (vault / "raw").mkdir(exist_ok=True)
            (vault / "raw/a.md").write_text("青瓷证据甲。\n", encoding="utf-8")
            (vault / "raw/b.md").write_text("未引用证据乙。\n", encoding="utf-8")
            call("scan")
            order = next(o for o in call("plan") if o["source"] == "raw/a.md")["id"]
            call("context", order=order)
            call("analysis-submit", order=order,
                 analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "d"})
            staged = vault / f"staging/{order}/0.md"
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(
                '---\ntype: concept\ntitle: 甲\nsources: ["raw/a.md"]\n---\n青瓷正文甲。\n',
                encoding="utf-8")
            call("commit", order=order, at="2026-11-12",
                 pages=[{"id": "concepts/a", "path": "wiki/concepts/a.md",
                         "staged": f"staging/{order}/0.md"}])
            call("rebuild")

        def drive(extra):
            run = subprocess.run([sys.executable, str(DRIVER), "--vault", str(vault),
                                  "--cli", str(EXE), "--once", "--mock",
                                  "--driver", "driver-rsi"] + extra,
                                 capture_output=True, text=True, timeout=120)
            assert run.returncode == 0, (run.stdout, run.stderr)
            return run.stdout.strip(), run.stderr

        seed()
        # Make the vault immediately due with one opportunity.
        call("dream-policy", due_after_seconds=0, min_opportunities=1,
             max_open_rounds=1, at=at(0))

        # 1. one pass: open from the plan fingerprint, answer work, retain.
        stdout, stderr = drive([])
        summary = json.loads(stdout)
        assert summary["due"] is True and summary["closed"] == "retained", (summary, stderr)
        assert summary["work"]["done"] >= 1 and summary["work"]["failed"] == 0, summary
        rounds = call("dream-list")["dreams"]
        assert len(rounds) == 1 and rounds[0]["status"] == "retained", rounds
        assert "driver-rsi" in rounds[0]["outcome"]["drivers"], rounds[0]
        assert rounds[0]["outcome"]["delta"]["uncovered_sources"] == 0, rounds[0]
        work = call("dream-work-list")["work"]
        assert work and all(w["status"] == "done" for w in work), work
        assert all(w["driver"] == "driver-rsi" for w in work), work
        judgements = [w["result"]["judgments"] for w in work]
        assert any(j.get("verdict") == "mock-reviewed" for j in judgements), judgements

        # 2. no due opportunity: the driver reports a no-op and writes nothing.
        call("dream-policy", due_after_seconds=3600, min_opportunities=90,
             max_open_rounds=1, at=at(1))
        before = (vault / "index.mbt.md").read_bytes()
        stdout, stderr = drive([])
        summary = json.loads(stdout)
        assert summary["due"] is False and summary["closed"] is None, (summary, stderr)
        assert (vault / "index.mbt.md").read_bytes() == before
        assert len(call("dream-list")["dreams"]) == 1

        # 3. compatibility loss between open and close downgrades to rejected.
        call("dream-policy", due_after_seconds=0, min_opportunities=1,
             max_open_rounds=1, at=at(2))
        # Open a round manually, then add an uncovered source: retention must
        # fail the evidence gate and the driver must record a rejection.
        plan = call("dream-plan")
        opened = call("dream-open", baseline=plan["fingerprint"], at=at(3))
        (vault / "raw/c.md").write_text("轮次开启后新增的未引用证据。\n", encoding="utf-8")
        call("scan")
        call("rebuild")
        run = subprocess.run([sys.executable, str(DRIVER), "--vault", str(vault),
                              "--cli", str(EXE), "--once", "--mock",
                              "--driver", "driver-rsi"], capture_output=True,
                             text=True, timeout=120)
        assert run.returncode == 0, (run.stdout, run.stderr)
        summary = json.loads(run.stdout)
        assert summary["closed"] == "rejected" and summary["decision"] == "rejected", summary
        round_row = next(r for r in call("dream-list")["dreams"] if r["id"] == opened["id"])
        assert round_row["status"] == "rejected", round_row
        assert round_row["outcome"]["delta"]["uncovered_sources"] == 1, round_row

    print("rsi driver e2e: due->plan->open->work->LLM judgments->close, no-op and "
          "compatibility downgrade passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())