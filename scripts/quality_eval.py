#!/usr/bin/env python3
"""Frozen real-project queries against curated reference pages; not an LLM benchmark."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
questions = json.loads((REPO / "tests/quality/questions.json").read_text())
results = []
with tempfile.TemporaryDirectory(prefix="corridor-quality-") as work:
    root = Path(work)
    subprocess.run(["python3", str(REPO / "scripts/make_demo.py"), work], check=True, capture_output=True, text=True)
    requests = [{"op": "search", "vault": work, "query": q["query"], "limit": 3} for q in questions]
    process = subprocess.run([str(REPO / "_build/native/debug/build/cli/cli.exe")], input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, check=True)
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    for q, response in zip(questions, responses, strict=True):
        assert response["ok"], response
        result = response["result"]
        hits = [h["id"] for h in result["hits"]]
        blocks = [b for b in result["context"]["blocks"] if b["id"] == q["expected"]]
        supported = bool(blocks) and q["source"] in blocks[0]["sources"]
        raw = (root / q["source"]).read_text()
        raw_exact_match = q["query"].lower() in raw.lower()
        results.append({**q, "hits": hits, "recall_at_3": q["expected"] in hits,
                        "source_attached": supported, "raw_exact_match": raw_exact_match})
report = {
    "dataset": "owned PROPOSAL.md and LICENSE; manually curated reference pages",
    "source_sha256": hashlib.sha256((REPO / "PROPOSAL.md").read_bytes()).hexdigest(),
    "questions_sha256": hashlib.sha256((REPO / "tests/quality/questions.json").read_bytes()).hexdigest(),
    "question_count": len(results),
    "recall_at_3": sum(r["recall_at_3"] for r in results) / len(results),
    "source_attachment_rate": sum(r["source_attached"] for r in results) / len(results),
    "raw_exact_match_rate": sum(r["raw_exact_match"] for r in results) / len(results),
    "scope": "retrieval/provenance smoke evaluation only; no model-generated page quality or semantic entailment claim",
    "results": results,
}
assert report["recall_at_3"] >= 0.8, report
assert report["source_attachment_rate"] == 1.0, report
(REPO / "docs/quality-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "results"}, ensure_ascii=False, indent=2))
