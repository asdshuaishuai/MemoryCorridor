#!/usr/bin/env python3
"""Structured anthropomorphic expression end-to-end (续三十九).

The digital-soul layer must express itself without the engine inventing
language: `evo-expression` is a read-only, deterministic mapping from affect to
tokens (posture/label/prosody/gesture/face/will_initiate/energy). Wording stays
with the external LLM and rendering with the host.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def at(seconds: int) -> str:
    base = datetime(2026, 11, 12, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-expression-") as work:
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

        call("init", purpose="拟人化表达端到端")
        call("evo-policy", enabled=True, at=at(0))
        call("evo-init", seed=7, at=at(1))

        # 1. neutral state: no initiation, calm idle frame, bounded tokens.
        calm = call("evo-expression", at=at(2))
        assert calm["will_initiate"] is False and calm["posture"] == "idle", calm
        assert calm["emotion_label"] == "calm" and calm["gesture"] == "none", calm
        assert calm["expression"] == "neutral", calm
        assert 0.0 <= calm["energy"] <= 1.0, calm
        assert 0.5 <= calm["prosody"]["rate"] <= 1.5, calm
        assert 0.5 <= calm["prosody"]["pitch"] <= 1.5, calm
        assert 0.5 <= calm["prosody"]["volume"] <= 1.0, calm

        # 2. drive the affect loop until the proactive gate opens; the frame
        #    must switch to speaking with a matching gesture/face.
        step = 0
        due = None
        for _ in range(160):
            step += 1
            call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                 subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                 at=at(10 + step))
            candidate = call("evo-expression", at=at(1000 + step))
            if candidate["will_initiate"]:
                due = candidate
                break
        assert due is not None, "affect never reached the proactive gate"
        assert due["posture"] == "speak" and due["gesture"] == "open_palm", due
        # The exact label depends on the evolved controller's plateau; the
        # contract is the token vocabulary, not one fixed mood.
        assert due["emotion_label"] in ("excited", "content", "alert"), due
        assert due["expression"] in ("bright", "soft_smile", "focused"), due
        assert due["reason"] in ("impulse", "valence_high", "valence_low"), due

        # 3. deterministic and read-only: the same state returns the same frame
        #    and never touches the catalog.
        before = (vault / "index.mbt.md").read_bytes()
        again = call("evo-expression", at=at(1000 + step))
        assert again == due, (due, again)
        assert (vault / "index.mbt.md").read_bytes() == before

        # 4. disabling the subsystem stops the expression surface too.
        call("evo-policy", enabled=False, at=at(4000))
        call("evo-expression", at=at(4001), error="evo_disabled")

    print("evo expression e2e: calm idle frame, due -> speak/gesture/face, deterministic "
          "read-only tokens and disable gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())