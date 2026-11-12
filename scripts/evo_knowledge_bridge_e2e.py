#!/usr/bin/env python3
"""Knowledge -> affect bridge end-to-end (续三十八).

Proves that the emotion/personality layer is driven by the memory engine's own
deterministic tensions, not by a free-standing mood simulation:

  dream-plan opportunities -> evo-observe (task/novel, salience/valence)
  closed dream-round delta -> evo-observe (outcome feedback, cursor-deduped)
  evo-proactive-due         -> read-only affect readout for the host

Also pins: no knowledge-page writes, monotonic steps, and the evo disable gate.
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
BRIDGE = ROOT / "scripts/evo_knowledge_bridge.py"


def at(seconds: int) -> str:
    base = datetime(2026, 11, 12, 2, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-evo-bridge-") as work:
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

        def bridge():
            run = subprocess.run([sys.executable, str(BRIDGE), "--vault", str(vault),
                                  "--cli", str(EXE), "--once"],
                                 capture_output=True, text=True, timeout=120)
            return run

        def seed():
            call("init", purpose="知识情感桥端到端")
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

        # 1. the bridge senses the engine's own uncovered source and observes it.
        # The bridge writes evo state, so index.mbt.md (the catalog of state
        # entries too) legitimately moves. Knowledge bytes are the invariant.
        before = {path: path.read_bytes() for path in
                  [vault / "wiki/concepts/a.md", vault / "raw/b.md"]}
        before_status = call("status")
        run = bridge()
        assert run.returncode == 0, (run.stdout, run.stderr)
        first = json.loads(run.stdout)
        assert first["observed"], first
        sources = [item["source"]["opportunity"] for item in first["observed"]]
        assert any(item["kind"] == "uncovered_source" and item["id"] == "raw/b.md"
                   for item in sources), sources
        status = call("evo-status")
        assert status["window"]["steps"] == first["steps"], (status, first)
        assert status["window"]["steps"] == len(first["observed"]), status
        assert all(path.read_bytes() == content for path, content in before.items())
        status = call("status")
        assert status["pages"] == before_status["pages"], (before_status, status)
        assert status["sources"] == before_status["sources"], (before_status, status)
        assert first["due"]["pending"] == 0, first["due"]

        # 2. every tick advances the affect step; observations are not cached.
        run = bridge()
        assert run.returncode == 0, (run.stdout, run.stderr)
        second = json.loads(run.stdout)
        assert second["steps"] > first["steps"], (first, second)
        assert call("evo-status")["window"]["steps"] == second["steps"]

        # 3. a closed RSI round feeds its outcome back exactly once (cursor).
        plan = call("dream-plan")
        opened = call("dream-open", baseline=plan["fingerprint"], at=at(100))
        call("dream-close", id=opened["id"], decision="rejected", at=at(200),
             note="bridge outcome feedback")
        run = bridge()
        assert run.returncode == 0, (run.stdout, run.stderr)
        third = json.loads(run.stdout)
        assert third["outcomes"] == [opened["id"]], third
        assert any(item["source"].get("round") == opened["id"] for item in third["observed"]), third
        run = bridge()
        fourth = json.loads(run.stdout)
        assert fourth["outcomes"] == [], fourth

        # 4. disabling the personality layer stops the bridge at the gate.
        call("evo-policy", enabled=False, at=at(300))
        run = bridge()
        assert run.returncode == 1, (run.stdout, run.stderr)
        assert "evo_disabled" in run.stderr, run.stderr

    print("evo knowledge bridge e2e: dream-plan tensions -> affect observations, "
          "closed-round outcome feedback with cursor, no knowledge writes, disable gate passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())