#!/usr/bin/env python3
"""Optional end-to-end acceptance for the multimodal vector space (续二十六).

Runs the REAL CLIP ViT-B/32 int8 pair (vision + text towers) through the
engine's vector pipeline: two solid-color images become pages with image
sources, embedding-plan routes them as image items to adapters/embed-rs,
the vision tower vectors go back via embedding-submit, and search proves
(a) image-to-image recall and (b) cross-modal text-query recall through the
CLIP text tower -- while the default bge text space stays untouched for a
provider without the embed-multimodal capability.

Like embed_e2e this SKIPs cleanly (exit 0) when the adapter binary, the
pinned CLIP pair or the ONNX Runtime dylib are absent, so CI without model
downloads is unaffected.

Run:
  sh scripts/fetch_clip.sh && sh scripts/fetch_bge.sh
  (cd adapters/embed-rs && cargo build --release)
  python3 scripts/multimodal_e2e.py
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
EMBED_BIN = os.environ.get("EMBED_BIN", str(REPO / "adapters/embed-rs/target/release/embed-adapter"))
ORT_DYLIB = os.environ.get("ORT_DYLIB_PATH", str(REPO / "adapters/ocr-rs/runtime/libonnxruntime.dylib"))
CLIP_DIR = os.environ.get("EMBED_CLIP_DIR", str(REPO / "adapters/embed-rs/clip"))
MM_SPACE = {"id": "clip-mm-v1:recipe-v1", "dimensions": 512}
TEXT_SPACE = {"id": "model-content-v1:recipe-v1", "dimensions": 512}


def available():
    return (Path(EMBED_BIN).exists() and Path(ORT_DYLIB).exists()
            and (Path(CLIP_DIR) / "vision_model_quantized.onnx").exists()
            and (Path(CLIP_DIR) / "text_model_quantized.onnx").exists())


def png_bytes(color):
    """Deterministic 32x32 solid-color PNG, stdlib only."""
    w = h = 32
    raw = b"".join(b"\x00" + bytes(color) * w for _ in range(h))

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def run_adapter(env, args, stdin=None, check=True):
    proc = subprocess.run([EMBED_BIN] + args, input=stdin, env=env,
                          capture_output=True, text=True, timeout=300, check=check)
    return proc.stdout


def adapter_rejects(env, items, why):
    """The adapter must exit non-zero on hostile/locked items (host-side guards
    complement the engine re-validation; a mutation of these guards lands here)."""
    proc = subprocess.run([EMBED_BIN], input=json.dumps(items), env=env,
                          capture_output=True, text=True, timeout=300)
    assert proc.returncode != 0, f"adapter should reject: {why} -> {proc.stdout[:120]}"


def main():
    if not CLI.exists():
        print("SKIP: build the CLI first (moon build --target native cli)")
        return 0
    if not available():
        print("SKIP multimodal_e2e: embed-adapter/CLIP pair/ONNX Runtime not present "
              "(scripts/fetch_clip.sh + adapters/embed-rs). The multimodal PROTOCOL face "
              "is gated unconditionally by embedding_e2e.py.")
        return 0

    red = png_bytes((230, 40, 40))
    blue = png_bytes((30, 60, 230))
    env = {**os.environ, "ORT_DYLIB_PATH": ORT_DYLIB,
           "EMBED_MODEL_DIR": str(REPO / "adapters/embed-rs/model"),
           "EMBED_CLIP_DIR": CLIP_DIR}

    with tempfile.TemporaryDirectory(prefix="corridor-mm-e2e-") as work:
        vault = Path(work)
        env["EMBED_VAULT_DIR"] = str(vault)

        def call(op, error=None, **fields):
            run = subprocess.run([str(CLI)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            if error:
                assert not response["ok"] and error in response["error"], response
                return response
            assert response["ok"], response
            return response["result"]

        call("init", purpose="多模态向量端到端")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/red.png").write_bytes(red)
        (vault / "raw/blue.png").write_bytes(blue)
        (vault / "raw/prose.md").write_text("纯文字证据。\n")
        call("scan")

        colors = {"raw/red.png": ("concepts/red", "鲜红色彩页。"),
                  "raw/blue.png": ("concepts/blue", "鲜蓝色彩页。"),
                  "raw/prose.md": ("concepts/prose", "红色与蓝色的纯文字讨论。")}
        for order in sorted(call("plan"), key=lambda o: o["source"]):
            source = order["source"]
            oid = order["id"]
            pid, body = colors[source]
            call("context", order=oid)
            call("analysis-submit", order=oid,
                 analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "mm"})
            staged = vault / f"staging/{oid}/0.md"
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(f'---\ntype: concept\ntitle: {pid}\nsources: ["{source}"]\n---\n{body}\n',
                              encoding="utf-8")
            call("commit", order=oid,
                 pages=[{"id": pid, "path": f"wiki/concepts/{pid.rsplit('/', 1)[-1]}.md",
                         "staged": f"staging/{oid}/0.md"}], at="2026-11-04")
        call("rebuild")

        # provider: the multimodal face (declares embed-multimodal)
        call("provider-register", provider="clip-mm", kind="embedding", space=MM_SPACE,
             capabilities=["embed", "embed-multimodal"], at="2026-11-04T00:00:00Z")
        plan = call("embedding-plan", space=MM_SPACE, provider="clip-mm", limit=128)
        image_items = [i for i in plan["items"] if i.get("modality") == "image"]
        pages_in_items = {i["page"] for i in image_items}
        assert "concepts/red" in pages_in_items and "concepts/blue" in pages_in_items
        assert "concepts/prose" not in pages_in_items  # text-only page never vectorized
        for i in image_items:  # byte lock must match reality
            expected = hashlib.sha256((vault / i["image"]).read_bytes()).hexdigest()
            assert i["image_sha256"] == expected, i

        submitted = json.loads(run_adapter(env, [], stdin=json.dumps(plan["items"])))
        assert len(submitted) == len(image_items)
        for row in submitted:
            assert len(row["values"]) == 512
        call("embedding-submit", space=MM_SPACE, items=submitted, provider="clip-mm")

        # 1. image-to-image recall: the red image query must rank the red page
        #    (and its revision page) above the blue page.
        q_items = [{"page": "q", "sha256": "0" * 64, "modality": "image",
                    "image": "raw/red.png", "image_sha256": hashlib.sha256(red).hexdigest()}]
        q = json.loads(run_adapter(env, [], stdin=json.dumps(q_items)))[0]["values"]
        hits = [h["id"] for h in call("search", query="", provider="clip-mm",
                                      query_vector={"space": MM_SPACE, "values": q})["hits"]]
        assert hits[0] == "concepts/red", hits
        assert hits.index("concepts/red") < hits.index("concepts/blue"), hits

        # 2. cross-modal recall through the CLIP text tower.
        q_txt = json.loads(run_adapter(env, ["--mm-query"], stdin="a bright red square picture\n"))
        hits_t = [h["id"] for h in call("search", query="", provider="clip-mm",
                                        query_vector={"space": MM_SPACE, "values": q_txt})["hits"]]
        assert "concepts/red" in hits_t[:3] and hits_t.index("concepts/red") < hits_t.index("concepts/blue"), hits_t

        # 3. the default text-centric face is untouched for a plain provider.
        call("provider-register", provider="embed-rs", kind="embedding", space=TEXT_SPACE,
             capabilities=["embed"], at="2026-11-04T00:00:01Z")
        tplan = call("embedding-plan", space=TEXT_SPACE, provider="embed-rs", limit=128)
        assert all("modality" not in i and "text" in i for i in tplan["items"])
        assert "concepts/prose" in [i["page"] for i in tplan["items"]]
        tvectors = json.loads(run_adapter(env, [], stdin=json.dumps(tplan["items"])))
        call("embedding-submit", space=TEXT_SPACE, items=tvectors, provider="embed-rs")

        # 3b. host-side guards: the adapter refuses drifted image bytes and
        #     path-escape image references before ever touching a tower.
        adapter_rejects(env, [{"page": "q", "sha256": "0" * 64, "modality": "image",
                               "image": "raw/red.png",
                               "image_sha256": "d" * 64}], "image_sha256 mismatch")
        adapter_rejects(env, [{"page": "q", "sha256": "0" * 64, "modality": "image",
                               "image": "../outside.png",
                               "image_sha256": hashlib.sha256(red).hexdigest()}],
                        "path escape outside raw/")

        # 4. page-redundancy on the mm space is driven by real vision vectors.
        #    EMPIRICAL FINDING pinned here: flat synthetic colors are mutually
        #    close in CLIP space, so the text-tuned 0.92 cosine floor nominates
        #    even a red/blue pair (~0.925). Candidates are advisory
        #    nominations ("提议不决定"), and hosts on visual spaces must read
        #    them against ~1.0 for same-content pairs -- documented in
        #    docs/vector.md rather than hidden behind a special-cased floor.
        red2 = call("page-redundancy", space=MM_SPACE, limit=50)
        vc = [c for c in red2["candidates"] if c["reason"] == "vector_cosine"]
        assert vc, red2["candidates"]
        # same image = same content: every page pins its own sources/ revision
        # page at ~1.0 (this is what "duplicate" means on a visual space).
        exact = [c for c in vc if c["score"] >= 0.999]
        assert len(exact) == 1 and exact[0]["keeper"] == "concepts/blue" \
            and exact[0]["duplicate"].startswith("sources/"), vc
        # ...and the calibration finding: flat colors sit at ~0.925, so the
        # text-tuned 0.92 floor absorbs the red group into blue at keeper=blue.
        # Nominations are advisory ("提议不决定"): hosts on visual spaces must
        # treat >=0.999 as same-content, not the raw floor. Documented.
        absorbed = next((c for c in vc if c["duplicate"] == "concepts/red"), None)
        assert absorbed is not None and 0.92 <= absorbed["score"] < 0.93, vc

    print("multimodal e2e: real CLIP vision/text towers drive image recall, "
          "cross-modal search, untouched bge text default and mm-space redundancy")
    return 0


if __name__ == "__main__":
    sys.exit(main())
