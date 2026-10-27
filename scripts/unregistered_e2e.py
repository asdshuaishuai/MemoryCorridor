#!/usr/bin/env python3
"""Verify unregistered managed files are reported: state/, wiki/ and vectors/
hold data the catalog does not know about, so nothing reads, verifies, searches
or packs it. Directory-driven and pending-work locations stay unflagged."""
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


def orphans(root):
    return [row["path"] for row in call(root, "lint")["violations"]
            if row["predicate"] == "file_unregistered"]


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
                 "staged": f"staging/{order}/page.md"}], at="2026-10-28T09:00:00Z")


with tempfile.TemporaryDirectory(prefix="memorycorridor-unregistered-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷")
    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "陶瓷正文。")
    call(root, "rebuild")
    # A healthy vault, including the engine-maintained wiki views, is clean.
    assert call(root, "lint")["status"] == "clean", call(root, "lint")["violations"]
    assert orphans(root) == []
    assert call(root, "verify")["cache"] == "valid"

    # Unreachable data in the three catalog-driven directories.
    (root / "wiki/stray.md").write_text(
        "---\ntype: concept\ntitle: 游离页\nsources: [\"raw/ceramics.md\"]\n---\n正文。\n")
    (root / "vectors/stray.json").write_text(
        '{"page":"concepts/ceramics","sha256":"' + "0" * 64 +
        '","space":{"id":"s","dimensions":1},"values":[1.0]}')
    (root / "state/events/stray.json").write_text('{"op":"forget"}')
    found = orphans(root)
    assert sorted(found) == ["state/events/stray.json", "vectors/stray.json",
                             "wiki/stray.md"], found
    rows = {row["path"]: row for row in call(root, "lint")["violations"]
            if row["predicate"] == "file_unregistered"}
    for row in rows.values():
        assert row["severity"] == "error"
        assert row["fix"].startswith("remove the orphan file")

    # Directory-driven and pending-work locations are deliberately not flagged.
    (root / "views/stray.mbt.md").write_text("# 游离视图\n")
    (root / "raw/stray.md").write_text("未登记来源\n")
    assert orphans(root) == sorted(found)
    # Pending material is work, reported by the inbox rather than as damage.
    assert "unscanned-source" in {row["kind"] for row in call(root, "inbox")["items"]}
    # Staging is recoverable input, so it stays out of the check as well.
    assert not any(path.startswith("staging/") for path in orphans(root))

    for path in ["wiki/stray.md", "vectors/stray.json", "state/events/stray.json",
                 "views/stray.mbt.md", "raw/stray.md"]:
        (root / path).unlink()
    assert orphans(root) == []
    assert call(root, "lint")["status"] == "clean"
    call(root, "rebuild")
    call(root, "verify")
    print("unregistered files: state/wiki/vectors flagged, views/raw/staging exempt passed")
