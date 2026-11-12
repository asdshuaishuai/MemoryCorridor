#!/usr/bin/env python3
"""Proactive agent loop end-to-end (续三十三).

Proves the special semantics the user asked for: when the emotion/personality
subsystem is ENABLED, its affect state initiates an LLM call on its own --
the engine publishes a structured request, a host-side driver claims it, calls
the model (mock here, no network) and writes the reply back. Disabling evo
stops the loop because every op answers `evo_disabled`.

Also pins: one-request backpressure, cooldown between proactive requests,
owner/lease semantics, replay, failure recording, and the read-only list.
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
    base = datetime(2026, 11, 12, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-proactive-") as work:
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

        call("init", purpose="主动式情感人格端到端")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))
        step = 0

        def observe(count):
            nonlocal step
            last = None
            for _ in range(count):
                step += 1
                last = call("evo-observe", step=step, kind="social", salience=1.0,
                            valence=1.0, subject="user",
                            body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                            at=at(10 + step))
            return last

        def observe_until_due(limit=160):
            for _ in range(limit):
                due = call("evo-proactive-due", at=at(1000 + step))
                if due["due"]:
                    return due
                observe(1)
            raise AssertionError("affect state never became due")

        # 1. the affect system decides to speak on its own.
        due = observe_until_due()
        assert due["due"] is True and due["reason"] in ("impulse", "valence_high"), due
        opened = call("evo-proactive-open", driver="driver-a",
                      lease_until=at(100000), at=at(2000))
        assert opened["id"] and opened["context"]["genome"], opened
        # A claimed reply is not deliverable yet.
        call("evo-proactive-ack", id=opened["id"], at=at(2001),
             error="evo_proactive_not_deliverable")
        assert opened["urgency"] > 0.0, opened
        # pending request is backpressure for a second open.
        call("evo-proactive-open", driver="driver-b", lease_until=at(100001),
             at=at(2001), error="evo_proactive_backpressure")
        # cooldown: immediately after opening there is nothing due.
        assert call("evo-proactive-due", at=at(2002))["due"] is False
        # owner/lease semantics.
        call("evo-proactive-complete", id=opened["id"], driver="driver-b",
             at=at(2003), result={"text": "wrong owner", "model": "m"},
             error="evo_proactive_not_owner")
        assert call("evo-proactive-complete", id=opened["id"], driver="driver-a",
                    at=at(2003), result={"text": "主动问候", "model": "mock"})["status"] == "done"
        assert call("evo-proactive-complete", id=opened["id"], driver="driver-a",
                    at=at(2003), result={"text": "主动问候", "model": "mock"})["replayed"] is True
        # Delivery ack: cannot precede the reply, is idempotent at the same
        # time, and refuses a second delivery at a different time.
        call("evo-proactive-ack", id=opened["id"], at=at(2002),
             error="evo_proactive_ack_time_invalid")
        acked = call("evo-proactive-ack", id=opened["id"], at=at(2004))
        assert acked["status"] == "acknowledged" and acked["delivered_at"] == at(2004), acked
        assert call("evo-proactive-ack", id=opened["id"], at=at(2004))["replayed"] is True
        call("evo-proactive-ack", id=opened["id"], at=at(2005),
             error="evo_proactive_already_delivered")
        counts = call("evo-proactive-list")["counts"]
        assert counts["done"] == 1 and counts["delivered"] == 1 and counts["undelivered"] == 0, counts

        # 2. cooldown gates the next request; after enough steps a failure is
        #    recorded distinctly from a completed reply.
        assert call("evo-proactive-due", at=at(2004))["due"] is False
        observe(8)
        due2 = observe_until_due()
        second = call("evo-proactive-open", driver="driver-a",
                      lease_until=at(100002), at=at(3000))
        call("evo-proactive-fail", id=second["id"], driver="driver-a",
             reason="model unavailable", at=at(3001))
        assert call("evo-proactive-list")["counts"]["failed"] == 1
        call("evo-proactive-ack", id=second["id"], at=at(3002),
             error="evo_proactive_not_deliverable")

        # 3. disabling the subsystem stops the loop at the gate.
        call("evo-policy", enabled=False, at=at(4000))
        call("evo-proactive-due", at=at(4001), error="evo_disabled")

        # 4. the host driver itself: with evo enabled it initiates the reply.
        call("evo-policy", enabled=True, at=at(4100))
        observe_until_due()
        before = call("evo-proactive-list")["counts"]["done"]
        run = subprocess.run([sys.executable, str(DRIVER), "--vault", str(vault),
                              "--cli", str(EXE), "--once", "--mock", "--driver", "driver-c"],
                             capture_output=True, text=True, timeout=120)
        assert run.returncode == 0, (run.stdout, run.stderr)
        assert "mock 主动应答" in run.stdout, run.stdout
        after = call("evo-proactive-list")
        assert after["counts"]["done"] == before + 1, after["counts"]
        assert any(row["driver"] == "driver-c" for row in after["proactive"]), after

        # 5. an expired claim is taken over, not duplicated or left blocking.
        observe_until_due()
        holder = call("evo-proactive-open", driver="driver-a",
                      lease_until=at(90000), at=at(80000))
        assert holder["reclaimed"] is False, holder
        observe(8)
        expired = call("evo-proactive-due", at=at(100000))
        assert expired["due"] is True and expired["expired"] == 1 and expired["pending"] == 0, expired
        taken = call("evo-proactive-open", driver="driver-b",
                     lease_until=at(110000), at=at(100001))
        assert taken["reclaimed"] is True and taken["id"] == holder["id"], (holder, taken)
        call("evo-proactive-complete", id=taken["id"], driver="driver-a", at=at(100002),
             result={"text": "旧驱动", "model": "m"}, error="evo_proactive_not_owner")
        assert call("evo-proactive-complete", id=taken["id"], driver="driver-b",
                    at=at(100002), result={"text": "接管答复", "model": "mock"})["status"] == "done"
        row = next(r for r in call("evo-proactive-list")["proactive"] if r["id"] == taken["id"])
        assert row["driver"] == "driver-b" and row["lease_until"] == at(110000), row

        # 6. the list is read-only.
        baseline = (vault / "index.mbt.md").read_bytes()
        call("evo-proactive-list")
        assert (vault / "index.mbt.md").read_bytes() == baseline

    print("evo proactive e2e: affect-driven proactive requests, backpressure, cooldown, "
          "owner/lease, host driver LLM initiation and disable gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())