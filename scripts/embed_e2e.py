#!/usr/bin/env python3
"""End-to-end acceptance for the native embedding provider (续二十五).

Wires adapters/embed-rs (bge-small-zh-v1.5 ONNX over the ONNX Runtime OCR
already introduced) into the engine's real vector pipeline:
  provider-register -> embedding-plan -> embed-rs -> embedding-submit ->
  rebuild -> search(query_vector) + page-redundancy(vector_cosine).

Unlike redundancy_e2e.py (hand-built vectors), here the vectors come from a
genuine embedding model, so the paraphrased pages are nominated by real
semantic similarity. SKIPs cleanly (exit 0) when the adapter binary or the
pinned model is absent, so CI without the model download is unaffected.

Run:
  EMBED_BIN=adapters/embed-rs/target/release/embed-adapter \
  ORT_DYLIB_PATH=... EMBED_MODEL_DIR=adapters/embed-rs/model \
  python3 scripts/embed_e2e.py
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
EMBED_BIN = os.environ.get("EMBED_BIN")
SPACE = {"id": "model-content-v1:recipe-v1", "dimensions": 512}


def available():
    if not EMBED_BIN or not Path(EMBED_BIN).exists():
        return False
    if not os.environ.get("ORT_DYLIB_PATH"):
        return False
    model_dir = os.environ.get("EMBED_MODEL_DIR", str(REPO / "adapters/embed-rs/model"))
    return (Path(model_dir) / "model_int8.onnx").exists()


def embed_items(items):
    """Run the adapter on [{page,sha256,text}] -> [{page,sha256,values}]."""
    proc = subprocess.run([EMBED_BIN], input=json.dumps(items),
                          capture_output=True, text=True, check=True, timeout=180)
    return json.loads(proc.stdout)


def embed_query(text):
    return embed_items([{"page": "query", "sha256": "0" * 64, "text": text}])[0]["values"]


def main():
    if not CLI.exists():
        print("SKIP: build the CLI first (moon build --target native cli)")
        return 0
    if not available():
        print("SKIP embed_e2e: EMBED_BIN/ORT_DYLIB_PATH/model not present "
              "(adapters/embed-rs + scripts/fetch_bge.sh). The engine's vector "
              "subsystem itself stays gated by redundancy_e2e.py.")
        return 0
    with tempfile.TemporaryDirectory(prefix="corridor-embed-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            run = subprocess.run([str(CLI)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=60)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"] and error in response["error"], response
                return response
            assert response["ok"], response
            return response["result"]

        call("init", purpose="语义嵌入端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/x.md").write_text("龙泉窑青瓷的证据。\n", encoding="utf-8")
        call("scan")
        order = call("plan")[0]["id"]
        call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "e"})
        # two paraphrased pages: distinct wording, same meaning -> real model
        # should place them close (vector_cosine), unlike a token diff.
        pages = [
            {"id": "concepts/paraphrase-a", "path": "wiki/concepts/paraphrase-a.md",
             "body": "龙泉窑的青瓷以粉青和梅子青这两种釉色最为著名"},
            {"id": "concepts/paraphrase-b", "path": "wiki/concepts/paraphrase-b.md",
             "body": "梅子青与粉青是龙泉窑青瓷最具代表性的釉色"},
            {"id": "concepts/unrelated", "path": "wiki/concepts/unrelated.md",
             "body": "把 JavaScript 对象转换为 JSON 字符串的标准方法是 JSON.stringify"},
        ]
        staged = []
        for i, pg in enumerate(pages):
            sp = vault / f"staging/{order}/{i}.md"
            sp.parent.mkdir(parents=True, exist_ok=True)
            sp.write_text(f'---\ntype: concept\ntitle: t{i}\nsources: ["raw/x.md"]\n---\n'
                          + pg["body"] + "\n", encoding="utf-8")
            staged.append({"id": pg["id"], "path": pg["path"], "staged": f"staging/{order}/{i}.md"})
        call("commit", order=order, pages=staged, at="2026-11-04")
        call("rebuild")

        # register the embedding provider, then produce real vectors.
        call("provider-register", provider="embed-rs", kind="embedding",
             space=SPACE, capabilities=["embed"], at="2026-11-04T00:00:00Z")
        plan = call("embedding-plan", space=SPACE, provider="embed-rs")
        assert plan["space"] == SPACE and plan["items"], plan
        submitted = embed_items(plan["items"])
        # feed the model's vectors back through the engine's validated channel
        call("embedding-submit", space=SPACE, items=submitted, provider="embed-rs")
        call("rebuild")

        # 1. semantic search: a query in different words still ranks the two
        #    celadon pages above the JSON page (real embedding, not keywords).
        q = embed_query("哪种釉色最能代表龙泉窑的青瓷")
        hits = [h["id"] for h in call("search", query="", query_vector={"space": SPACE, "values": q},
                                      provider="embed-rs")["hits"]]
        assert "concepts/unrelated" not in hits[:2], hits
        assert {"concepts/paraphrase-a", "concepts/paraphrase-b"} <= set(hits[:2]), hits

        # 2. page-redundancy now nominates the paraphrase pair by real vector
        #    cosine (续二十三's vector path driven by a genuine model).
        red = call("page-redundancy", space=SPACE)
        vc = [c for c in red["candidates"] if c["reason"] == "vector_cosine"]
        assert vc, red["candidates"]
        pair = vc[0]
        assert {pair["keeper"], pair["duplicate"]} == {"concepts/paraphrase-a", "concepts/paraphrase-b"}, pair
        assert 0.92 <= pair["score"] <= 1.0, pair
        # the JSON page must NOT be a paraphrase duplicate of the celadon pages
        assert all("concepts/unrelated" not in (c["keeper"], c["duplicate"]) for c in vc), vc

        # 3. a rewritten page drops out (content-version lock): edit a, rescan.
        (vault / "raw/x.md").write_text("龙泉窑青瓷的证据。\n\n新增了一段完全不同的内容。\n", encoding="utf-8")
        call("scan")
        ob = next(o for o in call("plan") if o["source"] == "raw/x.md")["id"]
        call("context", order=ob)
        call("analysis-submit", order=ob,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "rewrite"})
        sp = vault / f"staging/{ob}/0.md"
        sp.write_text('---\ntype: concept\ntitle: t0\nsources: ["raw/x.md"]\n---\n'
                      "彻底改写的甲页与乙页梅子青毫无关系了\n", encoding="utf-8")
        call("commit", order=ob, pages=[{"id": "concepts/paraphrase-a",
             "path": "wiki/concepts/paraphrase-a.md", "staged": f"staging/{ob}/0.md"}], at="2026-11-04")
        call("rebuild")
        red2 = call("page-redundancy", space=SPACE)
        # a's stale vector no longer matches its new content hash -> not nominated
        assert all(c["keeper"] != "concepts/paraphrase-a" and c["duplicate"] != "concepts/paraphrase-a"
                   for c in red2["candidates"] if c["reason"] == "vector_cosine"), red2["candidates"]
    print("embed e2e: native bge-small-zh embedding provider drives search + page-redundancy end to end")
    return 0


if __name__ == "__main__":
    sys.exit(main())
