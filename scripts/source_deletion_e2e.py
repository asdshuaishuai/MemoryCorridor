#!/usr/bin/env python3
"""Verify raw deletion keeps a durable tombstone and is idempotent."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=30).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


with tempfile.TemporaryDirectory(prefix="memorycorridor-source-delete-") as temp:
    root = Path(temp)
    call(root, "init", purpose="来源删除")
    (root / "raw/source.md").write_text("来源正文。\n")
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["来源"], "conflicts": [], "summary": "来源"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        "---\ntype: concept\ntitle: 来源页\nsources: [\"raw/source.md\"]\n---\n正文。\n"
    )
    call(root, "commit", order=order,
         pages=[{"id": "concepts/source", "path": "wiki/concepts/source.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-10-17")

    (root / "raw/source.md").unlink()
    first = call(root, "scan")
    assert first["orders"] == []
    entries = {entry["id"]: entry for entry in call(root, "list-pages")}
    assert entries["concepts/source"]["stale"]
    listed = call(root, "list-pages")
    assert any(row["id"] == "concepts/source" and row["stale"] for row in listed)
    events = call(root, "read-log")
    assert any(event["op"] == "source-missing" and event["source"] == "raw/source.md" for event in events)
    source_stats = next(row for row in call(root, "stats")["evidence"]["coverage"]["sources"]
                        if row["source"] == "raw/source.md")
    assert source_stats["direct_pages"] == []
    assert "concepts/source" in source_stats["stale_direct_pages"]
    assert len(source_stats["stale_direct_pages"]) == 2  # includes the source-summary fallback page
    assert source_stats["support"] == "invalidated"
    fingerprint = call(root, "status")["fingerprint"]
    assert call(root, "scan")["fingerprint"] == fingerprint

    call(root, "rebuild")
    call(root, "verify")
    (root / "raw/source.md").write_text("重新登记的来源。\n")
    assert len(call(root, "scan")["orders"]) == 1
    assert any(event["op"] == "source-missing" for event in call(root, "read-log"))

    # `forget` is sticky: it does not delete the file, so re-creating the
    # identical bytes must not silently re-approve a revoked source. Anything
    # bound to it keeps reporting the source as revoked until the content
    # actually changes.
    original = "来源正文。\n"
    (root / "raw/revived.md").write_text(original)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["撤销黏性"], "conflicts": [], "summary": "撤销黏性"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        "---\ntype: concept\ntitle: 撤销黏性\nsources: [\"raw/revived.md\"]\n---\n正文。\n"
    )
    call(root, "commit", order=order,
         pages=[{"id": "concepts/sticky", "path": "wiki/concepts/sticky.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-10-18")
    call(root, "forget", source="raw/revived.md", at="2026-10-18T01:00:00Z")
    (root / "raw/revived.md").write_text(original)
    assert call(root, "scan")["orders"] == []
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="撤销后的来源不可核对", conditions=["核对资料时"],
         sources=["raw/revived.md"], at="2026-10-18T01:30:00Z", key="sticky-note",
         error="memory_source_not_active")
    # Changing the content is what re-registers it.
    (root / "raw/revived.md").write_text("重新登记的内容。\n")
    assert len(call(root, "scan")["orders"]) == 1
    call(root, "rebuild")
    call(root, "verify")
    note = call(root, "memory-submit", kind="fact", scope="workspace",
                text="重新登记后可核对", conditions=["核对资料时"],
                sources=["raw/revived.md"], at="2026-10-18T02:00:00Z", key="sticky-note")
    assert note["record"]["valid"] is True
    assert note["record"]["drifted_sources"] == []

print("source deletion e2e: durable tombstone, invalidation and idempotent rescan passed")
