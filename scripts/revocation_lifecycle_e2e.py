#!/usr/bin/env python3
"""Cross-layer integration: a source is revoked.

The companion to lifecycle_e2e.py. A revoked source must make a bound memory
note invalid (not drifted), invalidate pages built on it, move the knowledge
fingerprint, and surface through the inbox exactly once per subject.
"""
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


def publish(root, name, title, page_id, body):
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
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T09:00:00Z")


def predicates(root):
    return {row["predicate"] for row in call(root, "lint")["violations"]}


with tempfile.TemporaryDirectory(prefix="memorycorridor-revoke-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷")
    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "器形与釉色。")
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="官窑记录可据此核对", conditions=["核对官窑资料时"],
         sources=["raw/ceramics.md"], at="2026-11-14T09:30:00Z", key="note")
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
         at="2026-11-14T09:45:00Z", key="topic")
    before = call(root, "research-list")[0]["inputs_hash"]

    # Revoke the source: the bytes leave the vault entirely.
    (root / "raw/ceramics.md").unlink()
    call(root, "scan")

    # A revoked source is invalid, which is a different debt from drifted.
    note = [r for r in call(root, "memory-list")["notes"] if r["key"] == "note"][0]
    assert note["status"] == "active" and note["valid"] is False
    assert note["invalid_sources"] == ["raw/ceramics.md"]
    assert note["drifted_sources"] == []
    assert "memory_source_stale" in predicates(root)
    assert "stale_source" in predicates(root)
    assert "stale_page" in predicates(root)
    assert "page_source_stale" in predicates(root)
    assert [e for e in call(root, "list-pages") if e["id"] == "concepts/ceramics"][0]["stale"]

    # A research topic binds the knowledge fingerprint, not individual sources,
    # so losing one moves the fingerprint and reopens the topic's debt.
    # inputs_hash is the frozen baseline, so it must NOT move; the impact layer
    # is what compares it against the live fingerprint.
    assert call(root, "research-list")[0]["inputs_hash"] == before
    assert call(root, "impact-audit", at="2026-11-14T10:30:00Z")["opened"] == 1
    items = {i["kind"]: i for i in call(root, "inbox")["items"]}
    assert "impact" not in items, "one subject must not be proposed twice"
    assert items["research"]["drift"] == ["baseline-drift"]
    assert any(i["kind"] == "memory-source-stale" for i in items.values())
    assert call(root, "stats")["memory"]["invalid"] == 1
    assert call(root, "stats")["memory"]["drifted"] == 0

    # Revocation is durable: restoring identical bytes does not re-approve it.
    (root / "raw/ceramics.md").write_text("器形与釉色。")
    call(root, "scan")
    still = [r for r in call(root, "memory-list")["notes"] if r["key"] == "note"][0]
    assert still["valid"] is False, "forget must stay sticky"
    assert "stale_source" in predicates(root)

    # Clearing the debt requires new content, not the old bytes.
    (root / "raw/ceramics.md").write_text("第二版：器形、釉色与窑口。")
    call(root, "scan")
    cleared = [r for r in call(root, "memory-list")["notes"] if r["key"] == "note"][0]
    assert cleared["valid"] is False
    assert cleared["drifted_sources"] == ["raw/ceramics.md"]
    assert "memory_source_drift" in predicates(root)
    call(root, "rebuild")
    call(root, "verify")
    print("cross-layer revocation: invalidation, fingerprint, inbox and sticky forget passed")
