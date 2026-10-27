#!/usr/bin/env python3
"""Measure native retrieval and vault-lock behavior on real generated vaults.

This is a diagnostic benchmark, not a correctness gate: it records the local
machine/toolchain and refuses to claim a portable SLA. Use --pages to repeat
with a chosen size; --json writes a reviewable result.
"""
from concurrent.futures import ThreadPoolExecutor
import argparse
import datetime
import json
import math
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"

parser = argparse.ArgumentParser()
parser.add_argument("--pages", type=int, nargs="+", default=[32, 128, 256])
parser.add_argument("--queries", type=int, default=8)
parser.add_argument("--workers", type=int, nargs="+", default=[8])
parser.add_argument("--notes", type=int, default=64,
                    help="memory notes submitted before the memory probe")
parser.add_argument("--json", type=Path, default=REPO / "docs/scale-benchmark.json")
args = parser.parse_args()
if any(n < 4 or n > 2048 for n in args.pages) or args.queries < 1 or any(w < 1 for w in args.workers):
    parser.error("pages must be 4..2048; queries/workers must be positive")


def call(root, op, **fields):
    started = time.perf_counter()
    run = subprocess.run([str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
                         capture_output=True, text=True, check=True, timeout=120)
    elapsed = (time.perf_counter() - started) * 1000
    result = json.loads(run.stdout)
    assert result["ok"], result
    return result["result"], elapsed


def build(root, count):
    call(root, "init", purpose=f"规模基准 {count} pages")
    (root / "raw/benchmark.md").write_text("Benchmark source with needle-alpha and needle-beta evidence.\n")
    scan, _ = call(root, "scan")
    order = scan["orders"][0]
    context, _ = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["needle-alpha", "needle-beta"], "conflicts": [], "summary": "benchmark"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    declarations = []
    for index in range(count):
        page_id = f"concepts/p{index:04d}"
        body = (f"# Page {index}\n\nneedle-alpha evidence {index}. "
                f"needle-beta relation {index}. " + "context padding " * (60 + index % 40) +
                f"\n\nneedle-alpha closing evidence {index}. " + "tail padding " * (60 + index % 40) + "\n")
        staged = staging / f"{index}.md"
        staged.write_text("---\ntype: concept\ntitle: " + json.dumps(f"Page {index}") +
                          "\nsources: [\"raw/benchmark.md\"]\n---\n" + body)
        declarations.append({"id": page_id, "path": f"wiki/{page_id}.md", "staged": str(staged.relative_to(root))})
    call(root, "commit", order=order, context_token=context["context_token"], pages=declarations, at="2026-10-16")
    pages, _ = call(root, "list-pages")
    space = {"id": "benchmark-v1", "dimensions": 8}
    items = []
    for index, page in enumerate(pages):
        if not page["id"].startswith("concepts/"): continue
        values = [1.0 if index % 8 == axis else 0.1 for axis in range(8)]
        items.append({"page": page["id"], "sha256": page["sha256"], "values": values})
    for start in range(0, len(items), 128):
        call(root, "embedding-submit", space=space, items=items[start:start + 128])
    call(root, "rebuild")
    return space


def run_one(root, space, queries):
    rows = []
    for query, vector in [("needle-alpha", None), ("", {"space": space, "values": [1.0] + [0.1] * 7}),
                          ("needle-beta", {"space": space, "values": [0.1, 1.0] + [0.1] * 6})]:
        for _ in range(queries):
            fields = {"query": query, "limit": 10, "budget": 4096, "hops": 0}
            if vector is not None: fields["query_vector"] = vector
            result, elapsed = call(root, "search", **fields)
            assert result["hits"] and result["context"]["used"] <= 4096
            rows.append({"mode": "hybrid" if vector and query else "vector" if vector else "keyword", "ms": elapsed})
    return rows


def allocation_probe(root, queries):
    """Measured quota comparison under a tight budget: ranked/exact vs even/exact vs even/similar."""
    rows = []
    for dedup, spread in [("exact", "ranked"), ("exact", "even"), ("similar", "even")]:
        sizes = []
        blocks_seen = []
        elapsed_values = []
        last_strategy = ""
        for _ in range(queries):
            result, elapsed = call(root, "search", query="needle-alpha", limit=10, budget=1200, hops=0,
                                   dedup=dedup, spread=spread)
            context = result["context"]
            assert context["used"] <= 1200
            last_strategy = context["strategy"]
            sizes.append(len(context["blocks"]))
            blocks_seen.append(sum(len(block["text"].encode()) for block in context["blocks"]))
            elapsed_values.append(elapsed)
        rows.append({"dedup": dedup, "spread": spread, "strategy": last_strategy,
                     "median_ms": statistics.median(elapsed_values),
                     "median_blocks": statistics.median(sizes),
                     "median_block_bytes": statistics.median(blocks_seen)})
    return rows


def concurrent_probe(root, workers):
    def request(_):
        started = time.perf_counter()
        run = subprocess.run([str(EXE)], input=json.dumps({"op": "status", "vault": str(root)}) + "\n",
                             capture_output=True, text=True, check=True, timeout=120)
        elapsed = (time.perf_counter() - started) * 1000
        value = json.loads(run.stdout)
        return {"ok": value["ok"], "error": value.get("error"), "ms": elapsed}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        rows = list(pool.map(request, range(workers)))
    assert all(row["ok"] or row["error"].startswith("vault_locked") for row in rows)
    return rows


def memory_probe(root, notes, queries):
    """Measure the A5-derived surfaces that scale with the note count.

    `memory-prefetch` rebuilds an index over every note on each call, so it is
    the one place where the memory layer can regress silently as notes grow.
    """
    for index in range(notes):
        call(root, "memory-submit", kind="preference" if index % 2 else "constraint",
             scope="workspace", text=f"记忆判断 {index}：陶瓷器形与釉色的核对方式",
             conditions=[f"条件 {index % 8}"], sources=[], at="2026-10-16",
             key=f"memory-{index}")
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"], at="2026-10-16",
         key="scale-topic")
    rows = []
    for op, fields in [("memory-prefetch", {"query": "陶瓷 器形 釉色", "limit": 10}),
                       ("memory-list", {}),
                       ("inbox", {}),
                       ("impact-audit", {"at": "2026-10-17"})]:
        samples = []
        for _ in range(queries):
            result, elapsed = call(root, op, **fields)
            assert result is not None
            if op == "memory-prefetch":
                assert result["notes"] and result["estimated_tokens"] > 0
            samples.append(elapsed)
        ordered = sorted(samples)
        p95_index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * 0.95) - 1))
        rows.append({"op": op, "samples": len(samples), "median_ms": statistics.median(samples),
                     "p95_ms": ordered[p95_index]})
    return rows


