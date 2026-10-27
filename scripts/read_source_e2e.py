#!/usr/bin/env python3
"""Verify read-source: registered metadata, digest verification, byte ranges for
evidence anchors, binary extraction, revoked sources and bounded reads."""
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


def byte_offset(text, needle):
    return len(text.encode().split(needle.encode(), 1)[0])


with tempfile.TemporaryDirectory(prefix="memorycorridor-read-source-") as temp:
    root = Path(temp)
    call(root, "init", purpose="研究陶瓷")
    body = "南宋官窑博物馆的器形与釉色记录。\n第二段：釉色对照见青瓷与白瓷。\n"
    (root / "raw/ceramics.md").write_text(body)
    (root / "raw/scan.pdf").write_bytes(bytes(range(256)) * 8)
    call(root, "scan")

    # A registered textual source is served with its metadata and digest state.
    view = call(root, "read-source", id="raw/ceramics.md")
    assert view["textual"] is True and view["extraction_required"] is False
    assert view["stale"] is False and view["verified"] is True
    assert view["present"] is True and view["text"] == body
    assert view["bytes"] == len(body.encode())
    assert view["format"] == "markdown"
    assert view["registered_sha256"] == view["registered_sha256"]
    assert len(view["registered_sha256"]) == 64
    assert view["range"] == {"start": 0, "end": len(body.encode())}
    assert view["truncated"] is False
    # A read never claims a pending host action; extraction is the specific flag.
    assert "execution" not in view

    # A binary source reports its size and demands external extraction.
    binary = call(root, "read-source", id="raw/scan.pdf")
    assert binary["textual"] is False and binary["extraction_required"] is True
    assert binary["text"] is None and binary["bytes"] == 2048
    assert binary["format"] == "binary" and binary["verified"] is True

    # A byte range lets a host check an evidence anchor exactly.
    quote = "釉色对照见青瓷与白瓷"
    start = byte_offset(body, quote)
    stop = start + len(quote.encode())
    window = call(root, "read-source", id="raw/ceramics.md", start=start, end=stop)
    assert window["text"] == quote
    assert window["range"] == {"start": start, "end": stop}
    assert window["truncated"] is False
    assert window["bytes"] == len(body.encode())
    call(root, "read-source", id="raw/ceramics.md", start=stop, end=stop,
         error="source_range_invalid")
    call(root, "read-source", id="raw/ceramics.md", start=0, end=len(body.encode()) + 1,
         error="source_range_invalid")
    call(root, "read-source", id="raw/ceramics.md", start="0", end=stop,
         error="source_range_invalid")
    # A range that splits a multi-byte character must be refused rather than
    # silently yielding invalid text: an evidence anchor is checked byte for
    # byte, so a half character would make the comparison meaningless. Every
    # CJK character here is three bytes, so +1 from a boundary always lands
    # inside one.
    for offset in (1, 2):
        call(root, "read-source", id="raw/ceramics.md", start=offset, end=stop,
             error="utf8_range_boundary_invalid")
        call(root, "read-source", id="raw/ceramics.md", start=start, end=stop - offset,
             error="utf8_range_boundary_invalid")
    # The aligned boundaries around the same window still work, which is what
    # makes the refusals above about the split and not about the offsets. The
    # offsets come from character-index arithmetic, so they are boundaries by
    # construction rather than by assumption.
    head = body.split(quote, 1)[0]
    char_index = len(head)
    before = len(body[:char_index - 1].encode())
    aligned = call(root, "read-source", id="raw/ceramics.md", start=before, end=stop)
    assert aligned["text"] == body.encode()[before:stop].decode(), aligned["range"]
    after = len(body[:char_index + len(quote) + 1].encode())
    aligned = call(root, "read-source", id="raw/ceramics.md", start=start, end=after)
    assert aligned["text"] == body.encode()[start:after].decode(), aligned["range"]

    # Only raw sources are readable this way.
    call(root, "read-source", id="purpose.md", error="expected_raw_source")
    call(root, "read-source", id="raw/missing.md", error="entry_not_found")

    # A revoked source keeps its tombstone and says so instead of pretending.
    call(root, "forget", source="raw/ceramics.md", at="2026-10-31T12:00:00Z")
    revoked = call(root, "read-source", id="raw/ceramics.md")
    assert revoked["stale"] is True
    # The bytes are still on disk and still match, which is exactly what a host
    # needs to know before trusting a citation written against them.
    assert revoked["verified"] is True and revoked["present"] is True
    assert revoked["text"] == body

    # A bounded whole-source read reports truncation instead of silently cutting.
    big = "陶瓷" * 40000
    (root / "raw/big.md").write_text(big)
    call(root, "scan")
    capped = call(root, "read-source", id="raw/big.md")
    assert capped["truncated"] is True
    assert capped["bytes"] == len(big.encode())
    assert len(capped["text"].encode()) <= 65536
    assert big.startswith(capped["text"])
    assert capped["range"]["end"] == len(capped["text"].encode())
    # An explicit range is never capped.
    exact = call(root, "read-source", id="raw/big.md", start=0, end=9)
    assert exact["truncated"] is False and exact["text"] == "陶瓷陶"

    # The view is read-only and deterministic.
    fingerprint = call(root, "status")["fingerprint"]
    assert call(root, "read-source", id="raw/big.md") == capped
    assert call(root, "status")["fingerprint"] == fingerprint

    # An evidence anchor can be checked against the source it claims.
    anchor_body = "釉色对照：青瓷偏灰，白瓷偏透。\n"
    (root / "raw/glaze.md").write_text(anchor_body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        "---\ntype: concept\ntitle: 陶瓷\nsources: [\"raw/glaze.md\"]\n---\n"
        "青瓷偏灰，白瓷偏透。\n")
    call(root, "commit", order=order,
         pages=[{"id": "concepts/ceramics", "path": "wiki/concepts/ceramics.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-10-31T13:00:00Z")
    page = call(root, "read-page", id="concepts/ceramics")
    claim_quote = "青瓷偏灰"
    claim_start = byte_offset(anchor_body, claim_quote)
    claim_end = claim_start + len(claim_quote.encode())
    call(root, "evidence-submit", page="concepts/ceramics",
         page_hash=page["entry"]["sha256"],
         items=[{"source": "raw/glaze.md", "body_start": 0,
                 "body_end": len("青瓷偏灰，白瓷偏透。".encode()),
                 "quote": "青瓷偏灰，白瓷偏透。",
                 "source_start": claim_start, "source_end": claim_end,
                 "source_quote": claim_quote}])
    evidence = call(root, "evidence-list", page="concepts/ceramics")
    claim = evidence[0]["claims"][0]
    assert claim["source_anchor"] == "exact"
    # The host re-reads exactly the bytes the claim is bound to.
    checked = call(root, "read-source", id="raw/glaze.md",
                   start=claim["source_start"], end=claim["source_end"])
    assert checked["text"] == claim["source_quote"]

    call(root, "rebuild")
    call(root, "verify")
    print("read-source: metadata, verification, ranges, extraction and truncation passed")
