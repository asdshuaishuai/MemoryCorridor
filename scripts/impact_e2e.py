#!/usr/bin/env python3
"""Verify change impact for durable work: drift detection, idempotent replay,
auto-resolve, explicit resolve, purpose/page/synthesis drift and lint invariants."""
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


def impacts(root):
    return {row["id"]: row for row in call(root, "impact-list")["impacts"]}


def open_rows(root, kind=None):
    return [r for r in impacts(root).values()
            if r["status"] == "open" and (kind is None or r["kind"] == kind)]


def predicates(root):
    return {row["predicate"] for row in call(root, "lint")["violations"]}


def lint_predicates(root):
    return predicates(root)


def synthesis_text(body):
    sources = ", ".join(f"\"raw/{name}\""
                        for name in sorted(p.name for p in (root / "raw").glob("*.md")))
    return (f"---\ntype: synthesis\ntitle: 全局综述\nsources: [{sources}]\n---\n{body}\n")


def publish(root, name, body, page_id, title):
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
                 "staged": f"staging/{order}/page.md"}], at="2026-10-21T09:00:00Z")


with tempfile.TemporaryDirectory(prefix="memorycorridor-impact-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷器形与釉色")

    # Nothing durable is open yet, so an audit is a no-op and writes nothing.
    first = call(root, "impact-audit", at="2026-10-21T09:30:00Z")
    assert first == {"opened": 0, "updated": 0, "resolved": 0, "replayed": 0, "open": 0,
                     "fingerprint": call(root, "status")["fingerprint"], "committed": False}

    # Publishing the work item itself must not count as drift.
    call(root, "research-topic", topic="陶瓷窑口", queries=["陶瓷 器形"], at="2026-10-21T09:00:00Z")
    quiet = call(root, "impact-audit", at="2026-10-21T09:30:00Z")
    assert quiet["opened"] == 0 and quiet["open"] == 0 and quiet["committed"] is False
    assert call(root, "impact-list")["impacts"] == []

    # New material moves the knowledge inputs the topic was frozen against.
    publish(root, "ceramics.md", "南宋官窑博物馆的器形与釉色记录。\n", "concepts/ceramics", "陶瓷")
    drift = call(root, "impact-audit", at="2026-10-21T10:00:00Z")
    assert drift["opened"] == 1 and drift["committed"] is True
    record = next(iter(impacts(root).values()))
    assert record["kind"] == "research" and record["cause"] == "baseline-drift"
    assert record["status"] == "open" and record["subject_present"] is True
    assert record["frozen"] != record["current"]
    assert record["subject"].startswith("state/research/")

    # More material moves the inputs again, so the record is refreshed in place
    # rather than reopened or duplicated.
    publish(root, "bronze.md", "青铜器记录。\n", "concepts/bronze", "青铜器")
    refreshed = call(root, "impact-audit", at="2026-10-21T10:20:00Z")
    assert refreshed["opened"] == 0 and refreshed["updated"] == 1
    assert refreshed["resolved"] == 0 and refreshed["replayed"] == 0
    assert refreshed["open"] == 1 and refreshed["committed"] is True
    assert len(impacts(root)) == 1
    row = next(iter(impacts(root).values()))
    assert row["status"] == "open" and row["updated_at"] == "2026-10-21T10:20:00Z"
    assert row["created_at"] == "2026-10-21T10:00:00Z"
    assert row["current"] != record["current"]

    # Filing more state must not move the knowledge inputs, so the audit replays.
    call(root, "memory-submit", kind="preference", scope="workspace", text="关注器形",
         conditions=["规划参观时"], sources=[], at="2026-10-21T10:15:00Z", key="shape")
    fingerprint = call(root, "status")["fingerprint"]
    again = call(root, "impact-audit", at="2026-10-21T10:30:00Z")
    assert again["opened"] == 0 and again["replayed"] == 1 and again["committed"] is False
    assert call(root, "status")["fingerprint"] == fingerprint
    assert len(impacts(root)) == 1

    # The audit is a live view: closing the topic resolves the impact.
    topic_id = record["subject"].removeprefix("state/research/").removesuffix(".json")
    call(root, "research-cancel", id=topic_id, at="2026-10-21T11:00:00Z")
    closed = call(root, "impact-audit", at="2026-10-21T11:30:00Z")
    assert closed["resolved"] == 1 and closed["open"] == 0
    row = next(iter(impacts(root).values()))
    assert row["status"] == "resolved" and row["resolved_at"] == "2026-10-21T11:30:00Z"
    assert call(root, "impact-audit", at="2026-10-21T11:45:00Z")["resolved"] == 0

    # A resolved impact reopens when the same drift returns.
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色"], at="2026-10-21T12:00:00Z")
    publish(root, "glaze.md", "釉色对照记录。\n", "concepts/glaze", "釉色")
    reopened = call(root, "impact-audit", at="2026-10-21T12:30:00Z")
    assert reopened["opened"] == 1 and reopened["open"] == 1
    assert len(open_rows(root, "research")) == 1

    # A pending overview suggestion drifts when the pages it froze move.
    overview = call(root, "overview-suggest", at="2026-10-21T12:45:00Z")
    assert call(root, "impact-audit", at="2026-10-21T13:00:00Z")["opened"] == 0
    publish(root, "kiln.md", "窑口对照记录。\n", "concepts/kiln", "窑口")
    assert call(root, "impact-audit", at="2026-10-21T13:15:00Z")["opened"] >= 1
    page_rows = open_rows(root, "overview-suggestion")
    assert len(page_rows) == 1 and page_rows[0]["cause"] == "page-drift"
    assert page_rows[0]["subject"].endswith(overview["id"] + ".json")
    # A stale suggestion cannot be applied, so the host re-freezes or resolves it.
    call(root, "overview-apply", id=overview["id"], text=synthesis_text("结论"),
         at="2026-10-21T13:20:00Z", error="overview_suggestion_stale")
    call(root, "impact-resolve", id=page_rows[0]["id"], note="重新生成综述",
         at="2026-10-21T13:25:00Z")
    assert open_rows(root, "overview-suggestion") == []
    fresh = call(root, "overview-suggest", at="2026-10-21T13:30:00Z")
    call(root, "overview-apply", id=fresh["id"], text=synthesis_text("陶瓷与釉色的研究结论。"),
         at="2026-10-21T13:45:00Z")
    assert open_rows(root, "overview-suggestion") == []
    assert open_rows(root, "overview-synthesis") == []

    # A published synthesis edited outside the engine is reported once, and a
    # newer applied suggestion clears it instead of piling up records.
    assert open_rows(root, "overview-synthesis") == []
    (root / "wiki/overview.md").write_text(synthesis_text("人工改写的结论。"))
    call(root, "refresh")
    assert call(root, "impact-audit", at="2026-10-21T14:00:00Z")["opened"] >= 1
    synthesis = open_rows(root, "overview-synthesis")
    assert len(synthesis) == 1 and synthesis[0]["cause"] == "synthesis-drift"
    assert synthesis[0]["subject"] == "wiki/overview.md"
    assert synthesis[0]["frozen"] != synthesis[0]["current"]
    # Identical inputs replay the applied record, so a new run needs its own key.
    suggestion = call(root, "overview-suggest", at="2026-10-21T14:00:00Z", key="overview-rerun")
    call(root, "overview-apply", id=suggestion["id"], text=synthesis_text("重新发布的结论。"),
         at="2026-10-21T14:15:00Z")
    assert call(root, "impact-audit", at="2026-10-21T14:30:00Z")["resolved"] >= 1
    assert open_rows(root, "overview-synthesis") == []

    # A host that dealt with a stranded work item closes its impact explicitly.
    call(root, "research-topic", topic="陶瓷断代", queries=["断代"], at="2026-10-21T14:30:00Z")
    publish(root, "dating.md", "断代依据记录。\n", "concepts/dating", "断代")
    assert call(root, "impact-audit", at="2026-10-21T14:45:00Z")["opened"] >= 1
    stranded = open_rows(root, "research")
    assert len(stranded) == 2  # the earlier glaze topic and the new dating topic
    dating = [r for r in stranded if r["created_at"] == "2026-10-21T14:45:00Z"]
    assert len(dating) == 1
    call(root, "impact-resolve", id=dating[0]["id"], note="改由人工跟踪", at="2026-10-21T15:00:00Z")
    assert len(open_rows(root, "research")) == 1
    replay = call(root, "impact-resolve", id=dating[0]["id"], note="改由人工跟踪",
                  at="2026-10-21T15:00:00Z")
    assert replay["replayed"] is True
    # Resolved drift does not come back unless the inputs move again.
    assert call(root, "impact-audit", at="2026-10-21T15:30:00Z")["resolved"] == 0
    remaining = open_rows(root, "research")
    assert len(remaining) == 1 and remaining[0]["id"] != dating[0]["id"]
    call(root, "impact-resolve", id=remaining[0]["id"], note="继续跟踪釉色线索",
         at="2026-10-21T15:45:00Z")
    assert open_rows(root, "research") == []

    # The abandoned overview suggestion is still proposed, so its drift stays
    # debt that reopens whenever the knowledge inputs move again.
    debt = open_rows(root, "overview-suggestion")
    assert len(debt) == 1 and debt[0]["subject"].endswith(overview["id"] + ".json")
    assert debt[0]["dismissed"] is None
    call(root, "impact-resolve", id=debt[0]["id"], note="放弃该轮综述", at="2026-10-21T16:00:00Z")
    # A host decision against these exact inputs is not reported again.
    assert call(root, "impact-audit", at="2026-10-21T16:15:00Z")["resolved"] == 0
    assert open_rows(root, "overview-suggestion") == []
    # New material is a material change, so the same debt comes back.
    publish(root, "extra.md", "补充记录。\n", "concepts/extra", "补充")
    assert call(root, "impact-audit", at="2026-10-21T16:30:00Z")["opened"] >= 1
    assert len(open_rows(root, "overview-suggestion")) == 1
    for row in open_rows(root):
        call(root, "impact-resolve", id=row["id"], note="收尾", at="2026-10-21T16:45:00Z")
    assert open_rows(root) == []

    # stats and lint stay consistent with the ledger.
    summary = call(root, "stats")["impacts"]
    assert summary["total"] == len(impacts(root))
    assert summary["open"] == len(open_rows(root))
    assert "impact_no_drift" not in predicates(root)
    assert "impact_subject_missing" not in predicates(root)

    # Malformed requests never reach the vault.
    before = call(root, "status")["fingerprint"]
    call(root, "impact-audit", at="short", error="impact_time_invalid")
    call(root, "impact-audit", at="2026-10-21T16:00:00Z", key="a\nb",
         error="impact_idempotency_key_invalid")
    call(root, "impact-resolve", id="not-a-hash", note="x", at="2026-10-21T16:00:00Z",
         error="invalid_impact_id")
    call(root, "impact-resolve", id=next(iter(impacts(root))), note="", at="2026-10-21T16:00:00Z",
         error="impact_note_invalid")
    assert call(root, "status")["fingerprint"] == before

    # Impact records are durable state, so they survive a deterministic pack
    # round trip with every transition state intact: open, host-resolved with a
    # dismissal digest, and auto-resolved.
    call(root, "research-topic", topic="陶瓷釉色对照", queries=["釉色 对照"],
         at="2026-10-21T17:00:00Z")
    call(root, "research-topic", topic="陶瓷断代", queries=["断代"], at="2026-10-21T17:15:00Z")
    publish(root, "batch.md", "批量变化记录。\n", "concepts/batch", "批量")
    # One audit writes several records in a single transaction.
    batch = call(root, "impact-audit", at="2026-10-21T17:30:00Z")
    assert batch["opened"] >= 2 and batch["committed"] is True
    assert len(open_rows(root)) >= 3
    # A host decision taken now, with no further input change, stays closed and
    # carries the inputs it was made against.
    stranded = sorted(open_rows(root), key=lambda r: r["id"])[0]
    call(root, "impact-resolve", id=stranded["id"], note="交由人工跟踪",
         at="2026-10-21T17:45:00Z")
    rows = impacts(root)
    dismissed = [r for r in rows.values() if r["status"] == "resolved" and r["dismissed"]]
    assert dismissed, "a host decision must carry the inputs it was made against"
    auto = [r for r in rows.values() if r["status"] == "resolved" and not r["dismissed"]]
    assert auto, "an engine-closed record must not claim a host decision"
    # A host decision taken against these exact inputs stays closed on the next
    # audit, and it keeps the digest it was made against. This regressed once:
    # the suppression was hardcoded to `false`, so re-auditing reopened the
    # record and cleared `dismissed`, silently discarding the human decision.
    quiet = call(root, "impact-audit", at="2026-10-21T17:50:00Z")
    assert quiet["opened"] == 0 and quiet["replayed"] >= 1, quiet
    assert quiet["committed"] is False, quiet
    kept = impacts(root)[stranded["id"]]
    assert kept["status"] == "resolved" and kept["dismissed"], kept
    fingerprint = call(root, "status")["fingerprint"]
    inbox_before = call(root, "inbox")["items"]

    call(root, "pack", output="exports/impacts.mcpack")
    target = root / "restored-impacts"
    (target / "imports").mkdir(parents=True, exist_ok=True)
    (target / "imports/impacts.mcpack").write_bytes(
        (root / "exports/impacts.mcpack").read_bytes())
    unpacked = call(target, "unpack", file="imports/impacts.mcpack")
    assert unpacked["vault_fingerprint"] == fingerprint
    assert call(target, "impact-list")["impacts"] == call(root, "impact-list")["impacts"]
    assert call(target, "inbox")["items"] == inbox_before
    restored = {row["id"]: row for row in call(target, "impact-list")["impacts"]}
    assert {r["status"] for r in restored.values()} == {"open", "resolved"}
    assert [r for r in restored.values() if r["dismissed"]]
    assert [r for r in restored.values() if not r["dismissed"]]
    call(target, "rebuild")
    call(target, "verify")
    # The restored vault keeps the same decisions: a dismissed impact stays
    # closed and does not come back on the next audit. Both directions matter --
    # asserting only `resolved == 0` would pass even if the suppression were
    # dropped and the record reopened, which is exactly the regression that
    # `suppressed = false` caused.
    replay = call(target, "impact-audit", at="2026-10-21T18:00:00Z")
    assert replay["resolved"] == 0, replay
    assert replay["opened"] == 0, replay
    assert replay["replayed"] >= 1, replay
    assert replay["committed"] is False, replay
    survived = {row["id"]: row for row in call(target, "impact-list")["impacts"]}
    assert survived[stranded["id"]]["status"] == "resolved", survived[stranded["id"]]
    assert survived[stranded["id"]]["dismissed"], survived[stranded["id"]]

    # New material moves the inputs again, so the same work reopens -- a refusal
    # is a stale read, not a permanent suppression. Checked after the round trip
    # so the dismissed record it reopens is the one that survived packing.
    publish(root, "later.md", "更晚的材料。\n", "concepts/later", "更晚")
    moved = call(root, "impact-audit", at="2026-10-21T18:10:00Z")
    assert moved["opened"] >= 1, moved
    assert [r for r in impacts(root).values() if r["status"] == "open"], \
        "new inputs must reopen resolved drift"

    # Every op reached directly from dispatch must refuse an externally edited
    # record. `impact-list` lost that guarantee when its row helper stopped
    # verifying internally, and no test caught it until a mutation was added.
    target_record = next(iter(impacts(root).values()))
    record_path = root / "state/impacts" / (target_record["id"] + ".json")
    registered = record_path.read_text()
    tampered = json.loads(registered)
    tampered["detail"] = "被外部篡改的 detail"
    record_path.write_text(json.dumps(tampered, ensure_ascii=False, separators=(",", ":")))
    for op in ["impact-list", "status", "stats", "inbox"]:
        call(root, op, error="content_changed")
    assert "content_hash_drift" in lint_predicates(root)
    # Restoring the registered bytes makes the reads work again.
    record_path.write_text(registered)
    assert call(root, "impact-list")["impacts"] != []
    call(root, "rebuild")
    call(root, "verify")
    print("change impact: drift detection, replay, resolve and reopen passed")
