#!/usr/bin/env python3
"""Observe batch end-to-end (续五十九).

Pins evo-observe-batch: ordered multi-row application in one atomic commit,
byte-identity with sequential single observes, in-batch replay, fail-closed on
any invalid or conflicting row, and the 1..64 row cap.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def row(step, at, valence=0.6, outcome=0.4, kind="task", subject=None):
    return {"step": step, "kind": kind, "salience": 1.0, "valence": valence,
            "outcome": outcome,
            "body": {"cpu": 0.2, "memory": 0.1, "latency": 0.1, "budget": 0.1},
            "subject": subject, "at": at}


def seed(vault):
    for payload in [json.dumps({"op": "init", "purpose": "批量观察端到端",
                                "vault": str(vault)}),
                    json.dumps({"op": "evo-policy", "enabled": True,
                                "vault": str(vault),
                                "at": "2026-11-18T02:00:00Z"}),
                    json.dumps({"op": "evo-init", "seed": 7, "vault": str(vault),
                                "at": "2026-11-18T02:00:01Z"})]:
        run = subprocess.run([str(EXE)], input=payload + "\n", text=True,
                             capture_output=True, check=True, timeout=120)
        assert json.loads(run.stdout)["ok"], run.stdout


def call(op, vault, error=None, **fields):
    payload = json.dumps(dict(fields, op=op, vault=str(vault)))
    run = subprocess.run([str(EXE)], input=payload + "\n", text=True,
                         capture_output=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if error:
        assert not response["ok"] and error in response["error"], response
        return response
    assert response["ok"], response
    return response["result"]


def state_bytes(vault):
    return (vault / "evo/state.json").read_bytes()


def main():
    rows = [row(step + 1, f"2026-11-18T02:01:{step + 1:02d}Z") for step in range(5)]

    # 1. batch equals its sequential singles, byte for byte.
    with tempfile.TemporaryDirectory(prefix="corridor-evo-batch-") as work:
        vault = Path(work)
        seed(vault)
        result = call("evo-observe-batch", vault, rows=rows)
        assert result["applied"] == 5 and result["replays"] == 0, result
        assert result["step"] == 5 and result["window"]["have"] == 5, result
        batch_state = state_bytes(vault)

        with tempfile.TemporaryDirectory(prefix="corridor-evo-batch-single-") as single:
            single_vault = Path(single)
            seed(single_vault)
            for item in rows:
                call("evo-observe", single_vault, **item)
            assert state_bytes(single_vault) == batch_state, \
                "batch state must be byte-identical to sequential singles"

        # 2. in-batch replay: a repeated identical row counts as a replay; the
        # row-level fields describe the last row (the replay), counts aggregate.
        repeated = row(6, "2026-11-18T02:02:00Z")
        again = call("evo-observe-batch", vault, rows=[repeated, dict(repeated)])
        assert again["applied"] == 1 and again["replays"] == 1, again
        assert again["step"] == 6 and again["replayed"] is True, again
        assert state_bytes(vault) != batch_state, "step 6 must change state bytes"

        # 3. zero-write replay batch: every row replays the last applied row.
        fingerprint_before = call("evo-observe", vault,
                                  **dict(repeated))["fingerprint"]
        replay_only = call("evo-observe-batch", vault,
                           rows=[dict(repeated), dict(repeated)])
        assert replay_only["applied"] == 0 and replay_only["replays"] == 2, replay_only
        assert replay_only["replayed"] is True, replay_only
        assert replay_only["fingerprint"] == fingerprint_before, replay_only

        # 4. fail-closed: an invalid row aborts the whole batch, zero writes.
        keep = state_bytes(vault)
        call("evo-observe-batch", vault,
             rows=[row(7, "2026-11-18T02:03:00Z"),
                   row(8, "2026-11-18T02:03:01Z", kind="boss")],
             error="evo_kind_invalid")
        assert state_bytes(vault) == keep, "invalid row must leave state untouched"
        call("evo-observe-batch", vault,
             rows=[row(7, "2026-11-18T02:03:00Z"),
                   row(7, "2026-11-18T02:03:02Z", valence=-0.5)],
             error="evo_observe_conflict")
        assert state_bytes(vault) == keep, "conflict row must leave state untouched"

        # 5. cap: empty, oversized and non-array rows are rejected.
        call("evo-observe-batch", vault, rows=[], error="evo_batch_invalid")
        call("evo-observe-batch", vault,
             rows=[row(7, "2026-11-18T02:04:00Z")] * 65, error="evo_batch_invalid")
        call("evo-observe-batch", vault, rows={"step": 7}, error="evo_batch_invalid")

        # 6. after all the refusals the engine still advances from where it was.
        resumed = call("evo-observe-batch", vault,
                       rows=[row(7, "2026-11-18T02:05:00Z", subject="同伴")])
        assert resumed["applied"] == 1 and resumed["step"] == 7, resumed

    print("evo batch e2e: batch equals sequential singles byte for byte, "
          "in-batch replay, fail-closed refusal, row cap and resume passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
