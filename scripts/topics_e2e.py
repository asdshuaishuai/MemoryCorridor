#!/usr/bin/env python3
"""Verify topic browsing: synthesis pages are the semantic layer, material pages
are not topics, links and sources are listed, and the view is read-only."""
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


def publish(root, name, title, page_id, body, kind="concept"):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [], "summary": title})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: {kind}\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}"
    )
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-10-26T09:00:00Z")


with tempfile.TemporaryDirectory(prefix="memorycorridor-topics-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷器形与釉色")

    # An empty vault has no topics, and the view writes nothing.
    empty = call(root, "topics")
    assert empty == {"topics": [], "counts": {"topics": 0, "stale": 0, "links": 0},
                     "fingerprint": call(root, "status")["fingerprint"]}

    # Material pages are the layer below topics, not topics themselves.
    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "陶瓷正文。")
    publish(root, "glaze.md", "釉色", "concepts/glaze", "釉色正文。")
    assert call(root, "topics")["topics"] == []

    # A synthesis page becomes the browsable semantic layer.
    suggestion = call(root, "overview-suggest", at="2026-10-26T10:00:00Z")
    call(root, "overview-apply", id=suggestion["id"],
         text="---\ntype: synthesis\ntitle: 陶瓷与釉色\n"
              "sources: [\"raw/ceramics.md\", \"raw/glaze.md\"]\n---\n"
              "综述，见 [[concepts/ceramics]] 与 [[concepts/glaze]]。\n",
         at="2026-10-26T10:30:00Z")
    view = call(root, "topics")
    assert view["counts"] == {"topics": 1, "stale": 0, "links": 2}
    topic = view["topics"][0]
    assert topic["id"] == "overview" and topic["path"] == "wiki/overview.md"
    assert topic["kind"] == "synthesis" and topic["title"] == "陶瓷与釉色"
    assert topic["stale"] is False and topic["stale_sources"] == []
    assert topic["sources"] == ["raw/ceramics.md", "raw/glaze.md"]
    assert topic["links"] == ["concepts/ceramics", "concepts/glaze"]
    assert topic["body_bytes"] > 0 and len(topic["sha256"]) == 64
    # The linked pages are reachable, so a host can go from topic to material.
    for link in topic["links"]:
        page = call(root, "read-page", id=link)
        assert page["entry"]["path"] == f"wiki/{link}.md"
        assert topic["sources"] and page["entry"]["sources"]

    # The view is read-only and deterministic.
    fingerprint = call(root, "status")["fingerprint"]
    assert call(root, "topics") == view
    assert call(root, "status")["fingerprint"] == fingerprint

    # A revoked source is reported per topic instead of silently dropped.
    call(root, "forget", source="raw/ceramics.md", at="2026-10-26T11:00:00Z")
    after = call(root, "topics")
    assert after["counts"] == {"topics": 1, "stale": 1, "links": 2}
    assert after["topics"][0]["stale"] is True
    assert after["topics"][0]["stale_sources"] == ["raw/ceramics.md"]
    assert after["topics"][0]["sources"] == ["raw/glaze.md"]

    # A topic page published through the normal ingest flow joins the layer.
    # overview-apply always rewrites wiki/overview.md, so a second topic has to
    # come from a committed synthesis page.
    publish(root, "kiln.md", "窑口", "concepts/kiln", "窑口正文。")
    publish(root, "kiln2.md", "窑口对照", "synthesis/kiln", "窑口对照，见 [[concepts/kiln]]。",
            kind="synthesis")
    two = call(root, "topics")
    assert [row["id"] for row in two["topics"]] == ["overview", "synthesis/kiln"]
    assert two["counts"]["topics"] == 2
    assert two["counts"]["links"] == 3
    kiln = two["topics"][1]
    assert kiln["title"] == "窑口对照" and kiln["links"] == ["concepts/kiln"]
    assert kiln["sources"] == ["raw/kiln2.md"]
    assert call(root, "topics") == two

    call(root, "rebuild")
    call(root, "verify")
    print("topics: semantic layer, material exclusion, links and stale sources passed")
