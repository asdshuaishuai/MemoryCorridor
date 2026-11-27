#!/usr/bin/env python3
"""Hermetic test for the native host's automatic OCR/PDF bridge.

The real adapter is optional and lives outside the engine (see ocr_e2e.py).
This suite uses a tiny Python stub with the same stdin/stdout contract, so the
nativehost hook, digest binding, sidecar intake, fallback and opt-out paths run
on every platform without ONNX Runtime, models or network access.
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
AT = "2026-11-02T09:00:00Z"
CHECKS = []


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def png_bytes():
    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    raw = b"\x00" + b"\x00\x00\x00\x00"
    idat = zlib.compress(raw, 9)

    def chunk(kind, data):
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    return signature + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def write_stub(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | 0o100)
    return path


def stub_body(text, kind="image", origin="ocr", digest="input"):
    if digest == "input":
        digest_expr = "hashlib.sha256(data).hexdigest()"
    else:
        digest_expr = json.dumps(digest)
    return f"""import hashlib, json, sys
data = open(sys.argv[1], "rb").read()
print(json.dumps({{"sha256": {digest_expr}, "kind": {json.dumps(kind)},
                  "source": {json.dumps(origin)}, "confidence": 0.99,
                  "text": {json.dumps(text)}}}, ensure_ascii=False))
