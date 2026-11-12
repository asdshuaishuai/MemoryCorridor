#!/usr/bin/env python3
"""Dream round ledger end-to-end (续二十八).

Proves the RSI-facing engine surface on the real CLI:
  dream-plan  read-only deterministic opportunity set + metrics + report_hash
  dream-open  round bound to the exact fingerprint, idempotent replay
  dream-close retain/reject decisions, compatibility gates (lint regression,
              evidence loss) and replay-safe terminal states
  dream-list  cross-round experience ledger
Plus the record-validation branches on a tampered state/dreams row.
"""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-dream-") as work:
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
            call("init", purpose="梦境轮次端到端")
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
            staged.write_text('---\ntype: concept\ntitle: 甲\nsources: ["raw/a.md"]\n---\n青瓷正文甲。\n',
                              encoding="utf-8")
            call("commit", order=order, at="2026-11-11",
                 pages=[{"id": "concepts/a", "path": "wiki/concepts/a.md",
                         "staged": f"staging/{order}/0.md"}])
            call("rebuild")

        def plan(**fields):
            return call("dream-plan", **fields)

        def open_round(baseline, at, policy=None, space=None, error=None):
            fields = {"baseline": baseline, "at": at}
            if policy is not None:
                fields["policy"] = policy
            if space is not None:
                fields["space"] = space
            return call("dream-open", error=error, **fields)

        def close_round(round_id, decision, at, note=None, error=None):
            fields = {"id": round_id, "decision": decision, "at": at}
            if note is not None:
                fields["note"] = note
            return call("dream-close", error=error, **fields)

        seed()

        # 1. read-only deterministic dream plan: same bytes before/after, two
        #    calls byte-identical, report_hash stable across limits.
        before = (vault / "index.mbt.md").read_bytes()
        first = plan()
        assert first == plan(), "dream-plan must be deterministic"
        assert (vault / "index.mbt.md").read_bytes() == before
        metrics = first["metrics"]
        assert metrics["pages"] >= 2 and metrics["uncovered_sources"] >= 1, metrics
        assert metrics["missing_vectors"] == 0  # no space requested
        kinds = [(o["kind"], o["id"]) for o in first["opportunities"]]
        assert ("uncovered_source", "raw/b.md") in kinds, kinds
        short = plan(limit=1)
        assert len(short["opportunities"]) == 1 and short["remaining"] == len(kinds) - 1, short
        assert short["report_hash"] == first["report_hash"], (short["report_hash"], first["report_hash"])
        call("dream-plan", limit=0, error="invalid_integer: limit")

        # 2. a round binds the exact fingerprint; replay is idempotent even
        #    though the round's own record moves the fingerprint afterwards.
        baseline = first["fingerprint"]
        policy = {"cosine_floor": 0.995, "note": "demo"}
        opened = open_round(baseline, "2026-11-11T01:00:00Z", policy=policy)
        assert opened["replayed"] is False and opened["status"] == "open"
        assert open_round(baseline, "2026-11-11T01:00:00Z", policy=policy)["replayed"] is True
        open_round("d" * 64, "2026-11-11T01:00:00Z", policy=policy, error="dream_stale_baseline")
        open_round(baseline, "2026-11-11T01:00:00Z", policy={"bad": [1]}, error="dream_policy_value_invalid")
        assert close_round(opened["id"], "retained", "2026-11-11T01:30:00Z")["status"] == "retained"
        call("rebuild")

        # 3. rejected rounds record their outcome and close terminally.
        fp2 = plan()["fingerprint"]
        r2 = open_round(fp2, "2026-11-11T02:00:00Z")["id"]
        done = close_round(r2, "rejected", "2026-11-11T02:30:00Z", note="not worth it")
        assert done["status"] == "rejected" and "outcome" in done
        assert close_round(r2, "rejected", "2026-11-11T02:30:00Z", note="not worth it")["replayed"] is True
        close_round(r2, "retained", "2026-11-11T03:00:00Z", error="dream_terminal")
        call("rebuild")

        # 4. evidence-loss gate: a new uncovered source appeared after the
        #    round opened -> retaining is refused, rejecting still records.
        fp3 = plan()["fingerprint"]
        r3 = open_round(fp3, "2026-11-11T04:00:00Z")["id"]
        (vault / "raw/c.md").write_text("轮次开启后新增的未引用证据。\n", encoding="utf-8")
        call("scan")
        call("rebuild")
        close_round(r3, "retained", "2026-11-11T04:30:00Z", error="dream_compat_evidence_loss")
        assert close_round(r3, "rejected", "2026-11-11T04:45:00Z")["status"] == "rejected"
        call("rebuild")

        # 5. lint-regression gate: an unregistered wiki file raises errors;
        #    retaining is refused until the damage is gone.
        fp4 = plan()["fingerprint"]
        r4 = open_round(fp4, "2026-11-11T05:00:00Z")["id"]
        orphan = vault / "wiki/concepts/orphan.md"
        orphan.write_text("---\ntype: concept\ntitle: 孤儿\nsources: []\n---\n未登记。\n",
                          encoding="utf-8")
        call("rebuild")
        close_round(r4, "retained", "2026-11-11T05:30:00Z", error="dream_compat_lint_regression")
        orphan.unlink()
        call("rebuild")
        assert close_round(r4, "retained", "2026-11-11T06:00:00Z")["status"] == "retained"
        call("rebuild")

        # 6. the ledger lists every round with its decision and delta.
        ledger = call("dream-list")
        assert ledger["counts"] == {"open": 0, "retained": 2, "rejected": 2}, ledger["counts"]
        statuses = sorted(d["status"] for d in ledger["dreams"])
        assert statuses == ["rejected", "rejected", "retained", "retained"], statuses
        deltas = [d["outcome"]["delta"] for d in ledger["dreams"] if d["outcome"]]
        assert all(isinstance(v, int) for delta in deltas for v in delta.values())

        # 7. tampered ledger rows report the exact validation branch through
        #    lint, and restoring the bytes clears it.
        record = next((vault / "state/dreams").glob("*.json"))
        original = record.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["status"] = "open"  # closed rows must not regress to open
        record.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        details = [v["detail"] for v in call("lint")["violations"]
                   if v["predicate"] == "record_invalid"]
        assert any("dream_decision_status_mismatch" in d or "dream_open_state_invalid" in d
                   for d in details), details
        record.write_text(original, encoding="utf-8")
        call("rebuild")
        assert [v for v in call("lint")["violations"] if v["predicate"] == "record_invalid"] == []

        # 8. the ledger is pack/restore durable: a bundle round trip keeps
        #    every round and the same fingerprint.
        assert len(call("dream-list")["dreams"]) == 4
        packed = call("pack", output="exports/dreams.mcpack")
        restored = Path(work) / "restored"
        (restored / "imports").mkdir(parents=True)
        (restored / "imports/dreams.mcpack").write_bytes(
            (vault / "exports/dreams.mcpack").read_bytes())
        run = subprocess.run([str(EXE)], input=json.dumps({
            "op": "unpack", "vault": str(restored), "file": "imports/dreams.mcpack"}) + "\n",
            text=True, capture_output=True, check=True, timeout=120)
        answer = json.loads(run.stdout)
        assert answer["ok"], answer
        restored_list = json.loads(subprocess.run(
            [str(EXE)], input=json.dumps({"op": "dream-list", "vault": str(restored)}) + "\n",
            text=True, capture_output=True, check=True, timeout=120).stdout)["result"]
        assert len(restored_list["dreams"]) == 4, restored_list
        assert restored_list["fingerprint"] == answer["result"]["vault_fingerprint"], answer

        # 9. cadence contract (续三十一): policy read/write, replay, due reasons.
        default_policy = call("dream-policy")
        assert default_policy["default"] is True, default_policy
        assert default_policy["policy"]["due_after_seconds"] == 86400, default_policy
        written = call("dream-policy", due_after_seconds=0, min_opportunities=0,
                       max_open_rounds=1, at="2026-11-12T00:00:00Z")
        assert written["changed"] is True and written["policy"]["max_open_rounds"] == 1, written
        assert call("dream-policy")["policy"]["due_after_seconds"] == 0
        # Regression (续三十四): policy.json is a cadence record, not a round;
        # the ledger must skip it instead of demanding a `status` field.
        listed = call("dream-list")
        assert all(row["id"] != "state/dreams/policy.json" for row in listed["dreams"]), listed
        assert listed["counts"]["open"] == 0, listed
        assert call("dream-policy", due_after_seconds=0, min_opportunities=0,
                    max_open_rounds=1, at="2026-11-12T00:00:01Z")["replayed"] is True
        call("dream-policy", max_open_rounds=9, at="2026-11-12T00:00:02Z",
             error="invalid_integer: max_open_rounds")
        due = call("dream-due", at="2026-11-12T00:00:03Z")
        assert due["due"] is True and due["open_rounds"] == 0 and due["default"] is False, due
        fp = call("dream-plan")["fingerprint"]
        open_id = call("dream-open", baseline=fp, at="2026-11-12T00:00:04Z")["id"]
        blocked = call("dream-due", at="2026-11-12T00:00:05Z")
        assert blocked["due"] is False and "open_rounds_capacity" in blocked["reasons"], blocked
        call("dream-close", id=open_id, decision="rejected", at="2026-11-12T00:00:06Z")
        reopened = call("dream-due", at="2026-11-12T00:00:07Z")
        assert reopened["due"] is True, reopened

    print("dream e2e: deterministic dream plan, fingerprint-bound rounds, "
          "compatibility-gated retention and tamper branches passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())