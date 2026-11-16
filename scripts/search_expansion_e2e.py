#!/usr/bin/env python3
"""Search expansion end-to-end (续四十九).

Proves the host-side wiring of the NLP adapter into retrieval: one user query
becomes 1..8 engine queries, hits are merged by page with the expansion that
produced them recorded, and the engine's read-only contract is untouched.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
EXPANDER = ROOT / "scripts/search_expander.py"


def main():
    with tempfile.TemporaryDirectory(prefix="corridor-search-expand-") as work:
        vault = Path(work)

        def call(op, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="检索扩展端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/a.md").write_text("青瓷证据甲。\n", encoding="utf-8")
        call("scan")
        order = next(o for o in call("plan") if o["source"] == "raw/a.md")["id"]
        call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "d"})
        staged = vault / f"staging/{order}/0.md"
        staged.parent.mkdir(parents=True, exist_ok=True)
        staged.write_text(
            '---\ntype: concept\ntitle: 甲\nsources: ["raw/a.md"]\n---\n青瓷正文甲。\n',
            encoding="utf-8")
        call("commit", order=order, at="2026-11-16",
             pages=[{"id": "concepts/a", "path": "wiki/concepts/a.md",
                     "staged": f"staging/{order}/0.md"}])
        call("rebuild")

        before = {path: path.read_bytes() for path in
                  [vault / "wiki/concepts/a.md", vault / "raw/a.md"]}
        run = subprocess.run([sys.executable, str(EXPANDER), "--vault", str(vault),
                              "--cli", str(EXE), "--query", "青瓷的来源",
                              "--provider", "auto", "--limit", "5"],
                             capture_output=True, text=True, timeout=120)
        assert run.returncode == 0, (run.stdout, run.stderr)
        summary = json.loads(run.stdout)
        assert summary["provider"] in ("hanlp", "lexicon"), summary
        if summary["provider"] == "lexicon":
            assert summary.get("auto_fallback"), summary
        assert summary["expansions"][0] == "青瓷的来源", summary
        assert len(summary["expansions"]) >= 2, summary
        assert summary["count"] >= 1, summary
        pages = {hit["id"] for hit in summary["results"] if "id" in hit}
        assert "concepts/a" in pages, summary
        for hit in summary["results"]:
            assert hit["matched_query"] in summary["expansions"], hit
            assert hit["expansion_source"].startswith("nlp_adapter:"), hit
        assert summary["errors"] == [], summary
        assert all(path.read_bytes() == content for path, content in before.items())

    print("search expansion e2e: auto expansion, per-query engine calls, merged hits "
          "with expansion source, read-only knowledge passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())