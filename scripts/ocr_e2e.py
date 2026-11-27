#!/usr/bin/env python3
"""End-to-end acceptance for direct native OCR/PDF intake (docs/ocr.md).

The adapter under test is adapters/ocr-rs: one self-contained binary (PP-OCRv4
mobile models and the official ONNX Runtime dylib embedded by build.rs), zero
Python in the delivery. This test is a dev-time harness: it only needs Python
to *manufacture* CJK fixtures with a system font. A non-embedded build without
the runtime dylib, or a missing fixture toolchain, SKIPS with an explicit
message (exit 0) instead of downloading models. The digest/sidecar/fallback
contracts are gated hermetically by ocr_native_e2e.py and extraction_e2e.py.

The native host is now the caller: scan/refresh schedules OCR by imported
PDF/image source, books the sidecar, and context serves source_text.

Run:
  scripts/fetch_ort.sh                                 # runtime build input
  cd adapters/ocr-rs && cargo build --release          # build.rs embeds it
  OCR_BIN=adapters/ocr-rs/target/release/ocr-adapter python3 scripts/ocr_e2e.py
  # fixture renderer (dev-only): FIXTURE_PYTHON=/tmp/ocr-venv/bin/python (pillow+fpdf2)
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
OCR_BIN = Path(os.environ["OCR_BIN"]) if os.environ.get("OCR_BIN") else None
RUNTIME = Path(os.environ.get("ORT_DYLIB_PATH") or
               REPO / "adapters/ocr-rs/runtime/libonnxruntime.dylib")
FIXTURE_PYTHON = os.environ.get("FIXTURE_PYTHON") or shutil.which("python3")
DOC = ["龙泉窑青瓷以粉青与梅子青著称",
       "哥窑以开片釉闻名紫口铁足为辨识特征",
       "釉料以石灰碱釉为基钾长石约占三成",
       "铁还原呈色含量约百分之一点五"]
CHECKS = []


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def cli(work, op, **args):
    req = {"op": op, "vault": str(work), **args}
    r = subprocess.run([str(CLI)], input=json.dumps(req, ensure_ascii=False) + "\n",
                       capture_output=True, text=True)
    assert r.stdout.strip(), r.stderr
    return json.loads(r.stdout.splitlines()[0])


def ok(work, op, **args):
    v = cli(work, op, **args)
    assert v["ok"], v
    return v["result"]


def make_fixtures(samples):
    """Raster/PDF fixtures only - never part of inference or delivery."""
    code = r'''
import sys, os
from PIL import Image, ImageDraw, ImageFont
from fpdf import FPDF
DOC = %r
candidates = ["/System/Library/Fonts/STHeiti Medium.ttc",
              "/System/Library/Fonts/Hiragino Sans GB.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
font_path = next((c for c in candidates if os.path.exists(c)), None)
if not font_path:
    print("no-cjk-font"); sys.exit(3)
img = Image.new("RGB", (1040, 460), (250, 250, 250)); d = ImageDraw.Draw(img)
font = ImageFont.truetype(font_path, 52); y = 60
for line in DOC:
    d.text((48, y), line, font=font, fill=(0, 0, 0)); y += 96
img.save(sys.argv[1] + "/plate.png")
img.save(sys.argv[1] + "/scan.pdf", resolution=150)
pdf = FPDF(); pdf.add_page(); pdf.add_font("heiti", "", font_path)
pdf.set_font("heiti", size=22)
for line in DOC:
    pdf.cell(0, 18, line, new_x="LMARGIN", new_y="NEXT")
pdf.output(sys.argv[1] + "/textlayer.pdf")
img.rotate(180).save(sys.argv[1] + "/plate_upside.png")
print("made")
''' % (DOC,)
    r = subprocess.run([FIXTURE_PYTHON, "-c", code, str(samples)],
                       capture_output=True, text=True)
    if "no-cjk-font" in r.stdout or r.returncode != 0:
        return False
    return all((samples / n).exists()
               for n in ("plate.png", "scan.pdf", "textlayer.pdf", "plate_upside.png"))


def adapter_text(path):
    r = subprocess.run([str(OCR_BIN), str(path), "--json"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def main():
    if not CLI.exists():
        print("SKIP: build the CLI first (moon build --target native cli)"); return 0
    if OCR_BIN is None or not Path(OCR_BIN).exists():
        print("SKIP ocr_e2e: set OCR_BIN to the native adapter "
              "(cd adapters/ocr-rs && cargo build --release). Engine sidecar "
              "accounting is still gated by ocr_native_e2e.py and "
              "extraction_e2e.py in verify.sh.")
        return 0
    embedded_runtime = Path(OCR_BIN).stat().st_size > 40 * 1024 * 1024
    if not RUNTIME.is_file() and not embedded_runtime:
        print("SKIP ocr_e2e: ONNX Runtime is neither embedded in the adapter "
              "nor present at %s (run scripts/fetch_ort.sh)" % RUNTIME)
        return 0
    if RUNTIME.is_file():
        os.environ["ORT_DYLIB_PATH"] = str(RUNTIME)
    os.environ["MEMORYCORRIDOR_OCR_BIN"] = str(Path(OCR_BIN).resolve())
    os.environ["MEMORYCORRIDOR_OCR_AT"] = "2026-11-02T09:00:00Z"
    with tempfile.TemporaryDirectory(prefix="corridor-ocr-") as work:
        samples = Path(work) / "samples"; samples.mkdir()
        if not make_fixtures(samples):
            print("SKIP ocr_e2e: fixture toolchain unavailable "
                  "(FIXTURE_PYTHON needs pillow + fpdf2; dev-only, not a runtime dep)")
            return 0
        root = Path(work) / "vault"; root.mkdir()
        ok(root, "init", purpose="青瓷 OCR 端到端")
        (root / "raw/板.png").write_bytes((samples / "plate.png").read_bytes())
        (root / "raw/扫描件.pdf").write_bytes((samples / "scan.pdf").read_bytes())
        (root / "raw/文本层.pdf").write_bytes((samples / "textlayer.pdf").read_bytes())
        (root / "raw/颠倒.png").write_bytes((samples / "plate_upside.png").read_bytes())
        ok(root, "scan")
        sidecars = list((root / "state/extractions").glob("*.json"))
        assert len(sidecars) == 4, (len(sidecars), sidecars)
        check("scan schedules OCR/PDF by imported PDF/image sources")
        orders = {o["source"]: o["id"] for o in ok(root, "plan")}
        assert set(orders) == {"raw/板.png", "raw/扫描件.pdf", "raw/文本层.pdf", "raw/颠倒.png"}, orders

        extracted = {}
        fixtures = {"raw/板.png": "plate.png", "raw/扫描件.pdf": "scan.pdf",
                    "raw/文本层.pdf": "textlayer.pdf", "raw/颠倒.png": "plate_upside.png"}
        for src in orders:
            extracted[src] = adapter_text(samples / fixtures[src])
        for src in ("raw/板.png", "raw/扫描件.pdf", "raw/颠倒.png"):
            joined = extracted[src]["text"]
            assert "龙泉窑青瓷" in joined and "百分之一点五" in joined, (src, joined)
            assert extracted[src]["source"] == "ocr" and extracted[src]["confidence"] > 0.9, src
        assert extracted["raw/文本层.pdf"]["source"] == "text-layer"
        check("native adapter OCRs image + scanned PDF + upside-down page and reads the text-layer PDF exactly")

        # the source we publish over must stay open to the end - process it LAST,
        # since context is exclusive per vault (another_order_active otherwise)
        publish_src, publish_order = "raw/扫描件.pdf", orders["raw/扫描件.pdf"]
        order_seq = [s for s in orders if s != publish_src] + [publish_src]
        for src in order_seq:
            order = orders[src]
            sha = hashlib.sha256((root / src).read_bytes()).hexdigest()
            assert extracted[src]["sha256"] == sha, (src, extracted[src]["sha256"], sha)
            # The import stage already booked the sidecar; context must serve
            # the digest-bound text without another adapter run.
            served = ok(root, "context", order=order)
            assert served["extraction_required"] is False, (src, served)
            assert served["source_text"] is not None, (src, served)
            assert served["extraction"]["bound_sha256"] == sha, (src, served)
            expected = "lopdf" if extracted[src]["source"] == "text-layer" else "ppocrv4-mobile-ocr-rs"
            assert served["extraction"]["extractor"] == expected, (src, served)
            if extracted[src]["source"] == "text-layer":
                assert served["source_text"] == extracted[src]["text"], src
            else:
                assert "龙泉窑青瓷" in served["source_text"], (src, served["source_text"])
            if order != publish_order:
                ok(root, "cancel", order=order)
        check("context serves the sidecars booked at import time")

        order = publish_order
        ok(root, "analysis-submit", order=order,
           analysis={"entities": ["哥窑"], "concepts": ["粉青"], "conflicts": [],
                     "summary": "青瓷釉色与窑口（OCR 摄入）"})
        staging = root / "staging" / order; staging.mkdir(exist_ok=True)
        (staging / "0.md").write_text(
            '---\ntype: concept\ntitle: 粉青\ntags: ["青瓷"]\nsources: ["raw/扫描件.pdf"]\n---\n'
            "粉青呈色依赖铁还原，哥窑以开片釉闻名。\n", encoding="utf-8")
        ok(root, "commit", order=order,
           pages=[{"id": "concepts/粉青", "path": "wiki/concepts/粉青.md",
                   "staged": f"staging/{order}/0.md"}], at="2026-11-02")
        ok(root, "rebuild")
        assert ok(root, "verify")["violations"] == []
        hits = ok(root, "search", query="哥窑 开片")["hits"]
        assert hits and hits[0]["id"] == "concepts/粉青", hits
        check("committed page over an OCR source is published, verified and retrieved")
    print(f"ocr e2e: {len(CHECKS)} checks passed (native adapter accepted end to end)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
