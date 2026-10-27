#!/usr/bin/env python3
"""Reject hostile native requests without partial state or cache publication."""
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"


def snapshot(root):
    return {str(path.relative_to(root)): path.read_bytes()
            for path in root.rglob("*")
            if path.is_file() and not path.is_symlink() and ".corridor" not in path.relative_to(root).parts}


def call(root, op, error=None, **fields):
    run = subprocess.run(
        [str(EXE)],
        input=json.dumps({"op": op, "vault": str(root), **fields}, ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=30,
    )
    value = json.loads(run.stdout)
    assert "Panic" not in run.stderr and "Warning:" not in run.stderr, run.stderr
    if error is None:
        assert value["ok"], value
    else:
        assert not value["ok"] and error in value["error"], value
    return value


with tempfile.TemporaryDirectory(prefix="corridor-adversarial-") as work:
    root = Path(work)
    subprocess.run(
        ["python3", str(REPO / "scripts/make_demo.py"), work],
        check=True, capture_output=True, text=True,
    )
    baseline = call(root, "status")["result"]["fingerprint"]
    files = snapshot(root)

    malformed = [
        ("status", {"unexpected": True}, "unknown_field"),
        ("read-page", {"id": "../outside"}, "entry_not_found"),
        ("read-page", {"id": "/absolute"}, "entry_not_found"),
        ("read-page", {"id": ""}, "entry_not_found"),
        ("search", {"query": "x", "limit": 0}, "invalid_limit"),
        ("search", {"query": "x", "limit": 101}, "invalid_limit"),
        ("search", {"query": "x", "limit": 1.5}, "invalid_limit"),
        ("search", {"query": "x", "budget": 0}, "invalid_integer"),
        ("search", {"query": "x", "budget": -1}, "invalid_integer"),
        # The upper bound is a separate branch from the lower one: a clamp
        # that only rejects small values would pass every other case here.
        ("search", {"query": "x", "budget": 65537}, "invalid_integer"),
        ("search", {"query": "x", "budget": 65536}, None),
        ("read-source", {"id": "raw/LICENSE.txt", "start": 16777217}, "source_range_invalid"),
        ("read-source", {"id": "raw/LICENSE.txt", "start": 0, "end": 16777217},
         "source_range_invalid: end"),
        ("search", {"query": "x", "dedup": "fuzzy"}, "invalid_choice"),
        ("search", {"query": "x", "dedup": ""}, "invalid_choice"),
        ("search", {"query": "x", "dedup": True}, "invalid_choice"),
        ("search", {"query": "x", "dedup": "similar "}, "invalid_choice"),
        ("search", {"query": "x", "spread": "ranked_halves"}, "invalid_choice"),
        ("search", {"query": "x", "spread": 1}, "invalid_choice"),
        ("search", {"query": "x", "dedup": "similar", "spread": "even", "dedup_ratio": 0.9}, "unknown_field"),
        ("search", {"query": "x", "dedup": "similar", "spread": "unknown"}, "invalid_choice"),
        ("search", {"query": "x", "dedup": "unknown", "spread": "even"}, "invalid_choice"),
        ("graph", {"seed": "concepts/文学化目录", "hops": 9}, "invalid_integer"),
        ("graph", {"seed": "concepts/文学化目录", "hops": 1.5}, "invalid_integer"),
        ("view-init", {"view": "../escape"}, "unsafe_path"),
        ("render-view", {"view": "views/../escape.mbt.md"}, "unsafe_path"),
        ("embedding-submit", {"space": {"id": "bad", "dimensions": 0}, "items": []},
         "invalid_vector_dimension"),
        ("embedding-submit", {"space": {"id": "bad", "dimensions": 2}, "items": []},
         "vector_batch_size"),
    ]
    for op, fields, expected in malformed:
        call(root, op, error=expected, **fields)
        assert call(root, "status")["result"]["fingerprint"] == baseline, (op, fields)
        assert snapshot(root) == files, (op, fields)

    boundaries = [
        ("search", {"query": "x", "budget": 1, "dedup": "similar", "spread": "even"}),
        ("search", {"query": "x", "budget": 65536, "dedup": "similar", "spread": "even"}),
        ("search", {"query": "x", "budget": 1, "dedup": "exact", "spread": "ranked"}),
        ("search", {"query": "x", "budget": 65536, "dedup": "exact", "spread": "ranked"}),
        ("search", {"query": "x", "dedup": "similar"}),
        ("search", {"query": "x", "spread": "even"}),
    ]
    for op, fields in boundaries:
        result = call(root, op, **fields)["result"]
        assert result["context"]["used"] <= fields.get("budget", 4096), (op, fields)
        assert call(root, "status")["result"]["fingerprint"] == baseline, (op, fields)
        assert snapshot(root) == files, (op, fields)

    page = root / "wiki/concepts/文学化目录.md"
    original_page = page.read_text()
    rendered = (root / ".corridor/viewer.html").read_bytes()
    page.write_text(original_page.replace("title:", "title: Duplicate\ntitle:", 1))
    call(root, "refresh", error="unknown_or_duplicate_frontmatter")
    assert (root / "index.mbt.md").read_bytes() == files["index.mbt.md"]
    assert (root / ".corridor/viewer.html").read_bytes() == rendered
    page.write_text(original_page)

    view = root / "views/library.mbt.md"
    original_view = view.read_text()
    view.write_text("not a valid mbt.md declaration")
    call(root, "render-view", error="view_")
    assert (root / ".corridor/viewer.html").read_bytes() == rendered
    view.write_text(original_view)

    outside = root.parent / "outside.md"
    outside.write_text("outside")
    (root / "raw/hostile-link.md").symlink_to(outside)
    call(root, "scan", error="list_failed_or_symlink")
    (root / "raw/hostile-link.md").unlink()
    outside.unlink()
    assert call(root, "status")["result"]["fingerprint"] == baseline

    oversized = (
        json.dumps({"op": "status", "vault": str(root)})[:-1]
        + ",\"padding\":\"" + "x" * (2 * 1024 * 1024) + "\"}\n"
    )
    run = subprocess.run([str(EXE)], input=oversized, capture_output=True,
                         text=True, check=True, timeout=30)
    response = json.loads(run.stdout)
    assert not response["ok"] and "invalid_json" in response["error"]
    assert call(root, "status")["result"]["fingerprint"] == baseline

    call(root, "verify")
    assert call(root, "search", query="EmbeddingProvider")["result"]["hits"]

print("Adversarial native corpus: malformed fields, paths, budgets, vectors, declarations, symlinks and oversized requests rejected without state drift")
