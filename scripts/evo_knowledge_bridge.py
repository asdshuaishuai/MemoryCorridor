#!/usr/bin/env python3
"""Knowledge -> affect bridge (续三十八).

MemoryCorridor is a memory/knowledge engine; the emotion/personality layer is
an *amplifier* for that memory, not a separate soul kernel. This host-side
bridge reads the deterministic knowledge tension the engine already computes
(`dream-plan` opportunities, plus closed-round outcomes) and feeds it to the
evo controller through `evo-observe`.

The engine still never calls a model and never writes knowledge pages: the
bridge only writes evo state through the normal ops, and any page proposal is
left to the existing commit flow.

Usage:
  python3 scripts/evo_knowledge_bridge.py --vault /abs/vault --once
  python3 scripts/evo_knowledge_bridge.py --vault /abs/vault --interval 60

The bridge is opt-in: if evo is disabled it exits with a clear message instead
of silently doing nothing.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "_build/native/debug/build/cli/cli.exe"

# How each deterministic opportunity kind feels to the affect controller.
# (kind, salience, valence). Defects are negative and salient; gaps that need
# new material are "novel" stimuli; low-priority housekeeping stays mild.
TENSION = {
    "lint": (0.9, -0.7),
    "stale_page": (0.8, -0.6),
    "uncovered_source": (0.7, 0.35),  # a chance to learn, not only a defect
    "sparse_topic": (0.5, -0.3),
    "missing_vector": (0.4, -0.2),
}


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def call(cli: str, vault: str, op: str, **fields):
    run = subprocess.run([cli], input=json.dumps(dict(fields, op=op, vault=vault)) + "\n",
                         capture_output=True, text=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if not response["ok"]:
        raise RuntimeError("%s: %s" % (op, response.get("error", "engine error")))
    return response["result"]


def short_subject(kind: str, value: str) -> str:
    """evo-observe subjects are capped at 64 bytes; keep a stable readable id."""
    raw = f"{kind}:{value}"
    if len(raw.encode()) <= 64:
        return raw
    return f"{kind}:{hashlib.sha256(value.encode()).hexdigest()[:24]}"


def classify(opportunity):
    kind = opportunity.get("kind", "unknown")
    salience, valence = TENSION.get(kind, (0.5, -0.3))
    if kind == "lint":
        if opportunity.get("severity") == "error":
            salience, valence = 1.0, -0.8
        else:
            salience, valence = 0.7, -0.4
    # A new uncovered source is a chance to learn, not only a defect.
    evo_kind = "novel" if kind in ("uncovered_source", "missing_vector") else "task"
    return evo_kind, salience, valence


def body() -> dict:
    # Host resource signals are optional; the bridge does not pretend to know
    # CPU/memory. A neutral, explicit baseline keeps the observation replayable.
    return {"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1}


def cursor_path(vault: str) -> Path:
    return Path(vault) / ".corridor" / "evo-bridge" / "state.json"


def load_cursor(vault: str) -> dict:
    path = cursor_path(vault)
    if not path.exists():
        return {"last_closed_at": "", "last_closed_id": ""}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return {"last_closed_at": value.get("last_closed_at", ""),
                "last_closed_id": value.get("last_closed_id", "")}
    except (json.JSONDecodeError, OSError):
        return {"last_closed_at": "", "last_closed_id": ""}


def save_cursor(vault: str, cursor: dict) -> None:
    path = cursor_path(vault)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(cursor, ensure_ascii=False, sort_keys=True), encoding="utf-8")


def knowledge_tensions(cli: str, vault: str, limit: int) -> list:
    plan = call(cli, vault, "dream-plan", limit=limit)
    return plan.get("opportunities", [])[:limit]


def closed_rounds(cli: str, vault: str, cursor: dict, limit: int) -> list:
    rows = call(cli, vault, "dream-list").get("dreams", [])
    last = (cursor.get("last_closed_at") or "", cursor.get("last_closed_id") or "")
    fresh = [row for row in rows
             if row.get("closed_at") and row.get("outcome") and
             (row["closed_at"], row["id"]) > last]
    fresh.sort(key=lambda row: (row["closed_at"], row["id"]))
    return fresh[:limit]


def outcome_feeling(row):
    delta = (row.get("outcome") or {}).get("delta") or {}
    gain = (delta.get("pages", 0) + delta.get("lint_errors", 0) * -1
            + delta.get("uncovered_sources", 0) * -1 + delta.get("stale_pages", 0) * -1)
    score = max(-5.0, min(5.0, float(gain)))
    normalized = max(-1.0, min(1.0, score / 3.0))
    return "task", min(1.0, abs(score) / 3.0), normalized, normalized


def run_pass(cli: str, vault: str, limit: int, outcomes: bool, stamp: str = None) -> dict:
    status = call(cli, vault, "evo-status")
    if not status.get("initialized"):
        raise RuntimeError("evo_not_initialized: run evo-init first")
    step = int(status["window"]["steps"])
    at = stamp or now()
    observed = []

    def observe(evo_kind, salience, valence, subject, source, outcome=0.0):
        nonlocal step
        step += 1
        call(cli, vault, "evo-observe", step=step, kind=evo_kind,
             salience=salience, valence=valence, subject=short_subject(subject[0], subject[1]),
             outcome=outcome, body=body(), at=at)
        observed.append({"step": step, "kind": evo_kind, "salience": salience,
                         "valence": valence, "outcome": outcome, "source": source})

    for opportunity in knowledge_tensions(cli, vault, limit):
        evo_kind, salience, valence = classify(opportunity)
        observe(evo_kind, salience, valence,
                (opportunity.get("kind", "unknown"), opportunity.get("id", "")),
                {"opportunity": opportunity})

    outcomes_seen = []
    if outcomes:
        cursor = load_cursor(vault)
        fresh = closed_rounds(cli, vault, cursor, limit)
        for row in fresh:
            evo_kind, salience, valence, outcome = outcome_feeling(row)
            observe(evo_kind, salience, valence, ("dream", row["id"]),
                    {"round": row["id"], "decision": row.get("decision"),
                     "delta": (row.get("outcome") or {}).get("delta")}, outcome)
            outcomes_seen.append(row["id"])
        if fresh:
            save_cursor(vault, {"last_closed_at": fresh[-1]["closed_at"],
                                "last_closed_id": fresh[-1]["id"]})

    try:
        due = call(cli, vault, "evo-proactive-due", at=at)
    except RuntimeError as error:
        # A human gate or a paused subsystem must not discard the sensing work.
        due = {"available": False, "error": str(error)}
    return {"observed": observed, "outcomes": outcomes_seen,
            "steps": step, "due": due}


def main() -> int:
    parser = argparse.ArgumentParser(description="Knowledge -> affect bridge for evo")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--limit", type=int, default=3,
                        help="opportunities/outcomes per pass (1..50)")
    parser.add_argument("--interval", type=float, default=60.0)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--no-outcomes", action="store_true",
                        help="skip closed-round outcome feedback")
    args = parser.parse_args()
    if not 1 <= args.limit <= 50:
        parser.error("--limit must be in 1..50")
    while True:
        try:
            summary = run_pass(args.cli, args.vault, args.limit, not args.no_outcomes)
            print(json.dumps(summary, ensure_ascii=False))
        except Exception as error:  # noqa: BLE001 - a host tick must report, not crash
            print(f"bridge: pass failed: {error}", file=sys.stderr)
            if args.once:
                return 1
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())