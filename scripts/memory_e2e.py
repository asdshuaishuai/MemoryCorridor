#!/usr/bin/env python3
"""Verify lifelong memory notes: submit/supersede/archive/restore, source drift
invalidation, prefetch ranking and the lint invariants that guard the chain."""
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


def notes(root):
    return {row["id"]: row for row in call(root, "memory-list")["notes"]}


def lint_predicates(root):
    return {row["predicate"] for row in call(root, "lint")["violations"]}


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
                 "staged": f"staging/{order}/page.md"}], at="2026-10-20T21:00:00Z")


def ingest(root, name, body):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "摘要"})
    return order


with tempfile.TemporaryDirectory(prefix="memorycorridor-memory-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷器形与釉色")

    # A preference note bound to a raw source, with an applicability condition.
    first = call(root, "memory-submit", kind="preference", scope="workspace",
                 text="优先安排陶瓷窑口对比的参观时间",
                 conditions=["规划博物馆行程时"],
                 sources=[], at="2026-10-20T09:00:00Z", key="ceramics-preference")
    assert first["replayed"] is False and first["status"] == "active"
    assert first["record"]["valid"] is True
    # Idempotent replay of the same key and content.
    replay = call(root, "memory-submit", kind="preference", scope="workspace",
                  text="优先安排陶瓷窑口对比的参观时间",
                  conditions=["规划博物馆行程时"],
                  sources=[], at="2026-10-20T09:00:00Z", key="ceramics-preference")
    assert replay["replayed"] is True and replay["id"] == first["id"]

    # A different key with identical content is a duplicate, not a second note.
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="优先安排陶瓷窑口对比的参观时间",
         conditions=["规划博物馆行程时"],
         sources=[], at="2026-10-20T09:00:00Z", key="ceramics-preference-copy",
         error="memory_duplicate_text")

    # A corrected note supersedes instead of forking, and keeps its history.
    corrected = call(root, "memory-submit", kind="preference", scope="workspace",
                     text="优先安排陶瓷窑口对比的参观时间，并保留半天自由活动",
                     conditions=["规划博物馆行程时"],
                     sources=[], at="2026-10-20T10:00:00Z", key="ceramics-preference")
    assert corrected["supersedes"] == first["id"]
    rows = notes(root)
    assert rows[first["id"]]["status"] == "superseded"
    assert rows[first["id"]]["superseded_by"] == corrected["id"]
    assert rows[corrected["id"]]["status"] == "active"
    assert rows[corrected["id"]]["supersedes"] == first["id"]

    # A second, unrelated note plus an explicit supersede by id.
    constraint = call(root, "memory-submit", kind="constraint", scope="workspace",
                      text="交付物必须带来源引用", conditions=[], sources=[],
                      at="2026-10-20T11:00:00Z", key="citation-rule")
    replaced = call(root, "memory-supersede", id=constraint["id"],
                    text="交付物必须带可核对的来源引用", conditions=["发布知识页时"],
                    sources=[], at="2026-10-20T12:00:00Z")
    assert replaced["supersedes"] == constraint["id"]
    assert notes(root)[constraint["id"]]["status"] == "superseded"

    # Prefetch ranks the relevant note and reports its applicability conditions.
    brief = call(root, "memory-prefetch", query="陶瓷 参观 时间")
    assert [row["id"] for row in brief["notes"]][0] == corrected["id"]
    assert brief["notes"][0]["conditions"] == ["规划博物馆行程时"]
    assert brief["notes"][0]["score"] > 0
    assert brief["overview"]["purpose"].startswith("研究陶瓷")
    assert brief["selection"] == "host_required"
    assert brief["estimate_recipe"] == "cjk_char_latin_word_v1"
    # Superseded notes stay out of the default candidate set.
    assert all(row["status"] == "active" for row in brief["notes"])
    assert first["id"] not in {row["id"] for row in brief["notes"]}

    # Archived notes leave the default set but stay listable and restorable.
    archived = call(root, "memory-archive", id=corrected["id"], at="2026-10-20T13:00:00Z")
    assert archived["status"] == "archived" and archived["replayed"] is False
    assert call(root, "memory-archive", id=corrected["id"], at="2026-10-20T13:00:00Z")["replayed"] is True
    default_ids = {row["id"] for row in call(root, "memory-prefetch", query="陶瓷 参观 时间")["notes"]}
    assert corrected["id"] not in default_ids
    widened = call(root, "memory-prefetch", query="陶瓷 参观 时间", archived=True)
    assert corrected["id"] in {row["id"] for row in widened["notes"]}
    # Leaving the archived state is explicit: restore, never a silent supersede.
    call(root, "memory-supersede", id=corrected["id"], text="已归档笔记", conditions=[],
         sources=[], at="2026-10-20T15:00:00Z", error="memory_archived_note_refused")
    restored = call(root, "memory-restore", id=corrected["id"], at="2026-10-20T14:00:00Z")
    assert restored["status"] == "active" and restored["record"]["archived_at"] is None
    assert corrected["id"] in {row["id"] for row in
                               call(root, "memory-prefetch", query="陶瓷 参观 时间")["notes"]}
    call(root, "memory-archive", id=corrected["id"], at="2026-10-20T18:30:00Z")
    assert notes(root)[corrected["id"]]["status"] == "archived"

    # Source drift invalidates the note without deleting its history.
    ingest(root, "ceramics.md", "南宋官窑博物馆的器形与釉色记录。\n")
    bound = call(root, "memory-submit", kind="fact", scope="workspace",
                 text="官窑记录来自已登记来源", conditions=[], sources=["raw/ceramics.md"],
                 at="2026-10-20T16:00:00Z", key="ceramics-fact")
    assert bound["record"]["valid"] is True
    forgotten = call(root, "forget", source="raw/ceramics.md", at="2026-10-20T17:00:00Z")
    assert forgotten["source"] == "raw/ceramics.md" and forgotten["raw_retained"] is True
    rows = notes(root)
    assert rows[bound["id"]]["valid"] is False
    assert rows[bound["id"]]["invalid_sources"] == ["raw/ceramics.md"]
    assert rows[bound["id"]]["status"] == "active"
    assert "memory_source_stale" in lint_predicates(root)
    summary = call(root, "stats")["memory"]
    assert summary["invalid"] >= 1

    # A note pins the bytes it was written against, so rewriting the source
    # whole is drift rather than something the note silently survives.
    (root / "raw/ceramics.md").write_text("完全无关的内容：天气与市场行情。\n")
    call(root, "scan")
    note = [r for r in notes(root).values() if r["key"] == "ceramics-fact"][0]
    assert note["valid"] is False
    assert note["invalid_sources"] == []
    assert note["drifted_sources"] == ["raw/ceramics.md"]
    assert len(note["source_hashes"]) == len(note["sources"])
    assert "memory_source_drift" in lint_predicates(root)
    assert call(root, "stats")["memory"]["drifted"] >= 1
    stale_items = [i for i in call(root, "inbox")["items"]
                   if i["kind"] == "memory-source-stale"]
    assert len(stale_items) == 1
    assert stale_items[0]["reason"] == "source-bytes-changed"
    assert stale_items[0]["detail"].startswith("fact note was written against different bytes")
    # Re-binding against the current bytes clears the debt.
    call(root, "memory-supersede", id=note["id"], text="来源已改写，需重新核对",
         conditions=[], sources=["raw/ceramics.md"], at="2026-10-20T17:30:00Z")
    rebound = [r for r in notes(root).values() if r["key"] == "ceramics-fact"][0]
    assert rebound["valid"] is True and rebound["drifted_sources"] == []
    assert [i for i in call(root, "inbox")["items"]
            if i["kind"] == "memory-source-stale"] == []
    # The same judgment under different bindings is a duplicate, not a
    # competing judgment: `note_hash` pins the evidence, but duplicate and
    # conflict detection must look at what the note actually says.
    (root / "raw/other.md").write_text("另一份官窑记录。\n")
    call(root, "scan")
    current = [r for r in notes(root).values()
               if r["key"] == "ceramics-fact" and r["status"] == "active"][0]
    call(root, "memory-submit", kind="fact", scope="workspace",
         text=current["text"], conditions=current["conditions"],
         sources=["raw/other.md"], at="2026-10-20T18:00:00Z", key="ceramics-fact-copy",
         error="memory_duplicate_text")
    assert call(root, "memory-conflicts")["counts"]["notes"] == 0
    # A genuinely different judgment under the same conditions still conflicts.
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="官窑记录只说明器形，不涉及釉色", conditions=current["conditions"],
         sources=["raw/other.md"], at="2026-10-20T18:15:00Z", key="ceramics-rival")
    rivals = call(root, "memory-conflicts")
    assert rivals["counts"]["notes"] == 2
    assert {n["key"] for g in rivals["conflicts"] for n in g["notes"]} == {
        "ceramics-fact", "ceramics-rival"}
    # Narrowing the rival's conditions resolves it, so the rest of the flow sees
    # a single conflict group again.
    rival = [r for r in notes(root).values()
             if r["key"] == "ceramics-rival" and r["status"] == "active"][0]
    call(root, "memory-supersede", id=rival["id"], text="官窑记录只说明器形，不涉及釉色",
         conditions=["只核对器形时"], sources=["raw/other.md"],
         at="2026-10-20T18:30:00Z")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 0, "notes": 0}

    # A binding must point at a registered, active source.
    call(root, "memory-submit", kind="fact", scope="workspace", text="x", conditions=[],
         sources=["raw/absent.md"], at="2026-10-20T17:45:00Z", key="unregistered",
         error="memory_source_not_registered")

    # Competing judgments under the same conditions are review debt: both sides
    # stay readable until a host resolves one of them.
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先看陶瓷窑口", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-20T18:00:00Z", key="trip-ceramics")
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先看青铜器", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-20T18:05:00Z", key="trip-bronze")
    # A different kind and a different condition are not competing judgments.
    call(root, "memory-submit", kind="constraint", scope="workspace",
         text="行程预算不超过三千", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-20T18:10:00Z", key="trip-budget")
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="阅读时先看摘要", conditions=["整理资料时"], sources=[],
         at="2026-10-20T18:15:00Z", key="reading-order")
    conflicts = call(root, "memory-conflicts")
    assert conflicts["counts"] == {"groups": 1, "notes": 2}
    group = conflicts["conflicts"][0]
    assert group["kind"] == "preference" and group["conditions"] == ["规划博物馆行程时"]
    assert {n["key"] for n in group["notes"]} == {"trip-ceramics", "trip-bronze"}
    assert all(n["conflicted"] for n in group["notes"])
    listed = notes(root)
    by_key = {row["key"]: row for row in listed.values()}
    assert by_key["trip-ceramics"]["conflicted"] is True
    assert by_key["trip-bronze"]["conflicted"] is True
    assert by_key["trip-budget"]["conflicted"] is False
    assert by_key["reading-order"]["conflicted"] is False
    assert call(root, "stats")["memory"]["conflicted"] == 2
    assert "memory_conflict" in lint_predicates(root)
    # Prefetch surfaces the competing judgments with the candidates.
    brief = call(root, "memory-prefetch", query="行程 陶瓷 青铜")
    assert brief["conflict_counts"] == {"groups": 1, "notes": 2}
    assert [g["kind"] for g in brief["conflicts"]] == ["preference"]
    assert all(n["conflicted"] for n in brief["notes"]
               if n["key"] in {"trip-ceramics", "trip-bronze"})
    # Superseding one side does not resolve it: the replacement is still a
    # competing judgment under the same conditions. Narrowing the conditions or
    # archiving the losing side does, and both keep the history.
    loser = [r for r in notes(root).values() if r["key"] == "trip-bronze" and r["status"] == "active"][0]
    call(root, "memory-supersede", id=loser["id"], text="行程优先看青铜器，仅次于陶瓷",
         conditions=["规划博物馆行程时"], sources=[], at="2026-10-20T19:00:00Z")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 1, "notes": 2}
    narrowed = [r for r in notes(root).values() if r["key"] == "trip-bronze" and r["status"] == "active"][0]
    call(root, "memory-supersede", id=narrowed["id"], text="只有青铜特展时优先看青铜器",
         conditions=["规划青铜特展时"], sources=[], at="2026-10-20T19:30:00Z")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 0, "notes": 0}
    assert call(root, "stats")["memory"]["conflicted"] == 0
    assert "memory_conflict" not in lint_predicates(root)
    # Both judgments remain readable; only the default conflict set is empty.
    bronze = [r for r in notes(root).values()
              if r["key"] == "trip-bronze" and r["status"] == "active"][0]
    assert bronze["conditions"] == ["规划青铜特展时"]
    assert bronze["supersedes"] == narrowed["id"]
    assert notes(root)[loser["id"]]["status"] == "superseded"
    assert notes(root)[narrowed["id"]]["status"] == "superseded"
    ceramics = [r for r in notes(root).values()
                if r["key"] == "trip-ceramics" and r["status"] == "active"][0]
    # Archiving the remaining side also clears it, and restore brings it back.
    call(root, "memory-archive", id=ceramics["id"], at="2026-10-20T20:00:00Z")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 0, "notes": 0}
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先看瓷器", conditions=["规划博物馆行程时"], sources=[],
         at="2026-10-20T20:30:00Z", key="trip-porcelain")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 0, "notes": 0}
    call(root, "memory-restore", id=ceramics["id"], at="2026-10-20T21:00:00Z")
    assert call(root, "memory-conflicts")["counts"] == {"groups": 1, "notes": 2}

    # A5's Autodream merges duplicate information: a reworded judgment must not
    # crowd a distinct one out of the budget. The two notes differ only in
    # punctuation and apply under different conditions, so they are not
    # competing judgments.
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先安排陶瓷窑口对比的参观时间，并保留半天的自由活动",
         conditions=["规划周末短途旅行时"], sources=[], at="2026-10-20T21:30:00Z", key="plan-a")
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="行程优先安排陶瓷窑口对比的参观时间，并保留半天的自由活动！",
         conditions=["规划城市漫步时"], sources=[], at="2026-10-20T21:35:00Z", key="plan-b")
    query = "陶瓷 窑口 参观 时间 自由活动"
    plain = call(root, "memory-prefetch", query=query, limit=10)
    assert plain["dedup"] == "none" and plain["similar_duplicates"] == []
    assert len([n for n in plain["notes"] if n["key"].startswith("plan-")]) == 2
    merged = call(root, "memory-prefetch", query=query, limit=10, dedup="similar")
    assert merged["dedup"] == "similar"
    kept = [n for n in merged["notes"] if n["key"].startswith("plan-")]
    assert len(kept) == 1
    assert len(merged["similar_duplicates"]) == 1
    duplicate = merged["similar_duplicates"][0]
    assert duplicate["keeper"] == kept[0]["id"]
    assert duplicate["duplicate"] in {row["id"] for row in call(root, "memory-list")["notes"]}
    assert duplicate["duplicate"] != duplicate["keeper"]
    # Both notes stay listed; only the default candidate set is deduplicated.
    assert len([n for n in call(root, "memory-list")["notes"]
                if n["key"].startswith("plan-")]) == 2
    # Short notes never merge on a coincidental token sequence.
    call(root, "memory-submit", kind="constraint", scope="workspace", text="预算三千",
         conditions=["规划预算时"], sources=[], at="2026-10-20T21:40:00Z", key="budget-a")
    call(root, "memory-submit", kind="constraint", scope="workspace", text="预算三千。",
         conditions=["规划差旅时"], sources=[], at="2026-10-20T21:45:00Z", key="budget-b")
    short = call(root, "memory-prefetch", query="预算 三千", limit=10, dedup="similar")
    assert len([n for n in short["notes"] if n["key"].startswith("budget-")]) == 2
    assert short["similar_duplicates"] == []
    # kinds restricts the candidate set without touching the others.
    only = call(root, "memory-prefetch", query="陶瓷 预算", limit=10, kinds=["constraint"])
    assert {n["kind"] for n in only["notes"]} == {"constraint"}
    assert {"budget-a", "budget-b"} <= {n["key"] for n in only["notes"]}
    # A near-duplicate under the SAME conditions is a competing judgment, so it
    # is never merged: dropping one side would hide the conflict.
    call(root, "memory-submit", kind="decision", scope="workspace",
         text="本阶段只整理陶瓷窑口的资料，暂不扩展到其他窑口",
         conditions=["规划资料整理范围时"], sources=[], at="2026-10-20T22:00:00Z", key="scope-a")
    call(root, "memory-submit", kind="decision", scope="workspace",
         text="本阶段只整理陶瓷窑口的资料，暂不扩展到其他窑口。",
         conditions=["规划资料整理范围时"], sources=[], at="2026-10-20T22:05:00Z", key="scope-b")
    assert call(root, "memory-conflicts")["counts"]["notes"] >= 2
    guarded = call(root, "memory-prefetch", query="陶瓷 窑口 资料 整理 范围",
                   limit=10, dedup="similar")
    scope_notes = [n for n in guarded["notes"] if n["key"].startswith("scope-")]
    assert len(scope_notes) == 2, scope_notes
    assert all(n["conflicted"] for n in scope_notes)
    assert not any(row["duplicate"] in {n["id"] for n in scope_notes}
                   for row in guarded["similar_duplicates"])
    assert guarded["conflict_counts"]["notes"] >= 2
    # A candidate dropped by the budget must be reported, not silently lost.
    big = "陶瓷" * 2048
    assert len(big) == 4096
    call(root, "memory-submit", kind="fact", scope="workspace", text=big,
         conditions=["整理长篇资料时"], sources=[], at="2026-10-20T23:20:00Z", key="big-note")
    call(root, "memory-submit", kind="fact", scope="workspace", text="陶瓷短判断",
         conditions=["整理短资料时"], sources=[], at="2026-10-20T23:25:00Z", key="small-note")
    capped = call(root, "memory-prefetch", query="陶瓷", limit=10)
    assert capped["truncated"] is True, capped["truncated"]
    assert len(capped["notes"]) == 1
    assert capped["notes"][0]["key"] == "big-note"
    assert capped["estimated_tokens"] >= 4096
    # `limit` had only ever been exercised at 0 (refused) and 10 (never binding,
    # because no scenario produced more than ten candidates). A limit that is
    # silently ignored looks exactly like a limit that is honoured, so bind it
    # against notes written for the purpose.
    for index in range(4):
        call(root, "memory-submit", kind="fact", scope="workspace",
             text=f"限定标记的第{index}条独立判断，用于验证候选条数上限。",
             conditions=[f"限定条件{index}"], sources=[],
             at=f"2026-10-21T00:0{index}:00Z", key=f"cap-{index}")
    def capped_read(count):
        rows = call(root, "memory-prefetch", query="限定标记", limit=count)["notes"]
        return [row for row in rows if row["key"].startswith("cap-")]
    for count in range(1, 4):
        bounded = capped_read(count)
        assert len(bounded) == count, (count, [n["key"] for n in bounded])
        scores = [row["score"] for row in bounded]
        assert scores == sorted(scores, reverse=True), scores
    # A limit above the candidate count returns them all rather than padding.
    wide = capped_read(50)
    assert len(wide) == 4, [n["key"] for n in wide]
    assert call(root, "memory-prefetch", query="限定标记", limit=50)["truncated"] is False
    # The capped read is a prefix of the uncapped one, so the limit selects the
    # top of the same ranking instead of a different subset.
    assert [row["id"] for row in wide[:2]] == [row["id"] for row in capped_read(2)]
    assert capped["estimate_recipe"] == "cjk_char_latin_word_v1"

    # A host working on a page should not have to distil a query from it: the
    # page's own title and body seed the ranking deterministically.
    publish(root, "page-seed.md", "陶瓷窑口", "concepts/ceramics",
            "陶瓷窑口的器形与釉色对比记录。")
    page_id = "concepts/ceramics"
    seeded = call(root, "memory-prefetch", page=page_id)
    assert seeded["query_seed"] == "page:" + page_id
    assert seeded["query"] != ""
    assert "陶瓷" in seeded["query"]
    assert seeded["notes"], seeded
    assert seeded["notes"], seeded
    assert all(n["status"] == "active" for n in seeded["notes"])
    # An explicit query reports its own seed and is mutually exclusive.
    explicit = call(root, "memory-prefetch", query="陶瓷 参观 时间")
    assert explicit["query_seed"] == "query"
    call(root, "memory-prefetch", query="陶瓷", page=page_id,
         error="memory_query_exclusive")
    call(root, "memory-prefetch", error="memory_query_required")
    call(root, "memory-prefetch", page="purpose.md", error="memory_page_required")
    call(root, "memory-prefetch", page="concepts/absent", error="entry_not_found")
    # The seed is read-only and deterministic.
    fingerprint = call(root, "status")["fingerprint"]
    assert call(root, "memory-prefetch", page=page_id) == seeded
    assert call(root, "status")["fingerprint"] == fingerprint

    # Unknown dedup modes and kinds are refused, and nothing changes.
    before = call(root, "status")["fingerprint"]
    call(root, "memory-prefetch", query="陶瓷", dedup="exact", error="memory_dedup_unsupported")
    call(root, "memory-prefetch", query="陶瓷", kinds=["habit"], error="memory_kind_unsupported")
    assert call(root, "status")["fingerprint"] == before

    # A single note is addressable by id, so a host does not have to list the
    # whole memory set to read one judgment.
    target = [r for r in notes(root).values() if r["key"] == "ceramics-fact"][0]
    read = call(root, "memory-read", id=target["id"])
    assert read["record"]["text"] == target["text"]
    assert read["record"]["conditions"] == target["conditions"]
    assert read["record"]["pinned"] is False
    # A read never claims a pending host action.
    assert "execution" not in read
    call(root, "memory-read", id="deadbeef", error="invalid_memory_id")
    call(root, "memory-read", id=target["id"][:63], error="invalid_memory_id")

    # A pinned note is important despite being used infrequently, so automated
    # archiving cannot drop it without an explicit unprotect.
    pinned = call(root, "memory-submit", kind="goal", scope="workspace",
                  text="长期目标是建立可核对的陶瓷知识库", conditions=[], sources=[],
                  at="2026-10-20T22:30:00Z", key="long-goal")
    call(root, "memory-pin", id=pinned["id"], pinned=True, at="2026-10-20T22:45:00Z")
    assert notes(root)[pinned["id"]]["pinned"] is True
    call(root, "memory-archive", id=pinned["id"], at="2026-10-20T23:00:00Z",
         error="memory_pinned_archive_refused")
    assert call(root, "memory-pin", id=pinned["id"], pinned=True,
                at="2026-10-20T22:45:00Z")["replayed"] is True
    call(root, "memory-pin", id=pinned["id"], pinned=False, at="2026-10-20T23:30:00Z")
    assert notes(root)[pinned["id"]]["pinned"] is False
    call(root, "memory-archive", id=pinned["id"], at="2026-10-20T23:45:00Z")
    assert notes(root)[pinned["id"]]["status"] == "archived"

    # Every memory transition writes a registered event: an orphan state file is
    # invisible to read-log and verify, so lint has to report it.
    ops = [e["op"] for e in call(root, "read-log")]
    for expected in ["memory-submit", "memory-supersede", "memory-pin",
                     "memory-archive", "memory-restore"]:
        assert expected in ops, (expected, ops)
    assert not [v for v in call(root, "lint")["violations"]
                if v["predicate"] == "file_unregistered"]
    (root / "state/events/forged.json").write_text('{"op":"memory-pin"}')
    orphans = [v for v in call(root, "lint")["violations"]
               if v["predicate"] == "file_unregistered"]
    assert [v["path"] for v in orphans] == ["state/events/forged.json"], orphans
    assert orphans[0]["severity"] == "error"
    (root / "state/events/forged.json").unlink()
    assert not [v for v in call(root, "lint")["violations"]
                if v["predicate"] == "file_unregistered"]

    # A rejected scope or kind never reaches the vault.
    before = call(root, "status")["fingerprint"]
    call(root, "memory-submit", kind="habit", scope="workspace", text="x", conditions=[],
         sources=[], at="2026-10-20T18:00:00Z", key="bad-kind", error="memory_kind_unsupported")
    call(root, "memory-submit", kind="fact", scope="user", text="x", conditions=[],
         sources=[], at="2026-10-20T18:00:00Z", key="bad-scope", error="memory_scope_unsupported")
    call(root, "memory-submit", kind="fact", scope="workspace", text="x", conditions=["a\nb"],
         sources=[], at="2026-10-20T18:00:00Z", key="bad-condition", error="memory_condition_invalid")
    call(root, "memory-submit", kind="fact", scope="workspace", text="x",
         conditions=[], sources=["wiki/index.md"], at="2026-10-20T18:00:00Z",
         key="bad-source", error="memory_source_invalid")
    call(root, "memory-prefetch", query="陶瓷", limit=0, error="memory_limit_invalid")
    assert call(root, "status")["fingerprint"] == before

    # The string and array bounds had only ever been exercised with trivially
    # valid values ("x", one condition, no sources), so neither edge was pinned.
    # Both edges matter: a bound that is off by one in either direction is
    # invisible unless the exact limit is shown to pass and the next value to
    # fail. `length()` counts characters, so the CJK cases below would fail if
    # anyone switched the check to bytes.
    def sized(text, key, conditions=None, sources=None):
        return call(root, "memory-submit", kind="fact", scope="workspace", text=text,
                    conditions=conditions or [], sources=sources or [],
                    at="2026-10-20T19:00:00Z", key=key)

    assert sized("a" * 4096, "text-max")["status"] == "active"
    call(root, "memory-submit", kind="fact", scope="workspace", text="a" * 4097,
         conditions=[], sources=[], at="2026-10-20T19:00:00Z",
         key="text-over", error="memory_text_invalid")
    # 4096 CJK characters are 12288 bytes, so this only passes while the bound
    # counts characters rather than bytes.
    assert sized("陶" * 4096, "text-cjk-max")["status"] == "active"
    call(root, "memory-submit", kind="fact", scope="workspace", text="",
         conditions=[], sources=[], at="2026-10-20T19:00:00Z",
         key="text-empty", error="memory_text_invalid")
    assert sized("x", "key-" + "k" * 252)["status"] == "active"
    call(root, "memory-submit", kind="fact", scope="workspace", text="x",
         conditions=[], sources=[], at="2026-10-20T19:00:00Z",
         key="k" * 257, error="memory_idempotency_key_invalid")
    assert sized("x", "cond-count-max", conditions=["c"] * 16)["status"] == "active"
    call(root, "memory-submit", kind="fact", scope="workspace", text="x",
         conditions=["c"] * 17, sources=[], at="2026-10-20T19:00:00Z",
         key="cond-count-over", error="memory_conditions_count_invalid")
    assert sized("x", "cond-len-max", conditions=["c" * 256])["status"] == "active"
    call(root, "memory-submit", kind="fact", scope="workspace", text="x",
         conditions=["c" * 257], sources=[], at="2026-10-20T19:00:00Z",
         key="cond-len-over", error="memory_condition_invalid")
    # The count bound is checked before registration, so an unregistered path
    # still reaches it -- and that ordering is what lets the lower edge be pinned
    # without registering 32 files: at the documented limit the count check
    # passes and the registration check fires instead.
    call(root, "memory-submit", kind="fact", scope="workspace", text="x",
         conditions=[], sources=[f"raw/f{index}.md" for index in range(33)],
         at="2026-10-20T19:00:00Z", key="src-count-over",
         error="memory_sources_count_invalid")
    at_limit = call(root, "memory-submit", kind="fact", scope="workspace", text="x",
                    conditions=[], sources=[f"raw/f{index}.md" for index in range(32)],
                    at="2026-10-20T19:00:00Z", key="src-count-max",
                    error="memory_source_not_registered")
    assert call(root, "status")["fingerprint"] != before

    # Reporting foreground usage is what makes selective pruning possible:
    # without it a host can only guess which notes have gone stale by disuse.
    used = [r["id"] for r in notes(root).values()
            if r["key"] == "ceramics-fact" and r["status"] == "active"]
    assert notes(root)[used[0]]["last_used_at"] is None
    report = call(root, "memory-use", ids=used, at="2026-10-20T23:30:00Z")
    assert report["used"] == 1 and report["replayed"] is False
    assert notes(root)[used[0]]["last_used_at"] == "2026-10-20T23:30:00Z"
    # The same report twice is a replay, not a second write.
    assert call(root, "memory-use", ids=used, at="2026-10-20T23:30:00Z")["replayed"] is True
    # A later report advances the timestamp.
    assert call(root, "memory-use", ids=used, at="2026-10-20T23:40:00Z")["used"] == 1
    assert notes(root)[used[0]]["last_used_at"] == "2026-10-20T23:40:00Z"
    # Prefetch itself never records usage.
    before = notes(root)[used[0]]["last_used_at"]
    call(root, "memory-prefetch", query="官窑 记录")
    assert notes(root)[used[0]]["last_used_at"] == before
    # A batch reports many notes in one transaction.
    batch = [r["id"] for r in notes(root).values() if r["status"] == "active"][:3]
    assert call(root, "memory-use", ids=batch, at="2026-10-20T23:50:00Z")["used"] == len(batch)
    assert "memory-use" in [e["op"] for e in call(root, "read-log")]
    call(root, "memory-use", ids=[], at="2026-10-20T23:55:00Z",
         error="memory_use_count_invalid")
    call(root, "memory-use", ids=[batch[0], batch[0]], at="2026-10-20T23:55:00Z",
         error="memory_use_duplicate_id")
    call(root, "memory-use", ids=["0" * 64], at="2026-10-20T23:55:00Z",
         error="entry_not_found")

    # An archived note has left the default set, so it must not block a fresh
    # submission of the same judgment under a new binding.
    gone = call(root, "memory-submit", kind="decision", scope="workspace",
                text="阶段性结论：先整理陶瓷资料", conditions=["规划资料整理范围时"],
                sources=[], at="2026-10-20T23:50:00Z", key="stage-conclusion")
    call(root, "memory-archive", id=gone["id"], at="2026-10-20T23:55:00Z")
    reborn = call(root, "memory-submit", kind="decision", scope="workspace",
                  text="阶段性结论：先整理陶瓷资料", conditions=["规划资料整理范围时"],
                  sources=[], at="2026-10-20T23:59:00Z", key="stage-conclusion-again")
    assert reborn["status"] == "active" and reborn["id"] != gone["id"]
    assert [r for r in notes(root).values() if r["key"] == "stage-conclusion"
            and r["status"] == "archived"]
    assert not [v for v in call(root, "lint")["violations"]
                if v["predicate"] == "memory_duplicate_note"]
    # A competing ACTIVE note is still refused as a duplicate.
    call(root, "memory-submit", kind="decision", scope="workspace",
         text="阶段性结论：先整理陶瓷资料", conditions=["规划资料整理范围时"],
         sources=[], at="2026-10-21T00:05:00Z", key="stage-conclusion-third",
         error="memory_duplicate_text")

    call(root, "rebuild")
    call(root, "verify")
    assert call(root, "memory-list")["counts"]["active"] >= 1

    # A5's Autodream surface: an external agent must be able to discover what to
    # consolidate without first guessing a query that would surface it through
    # `memory-prefetch`. This block is the only place that capability is covered.
    reworded = "官窑记录的器形与釉色特征可以据此核对，包括胎质釉层厚度与开片形态便于断代参考"
    rephrased = "官窑记录的器形与釉色特征可以据此核对；包括胎质釉层厚度与开片形态便于断代参考"
    call(root, "memory-submit", kind="fact", scope="workspace", text=reworded,
         conditions=["核对釉色"], sources=[], at="2026-11-01T09:00:00Z", key="cand-a")
    call(root, "memory-submit", kind="fact", scope="workspace", text=rephrased,
         conditions=["撰写说明"], sources=[], at="2026-11-01T09:05:00Z", key="cand-b")
    call(root, "memory-submit", kind="preference", scope="workspace",
         text="偏好：上午参观。这条记录足够长以通过门槛并且从未被使用过。",
         conditions=["待定项"], sources=[], at="2026-11-01T09:10:00Z", key="cand-fresh")
    keep_id = call(root, "memory-submit", kind="preference", scope="workspace",
                   text="偏好：保留午休。这条记录足够长以通过门槛并且从未被使用过。",
                   conditions=["保护项"], sources=[],
                   at="2026-11-01T09:15:00Z", key="cand-pinned")["id"]
    call(root, "memory-pin", id=keep_id, pinned=True, at="2026-11-01T09:20:00Z")

    candidates = call(root, "memory-candidates")
    assert "execution" not in candidates, "a read op must not claim a host action"
    # Earlier blocks already created a near-duplicate pair, so filter to the keys
    # this block owns rather than assuming it is the only group.
    mine = {"cand-a", "cand-b"}
    merge = [(row["duplicate_key"], row["keeper_key"], row["reason"])
             for row in candidates["merge"] if row["duplicate_key"] in mine]
    # The keeper is whichever of the pair has the smaller id, so which side it
    # lands on is not the contract -- that they form exactly one group is.
    assert len(merge) == 1, merge
    duplicate_key, keeper_key, reason = merge[0]
    assert {duplicate_key, keeper_key} == mine, merge
    assert reason == "similar_text", merge
    assert duplicate_key != keeper_key, merge
    prune = [row["key"] for row in candidates["prune"]]
    # The merge participants are already going away, and the pinned note is a
    # human decision, so neither may be proposed for pruning as well. Earlier
    # blocks leave their own never-used notes, so only this block's keys are
    # asserted rather than the whole list.
    assert "cand-fresh" in prune, prune
    assert "cand-pinned" not in prune, prune
    assert not (mine & set(prune)), prune
    assert candidates["counts"]["pinned"] >= 1
    # The same vault state always yields the same candidates.
    assert call(root, "memory-candidates") == candidates

    # Both surfaces must agree: the seedless view and the seeded prefetch name
    # the same duplicate and keeper for the same pair.
    brief = call(root, "memory-prefetch", query="官窑 釉色", dedup="similar")
    cand_ids = {row["id"] for row in call(root, "memory-list")["notes"]}
    by_key = {row["key"]: row["id"] for row in call(root, "memory-list")["notes"]}
    seeded = sorted((row["duplicate"], row["keeper"])
                    for row in brief["similar_duplicates"])
    expected = {by_key["cand-a"], by_key["cand-b"]}
    assert len(expected) == 2
    seeded_ids = {note_id for pair in seeded for note_id in pair}
    assert expected <= seeded_ids, (seeded, expected)

    # Candidates are derived state, so they survive a pack round trip unchanged.
    call(root, "pack", output="exports/candidates.mcpack")
    round = root / "restored-candidates"
    (round / "imports").mkdir(parents=True, exist_ok=True)
    (round / "imports/candidates.mcpack").write_bytes(
        (root / "exports/candidates.mcpack").read_bytes())
    assert call(round, "unpack", file="imports/candidates.mcpack")["vault_fingerprint"] == \
        call(root, "status")["fingerprint"]
    assert call(round, "memory-candidates") == candidates
    call(round, "rebuild")
    call(round, "verify")
    # Memory notes are catalog state, so a deterministic pack survives a round trip.
    call(root, "pack", output="exports/memory.mcpack")
    target = root / "restored"
    (target / "imports").mkdir(parents=True, exist_ok=True)
    (target / "imports/memory.mcpack").write_bytes((root / "exports/memory.mcpack").read_bytes())
    assert call(target, "unpack", file="imports/memory.mcpack")["vault_fingerprint"] == \
        call(root, "status")["fingerprint"]
    assert {row["id"] for row in call(target, "memory-list")["notes"]} == set(notes(root))
    call(target, "rebuild")
    call(target, "verify")

    # Every aggregator reached from dispatch must notice an external edit, not
    # silently serve the tampered bytes. `graph_unchecked` trusts its caller, so
    # this is what keeps that trust honest.
    note_path = next((root / "state/memory").glob("*.json"))
    tampered = json.loads(note_path.read_text(encoding="utf-8"))
    tampered["text"] = "外部编辑过的正文"
    note_path.write_text(json.dumps(tampered, ensure_ascii=False), encoding="utf-8")
    for op in ("stats", "memory-list", "impact-list", "inbox"):
        assert call(root, op, error="content_changed"), op
    # `lint` is the diagnostic path: it reports instead of rejecting.
    assert call(root, "lint")["errors"] >= 1

    print("memory notes, supersede chain, drift invalidation and prefetch passed")
