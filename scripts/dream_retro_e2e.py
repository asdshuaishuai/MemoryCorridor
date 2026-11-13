#!/usr/bin/env python3
"""Cross-round RSI retro end-to-end (续四十二).

`dream-retro` is the read-only experience ledger: retention rate, summed deltas,
driver effectiveness and work-kind trends. This test builds one retained round
with a completed task and one rejected round, then pins the aggregation, the
empty-vault baseline, determinism and read-only behavior.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-dream-retro-") as work:
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

        call("init", purpose="RSI 跨轮复盘端到端")
        empty = call("dream-retro")
        assert empty["rounds"] == {"total": 0, "open": 0, "retained": 0, "rejected": 0}, empty
        assert empty["retention_rate"] == 0.0 and empty["drivers"] == [], empty
        assert empty["work"]["total"] == 0 and empty["last"] is None, empty

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
        call("dream-policy", due_after_seconds=0, min_opportunities=1,
             max_open_rounds=1, at="2026-11-12T00:00:00Z")

        # 1. retained round with one completed task.
        first = call("dream-plan")
        round1 = call("dream-open", baseline=first["fingerprint"],
                      at="2026-11-12T01:00:00Z")["id"]
        opened = call("dream-work-open", round=round1, limit=1,
                      at="2026-11-12T01:00:01Z")
        assert opened["created"] == 1, opened
        work = call("dream-work-list")["work"][0]
        call("dream-work-claim", id=work["id"], driver="driver-a",
             lease_until="2026-11-12T01:10:00Z", at="2026-11-12T01:00:02Z")
        call("dream-work-complete", id=work["id"], driver="driver-a",
             at="2026-11-12T01:00:03Z",
             result={"judgments": {"task": work["id"], "verdict": "ok"}, "proposals": []})
        closed1 = call("dream-close", id=round1, decision="retained",
                       at="2026-11-12T01:10:00Z", note="retro round 1")
        assert closed1["status"] == "retained", closed1

        # 2. rejected round without work.
        second = call("dream-plan")
        round2 = call("dream-open", baseline=second["fingerprint"],
                      at="2026-11-12T02:00:00Z")["id"]
        call("dream-close", id=round2, decision="rejected",
             at="2026-11-12T02:10:00Z", note="retro round 2")

        # 3. an open round proves the retention denominator is closed rounds,
        #    not all rounds.
        third = call("dream-plan")
        round3 = call("dream-open", baseline=third["fingerprint"],
                      at="2026-11-12T03:00:00Z")["id"]
        assert round3

        before = (vault / "index.mbt.md").read_bytes()
        retro = call("dream-retro")
        assert retro["rounds"] == {"total": 3, "open": 1, "retained": 1, "rejected": 1}, retro
        assert retro["retention_rate"] == 0.5, retro
        assert all(value == 0 for value in retro["deltas"].values()), retro
        assert retro["work"] == {"total": 1, "pending": 0, "claimed": 0, "done": 1,
                                 "failed": 0}, retro
        assert retro["work_by_kind"] == [{"kind": work["kind"], "count": 1}], retro
        drivers = {row["driver"]: row for row in retro["drivers"]}
        assert drivers["driver-a"] == {"driver": "driver-a", "rounds": 1, "retained": 1,
                                       "rejected": 0, "tasks_done": 1, "tasks_failed": 0}, drivers
        assert retro["last"]["id"] == round2 and retro["last"]["decision"] == "rejected", retro
        assert retro == call("dream-retro"), "retro must be deterministic"
        assert (vault / "index.mbt.md").read_bytes() == before

    print("dream retro e2e: empty baseline, retention rate, deltas, driver effectiveness, "
          "work-kind trend, last round, deterministic and read-only passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())