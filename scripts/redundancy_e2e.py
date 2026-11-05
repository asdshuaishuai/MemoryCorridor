#!/usr/bin/env python3
"""End-to-end acceptance for semantic page-redundancy detection (续二十三).

Proves the read-only `page-redundancy` op on the real CLI:
  1. two paraphrased pages (distinct tokens, distinct sources) nominate ONLY
     via vector cosine once the host submits embeddings -- the semantic signal
     the token path cannot catch;
  2. two formatting-only duplicate pages nominate via similar_text with no
     vectors at all -- the deterministic path;
  3. the op never writes the vault (index bytes unchanged across calls), and
     a rewritten page's stale vector does not nominate it (content-version lock).
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
SPACE = {"id": "model-content-v1:recipe-v1", "dimensions": 2}


def main():
    if not EXE.exists():
        print("SKIP: build the CLI first (moon build --target native cli)")
        return 0
    with tempfile.TemporaryDirectory(prefix="corridor-redundancy-") as work:
        vault = Path(work)

        def call(op, error=None, **fields):
            run = subprocess.run(
                [str(EXE)], input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                text=True, capture_output=True, check=True, timeout=60)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"] and error in response["error"], response
                return response
            assert response["ok"], response
            return response["result"]

        call("init", purpose="语义冗余检测")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/x.md").write_text("青瓷釉色的铁还原证据。\n", encoding="utf-8")
        call("scan")
        order = call("plan")[0]["id"]
        call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "evidence"})
        # two paraphrased pages: distinct tokens + distinct sources, so no
        # deterministic signal can fire -- only a vector cosine can nominate.
        pages = [
            {"id": "concepts/paraphrase-a", "path": "wiki/concepts/paraphrase-a.md",
             "body": "青瓷釉色以铁还原呈色为主基调"},
            {"id": "concepts/paraphrase-b", "path": "wiki/concepts/paraphrase-b.md",
             "body": "龙泉窑梅子青靠充足还原气氛烧成"},
        ]
        staged = []
        for i, pg in enumerate(pages):
            sp = vault / f"staging/{order}/{i}.md"
            sp.parent.mkdir(parents=True, exist_ok=True)
            src = "raw/x.md"
            sp.write_text(f'---\ntype: concept\ntitle: 改写{i}\nsources: ["{src}"]\n---\n' + pg["body"] + "\n",
                          encoding="utf-8")
            staged.append({"id": pg["id"], "path": pg["path"], "staged": f"staging/{order}/{i}.md"})
        call("commit", order=order, pages=staged, at="2026-11-03")
        call("rebuild")

        # 1. no vectors yet: the op runs, reports the space, but finds no
        #    semantic candidate (distinct tokens/sources, nothing submitted).
        before = (vault / "index.mbt.md").read_bytes()
        result = call("page-redundancy", space=SPACE)
        assert result["counts"]["with_vectors"] == 0, result
        assert result["candidates"] == [], result["candidates"]
        # read-only: the vault bytes are untouched by a detection call.
        assert (vault / "index.mbt.md").read_bytes() == before

        # 2. the host submits near-identical embeddings for both pages.
        plan = {it["page"]: it["sha256"] for it in call("embedding-plan", space=SPACE)["items"]}
        for pid, vec in [("concepts/paraphrase-a", [1, 0]), ("concepts/paraphrase-b", [9, 1])]:
            call("embedding-submit", space=SPACE,
                 items=[{"page": pid, "sha256": plan[pid], "values": vec}])
        call("rebuild")
        before_vectors = (vault / "index.mbt.md").read_bytes()
        result = call("page-redundancy", space=SPACE)
        assert result["counts"]["with_vectors"] == 2, result
        cands = result["candidates"]
        assert len(cands) == 1, cands
        pair = cands[0]
        assert pair["reason"] == "vector_cosine", pair
        assert "vector_cosine" in pair["signals"], pair
        assert {pair["keeper"], pair["duplicate"]} == {"concepts/paraphrase-a", "concepts/paraphrase-b"}, pair
        assert 0.92 <= pair["score"] <= 1.0, pair
        # keeper is the lower id (stable), duplicate the higher.
        assert pair["keeper"] == "concepts/paraphrase-a", pair
        # the detection call itself never writes: bytes identical to just before it
        assert (vault / "index.mbt.md").read_bytes() == before_vectors

        # 3. a rewritten page's stale vector must not nominate it: commit a new
        #    version of paraphrase-b (different bytes -> new sha256), the old
        #    vector's content-version lock drops it out of the cosine pairing.
        # rewrite via a fresh source + republish b
        (vault / "raw/z.md").write_text("改写后的新证据。\n", encoding="utf-8")
        call("scan")
        ob = next(o for o in call("plan") if o["source"] == "raw/z.md")["id"]
        call("context", order=ob)
        call("analysis-submit", order=ob,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "rewrite"})
        sp = vault / f"staging/{ob}/0.md"
        sp.write_text('---\ntype: concept\ntitle: 改写b新\nsources: ["raw/z.md"]\n---\n'
                      "完全不同的新正文与旧版毫无关系\n", encoding="utf-8")
        call("commit", order=ob, pages=[{"id": "concepts/paraphrase-b",
             "path": "wiki/concepts/paraphrase-b.md", "staged": f"staging/{ob}/0.md"}], at="2026-11-03")
        call("rebuild")
        # paraphrase-b now has a new content hash; its old vector no longer
        # matches, so the cosine nomination disappears.
        result = call("page-redundancy", space=SPACE)
        assert result["counts"]["with_vectors"] == 1, result  # only a still matches
        assert result["candidates"] == [], result["candidates"]

        # 4. deterministic path: two formatting-only duplicate pages nominate
        #    similar_text with no vectors at all.
        od = call("plan")
        # add two identical-body pages under the same source
        (vault / "raw/d.md").write_text("重复证据。\n", encoding="utf-8")
        call("scan")
        o2 = next(o for o in call("plan") if o["source"] == "raw/d.md")["id"]
        call("context", order=o2)
        call("analysis-submit", order=o2,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "dup"})
        dup_body = "龙泉窑青瓷以粉青与梅子青著称" + "釉料以石灰碱釉为基钾长石约占三成"
        dpages = []
        for i in range(2):
            sp = vault / f"staging/{o2}/{i}.md"
            # same title AND body modulo a trailing newline -> identical token
            # sequences, so the deterministic similar_text signal fires
            sp.write_text('---\ntype: concept\ntitle: 重复\nsources: ["raw/d.md"]\n---\n'
                          + dup_body + ("\n" if i else ""), encoding="utf-8")
            dpages.append({"id": f"concepts/dup-{i}", "path": f"wiki/concepts/dup-{i}.md",
                           "staged": f"staging/{o2}/{i}.md"})
        call("commit", order=o2, pages=dpages, at="2026-11-03")
        call("rebuild")
        result = call("page-redundancy", space=SPACE)
        dup_pairs = [c for c in result["candidates"] if c["reason"] == "similar_text"]
        assert len(dup_pairs) == 1, result["candidates"]
        assert {dup_pairs[0]["keeper"], dup_pairs[0]["duplicate"]} == {"concepts/dup-0", "concepts/dup-1"}, dup_pairs[0]

        # 5. explicit cosine tier (续二十七): a near-orthogonal third vector
        #    makes the DEFAULT tier meaningful (it must exclude cos 0.0/0.11
        #    pairs that a 0.0 default would absorb), while the ~0.994 a/b pair
        #    is nominated at 0.92, dropped at 0.995 and kept at 0.5. The
        #    deterministic similar_text pair is tier-orthogonal throughout;
        #    the applied floor is echoed; bounds fail closed; read-only.
        (vault / "raw/far.md").write_text("远景独立证据。\n", encoding="utf-8")
        call("scan")
        of = next(o for o in call("plan") if o["source"] == "raw/far.md")["id"]
        call("context", order=of)
        call("analysis-submit", order=of,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "far"})
        spf = vault / f"staging/{of}/0.md"
        spf.write_text('---\ntype: concept\ntitle: 远景\nsources: ["raw/far.md"]\n---\n'
                       "哥窑开片与龙泉青瓷毫无关联的另一段证据正文恰好够长以通过字节闸。\n", encoding="utf-8")
        call("commit", order=of, pages=[{"id": "concepts/far", "path": "wiki/concepts/far.md",
             "staged": f"staging/{of}/0.md"}], at="2026-11-05")
        plan_now = {it["page"]: it["sha256"] for it in call("embedding-plan", space=SPACE)["items"]}
        call("embedding-submit", space=SPACE, items=[
            {"page": "concepts/paraphrase-b", "sha256": plan_now["concepts/paraphrase-b"], "values": [9, 1]},
            {"page": "concepts/far", "sha256": plan_now["concepts/far"], "values": [0, 1]},
        ])
        default_pairs = [c for c in call("page-redundancy", space=SPACE)["candidates"]
                         if c["reason"] == "vector_cosine"]
        assert len(default_pairs) == 1, default_pairs
        high = call("page-redundancy", space=SPACE, cosine_floor=0.995)
        assert high["cosine_floor"] == 0.995, high
        assert [c for c in high["candidates"] if c["reason"] == "vector_cosine"] == [], high["candidates"]
        assert len([c for c in high["candidates"] if c["reason"] == "similar_text"]) == 1, high["candidates"]
        low = call("page-redundancy", space=SPACE, cosine_floor=0.5)
        assert low["cosine_floor"] == 0.5 and len([c for c in low["candidates"]
                                                   if c["reason"] == "vector_cosine"]) == 1, low
        for bad in (1.5, -0.01, "0.9", True):
            call("page-redundancy", space=SPACE, cosine_floor=bad, error="invalid_number")
        tier_before = (vault / "index.mbt.md").read_bytes()
        call("page-redundancy", space=SPACE, cosine_floor=0.995)
        assert (vault / "index.mbt.md").read_bytes() == tier_before
    print("redundancy e2e: semantic + deterministic page-redundancy accepted (read-only, version-locked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