"""


def call(vault, op, env, **fields):
    request = {"op": op, "vault": str(vault), **fields}
    process = subprocess.run(
        [str(CLI)], input=json.dumps(request, ensure_ascii=False) + "\n",
        capture_output=True, text=True, timeout=120, env=env, check=True)
    value = json.loads(process.stdout)
    assert "Panic" not in process.stderr, process.stderr
    assert value["ok"], value
    return value["result"]


def open_vault(work, name, purpose):
    vault = Path(work) / name
    vault.mkdir()
    base_env = {**os.environ, "MEMORYCORRIDOR_OCR_AT": AT}
    call(vault, "init", base_env, purpose=purpose)
    return vault, base_env


def scan_and_context(vault, env, source, payload):
    (vault / "raw").mkdir(exist_ok=True)
    (vault / "raw" / source).write_bytes(payload)
    call(vault, "scan", env)
    orders = call(vault, "plan", env)
    assert len(orders) == 1, orders
    return orders[0], call(vault, "context", env, order=orders[0]["id"])


def sidecars(vault):
    directory = vault / "state/extractions"
    return sorted(directory.glob("*.json")) if directory.exists() else []


def main():
    if not CLI.exists():
        print("SKIP ocr_native_e2e: build the native CLI first")
        return 0
    with tempfile.TemporaryDirectory(prefix="corridor-ocr-native-") as work:
        stubs = Path(work) / "stubs"
        stubs.mkdir()
        good = write_stub(stubs, "good", stub_body("龙泉窑青瓷 自动 OCR 测试"))
        text_layer = write_stub(
            stubs, "text-layer",
            stub_body("文本层 PDF 精确正文", kind="pdf", origin="text-layer"))
        wrong_digest = write_stub(
            stubs, "wrong-digest", stub_body("不应入账", digest="0" * 64))
        failing = write_stub(stubs, "failing", "raise SystemExit(2)\n")

        # 1. Image: context returns text directly; the sidecar and event are
        # booked under the registered byte digest.
        vault, env = open_vault(work, "auto-image", "图片自动 OCR")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(good)}
        image = png_bytes()
        order, ctx = scan_and_context(vault, env, "plate.png", image)
        sha = hashlib.sha256(image).hexdigest()
        assert order["source_hash"] == sha, order
        assert ctx["source_text"] == "龙泉窑青瓷 自动 OCR 测试", ctx
        assert ctx["extraction_required"] is False, ctx
        assert ctx["extraction"]["extractor"] == "ppocrv4-mobile-ocr-rs", ctx
        assert ctx["extraction"]["bound_sha256"] == sha, ctx
        record = json.loads(sidecars(vault)[0].read_text(encoding="utf-8"))
        assert record["submitted_at"] == AT and record["source_sha256"] == sha, record
        assert (vault / "state/events" / ("extraction-submit-" + sha + ".json")).exists()
        raw_view = call(vault, "read-source", env, id="raw/plate.png")
        assert raw_view["textual"] is False and raw_view["extraction_required"] is True, raw_view
        again = call(vault, "context", env, order=order["id"])
        assert again["source_text"] == "龙泉窑青瓷 自动 OCR 测试", again
        assert len(sidecars(vault)) == 1, sidecars(vault)
        assert len(list((vault / "state/events").glob("extraction-submit-*.json"))) == 1
        check("image context auto-OCRs, books a digest-bound sidecar and leaves read-source unchanged")

        # 2. The public extraction-submit path still replays the same record.
        replay = call(vault, "extraction-submit", env, source="raw/plate.png",
                      kind="image", extractor="ppocrv4-mobile-ocr-rs", version="1",
                      text="龙泉窑青瓷 自动 OCR 测试", at=AT)
        assert replay["replayed"] is True, replay
        check("manual extraction-submit remains a verbatim replay after auto-intake")

        # 3. Text-layer PDFs use the deterministic lopdf channel, not OCR.
        vault, env = open_vault(work, "text-layer", "文本层 PDF")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(text_layer)}
        pdf = b"%PDF-1.7\nstub text layer\n"
        _, ctx = scan_and_context(vault, env, "document.pdf", pdf)
        assert ctx["source_text"] == "文本层 PDF 精确正文", ctx
        assert ctx["extraction_required"] is False, ctx
        assert ctx["extraction"]["extractor"] == "lopdf", ctx
        check("text-layer PDF is extracted and mapped to the lopdf identity")

        # 4. A digest mismatch must never create a sidecar.
        vault, env = open_vault(work, "wrong-digest", "错误摘要")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(wrong_digest)}
        _, ctx = scan_and_context(vault, env, "plate.png", png_bytes())
        assert ctx["extraction_required"] is True and ctx["source_text"] is None, ctx
        assert sidecars(vault) == []
        check("adapter digest mismatch falls back with no sidecar")

        # 5. A failing adapter is a fallback, not a failed context request.
        vault, env = open_vault(work, "failing", "适配器失败")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(failing)}
        _, ctx = scan_and_context(vault, env, "plate.png", png_bytes())
        assert ctx["extraction_required"] is True and ctx["source_text"] is None, ctx
        assert sidecars(vault) == []
        check("non-zero adapter exit falls back with no sidecar")

        # 6. The opt-out is explicit and leaves the manual path untouched.
        vault, env = open_vault(work, "opt-out", "关闭自动 OCR")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(good), "MEMORYCORRIDOR_OCR": "off"}
        _, ctx = scan_and_context(vault, env, "plate.png", png_bytes())
        assert ctx["extraction_required"] is True and ctx["source_text"] is None, ctx
        assert sidecars(vault) == []
        check("MEMORYCORRIDOR_OCR=off preserves the manual extraction path")

        # 7. Import scheduling: scan itself books the sidecar before any
        # context call, so the imported PDF/image is ready to read.
        vault, env = open_vault(work, "import-time", "导入时调度")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(good)}
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/imported.png").write_bytes(png_bytes())
        scanned = call(vault, "scan", env)
        assert len(sidecars(vault)) == 1, sidecars(vault)
        assert scanned["fingerprint"] == call(vault, "fingerprints", env)["vault"], scanned
        orders = call(vault, "plan", env)
        imported = call(vault, "context", env, order=orders[0]["id"])
        assert imported["source_text"] == "龙泉窑青瓷 自动 OCR 测试", imported
        check("scan schedules OCR by imported PDF/image before context")

        # 8. Textual sources never invoke the adapter.
        vault, env = open_vault(work, "text", "文本来源")
        env = {**env, "MEMORYCORRIDOR_OCR_BIN": str(failing)}
        _, ctx = scan_and_context(vault, env, "notes.md", "普通文本正文\n".encode())
        assert ctx["source_text"] == "普通文本正文\n" and ctx["extraction_required"] is False, ctx
        assert sidecars(vault) == []
        check("textual source keeps its byte channel and never calls OCR")

    print(f"ocr native e2e: {len(CHECKS)} checks passed (stub adapter, no model/runtime)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
