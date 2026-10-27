#!/usr/bin/env python3
"""Persisted HumanGate quality debt from the verified graph snapshot."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"

with tempfile.TemporaryDirectory(prefix="corridor-quality-gate-") as work:
    vault = Path(work)

    def call(op, error=None, **fields):
        request = {"op": op, "vault": str(vault), **fields}
        process = subprocess.run([str(EXE)], input=json.dumps(request, ensure_ascii=False) + "\n",
                                 capture_output=True, text=True, check=True, timeout=30)
        value = json.loads(process.stdout)
        if error:
            assert not value["ok"] and error in value["error"], value
            return value
        assert value["ok"], value
        return value["result"]

    call("init", purpose="质量门测试")
    (vault / "raw/source.md").write_text("共享证据来源。\n")
    order = call("scan")["orders"][0]
    context = call("context", order=order)
    call("analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "人工分析"})
    staging = vault / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    pages = []
    for index, (page_id, title) in enumerate([("concepts/孤岛一", "孤岛一"), ("concepts/孤岛二", "孤岛二")]):
        staged = staging / f"{index}.md"
        staged.write_text(f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/source.md\"]\ntags: [\"孤岛域\"]\n---\n没有互链的页面。\n")
        pages.append({"id": page_id, "path": f"wiki/{page_id}.md", "staged": str(staged.relative_to(vault))})
    call("commit", order=order, pages=pages, at="2026-10-20")

    (vault / "raw/未入图.md").write_text("已登记但尚未进入知识图的来源。\n")
    call("scan")

    supported = call("read-page", id="concepts/孤岛一")
    # Evidence ranges are measured on parsed Page.body, not full frontmatter.
    body = "没有互链的页面。\n"
    evidence = call("evidence-submit", page="concepts/孤岛一",
                    page_hash=supported["entry"]["sha256"],
                    items=[{"source": "raw/source.md", "body_start": 0,
                            "body_end": len(body.encode("utf-8")), "quote": body},
                           {"source": "raw/source.md", "body_start": 0,
                            "body_end": len("没有".encode("utf-8")), "quote": "没有"}])
    assert not evidence["replayed"] and evidence["record"]["valid"]
    evidence_stats = call("stats")["evidence"]
    first_page = next(row for row in evidence_stats["coverage"]["pages"]
                      if row["page"] == "concepts/孤岛一")
    assert first_page["complete"] and first_page["coverage_basis_points"] == 10000
    assert first_page["provenance"] == "legacy"
    assert first_page["valid_claims"] == 2 and first_page["overlap_claims"] == 1
    assert first_page["legacy_source_claims"] == 2 and first_page["exact_source_claims"] == 0
    source_stats = next(row for row in evidence_stats["coverage"]["sources"]
                        if row["source"] == "raw/source.md")
    assert source_stats["valid_claims"] == 2 and source_stats["pages"] == ["concepts/孤岛一"]
    assert source_stats["provenance"] == "legacy"
    assert source_stats["legacy_source_claims"] == 2 and source_stats["exact_source_claims"] == 0
    assert {"concepts/孤岛一", "concepts/孤岛二"}.issubset(set(source_stats["direct_pages"]))
    assert len(source_stats["direct_pages"]) == 3  # includes the deterministic source-summary fallback page
    assert source_stats["stale_direct_pages"] == [] and source_stats["support"] == "evidenced"
    assert source_stats["basis"] == "provenance_v1"

    partial = call("read-page", id="concepts/孤岛二")
    partial_evidence = call("evidence-submit", page="concepts/孤岛二",
                            page_hash=partial["entry"]["sha256"],
                            items=[{"source": "raw/source.md", "body_start": 0,
                                    "body_end": len("没有".encode("utf-8")), "quote": "没有"}])
    assert not partial_evidence["replayed"] and partial_evidence["record"]["valid"]

    first = call("quality-audit", at="2026-10-20")
    assert not first["replayed"] and len(first["issues"]) >= 1 and len(first["created"]) == len(first["issues"])
    unreferenced = [row for row in first["issues"] if row["predicate"] == "unreferenced_source"]
    assert [row["source"] for row in unreferenced] == ["raw/未入图.md"]
    legacy = [row for row in first["issues"] if row["predicate"] == "legacy_evidence_anchor"]
    assert [row["page"] for row in legacy] == ["concepts/孤岛一", "concepts/孤岛二"]
    missing = [row for row in first["issues"] if row["predicate"] == "missing_evidence"]
    assert missing == []
    gaps = [row for row in first["issues"] if row["predicate"] == "evidence_coverage_gap"]
    assert [row["page"] for row in gaps] == ["concepts/孤岛二"]
    reviews = call("review-list")
    assert len(reviews) == len(first["created"])
    assert all(row["status"] == "pending" and row["reason"].startswith("质量门：") and
               row["input_status"] == "current" for row in reviews)

    replay = call("quality-audit", at="2026-10-20")
    assert replay["replayed"] and replay["created"] == [] and replay["issues"] == first["issues"]
    selected = reviews[0]["id"]
    resolved = call("review-resolve", id=selected, action="skip", note="记录后续研究", at="2026-10-20")
    assert resolved["status"] == "resolved"
    assert call("review-resolve", id=selected, action="skip", note="记录后续研究", at="2026-10-20")["replayed"]
    # `review-resolve` accepts exactly three actions. Two had been sent and the
    # third never was, so the enum's rejection branch was unexercised: an action
    # outside the set would have been recorded as a valid host decision. A real
    # review id is used on purpose -- with a nonexistent one the record lookup
    # fails first and the mutation is caught for the wrong reason.
    for bad_action in ("bogus", "", "SKIP", "skip "):
        call("review-resolve", id=reviews[1]["id"], action=bad_action, note="n",
             at="2026-10-20", error="unsupported_review_action")
    # The third valid action is accepted elsewhere in the suite; asserting it
    # here would resolve a second record and disturb the debt counts below.
    assert call("stats")["review_debt"]["resolved"] == 1

    # Upgrade the first page's legacy claims to exact raw anchors. The old
    # record remains durable history but must disappear from current coverage.
    source_quote = "共享证据来源。\n"
    upgraded = call("evidence-replace", page="concepts/孤岛一",
                    page_hash=supported["entry"]["sha256"], previous=evidence["id"],
                    items=[{"source": "raw/source.md", "body_start": 0,
                            "body_end": len(body.encode("utf-8")), "quote": body,
                            "source_start": 0, "source_end": len(source_quote.encode("utf-8")),
                            "source_quote": source_quote},
                           {"source": "raw/source.md", "body_start": 0,
                            "body_end": len("没有".encode("utf-8")), "quote": "没有",
                            "source_start": 0, "source_end": len(source_quote.encode("utf-8")),
                            "source_quote": source_quote}])
    assert not upgraded["replayed"] and upgraded["replaced"]
    assert all(claim["source_anchor"] == "exact" for claim in upgraded["record"]["claims"])
    assert call("evidence-replace", page="concepts/孤岛一",
                page_hash=supported["entry"]["sha256"], previous=evidence["id"],
                items=[{"source": "raw/source.md", "body_start": 0,
                        "body_end": len(body.encode("utf-8")), "quote": body,
                        "source_start": 0, "source_end": len(source_quote.encode("utf-8")),
                        "source_quote": source_quote},
                       {"source": "raw/source.md", "body_start": 0,
                        "body_end": len("没有".encode("utf-8")), "quote": "没有",
                        "source_start": 0, "source_end": len(source_quote.encode("utf-8")),
                        "source_quote": source_quote}])["replayed"]
    assert next(row for row in call("review-list") if row["id"] == selected)["input_status"] == "stale"
    current_stats = call("stats")["evidence"]["coverage"]["pages"]
    current_first = next(row for row in current_stats if row["page"] == "concepts/孤岛一")
    assert current_first["legacy_source_claims"] == 0 and current_first["exact_source_claims"] == 2
    assert current_first["provenance"] == "exact"
    call("rebuild")
    assert call("verify")["violations"] == []

    remaining = call("read-page", id="concepts/孤岛二")
    evidence = call("evidence-submit", page="concepts/孤岛二",
                    page_hash=remaining["entry"]["sha256"],
                    items=[{"source": "raw/source.md", "body_start": 0,
                            "body_end": len(body.encode("utf-8")), "quote": body}])
    assert not evidence["replayed"]
    later = call("quality-audit", at="2026-10-21")
    assert not later["replayed"] and len(later["created"]) == len(later["issues"])
    assert not any(row["predicate"] == "legacy_evidence_anchor" and row["page"] == "concepts/孤岛一"
                   for row in later["issues"])
    assert not any(row["predicate"] == "missing_evidence" for row in later["issues"])
    assert not any(row["predicate"] == "evidence_coverage_gap" for row in later["issues"])
    assert any(event["op"] == "quality-audit" for event in call("read-log"))
    # `evidence-replace` shares its anchor validation with `evidence-submit`, but
    # every anchor the scenario above replaces with starts at offset 0, so nothing
    # pins the recorded values back to the bytes they name. This re-anchors onto
    # text in the middle of both files on a page of its own, so it cannot disturb
    # the coverage counts asserted above.
    (vault / "raw/anchor.md").write_text(
        "无关前缀内容。\n关键结论落在中段。\n无关后缀内容。\n")
    anchor_orders = call("scan")["orders"]
    if anchor_orders:
        anchor_order = anchor_orders[0]
        context = call("context", order=anchor_order)
        call("analysis-submit", order=anchor_order,
             context_token=context["context_token"],
             analysis={"entities": [], "concepts": ["锚点"], "conflicts": [],
                       "summary": "锚点"})
        staged = vault / "staging" / anchor_order
        staged.mkdir(parents=True, exist_ok=True)
        (staged / "page.md").write_text(
            "---\ntype: concept\ntitle: 重锚页\nsources: [\"raw/anchor.md\"]\n"
            "tags: [\"锚点\"]\n---\n引言段落在这里。\n页面保留关键结论。\n尾注补充。\n"
        )
        call("commit", order=anchor_order,
             pages=[{"id": "concepts/anchor", "path": "wiki/concepts/anchor.md",
                     "staged": f"staging/{anchor_order}/page.md"}], at="2026-10-22")
        anchor_page = call("read-page", id="concepts/anchor")
        anchor_text = anchor_page["text"].split("---\n", 2)[-1]
        anchor_source = (vault / "raw/anchor.md").read_text(encoding="utf-8")
        quote = "页面保留关键结论"
        source_quote = "关键结论落在中段"
        assert quote in anchor_text and source_quote in anchor_source
        body_start = len(anchor_text.encode().split(quote.encode(), 1)[0])
        source_start = len(anchor_source.encode().split(source_quote.encode(), 1)[0])
        first = call("evidence-submit", page="concepts/anchor",
                     page_hash=anchor_page["entry"]["sha256"],
                     items=[{"source": "raw/anchor.md", "body_start": 0,
                             "body_end": len("引言段落在这里。".encode()),
                             "quote": "引言段落在这里。",
                             "source_start": 0,
                             "source_end": len("无关前缀内容。".encode()),
                             "source_quote": "无关前缀内容。"}])
        reanchored = call("evidence-replace", page="concepts/anchor",
                          page_hash=anchor_page["entry"]["sha256"], previous=first["id"],
                          items=[{"source": "raw/anchor.md",
                                  "body_start": body_start,
                                  "body_end": body_start + len(quote.encode()),
                                  "quote": quote,
                                  "source_start": source_start,
                                  "source_end": source_start + len(source_quote.encode()),
                                  "source_quote": source_quote}])
        assert reanchored["replaced"] and not reanchored["replayed"]
        claim = reanchored["record"]["claims"][0]
        assert claim["source_anchor"] == "exact", claim
        rebuilt = anchor_text.encode()[claim["body_start"]:claim["body_end"]].decode()
        assert rebuilt == quote, (rebuilt, claim)
        window = call("read-source", id="raw/anchor.md",
                      start=claim["source_start"], end=claim["source_end"])
        assert window["text"] == source_quote, window
        # The replaced record stays durable as history.
        assert len(call("evidence-list", page="concepts/anchor")) >= 1
    before = len(call("review-list"))
    shutil.rmtree(vault / ".corridor")
    call("rebuild")
    assert len(call("review-list")) == before
    assert call("verify")["violations"] == []

    # The event layer validates a resolved review's decision action independently
    # of the operation that wrote it, so a hand-edited record cannot smuggle in an
    # unsupported action. Nothing asserted `record_invalid` at all, which means
    # removing that check left the whole suite green. `lint` is the surface that
    # reports it, because `verify` stops at the content hash first.
    resolved_row = next(row for row in call("review-list")
                        if row["status"] == "resolved" and row["decision"])
    record = vault / "state/reviews" / (resolved_row["id"] + ".json")
    original = record.read_text(encoding="utf-8")
    tampered = json.loads(original)
    tampered["decision"]["action"] = "bogus"
    record.write_text(json.dumps(tampered, ensure_ascii=False), encoding="utf-8")
    reported = [row for row in call("lint")["violations"]
                if row["predicate"] == "record_invalid"]
    assert len(reported) == 1, reported
    assert reported[0]["detail"] == "review_action_invalid", reported[0]
    assert reported[0]["path"] == f"state/reviews/{resolved_row['id']}.json", reported[0]
    # The tampering is also refused by every verifying read.
    for op in ("verify", "review-list", "status", "stats"):
        call(op, error="content_changed")
    record.write_text(original, encoding="utf-8")
    call("rebuild")
    assert call("verify")["violations"] == []

print("HumanGate quality-audit: orphan/sparse debt, deterministic replay, resolution and cache rebuild passed")
