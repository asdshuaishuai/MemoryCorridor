#!/usr/bin/env python3
"""Verify optional exact raw-source anchors in evidence sidecars."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}, ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=30).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


with tempfile.TemporaryDirectory(prefix="memorycorridor-evidence-source-") as temp:
    root = Path(temp)
    call(root, "init", purpose="来源锚点")
    source_text = "原始事实：光合作用发生在叶绿体。\n"
    (root / "raw/source.md").write_text(source_text)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["光合作用"], "conflicts": [], "summary": "来源"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    page_text = "---\ntype: concept\ntitle: 来源锚点页\nsources: [\"raw/source.md\"]\n---\n页面保留：光合作用。\n"
    (staging / "page.md").write_text(page_text)
    call(root, "commit", order=order,
         pages=[{"id": "concepts/source-anchor", "path": "wiki/concepts/source-anchor.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-10-17")
    page = call(root, "read-page", id="concepts/source-anchor")
    body = page["text"].split("---\n", 2)[-1]
    page_quote = "页面保留"
    page_start = len(body.encode().split(page_quote.encode(), 1)[0])
    source_quote = "光合作用发生在叶绿体。"
    source_start = len(source_text.encode().split(source_quote.encode(), 1)[0])
    evidence = call(root, "evidence-submit", page="concepts/source-anchor", page_hash=page["entry"]["sha256"],
                    items=[{"source": "raw/source.md", "body_start": page_start,
                            "body_end": page_start + len(page_quote.encode()), "quote": page_quote,
                            "source_start": source_start, "source_end": source_start + len(source_quote.encode()),
                            "source_quote": source_quote}])
    claim = evidence["record"]["claims"][0]
    assert claim["valid"] and claim["source_quote_verified"] and claim["source_anchor"] == "exact"
    # The two operations must agree on what an offset counts. `evidence-submit`
    # accepted the anchors above and `read-source` reads by byte range, but no
    # test ever connected them: if either side counted characters instead, both
    # would still pass while every CJK anchor came back wrong. Take the recorded
    # anchors back to `read-source` and require the exact quote.
    window = call(root, "read-source", id="raw/source.md",
                  start=claim["source_start"], end=claim["source_end"])
    assert window["text"] == source_quote, window
    # The page-side anchors are relative to the parsed body, not to the text
    # `read-page` returns, which still carries the frontmatter. Documented in
    # protocol.md, but never checked end to end: applying the anchors to the
    # wrong base silently yields other bytes rather than failing.
    page_now = call(root, "read-page", id="concepts/source-anchor")
    body_now = page_now["text"].split("---\n", 2)[-1]
    rebuilt = body_now.encode()[claim["body_start"]:claim["body_end"]].decode()
    assert rebuilt == page_quote, (rebuilt, claim)
    assert page_now["text"].encode()[claim["body_start"]:claim["body_end"]].decode() != page_quote
    assert len(page_now["text"].encode()) - len(body_now.encode()) > 0
    assert window["range"] == {"start": claim["source_start"], "end": claim["source_end"]}
    # The character-based offsets for the same quote are different, which is what
    # makes the assertion above about byte counting rather than a coincidence.
    char_start = source_text.index(source_quote)
    char_end = char_start + len(source_quote)
    assert (char_start, char_end) != (claim["source_start"], claim["source_end"])
    # Character offsets are not valid byte offsets at all for CJK text, so the
    # read is refused rather than returning something plausible.
    call(root, "read-source", id="raw/source.md", start=char_start, end=char_end,
         error="utf8_range_boundary_invalid")
    evidence_stats = call(root, "stats")["evidence"]
    source_stats = next(row for row in evidence_stats["coverage"]["sources"]
                        if row["source"] == "raw/source.md")
    assert source_stats["exact_source_claims"] == 1 and source_stats["legacy_source_claims"] == 0
    fingerprint = call(root, "status")["fingerprint"]
    call(root, "evidence-submit", page="concepts/source-anchor", page_hash=page["entry"]["sha256"],
         items=[{"source": "raw/source.md", "body_start": page_start,
                 "body_end": page_start + len(page_quote.encode()), "quote": page_quote,
                 "source_start": source_start, "source_end": source_start + len(source_quote.encode()),
                 "source_quote": "错误原文"}], error="evidence_source_quote_mismatch")
    assert call(root, "status")["fingerprint"] == fingerprint
    # The quote must be AT the recorded anchors, not merely present somewhere in
    # the source. These anchors point at the other bytes of the same file while
    # the quote is real, so only a check that slices at the anchors can refuse
    # them: verifying by searching the text would accept, and the recorded
    # anchors would then send a host to the wrong bytes.
    elsewhere = len(source_text.encode().split("原始事实：".encode(), 1)[0])
    call(root, "evidence-submit", page="concepts/source-anchor", page_hash=page["entry"]["sha256"],
         items=[{"source": "raw/source.md", "body_start": page_start,
                 "body_end": page_start + len(page_quote.encode()), "quote": page_quote,
                 "source_start": elsewhere,
                 "source_end": elsewhere + len("原始事实：".encode()),
                 "source_quote": source_quote}],
         error="evidence_source_quote_mismatch")
    assert call(root, "status")["fingerprint"] == fingerprint
    (root / "raw/source.md").write_text("来源发生漂移。\n")
    call(root, "scan")
    assert not call(root, "evidence-list", page="concepts/source-anchor")[0]["claims"][0]["valid"]
    # Drift where the quote survives but moves is the case that separates "the
    # quote is at the anchors" from "the quote is in the file". The recorded
    # anchors still point at the old bytes, so the claim must not verify -- a
    # check that merely searched the text would report it as still exact.
    (root / "raw/source.md").write_text("前缀说明。\n" + source_text, encoding="utf-8")
    call(root, "scan")
    moved = call(root, "evidence-list", page="concepts/source-anchor")[0]["claims"][0]
    assert moved["valid"] is False, moved
    assert moved["source_quote_verified"] is False, moved
    audit = call(root, "quality-audit", at="2026-10-18")
    assert any(row["predicate"] == "invalid_evidence_anchor" and
               row["page"] == "concepts/source-anchor" for row in audit["issues"])
    assert not any(row["predicate"] == "legacy_evidence_anchor" and
                   row["page"] == "concepts/source-anchor" for row in audit["issues"])

print("evidence source e2e: exact raw anchors, mismatch refusal and drift invalidation passed")
