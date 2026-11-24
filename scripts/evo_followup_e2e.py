#!/usr/bin/env python3
"""Proactive follow-up chain end-to-end (续五十一).

A user reply to a delivered proactive message becomes a new request in the same
chain: `evo-proactive-followup` bypasses the affect due gate, but not delivery,
one-in-flight backpressure or the depth limit. The driver answers it with the
parent reply + user text in the prompt.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
DRIVER = ROOT / "scripts/evo_agent_driver.py"


def at(seconds: int) -> str:
    base = datetime(2026, 11, 16, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-followup-") as work:
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

        call("init", purpose="主动跟进链端到端")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))
        step = 0
        due = None
        for _ in range(160):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
            if call("evo-proactive-due", at=at(1900 + step))["due"]:
                due = True
                break
        assert due, "affect never reached the gate"

        parent = call("evo-proactive-open", driver="driver-a",
                      lease_until=at(200000), at=at(3000))
        assert parent["reclaimed"] is False
        call("evo-proactive-complete", id=parent["id"], driver="driver-a",
             at=at(3001), result={"text": "主动问候", "model": "mock"})
        call("evo-proactive-ack", id=parent["id"], at=at(3002))

        # 1. the host driver answers one follow-up with parent + user text.
        run = subprocess.run([sys.executable, str(DRIVER), "--vault", str(vault),
                              "--cli", str(EXE), "--mock", "--ack", "--once",
                              "--driver", "driver-f1", "--followup-parent", parent["id"],
                              "--user-text", "你为什么这么说？", "--now", at(3050)],
                             capture_output=True, text=True, timeout=120)
        assert run.returncode == 0, (run.stdout, run.stderr)
        assert "mock 跟进·第1轮" in run.stdout, run.stdout
        rows = call("evo-proactive-list")["proactive"]
        chain = [row for row in rows if row["parent"] == parent["id"]]
        assert len(chain) == 1 and chain[0]["turn"] == 1, chain
        assert chain[0]["user_text"] == "你为什么这么说？", chain
        assert chain[0]["status"] == "done" and chain[0]["delivered_at"], chain
        # The user's reply is activity: the idle window restarts at the
        # follow-up's timestamp, not at the last observation.
        due = call("evo-proactive-due", at=at(3100))
        assert due["idle"]["last_activity_at"] == at(3050), due
        assert due["idle"]["seconds_since_activity"] == 50, due

        # 2. depth limit: continue the chain to turn 8, then the 9th is refused.
        current = chain[0]["id"]
        for turn in range(2, 9):
            run = subprocess.run([sys.executable, str(DRIVER), "--vault", str(vault),
                                  "--cli", str(EXE), "--mock", "--ack", "--once",
                                  "--driver", f"driver-f{turn}",
                                  "--followup-parent", current,
                                  "--user-text", f"第{turn}轮问题",
                                  "--now", at(3050 + turn * 10)],
                                 capture_output=True, text=True, timeout=120)
            assert run.returncode == 0, (run.stdout, run.stderr)
            row = next(r for r in call("evo-proactive-list")["proactive"]
                       if r["parent"] == current)
            assert row["turn"] == turn, row
            current = row["id"]
        call("evo-proactive-followup", id=current, user_text="too deep",
             driver="driver-deep", lease_until=at(300000), at=at(4000),
             error="evo_proactive_followup_depth")

        # 3. one-in-flight backpressure: open a new request, then try a follow-up.
        for _ in range(8):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
        inflight = call("evo-proactive-open", driver="driver-b",
                        lease_until=at(310000), at=at(5000))
        call("evo-proactive-followup", id=parent["id"], user_text="blocked",
             driver="driver-c", lease_until=at(320000), at=at(5001),
             error="evo_proactive_backpressure")

        # 4. an undelivered parent cannot be followed up.
        call("evo-proactive-fail", id=inflight["id"], driver="driver-b",
             reason="test cleanup", at=at(5002))
        for _ in range(8):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
        undelivered = call("evo-proactive-open", driver="driver-d",
                           lease_until=at(330000), at=at(6000))
        call("evo-proactive-complete", id=undelivered["id"], driver="driver-d",
             at=at(6001), result={"text": "未确认", "model": "mock"})
        call("evo-proactive-followup", id=undelivered["id"], user_text="hello",
             driver="driver-e", lease_until=at(340000), at=at(6002),
             error="evo_proactive_parent_not_delivered")

    print("evo followup e2e: delivered-parent follow-up, prompt continuity, depth limit, "
          "backpressure and undelivered-parent refusal passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())