#!/usr/bin/env python3
"""Real compiled vault: late evidence, byte budgets, duplicate provenance and transports."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"

with tempfile.TemporaryDirectory(prefix="corridor-retrieval-") as work:
    root = Path(work)

    def call(op, error=None, **fields):
        run = subprocess.run([str(EXE)], input=json.dumps(dict(fields, op=op, vault=work)) + "\n",
                             capture_output=True, text=True, check=True, timeout=30)
        value = json.loads(run.stdout)
        if error:
            assert not value["ok"] and error in value["error"], value
            return value
        assert value["ok"], value
        return value["result"]

    call("init")
    for source in ["a", "b"]:
        (root / f"raw/{source}.txt").write_text(f"Traceable source {source}; shared observations retained independently.\n")
    call("scan")
    bodies = {
        "concepts/a": "背景😀 introduction.\n" * 200 + "\n\nNeedle alpha evidence A.\n\n" + "后记😀 " * 200,
        "concepts/b": "另一前言𠀀.\n" * 200 + "\n\nNeedle beta evidence B.\n\n" + "结束😀 " * 200,
        "concepts/jp": "こんにちは世界。日本語の検索対象。\n",
    }
    bodies["concepts/copy"] = bodies["concepts/a"]
    for order in call("plan"):
        context = call("context", order=order["id"])
        token = context["context_token"]
        call("analysis-submit", order=order["id"], context_token=token,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "Curated test evidence."})
        ids = ["concepts/a"] if order["source"] == "raw/a.txt" else ["concepts/b", "concepts/copy", "concepts/jp"]
        pages = [{"id": pid, "kind": "concept", "title": "Needle" if pid != "concepts/jp" else "日本語",
                  "body": bodies[pid], "sources": [order["source"]], "tags": []} for pid in ids]
        staged = call("draft-submit", order=order["id"], context_token=token, pages=pages)
        call("commit", order=order["id"], context_token=token, pages=staged["pages"], at="2026-10-16")

    def validate_range(result, budget):
        context = result["context"]
        assert context["budget"] == budget and context["offset_unit"] == "body_utf8_bytes"
        assert context["estimate_recipe"] == "cjk_char_latin_word_v1"
        assert context["estimated_tokens"] == sum(block["estimated_tokens"] for block in context["blocks"])
        assert context["truncated"] == any(block["truncated"] for block in context["blocks"])
        actual = 0
        for block in context["blocks"]:
            assert block["estimated_tokens"] > 0
            page = call("read-page", id=block["id"])
            text = page["text"]
            body = text.split("\n---\n", 1)[1].encode()
            selected = body[block["body_start"]:block["body_end"]].decode()
            title = json.loads(next(line[7:] for line in text.splitlines() if line.startswith("title: ")))
            assert block["text"] == f'[{block["id"]}] {title}\n' + selected
            assert block["sha256"] == hashlib.sha256(text.encode()).hexdigest()
            assert block["sources"] == page["entry"]["sources"]
            actual += len(block["text"].encode())
        assert actual == context["used"] <= budget

    def validate(result, budget):
        validate_range(result, budget)
        context = result["context"]
        for block in context["blocks"]:
            body = call("read-page", id=block["id"])["text"].split("\n---\n", 1)[1].encode()
            for duplicate in block["duplicates"]:
                other = call("read-page", id=duplicate["id"])
                assert other["text"].split("\n---\n", 1)[1].encode() == body
                assert duplicate["sha256"] == hashlib.sha256(other["text"].encode()).hexdigest()
                assert duplicate["sources"] == other["entry"]["sources"]
                assert duplicate["path"] == other["entry"]["path"]

    def validate_similar(result, budget):
        validate_range(result, budget)
        context = result["context"]
        for block in context["blocks"]:
            body = call("read-page", id=block["id"])["text"].split("\n---\n", 1)[1].encode()
            for duplicate in block["duplicates"] + block["similar_duplicates"]:
                other = call("read-page", id=duplicate["id"])
                assert duplicate["sha256"] == hashlib.sha256(other["text"].encode()).hexdigest()
                assert duplicate["sources"] == other["entry"]["sources"]
                assert duplicate["path"] == other["entry"]["path"]
            for duplicate in block["paragraph_duplicates"] + block["similar_paragraph_duplicates"]:
                other = call("read-page", id=duplicate["id"])
                other_body = other["text"].split("\n---\n", 1)[1].encode()
                assert duplicate["sha256"] == hashlib.sha256(other["text"].encode()).hexdigest()
                assert duplicate["sources"] == other["entry"]["sources"]
                selected = other_body[duplicate["paragraph_start"]:duplicate["paragraph_end"]]
                assert hashlib.sha256(selected).hexdigest() == duplicate["paragraph_hash"]

    query = dict(query="needle", budget=400, hops=0)
    result = call("search", **query)
    assert [h["id"] for h in result["hits"]] == ["concepts/a", "concepts/b", "concepts/copy"]
    assert all("Needle" in h["excerpt"] for h in result["hits"])
    blocks = result["context"]["blocks"]
    assert [b["id"] for b in blocks] == ["concepts/a", "concepts/b"]
    assert "evidence A" in blocks[0]["text"] and "evidence B" in blocks[1]["text"]
    assert blocks[0]["duplicates"][0]["id"] == "concepts/copy"
    assert blocks[0]["sources"] == ["raw/a.txt"]
    assert blocks[0]["duplicates"][0]["sources"] == ["raw/b.txt"]
    assert all("Needle" not in body[:360] for body in bodies.values())  # Previous prefix selector missed it.
    repeated = call("search", **query)
    assert repeated["context"] == result["context"] and repeated["hits"] == result["hits"]
    validate(result, 400)
    for budget in [1, 2, 3, 4, 20, 31, 32, 33, 40, 80, 127, 128, 129, 400, 4096, 65536]:
        validate(call("search", query="needle", budget=budget), budget)

    # CJK unigram+bigram indexing finds substring queries inside Japanese text.
    japanese = call("search", query="こんにち", budget=200, hops=0)
    assert [h["id"] for h in japanese["hits"]] == ["concepts/jp"]
    assert "こんにちは世界" in japanese["context"]["blocks"][0]["text"]
    validate_range(japanese, 200)
    # Weighted graph expansion appends shared-source neighbors after the
    # retrieval hits (jp shares raw/b.txt with the b/copy seeds).
    expanded_result = call("search", query="needle", budget=2000, hops=1)
    expanded_ids = [b["id"] for b in expanded_result["context"]["blocks"]]
    assert expanded_ids[:3] == ["concepts/a", "concepts/b", "concepts/jp"], expanded_ids
    assert all(item.startswith("sources/") for item in expanded_ids[3:]), expanded_ids
    validate_range(expanded_result, 2000)
    # `hops` had only ever been passed as 0, 1 or 3 (refused), so the default of
    # 2 -- also the maximum for this operation -- was never exercised. On a graph
    # where one hop cannot reach everything, a silently clamped or ignored hops
    # looks exactly like a working one, so build a chain and require the second
    # hop to reach a node the first hop cannot.
    chain_pages = []
    for index in range(6):
        (root / "raw" / f"chain{index}.md").write_text(
            f"第{index}号链节来源。\n")
    chain_orders = call("scan")["orders"]
    for index in (5, 4, 3, 2, 1, 0):
        order = chain_orders[index]
        context = call("context", order=order)
        call("analysis-submit", order=order,
             context_token=context["context_token"],
             analysis={"entities": [], "concepts": [f"链节{index}"],
                       "conflicts": [], "summary": f"链节{index}"})
        staged = root / "staging" / order
        staged.mkdir(parents=True, exist_ok=True)
        forward = f" [[concepts/chain{index + 1}]]" if index < 5 else ""
        body = "独特关键标记。" if index == 0 else f"第{index}号普通正文。"
        (staged / "page.md").write_text(
            f"---\ntype: concept\ntitle: \"链节{index}\"\n"
            f"sources: [\"raw/chain{index}.md\"]\n---\n{body}{forward}\n"
        )
        call("commit", order=order,
             pages=[{"id": f"concepts/chain{index}",
                     "path": f"wiki/concepts/chain{index}.md",
                     "staged": f"staging/{order}/page.md"}], at="2026-10-16")
        chain_pages.append(f"concepts/chain{index}")
    call("rebuild")
    reached = {}
    for hops in (0, 1, 2):
        result = call("search", query="独特关键", budget=20000, hops=hops)
        reached[hops] = {block["id"] for block in result["context"]["blocks"]}
        validate_range(result, 20000)
    assert "concepts/chain1" in reached[1], sorted(reached[1])
    assert "concepts/chain2" not in reached[1], sorted(reached[1])
    assert "concepts/chain2" in reached[2], sorted(reached[2])
    # The default is the documented 2, not an accident of the call site.
    default = call("search", query="独特关键", budget=20000)
    assert {block["id"] for block in default["context"]["blocks"]} == reached[2]

    # RRF and keyword-only paths must use the same query-aware selector.
    entries = {p["id"]: p for p in call("list-pages")}
    space = {"id": "retrieval-test-v1", "dimensions": 2}
    call("embedding-submit", space=space, items=[{"page": pid, "sha256": entries[pid]["sha256"], "values": [1, 0]} for pid in bodies if pid != "concepts/jp"])
    vector = {"space": space, "values": [1, 0]}
    hybrid = call("search", **query, query_vector=vector)
    assert hybrid["vector_status"] == "brute_force"
    assert all("Needle" in h["excerpt"] for h in hybrid["hits"])
    validate(hybrid, 400)
    pure = call("search", query="", query_vector=vector, budget=400, hops=0)
    assert pure["context"]["blocks"][0]["body_start"] == 0
    validate(pure, 400)

    # MCP returns the same structured context, not a second implementation.
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "retrieval-test", "version": "1"}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "corridor_search", "arguments": dict(query, vault=work)}},
    ]
    mcp = subprocess.run([str(REPO / "_build/native/debug/build/mcp/mcp.exe")],
                         input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, check=True, timeout=30)
    messages = [json.loads(line) for line in mcp.stdout.splitlines()]
    assert len(messages) == 2 and not messages[1]["result"]["isError"]
    assert messages[1]["result"]["structuredContent"]["result"] == call("search", **query)

    # Never expose unregistered edits, including edits to a duplicate-only page.
    page = root / "wiki/concepts/copy.md"
    original = page.read_text()
    page.write_text(original + "\nUnregistered edit.")
    call("search", **query, error="content_changed")
    page.write_text(original)
    # Explicit similar/even modes: formatting-only near-duplicates merge into
    # similar_duplicates while keyword evidence stays intact; the ranked/exact
    # default above is unchanged.
    similar = call("search", query="needle", budget=400, hops=0, dedup="similar")
    assert similar["context"]["strategy"] == "similar_body_paragraph_ranked_v2"
    similar_blocks = similar["context"]["blocks"]
    assert [b["id"] for b in similar_blocks] == ["concepts/a", "concepts/b"]
    assert "evidence A" in similar_blocks[0]["text"] and "evidence B" in similar_blocks[1]["text"]
    similar_rows = similar["context"]["similar_duplicates"]
    assert [row["owner"] for row in similar_rows] == ["concepts/a"]
    assert [ref["id"] for ref in similar_rows[0]["duplicates"]] == ["concepts/copy"]
    assert similar_rows[0]["duplicates"][0]["similarity"] == 1.0
    similar_copy = call("read-page", id="concepts/copy")
    assert similar_rows[0]["duplicates"][0]["sha256"] == hashlib.sha256(similar_copy["text"].encode()).hexdigest()
    assert similar_rows[0]["duplicates"][0]["sources"] == similar_copy["entry"]["sources"]
    even = call("search", query="needle", budget=400, hops=0, dedup="similar", spread="even")
    assert even["context"]["strategy"] == "similar_body_paragraph_even_v2"
    assert even["context"]["used"] <= 400
    for block in even["context"]["blocks"]:
        even_page = call("read-page", id=block["id"])
        even_body = even_page["text"].split("\n---\n", 1)[1].encode()
        assert block["text"].endswith(even_body[block["body_start"]:block["body_end"]].decode())
    assert call("search", **query, dedup="unknown", error="invalid_choice")
    assert call("search", **query, spread="unknown", error="invalid_choice")
    validate_similar(similar, 400)
    validate_similar(even, 400)
    # A one-character difference must stop deduplication after explicit adoption.
    page.write_text(original + "!")
    call("refresh")
    changed = call("search", **query)
    assert len(changed["context"]["blocks"]) == 3
    assert all(not b["duplicates"] for b in changed["context"]["blocks"])
    validate(changed, 400)
    changed_similar = call("search", query="needle", budget=400, hops=0, dedup="similar")
    assert "similar_duplicates" in changed_similar["context"]
    validate_similar(changed_similar, 400)
    call("forget", source="raw/a.txt", at="2026-10-16")
    remaining = call("search", **query)
    assert all(h["id"] != "concepts/a" for h in remaining["hits"])
    assert all("raw/a.txt" not in b["sources"] for b in remaining["context"]["blocks"])
    validate(remaining, 400)
    call("verify")

print("Retrieval context: late evidence, ranked budgets, exact-body provenance, UTF-8 ranges, RRF/MCP parity and drift/forget rejection passed")
