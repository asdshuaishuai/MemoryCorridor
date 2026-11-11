#!/usr/bin/env python3
"""RSI work outbox end-to-end (续二十九).

Proves the improvement loop's driver-facing half on the real CLI:
  dream-work-open    structured tasks from a round's opportunity set, dedupe,
                     max_pending backpressure
  dream-work-claim   driver leases, replay, lease takeover by a new driver
  dream-work-complete structured judgments + staged proposals only (page text
                     still goes through the ordinary commit flow)
  dream-work-fail    terminal failure with a reason
  dream-work-list    queue view
  dream-close        retained refuses unresolved work; outcome records drivers
Plus record-validation branches on a tampered work row and a pack round trip.
"""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-dream-work-") as work:
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

        # Seed twelve uncovered sources: enough to exercise the pending cap.
        call("init", purpose="RSI 工作出箱端到端")
        (vault / "raw").mkdir(exist_ok=True)
        for i in range(10):
            (vault / f"raw/r{i}.md").write_text(f"未引用证据 {i}。\n", encoding="utf-8")
        call("scan")
        call("rebuild")

        plan = call("dream-plan")
        assert plan["metrics"]["uncovered_sources"] == 10, plan["metrics"]
        round_id = call("dream-open", baseline=plan["fingerprint"],
                        at="2026-11-11T01:00:00Z")["id"]

        # 1. generate the bounded batch, then hit the backpressure wall.
        opened = call("dream-work-open", round=round_id, at="2026-11-11T01:05:00Z", limit=10)
        assert opened["created"] == 10 and opened["pending"] == 10, opened
        call("dream-work-open", round=round_id, at="2026-11-11T01:06:00Z",
             error="dream_work_backpressure")
        queue = call("dream-work-list")
        assert queue["counts"]["pending"] == 10 and queue["backpressure"]["at_capacity"], queue["counts"]
        ids = sorted(item["id"] for item in queue["work"])
        first, second = ids[0], ids[1]

        # 2. lease semantics: replay, holder protection, expiry takeover.
        assert call("dream-work-claim", id=first, driver="driver-a",
                    lease_until="2026-11-11T02:00:00Z",
                    at="2026-11-11T01:10:00Z")["replayed"] is False
        assert call("dream-work-claim", id=first, driver="driver-a",
                    lease_until="2026-11-11T02:00:00Z",
                    at="2026-11-11T01:10:00Z")["replayed"] is True
        call("dream-work-claim", id=first, driver="driver-b",
             lease_until="2026-11-11T02:30:00Z", at="2026-11-11T01:20:00Z",
             error="dream_work_lease_held")
        assert call("dream-work-claim", id=first, driver="driver-b",
                    lease_until="2026-11-11T03:00:00Z",
                    at="2026-11-11T02:30:00Z")["status"] == "claimed"

        # 3. only the lease holder may complete; completion is structured only.
        result = {"judgments": {"uncovered_source:raw/r0.md": "keep as evidence"},
                  "proposals": [{"page": "wiki/concepts/r0.md", "kind": "link",
                                 "staged_path": "staging/demo/0.md"}]}
        call("dream-work-complete", id=first, driver="driver-a", at="2026-11-11T02:40:00Z",
             result=result, error="dream_work_not_owner")
        assert call("dream-work-complete", id=first, driver="driver-b",
                    at="2026-11-11T02:40:00Z", result=result)["status"] == "done"
        assert call("dream-work-complete", id=first, driver="driver-b",
                    at="2026-11-11T02:40:00Z", result=result)["replayed"] is True
        call("dream-work-complete", id=first, driver="driver-b", at="2026-11-11T02:50:00Z",
             result={"judgments": {}, "proposals": []}, error="dream_work_terminal")
        call("dream-work-complete", id=second, driver="driver-b", at="2026-11-11T02:50:00Z",
             result={"judgments": {}, "proposals": []}, error="dream_work_terminal")

        # 4. fail records a terminal reason and replays idempotently.
        call("dream-work-claim", id=second, driver="driver-a",
             lease_until="2026-11-11T03:20:00Z", at="2026-11-11T02:55:00Z")
        call("dream-work-complete", id=second, driver="driver-b", at="2026-11-11T02:56:00Z",
             result={"judgments": {}, "proposals": []}, error="dream_work_not_owner")
        assert call("dream-work-fail", id=second, driver="driver-a",
                    reason="no evidence available", at="2026-11-11T03:00:00Z")["status"] == "failed"
        assert call("dream-work-fail", id=second, driver="driver-a",
                    reason="no evidence available", at="2026-11-11T03:00:00Z")["replayed"] is True

        # 5. retention refuses while work is unattended; rejection records the
        #    decision without pretending the round is done.
        call("dream-close", id=round_id, decision="retained", at="2026-11-11T03:10:00Z",
             error="dream_compat_unresolved")

        # 6. finish the remaining tasks, then retention passes and records the
        #    drivers that actually did the work.
        for task_id in ids[2:]:
            call("dream-work-claim", id=task_id, driver="driver-a",
                 lease_until="2026-11-11T04:00:00Z", at="2026-11-11T03:20:00Z")
            call("dream-work-complete", id=task_id, driver="driver-a",
                 at="2026-11-11T03:30:00Z", result={"judgments": {}, "proposals": []})
        call("rebuild")  # clear the bookkeeping cache warning before dedupe
        dedupe = call("dream-work-open", round=round_id, at="2026-11-11T03:50:00Z", limit=10)
        assert dedupe["created"] == 0 and dedupe["skipped"] == 10, dedupe
        closed = call("dream-close", id=round_id, decision="retained", at="2026-11-11T04:00:00Z",
                      note="all tasks answered")
        assert closed["status"] == "retained", closed
        assert closed["outcome"]["drivers"] == ["driver-a", "driver-b"], closed["outcome"]
        assert call("dream-close", id=round_id, decision="retained", at="2026-11-11T04:00:00Z",
                    note="all tasks answered")["replayed"] is True
        call("dream-work-open", round=round_id, at="2026-11-11T04:10:00Z",
             error="dream_work_round_closed")

        final = call("dream-work-list")
        assert final["counts"] == {"pending": 0, "claimed": 0, "done": 9, "failed": 1}, final["counts"]

        # 7. a tampered row reports the exact validation branch through lint.
        record = sorted((vault / "state/dream-work").glob("*.json"))[0]
        original = record.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["status"] = "pending"  # pending must not carry a driver
        record.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        details = [v["detail"] for v in call("lint")["violations"]
                   if v["predicate"] == "record_invalid"]
        assert any("dream_work_pending_invalid" in d for d in details), details
        record.write_text(original, encoding="utf-8")
        call("rebuild")
        assert [v for v in call("lint")["violations"] if v["predicate"] == "record_invalid"] == []

        # 8. read-only queue view, then pack/unpack keeps the whole ledger.
        before = (vault / "index.mbt.md").read_bytes()
        assert call("dream-work-list")["counts"] == final["counts"]
        assert (vault / "index.mbt.md").read_bytes() == before
        call("pack", output="exports/rsi.mcpack")
        restored = Path(work) / "restored"
        (restored / "imports").mkdir(parents=True)
        (restored / "imports/rsi.mcpack").write_bytes((vault / "exports/rsi.mcpack").read_bytes())
        answer = json.loads(subprocess.run(
            [str(EXE)], input=json.dumps({"op": "unpack", "vault": str(restored),
                                          "file": "imports/rsi.mcpack"}) + "\n",
            text=True, capture_output=True, check=True, timeout=120).stdout)
        assert answer["ok"], answer
        restored_counts = json.loads(subprocess.run(
            [str(EXE)], input=json.dumps({"op": "dream-work-list", "vault": str(restored)}) + "\n",
            text=True, capture_output=True, check=True, timeout=120).stdout)["result"]["counts"]
        assert restored_counts == final["counts"], restored_counts

    print("dream work e2e: dedupe/backpressure, driver leases and takeover, structured "
          "completion, unresolved-retention gate, tamper branches and pack round trip passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())