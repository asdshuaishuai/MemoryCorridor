#!/usr/bin/env python3
"""Host search entry with NLP query expansion (续四十九).

The engine's `search` op takes one `query`; the NLP adapter's `expand` returns
1..8 candidate queries. This host wrapper runs the engine per expanded query,
merges hits by page (first/best wins), and records which expansion produced each
hit. It never writes knowledge pages and never bypasses the engine's evidence
and budget gates.

Usage:
  python3 scripts/search_expander.py --vault /abs/vault --query "青瓷的来源"
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "_build/native/debug/build/cli/cli.exe"
sys.path.insert(0, str(ROOT / "scripts"))
import nlp_adapter  # noqa: E402


def call(cli: str, vault: str, op: str, **fields):
    run = subprocess.run([cli], input=json.dumps(dict(fields, op=op, vault=vault)) + "\n",
                         capture_output=True, text=True, check=True, timeout=120)
    response = json.loads(run.stdout)
    if not response["ok"]:
        raise RuntimeError("%s: %s" % (op, response.get("error", "engine error")))
    return response["result"]


def main() -> int:
    parser = argparse.ArgumentParser(description="Search with NLP query expansion")
    parser.add_argument("--vault", required=True)
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    parser.add_argument("--query", required=True)
    parser.add_argument("--provider", default="auto",
                        choices=["auto", "lexicon", "llm", "hanlp"])
    parser.add_argument("--limit", type=int, default=10, help="hits per query (1..100)")
    parser.add_argument("--max-queries", type=int, default=8, help="expansions to run (1..8)")
    args = parser.parse_args()
    if not 1 <= args.limit <= 100:
        parser.error("--limit must be in 1..100")
    if not 1 <= args.max_queries <= 8:
        parser.error("--max-queries must be in 1..8")

    expansion = nlp_adapter.expand(args.query, provider=args.provider)
    queries = expansion["queries"][:args.max_queries]
    merged = []
    seen = set()
    errors = []
    for query in queries:
        try:
            page = call(args.cli, args.vault, "search", query=query, limit=args.limit)
        except RuntimeError as error:
            errors.append({"query": query, "error": str(error)[:200]})
            continue
        for hit in page.get("hits", []):
            key = hit.get("page") or hit.get("id")
            if not key or key in seen:
                continue
            seen.add(key)
            record = dict(hit)
            record["matched_query"] = query
            record["expansion_source"] = "nlp_adapter:" + expansion["provider"]
            merged.append(record)
    print(json.dumps({
        "query": args.query,
        "expansions": queries,
        "provider": expansion["provider"],
        "auto_fallback": expansion.get("auto_fallback"),
        "results": merged,
        "errors": errors,
        "count": len(merged),
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())