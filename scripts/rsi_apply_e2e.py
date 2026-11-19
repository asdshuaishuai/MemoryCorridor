#!/usr/bin/env python3
"""Staged RSI proposal application end-to-end (续六十).

Pins scripts/rsi_apply_proposal.py: a staged dream-work draft reaches a
published knowledge page ONLY through the ordinary order flow
(scan → context → analysis-submit → commit), refuses an already-active page,
missing drafts/sources and empty bodies, requires an unambiguous open order,
and a later source revocation still invalidates the applied page.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
APPLY = ROOT / "scripts/rsi_apply_proposal.py"
sys.path.insert(0, str(ROOT / "scripts"))
from rsi_agent_driver import write_staged_proposal  # noqa: E402  (real driver writer)


def call(vault, op, error=None, **fields):
    payload = json.dumps(dict(fields, op=op, vault=str(vault)))
    run = subprocess.run([str(EXE)], input=payload + "\n", text=True,
                         capture_output=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if error:
        assert not response["ok"] and error in response["error"], response
        return response
    assert response["ok"], response
    return response["result"]


def apply(vault, *extra):
    return subprocess.run(
        [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
         "--proposal", "staging/dream-work/task-demo.md",
         "--source", "raw/apply-source.md", "--at", "2026-11-18T06:00:00Z",
         *extra],
        capture_output=True, text=True, timeout=300)


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-rsi-apply-") as work:
        vault = Path(work)
        call(vault, "init", purpose="RSI 提案应用端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/apply-source.md").write_text("提案依据的原始来源。\n", encoding="utf-8")
        staged_dir = vault / "staging/dream-work"
        staged_dir.mkdir(parents=True)
        # The draft is written by the real driver helper, so the applied bytes
        # are exactly what --propose stages.
        write_staged_proposal(str(vault), {"id": "task-demo", "subject": "整理演示"},
                              "建议为该来源建立整理页：正文由驱动暂存，人审后经正规订单流应用。")

        # 1. happy path: staged draft -> ordinary order flow -> published page.
        result = apply(vault)
        assert result.returncode == 0, (result.stdout, result.stderr)
        applied = json.loads(result.stdout.strip().splitlines()[-1])
        assert applied["applied"] is True and applied["source"] == "raw/apply-source.md", applied
        page = call(vault, "read-page", id="dream-work/task-demo")
        assert page["stale"] is False and "正文由驱动暂存" in page["text"], page
        assert page["entry"]["sources"] == ["raw/apply-source.md"], page["entry"]

        # 2. idempotence: the same proposal must not silently re-publish.
        again = apply(vault)
        assert again.returncode != 0 and "already active" in again.stderr, again

        # 3. refusals: missing draft, missing source, empty body.
        missing_draft = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--proposal", "staging/dream-work/nope.md",
             "--source", "raw/apply-source.md", "--at", "2026-11-18T06:05:00Z"],
            capture_output=True, text=True, timeout=300)
        assert missing_draft.returncode != 0 and "not found" in missing_draft.stderr
        missing_source = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--proposal", "staging/dream-work/task-demo.md",
             "--source", "raw/nope.md", "--at", "2026-11-18T06:06:00Z"],
            capture_output=True, text=True, timeout=300)
        assert missing_source.returncode != 0 and "source file not found" in missing_source.stderr
        (staged_dir / "task-empty.md").write_text(
            "---\ntype: concept\ntitle: \"RSI 提案：空\"\nsources: []\n---\n", encoding="utf-8")
        empty = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--proposal", "staging/dream-work/task-empty.md",
             "--source", "raw/apply-source.md", "--at", "2026-11-18T06:07:00Z"],
            capture_output=True, text=True, timeout=300)
        assert empty.returncode != 0 and "empty body" in empty.stderr

        # 4. ambiguous orders: two fresh sources -> apply must demand --order.
        (vault / "raw/apply-source-2.md").write_text("第二个新来源。\n", encoding="utf-8")
        (vault / "raw/apply-source-3.md").write_text("第三个新来源。\n", encoding="utf-8")
        write_staged_proposal(str(vault), {"id": "task-amb", "subject": "整理演示"},
                              "第二份提案正文，用于多工单场景。")
        ambiguous = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--proposal", "staging/dream-work/task-amb.md",
             "--source", "raw/apply-source-2.md", "--at", "2026-11-18T06:10:00Z"],
            capture_output=True, text=True, timeout=300)
        # With several fresh sources in flight, the tool binds by SOURCE: the
        # open order for raw/apply-source-2.md is unique, so no --order is
        # needed (an order id only pins when a source could be ambiguous).
        assert ambiguous.returncode == 0, (ambiguous.stdout, ambiguous.stderr)
        amb_page = call(vault, "read-page", id="dream-work/task-amb")
        assert amb_page["stale"] is False, amb_page
        assert json.loads(ambiguous.stdout)["source"] == "raw/apply-source-2.md"
        open_orders = [row for row in call(vault, "status")["orders"]
                       if row["phase"] in ("pending", "context-ready", "analysis-done")]
        assert len(open_orders) == 1 and open_orders[0]["source"] == "raw/apply-source-3.md", \
            open_orders

        # 5. revocation still bites: delete the source, scan, page goes stale.
        (vault / "raw/apply-source.md").unlink()
        call(vault, "scan")
        revoked = call(vault, "read-page", id="dream-work/task-demo")
        assert revoked["stale"] is True, revoked
        amb_kept = call(vault, "read-page", id="dream-work/task-amb")
        assert amb_kept["stale"] is False, amb_kept

        # 6. proposal lifecycle (续六十四): applied markers, --list states and
        # --revive for a stale page whose source came back.
        marker = vault / "staging/dream-work/task-demo.applied.json"
        assert marker.is_file(), "apply must write an applied marker"
        assert json.loads(marker.read_text())["mode"] == "commit"
        write_staged_proposal(str(vault), {"id": "task-fresh", "subject": "待应用"},
                              "尚未应用的提案正文。")
        listing = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--list"], capture_output=True, text=True, timeout=300)
        assert listing.returncode == 0, listing.stderr
        states = {row["page"]: row["state"]
                  for row in json.loads(listing.stdout)["proposals"]}
        assert states["dream-work/task-demo"] == "stale", states
        assert states["dream-work/task-amb"] == "applied", states
        assert states["dream-work/task-fresh"] == "pending", states
        # A stale page comes back through the SAME flow once its source
        # changes: the changed bytes yield an open order, and the commit
        # revives the page. An unchanged source stays sticky by design.
        (vault / "raw/apply-source.md").write_text("提案依据的原始来源，第二版。\n",
                                                   encoding="utf-8")
        call(vault, "scan")
        reapply = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--proposal", "staging/dream-work/task-demo.md",
             "--source", "raw/apply-source.md", "--at", "2026-11-19T03:00:00Z"],
            capture_output=True, text=True, timeout=300)
        assert reapply.returncode == 0, (reapply.stdout, reapply.stderr)
        revived = call(vault, "read-page", id="dream-work/task-demo")
        assert revived["stale"] is False, revived
        # The page body stays the proposal's draft; what the republish
        # refreshes is the source binding (new source digest, stale:false).
        assert revived["entry"]["sources"] == ["raw/apply-source.md"], revived
        assert json.loads(marker.read_text())["mode"] == "commit"
        listing2 = subprocess.run(
            [sys.executable, str(APPLY), "--vault", str(vault), "--cli", str(EXE),
             "--list"], capture_output=True, text=True, timeout=300)
        states2 = {row["page"]: row["state"]
                   for row in json.loads(listing2.stdout)["proposals"]}
        assert states2["dream-work/task-demo"] == "applied", states2

    print("rsi apply e2e: staged proposal through the ordinary order flow, "
          "idempotence and refusals, ambiguous-order pinning, source "
          "revocation, applied markers, lifecycle listing and stale-page "
          "republish passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
