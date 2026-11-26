#!/usr/bin/env python3
"""Wire the macOS NLEmbedding host adapter into the real vector pipeline.

The engine still does not import an OS framework. This script drives the same
provider seam as embed-rs: provider-register -> embedding-plan -> os-embed ->
embedding-submit -> rebuild -> search(query_vector). It skips cleanly when the
adapter is not built or the platform is not macOS.

Run:
  scripts/build_os_embed.sh
  python3 -I scripts/os_embed_e2e.py
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
OS_EMBED = Path(os.environ.get("OS_EMBED_BIN", REPO / "adapters/os-embed/os-embed"))
SPACE = {"id": "os-nl-zh-v1", "dimensions": 640}


def available():
    return sys.platform == "darwin" and OS_EMBED.is_file()


def embed_items(items):
    completed = subprocess.run(
        [str(OS_EMBED), "--language", "zh"],
        input=json.dumps(items), capture_output=True, text=True, check=True, timeout=120)
    return json.loads(completed.stdout)


def main():
    if not CLI.is_file():
        print("SKIP: build the CLI first (moon build --target native cli)")
        return 0
    if not available():
        print("SKIP os_embed_e2e: macOS NLEmbedding adapter not built "
              "(run scripts/build_os_embed.sh); the engine vector seam is still "
              "covered by redundancy_e2e.py.")
        return 0
    with tempfile.TemporaryDirectory(prefix="corridor-os-embed-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            completed = subprocess.run(
                [str(CLI)], input=json.dumps({"op": op, "vault": str(vault), **fields}) + "\n",
                capture_output=True, text=True, check=True, timeout=120)
            value = json.loads(completed.stdout)
            if error:
                assert not value["ok"] and error in value["error"], value
                return value
            assert value["ok"], value
            return value["result"]

        call("init", purpose="系统向量端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/x.md").write_text("龙泉窑青瓷釉色记录。\n", encoding="utf-8")
        call("scan")
        order = call("plan")[0]["id"]
        call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "系统向量"})
        pages = [
            {"id": "concepts/paraphrase-a", "path": "wiki/concepts/paraphrase-a.md",
             "body": "龙泉窑的青瓷以粉青和梅子青这两种釉色最为著名"},
            {"id": "concepts/paraphrase-b", "path": "wiki/concepts/paraphrase-b.md",
             "body": "梅子青与粉青是龙泉窑青瓷最具代表性的釉色"},
            {"id": "concepts/unrelated", "path": "wiki/concepts/unrelated.md",
             "body": "把 JavaScript 对象转换为 JSON 字符串的标准方法是 JSON.stringify"},
        ]
        staged = []
        for index, page in enumerate(pages):
            staged_path = vault / f"staging/{order}/{index}.md"
            staged_path.parent.mkdir(parents=True, exist_ok=True)
            staged_path.write_text(
                f'---\ntype: concept\ntitle: t{index}\nsources: ["raw/x.md"]\n---\n'
                + page["body"] + "\n", encoding="utf-8")
            staged.append({"id": page["id"], "path": page["path"],
                           "staged": f"staging/{order}/{index}.md"})
        call("commit", order=order, pages=staged, at="2026-11-26T00:00:00Z")
        call("rebuild")
        call("provider-register", provider="os-nl", kind="embedding", space=SPACE,
             capabilities=["embed"], at="2026-11-26T00:01:00Z")
        plan = call("embedding-plan", space=SPACE, provider="os-nl")
        assert plan["items"], plan
        submitted = embed_items(plan["items"])
        assert len(submitted) == len(plan["items"])
        assert all(len(item["values"]) == SPACE["dimensions"] for item in submitted)
        call("embedding-submit", space=SPACE, items=submitted, provider="os-nl")
        call("rebuild")
        query = embed_items([{"page": "query", "sha256": "0" * 64,
                              "text": "哪种釉色最能代表龙泉窑的青瓷"}])[0]["values"]
        hits = call("search", query="", provider="os-nl",
                    query_vector={"space": SPACE, "values": query})["hits"]
        ids = [hit["id"] for hit in hits]
        assert "concepts/unrelated" not in ids[:2], ids
        assert {"concepts/paraphrase-a", "concepts/paraphrase-b"} <= set(ids[:2]), ids
        # The same host vector drives the chunk-level system lane: page hits
        # map to the page's first chunk and the lane reports its space.
        retrieved = call("retrieve", query="哪种釉色最能代表龙泉窑的青瓷", provider="os-nl",
                         limit=5, query_vector={"space": SPACE, "values": query})
        lanes = retrieved["lanes"]
        assert lanes["vector"] == "system", lanes
        assert lanes["reason"] == "provider_vectors", lanes
        assert lanes["vector_space"]["id"] == SPACE["id"], lanes
        assert lanes["vector_space"]["dimensions"] == SPACE["dimensions"], lanes
        pages = [hit["page"] for hit in retrieved["hits"]]
        assert pages[0] in {"concepts/paraphrase-a", "concepts/paraphrase-b"}, pages
        assert "concepts/unrelated" not in pages[:2], pages
        assert any(hit["lanes"]["vector_rank"] > 0 for hit in retrieved["hits"]), retrieved
        # Without query_vector the same call is a text+algorithm response; the
        # lack of a system engine is reported instead of silently omitted.
        fallback = call("retrieve", query="龙泉窑青瓷釉色", limit=5)["lanes"]
        assert fallback["vector"] == "algo", fallback
        assert fallback["reason"] == "no_system_engine", fallback
        # A query vector without a named provider is refused: the system lane
        # must be traceable to a registered embedding provider.
        call("retrieve", query="龙泉窑青瓷釉色", provider=None,
             query_vector={"space": SPACE, "values": query},
             error="retrieve_provider_required")
        # The vector is a real provider record; a stale page vector must not be
        # used after its content hash changes.
        (vault / "raw/x.md").write_text("龙泉窑青瓷釉色记录。\n\n新增内容。\n", encoding="utf-8")
        call("scan")
        rebuild_order = next(row for row in call("plan")
                             if row["source"] == "raw/x.md")["id"]
        call("context", order=rebuild_order)
        call("analysis-submit", order=rebuild_order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "rewrite"})
        rewrite = vault / f"staging/{rebuild_order}/0.md"
        rewrite.write_text('---\ntype: concept\ntitle: t0\nsources: ["raw/x.md"]\n---\n'
                           "彻底改写的甲页与乙页梅子青毫无关系了\n", encoding="utf-8")
        call("commit", order=rebuild_order, pages=[{"id": "concepts/paraphrase-a",
             "path": "wiki/concepts/paraphrase-a.md",
             "staged": f"staging/{rebuild_order}/0.md"}], at="2026-11-26T00:02:00Z")
        call("rebuild")
        stale_plan = call("embedding-plan", space=SPACE, provider="os-nl")
        assert any(item["page"] == "concepts/paraphrase-a" for item in stale_plan["items"]), stale_plan
    print("os embed e2e: macOS NLEmbedding host adapter drives registered vector search and content-version invalidation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
