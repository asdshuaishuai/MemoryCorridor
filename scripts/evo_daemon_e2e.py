#!/usr/bin/env python3
"""Minimal soul daemon end-to-end (续四十).

One host loop ties the fixed points together: knowledge sensing -> proactive
speech -> expression frame -> one RSI pass. The engine stays a pure library;
the daemon owns timing, the mock/LLM call and delivery ack. Disabling evo stops
the daemon cleanly.
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
    base = datetime(2026, 11, 12, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-daemon-") as work:
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

        def daemon():
            run = subprocess.run([sys.executable, str(DAEMON), "--vault", str(vault),
                                  "--cli", str(EXE), "--once", "--mock", "--with-rsi",
                                  "--driver", "daemon-a"],
                                 capture_output=True, text=True, timeout=300)
            assert run.returncode == 0, (run.stdout, run.stderr)
            return json.loads(run.stdout.strip().splitlines()[-1]), run

        def seed():
            call("init", purpose="数字灵魂 daemon 端到端")
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

        seed()
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))

        # Bring the affect state to the proactive gate, then let one daemon tick
        # do the whole loop: sense, speak, ack, expression, one RSI pass.
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

        first, run = daemon()
        assert first.get("stopped") is None, first
        assert first["sense"]["observed"], first
        assert first["speech"] and first["speech"]["model"] == "mock", first
        assert first["speech"]["acked"] is True, first
        assert "mock 主动应答" in run.stdout, run.stdout
        assert first["expression"]["posture"] in ("speak", "lean_in", "think", "idle", "still"), first
        assert 0.0 <= first["expression"]["energy"] <= 1.0, first
        assert first["rsi"] and first["rsi"].get("closed") == "retained", first
        assert first["reflection"] is not None, first
        assert call("evo-proactive-list")["counts"]["delivered"] >= 1
        assert any(row["status"] == "retained" for row in call("dream-list")["dreams"])

        # Second tick: speech cools down; the closed RSI round is fed back once;
        # the daily cadence keeps RSI from reopening immediately.
        second, _ = daemon()
        assert second["speech"] is None, second
        # Reflection/consolidation are scheduled (default 600/1800s), so an
        # immediate second tick is a no-op for both.
        assert second["reflection"] is None and second["rsi"] is None, second
        assert any(item["source"].get("round") for item in second["sense"]["observed"]), second

        # The soul switch is authoritative: disabling evo stops the daemon.
        call("evo-policy", enabled=False, at=at(5000))
        stopped, _ = daemon()
        assert stopped == {"stopped": "evo_disabled", "at": stopped["at"]}, stopped

    print("evo daemon e2e: sense -> proactive speech/ack -> expression -> retained RSI pass, "
          "cooldown/outcome feedback and disable stop passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())