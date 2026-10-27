#!/usr/bin/env python3
"""Verify the inbox aggregates every piece of durable work a host must act on,
stays deterministic and read-only, and empties as the work is finished."""
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


def inbox(root):
    return call(root, "inbox")["items"]


def kinds(root):
    return [row["kind"] for row in inbox(root)]


def publish(root, name, body, page_id, title):
    (root / "raw" / name).write_text(body)
    created = call(root, "scan")["orders"]
    order = created[0] if created else next(
        row["id"] for row in call(root, "plan") if row["source"] == f"raw/{name}")
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
                 "staged": f"staging/{order}/page.md"}], at="2026-10-23T09:00:00Z")


def synthesis_text(sources, body):
    listed = ", ".join('"' + path + '"' for path in sources)
    return f"---\ntype: synthesis\ntitle: 全局综述\nsources: [{listed}]\n---\n{body}\n"


with tempfile.TemporaryDirectory(prefix="memorycorridor-inbox-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷器形与釉色")

    # A fresh vault has nothing worth proposing.
    assert inbox(root) == []
    assert call(root, "inbox")["counts"] == {"total": 0, "by_kind": []}

    # Unregistered material is the cheapest item to clear.
    (root / "raw/ceramics.md").write_text("南宋官窑博物馆的器形与釉色记录。\n")
    unscanned = inbox(root)
    assert kinds(root) == ["unscanned-source"]
    assert unscanned[0]["subject"] == "raw/ceramics.md"
    assert unscanned[0]["next"] == "scan"
    call(root, "scan")
    assert inbox(root) == []

    # Publishing knowledge leaves the inbox empty: the work order is transient.
    publish(root, "ceramics.md", "南宋官窑博物馆的器形与釉色记录。\n",
            "concepts/ceramics", "陶瓷")
    assert inbox(root) == []

    # Durable work shows up as soon as it exists.
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
         at="2026-10-23T10:00:00Z")
    goal = call(root, "purpose-suggest", at="2026-10-23T10:15:00Z")
    overview = call(root, "overview-suggest", at="2026-10-23T10:30:00Z")
    found = {row["kind"]: row for row in inbox(root)}
    assert set(found) == {"research", "purpose-suggestion", "overview-suggestion"}
    assert found["research"]["subject"] == "state/research/" + call(root, "research-list")[0]["id"] + ".json"
    assert found["research"]["next"].startswith("research-complete")
    assert found["purpose-suggestion"]["subject"] == goal["path"]
    assert found["purpose-suggestion"]["next"] == "purpose-apply after human confirmation"
    assert found["overview-suggestion"]["subject"] == overview["path"]
    assert found["overview-suggestion"]["next"] == "overview-apply after human confirmation"

    # Change impact joins the inbox once the frozen inputs move.
    publish(root, "glaze.md", "釉色对照记录。\n", "concepts/glaze", "釉色")
    call(root, "impact-audit", at="2026-10-23T11:00:00Z")
    # Drift is never proposed twice: the cause rides on the item that already
    # covers the subject instead of becoming a second entry.
    assert [row for row in inbox(root) if row["kind"] == "impact"] == []
    by_kind = {row["kind"]: row for row in inbox(root)}
    assert by_kind["research"]["drift"] == ["baseline-drift"]
    assert by_kind["overview-suggestion"]["drift"] == ["page-drift"]

    # Competing memory judgments are confirmation debt and belong here too.
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先看陶瓷窑口", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-23T11:15:00Z", key="trip-ceramics")
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先看青铜器", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-23T11:20:00Z", key="trip-bronze")
    conflicts = [row for row in inbox(root) if row["kind"] == "memory-conflict"]
    assert len(conflicts) == 1
    assert conflicts[0]["reason"] == "conditions-overlap"
    assert conflicts[0]["next"].startswith("memory-supersede")
    assert conflicts[0]["subject"].count("state/memory/") == 2
    loser = [r for r in call(root, "memory-list")["notes"]
             if r["key"] == "trip-bronze" and r["status"] == "active"][0]
    call(root, "memory-archive", id=loser["id"], at="2026-10-23T11:45:00Z")
    assert [row for row in inbox(root) if row["kind"] == "memory-conflict"] == []

    # A memory note whose bound source is revoked keeps its history but can no
    # longer be checked, so it is confirmation debt too.
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="官窑记录来自已登记的来源，可作为参观时的核对依据",
         conditions=["核对官窑资料时"], sources=["raw/ceramics.md"],
         at="2026-10-23T11:25:00Z", key="ceramics-evidence")
    assert [row for row in inbox(root) if row["kind"] == "memory-source-stale"] == []
    call(root, "forget", source="raw/ceramics.md", at="2026-10-23T11:30:00Z")
    stale = [row for row in inbox(root) if row["kind"] == "memory-source-stale"]
    assert len(stale) == 1
    assert stale[0]["reason"] == "source-revoked-or-drifted"
    assert stale[0]["next"].startswith("restore the source, or memory-supersede")
    assert stale[0]["subject"].startswith("state/memory/")
    note = [r for r in call(root, "memory-list")["notes"]
            if r["key"] == "ceramics-evidence" and r["status"] == "active"][0]
    assert stale[0]["subject"] == "state/memory/" + note["id"] + ".json"
    # Re-binding the note to a live source clears the item.
    call(root, "memory-supersede", id=note["id"], text="官窑记录已无法核对，仅保留判断本身",
         conditions=["核对官窑资料时"], sources=[], at="2026-10-23T11:40:00Z")
    assert [row for row in inbox(root) if row["kind"] == "memory-source-stale"] == []

    # A revoked source invalidates a page, which becomes its own item.
    call(root, "forget", source="raw/ceramics.md", at="2026-10-23T11:30:00Z")
    stale = {row["subject"]: row for row in inbox(root) if row["kind"] == "stale-page"}
    # The revoked source also invalidates the generated source-summary page.
    assert set(stale) == {"concepts/ceramics", "sources/7b66db90bc7bcf023abec1c96c6d7bb8e282161173efc874e6693c133907c7b4"}
    assert stale["concepts/ceramics"]["reason"] == "page-invalidated"

    # HumanGate review debt raised by quality-audit is listed too.
    call(root, "quality-audit", at="2026-10-23T12:00:00Z")
    reviews = [row for row in inbox(root) if row["kind"] == "review"]
    assert reviews and all(row["next"].startswith("review-resolve") for row in reviews)
    pending = {row["id"] for row in call(root, "review-list")
               if row["status"] == "pending"}
    assert {row["subject"] for row in reviews} == {"state/reviews/" + i + ".json" for i in pending}

    # The listing is read-only and deterministically ordered.
    fingerprint = call(root, "status")["fingerprint"]
    first = inbox(root)
    assert inbox(root) == first
    assert call(root, "status")["fingerprint"] == fingerprint
    assert [row["kind"] for row in first] == sorted(row["kind"] for row in first)
    counts = call(root, "inbox")["counts"]
    assert counts["total"] == len(first)
    assert sum(n for _, n in counts["by_kind"]) == counts["total"]

    # Finishing the work empties the inbox. A suggestion whose baseline moved
    # can no longer be applied, so it is cancelled and its record is kept.
    topic = call(root, "research-list")[0]["id"]
    (root / "raw/research").mkdir(parents=True, exist_ok=True)
    (root / "raw/research/gap.md").write_text("釉色对照的补充材料。\n")
    call(root, "scan")
    call(root, "research-complete", id=topic, sources=["raw/research/gap.md"],
         at="2026-10-23T13:00:00Z")
    call(root, "purpose-cancel", id=goal["id"], at="2026-10-23T13:10:00Z")
    assert call(root, "purpose-cancel", id=goal["id"], at="2026-10-23T13:10:00Z")["replayed"]
    call(root, "overview-cancel", id=overview["id"], at="2026-10-23T13:15:00Z")
    assert call(root, "purpose-apply", id=goal["id"], text="研究陶瓷与釉色",
                at="2026-10-23T13:20:00Z", error="suggestion_terminal")
    fresh_goal = call(root, "purpose-suggest", at="2026-10-23T13:25:00Z", key="goal-final")
    call(root, "purpose-apply", id=fresh_goal["id"], text="研究陶瓷与釉色",
         at="2026-10-23T13:30:00Z")
    fresh_overview = call(root, "overview-suggest", at="2026-10-23T13:35:00Z", key="overview-final")
    # Only still-active sources may back the synthesis; ceramics.md is revoked
    # at this point and stays revoked until the final re-registration.
    call(root, "overview-apply", id=fresh_overview["id"],
         text=synthesis_text(["raw/glaze.md", "raw/research/gap.md"], "综述结论。"),
         at="2026-10-23T13:40:00Z")
    call(root, "impact-audit", at="2026-10-23T13:45:00Z")
    call(root, "impact-audit", at="2026-10-23T13:50:00Z")
    for row in call(root, "review-list"):
        if row["status"] == "pending":
            call(root, "review-resolve", id=row["id"], action="skip", note="本轮跳过",
                 at="2026-10-23T14:00:00Z")
    # Re-registering the revoked source gives it a new version, so the pages
    # built against the old one stay invalid until they are committed again.
    (root / "raw/ceramics.md").write_text("重新登记的来源。\n")
    call(root, "scan")
    remaining = inbox(root)
    assert {row["kind"] for row in remaining} == {"stale-page"}
    assert {row["subject"] for row in remaining} == {
        "concepts/ceramics",
        "sources/7b66db90bc7bcf023abec1c96c6d7bb8e282161173efc874e6693c133907c7b4",
    }
    publish(root, "ceramics.md", "重新登记的来源。\n", "concepts/ceramics", "陶瓷")
    assert "concepts/ceramics" not in {row["subject"] for row in inbox(root)}
    call(root, "rebuild")
    call(root, "verify")
    assert all(row["kind"] == "stale-page" for row in inbox(root))

    # The other half of "never proposed twice": a subject with no dedicated item
    # of its own must still surface, as its own `impact` entry. The folding above
    # only applies when something already covers the subject, so a synthesis page
    # edited outside the engine has nowhere to ride and must appear standalone.
    published = (root / "wiki/overview.md").read_text(encoding="utf-8")
    (root / "wiki/overview.md").write_text(published.replace("综述结论。", "外部编辑过的综述。"))
    call(root, "refresh")
    drifted = call(root, "impact-audit", at="2026-10-23T15:00:00Z")
    assert drifted["opened"] >= 1, drifted
    rows = {row["kind"]: row for row in inbox(root)}
    assert "impact" in rows, sorted(rows)
    assert rows["impact"]["subject"] == "wiki/overview.md"
    assert rows["impact"]["reason"] == "synthesis-drift"
    # One subject, one entry: the audit is a live view, not a log.
    assert sum(1 for row in inbox(root) if row["kind"] == "impact") == 1
    assert call(root, "impact-audit", at="2026-10-23T15:05:00Z")["opened"] == 0
    assert sum(1 for row in inbox(root) if row["kind"] == "impact") == 1
    print("inbox: aggregation, determinism, read-only and drain passed")
