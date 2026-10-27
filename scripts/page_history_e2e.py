#!/usr/bin/env python3
"""Verify page version history: commits, archives, restores and source
revocation are recoverable from the event log, in time order, read-only."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def publish(root, name, title, page_id, body, at):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [], "summary": title})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}"
    )
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at=at)


with tempfile.TemporaryDirectory(prefix="memorycorridor-page-history-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷")

    # A page that was never published has no history to report.
    call(root, "page-history", id="purpose.md", error="not_a_page")

    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "第一版。",
            "2026-10-31T09:00:00Z")
    first = call(root, "page-history", id="concepts/ceramics")
    assert first["counts"] == {"versions": 1, "commits": 1}
    assert first["versions"][0]["op"] == "commit"
    assert first["versions"][0]["at"] == "2026-10-31T09:00:00Z"
    assert first["versions"][0]["detail"] == "published from raw/ceramics.md"
    assert first["versions"][0]["page_hash"] == first["current"]["sha256"]
    assert first["current"]["stale"] is False

    # A second publication of the same page from another source is a new
    # version, and the current hash matches the newest commit.
    publish(root, "glaze.md", "陶瓷", "concepts/ceramics", "第二版，补充釉色。",
            "2026-10-31T10:00:00Z")
    second = call(root, "page-history", id="concepts/ceramics")
    assert second["counts"] == {"versions": 2, "commits": 2}
    assert [v["at"] for v in second["versions"]] == ["2026-10-31T09:00:00Z",
                                                     "2026-10-31T10:00:00Z"]
    assert second["versions"][0]["page_hash"] != second["versions"][1]["page_hash"]
    assert second["current"]["sha256"] == second["versions"][1]["page_hash"]
    assert second["versions"][1]["detail"] == "published from raw/glaze.md"

    # Archive and restore are part of the page's history, with their hashes.
    call(root, "archive-page", id="concepts/ceramics", at="2026-10-31T11:00:00Z",
         reason="整理中")
    call(root, "restore-page", id="concepts/ceramics", at="2026-10-31T11:30:00Z")
    third = call(root, "page-history", id="concepts/ceramics")
    assert [v["op"] for v in third["versions"]] == ["commit", "commit", "archive", "restore"]
    archived = third["versions"][2]
    assert archived["detail"] == "整理中"
    assert archived["page_hash"] == third["versions"][1]["page_hash"]
    assert third["versions"][3]["page_hash"] == third["versions"][1]["page_hash"]

    # Revoking the source the page currently depends on is recorded too.
    call(root, "forget", source="raw/glaze.md", at="2026-10-31T12:00:00Z")
    fourth = call(root, "page-history", id="concepts/ceramics")
    assert [v["op"] for v in fourth["versions"]] == ["commit", "commit", "archive",
                                                     "restore", "invalidate"]
    invalidated = fourth["versions"][4]
    assert invalidated["detail"] == "source revoked: raw/glaze.md"
    assert invalidated["page_hash"] == ""
    assert fourth["current"]["stale"] is True

    # The generated source-summary page has its own history.
    summary_id = "sources/" + __import__("hashlib").sha256(b"raw/ceramics.md").hexdigest()
    summary = call(root, "page-history", id=summary_id)
    assert summary["counts"]["commits"] == 1
    assert summary["versions"][0]["op"] == "commit"

    # The view is read-only and deterministic.
    fingerprint = call(root, "status")["fingerprint"]
    assert call(root, "page-history", id="concepts/ceramics") == fourth
    assert call(root, "status")["fingerprint"] == fingerprint

    # History survives a pack round trip, like every other durable record.
    call(root, "pack", output="exports/history.mcpack")
    target = root / "restored-history"
    (target / "imports").mkdir(parents=True, exist_ok=True)
    (target / "imports/history.mcpack").write_bytes(
        (root / "exports/history.mcpack").read_bytes())
    assert call(target, "unpack", file="imports/history.mcpack")["vault_fingerprint"] == fingerprint
    assert call(target, "page-history", id="concepts/ceramics") == fourth
    call(target, "rebuild")
    call(target, "verify")
    print("page history: commits, lifecycle, invalidation and round trip passed")