reports = []
with tempfile.TemporaryDirectory(prefix="corridor-scale-") as work:
    for count in args.pages:
        root = Path(work) / str(count)
        root.mkdir()
        space = build(root, count)
        rows = run_one(root, space, args.queries)
        allocation = allocation_probe(root, args.queries)
        concurrency = []
        for workers in args.workers:
            probe = concurrent_probe(root, workers)
            concurrency.append({
                "workers": workers, "successful": sum(r["ok"] for r in probe),
                "locked": sum(not r["ok"] for r in probe),
                "max_ms": max(r["ms"] for r in probe),
            })
        call(root, "verify")
        by_mode = {}
        for mode in {row["mode"] for row in rows}:
            values = [row["ms"] for row in rows if row["mode"] == mode]
            ordered = sorted(values)
            p95_index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * 0.95) - 1))
            by_mode[mode] = {"samples": len(values), "median_ms": statistics.median(values),
                             "p95_ms": ordered[p95_index]}
        memory = memory_probe(root, args.notes, args.queries)
        reports.append({"pages": count, "vectors": count, "queries": args.queries,
                        "notes": args.notes,
                        "retrieval": by_mode, "allocation": allocation, "memory": memory,
                        "concurrency": concurrency})
result = {"date": datetime.date.today().isoformat(), "platform": subprocess.run(["uname", "-a"], capture_output=True, text=True, check=True).stdout.strip(),
          "tool": "native cli", "scope": "diagnostic local baseline; no portable SLA", "cases": reports}
args.json.parent.mkdir(parents=True, exist_ok=True)
args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(result, ensure_ascii=False, indent=2))
