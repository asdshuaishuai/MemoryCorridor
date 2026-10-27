#!/usr/bin/env python3
"""Time the read paths that build a graph, to see whether the redundant verify matters."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=120).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def build(root, pages):
    call(root, "init", purpose="规模基准")
    for index in range(pages):
        name = f"source{index}.md"
        (root / "raw" / name).write_text(f"第 {index} 号来源正文。陶瓷与釉色。\n" * 3)
        order = call(root, "scan")["orders"][0]
        context = call(root, "context", order=order)
        call(root, "analysis-submit", order=order,
             context_token=context["context_token"],
             analysis={"entities": [], "concepts": [f"概念{index}"],
                       "conflicts": [], "summary": f"第 {index} 号"})
        staging = root / "staging" / order
        staging.mkdir(parents=True, exist_ok=True)
        (staging / "page.md").write_text(
            f"---\ntype: concept\ntitle: 概念{index}\nsources: [\"raw/{name}\"]\n---\n"
            f"第 {index} 号正文。\n"
        )
        call(root, "commit", order=order,
             pages=[{"id": f"concepts/c{index}", "path": f"wiki/concepts/c{index}.md",
                     "staged": f"staging/{order}/page.md"}],
             at=f"2026-11-14T09:{index % 60:02d}:00Z")
    call(root, "rebuild")


def timed(root, op, rounds=3, **fields):
    best = None
    for _ in range(rounds):
        start = time.perf_counter()
        call(root, op, **fields)
        elapsed = time.perf_counter() - start
        best = elapsed if best is None else min(best, elapsed)
    return best * 1000


with tempfile.TemporaryDirectory(prefix="memorycorridor-graph-") as temp:
    root = Path(temp)
    build(root, 24)
    print("pages: 24")
    for op, fields in [
        ("graph", {}),
        ("stats", {}),
        ("quality-audit", {"at": "2026-11-15T09:00:00Z"}),
        ("explore", {"query": "陶瓷", "limit": 5}),
    ]:
        try:
            print("  %-14s %7.1f ms" % (op, timed(root, op, **fields)))
        except Exception as exc:
            print("  %-14s ERROR %s" % (op, str(exc)[:60]))
    # purpose-suggest writes a record, so re-create the vault for a clean run.
    print("  purpose-suggest measured separately (writes a record)")
