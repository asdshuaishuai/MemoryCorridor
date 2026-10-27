#!/usr/bin/env python3
"""Cross-layer integration: a source gaining a new version.

No single-layer e2e covers what happens when one raw file is re-registered with
different bytes. This exercises the memory layer, page invalidation, change
impact and the inbox together, then clears all of it.
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


def publish(root, name, title, page_id, body, at="2026-11-14T09:00:00Z"):
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


def predicates(root, prefix):
    return {row["predicate"] for row in call(root, "lint")["violations"]
            if row["predicate"].startswith(prefix)}


with tempfile.TemporaryDirectory(prefix="memorycorridor-lifecycle-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷")
    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "第一版：器形与釉色。")
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="官窑记录可据此核对", conditions=["核对官窑资料时"],
         sources=["raw/ceramics.md"], at="2026-11-14T09:30:00Z", key="note")
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
         at="2026-11-14T09:45:00Z", key="topic")
    assert predicates(root, "memory") == set()
    assert call(root, "inbox")["items"] != []

    # The same path is re-registered with entirely different bytes.
    (root / "raw/ceramics.md").write_text("第二版：完全不同的内容。")
    call(root, "scan")

    # The memory note is not revoked, but its evidence is no longer what it was.
    note = [r for r in call(root, "memory-list")["notes"] if r["key"] == "note"][0]
    assert note["status"] == "active"
    assert note["valid"] is False
    assert note["invalid_sources"] == []
    assert note["drifted_sources"] == ["raw/ceramics.md"]

    # Pages built on the old version go stale, and lint names both causes.
    pages = {e["id"]: e for e in call(root, "list-pages")}
    assert pages["concepts/ceramics"]["stale"] is True
    assert "memory_source_drift" in predicates(root, "memory")
    assert "stale_page" in predicates(root, "stale")

    # The impact layer sees the moved research inputs and the inbox folds the
    # cause into the item that already covers that subject.
    audit = call(root, "impact-audit", at="2026-11-14T10:30:00Z")
    assert audit["opened"] == 1
    impacts = call(root, "impact-list")["impacts"]
    assert [r["cause"] for r in impacts] == ["baseline-drift"]
    inbox = {i["kind"]: i for i in call(root, "inbox")["items"]}
    assert inbox["research"]["drift"] == ["baseline-drift"]
    assert "impact" not in inbox, "one subject must not be proposed twice"
    assert any(i["kind"] == "memory-source-stale" for i in inbox.values())
    assert call(root, "stats")["memory"]["drifted"] == 1

    # Clearing the debt: re-commit the page and re-bind the note to new bytes.
    order = call(root, "plan")[0]["id"]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        "---\ntype: concept\ntitle: 陶瓷\nsources: [\"raw/ceramics.md\"]\n---\n第二版：完全不同的内容。\n"
    )
    call(root, "commit", order=order,
         pages=[{"id": "concepts/ceramics", "path": "wiki/concepts/ceramics.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T11:00:00Z")
    call(root, "memory-supersede", id=note["id"], text="第二版内容已核对",
         conditions=["核对官窑资料时"], sources=["raw/ceramics.md"],
         at="2026-11-14T11:30:00Z")
    assert predicates(root, "memory") == set()
    assert not [e for e in call(root, "list-pages") if e["id"] == "concepts/ceramics" and e["stale"]]
    # The research topic is still open, so its drift stays reported.
    assert call(root, "impact-audit", at="2026-11-14T12:00:00Z")["open"] == 1
    call(root, "research-complete", id=call(root, "research-list")[0]["id"],
         sources=["raw/ceramics.md"], at="2026-11-14T12:30:00Z")
    assert call(root, "impact-audit", at="2026-11-14T13:00:00Z")["open"] == 0
    assert call(root, "inbox")["items"] == []

    call(root, "rebuild")
    call(root, "verify")
    print("cross-layer lifecycle: source version, drift, impact and inbox passed")
