#!/usr/bin/env python3
"""Extraction sidecar over real bytes, end to end on disk.

The engine never runs OCR or a model (AGENTS.md hard constraint); a host adapter
does, then submits the text here. This suite drives that intake with a real PNG:
submit -> context serves the text and its byte-hash binding -> verbatim replay ->
a same-channel different-text conflict -> a second extractor refused as
extraction_exists -> an OOXML source rejected as extraction_override -> the engine's
own channel stays intact. Byte tampering and revocation must stop a sidecar
applying, which is the point of the digest binding (the decisive checks are the
sidecar filename/content mutual lock and context's lookup by the *current* digest;
a raw tamper is caught by `verify` first as `source_missing_or_changed`, exactly
like the embedding/authoring tamper precedents). The lifecycle is ONE-WAY per
digest: forget does not reopen a sidecar, identical-byte rescan does not revive a
revoked source, and the only recovery is replacing the bytes and booking against
the new digest. The text cap counts UTF-8 bytes (the transport's unit), an orphan
event without its registered sidecar is refused, and a pack/unpack round trip
proves the new state directory survives the pack whitelist.
"""
import hashlib
import json
import re
import struct
import subprocess
import tempfile
import zlib
import zipfile
from io import BytesIO
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"
CHECKS = []


def call(root, op, error=None, **fields):
    request = {"op": op, "vault": str(root), **fields}
    process = subprocess.run([str(EXE)], input=json.dumps(request, ensure_ascii=False) + "\n",
                             capture_output=True, text=True, timeout=60, check=True)
    value = json.loads(process.stdout)
    assert "Warning:" not in process.stderr and "Panic" not in process.stderr, process.stderr
    if error is not None:
        assert not value["ok"] and error in value["error"], value
    else:
        assert value["ok"], value
    return value.get("result", value)


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def png_bytes():
    # A real, minimally valid 1x1 RGBA PNG: signature + IHDR + IDAT + IEND with
    # correct CRCs. The engine only hashes these bytes; it never decodes them.
    signature = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)
    raw = b"\x00" + b"\x00\x00\x00\x00"  # filter byte + one RGBA pixel
    idat = zlib.compress(raw, 9)

    def chunk(kind, data):
        crc = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

    return signature + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")


def docx_bytes(text):
    document = (
        '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body><w:p><w:r><w:t>" + text + "</w:t></w:r></w:p></w:body></w:document>"
    )
    buffer = BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        archive.writestr("_rels/.rels", "<Relationships/>")
        archive.writestr("word/document.xml", document)
    return buffer.getvalue()


def sidecar(root, sha):
    return json.loads((root / "state/extractions" / (sha + ".json")).read_text(encoding="utf-8"))


def main():
    assert EXE.exists(), "build first: moon build --target native cli"
    with tempfile.TemporaryDirectory(prefix="corridor-extraction-") as work:
        root = Path(work) / "vault"
        root.mkdir()
        ok_init = call(root, "init", purpose="青瓷窑口图像记录")
        assert ok_init["format"] == "corridor-catalog-v1"

        # A real binary source: the engine registers its format and digest only.
        image = png_bytes()
        (root / "raw/窑口照片.png").write_bytes(image)
        png_sha = hashlib.sha256(image).hexdigest()
        order = call(root, "scan")["orders"][0]

        # No sidecar yet: an image is non-textual, so context demands extraction.
        bare = call(root, "context", order=order)
        assert bare["extraction_required"] is True and bare["source_text"] is None, bare
        assert bare["extraction"] is None, bare

        # The host adapter's result becomes a first-class record bound to bytes.
        text = "哥窑窑址在龙泉大窑村，鼎盛于南宋。"
        submitted = call(root, "extraction-submit", source="raw/窑口照片.png",
                         kind="ocr", extractor="ppocrv6-small", version="1",
                         text=text, at="2026-11-02T09:00:00Z")
        assert submitted["replayed"] is False and submitted["path"] == "state/extractions/" + png_sha + ".json", submitted
        assert submitted["source_sha256"] == png_sha
        record = sidecar(root, png_sha)
        assert record == {"source": "raw/窑口照片.png", "source_sha256": png_sha, "kind": "ocr",
                          "extractor": "ppocrv6-small", "version": "1", "text": text,
                          "submitted_at": "2026-11-02T09:00:00Z"}, record
        assert (root / "state/events" / ("extraction-submit-" + png_sha + ".json")).exists()
        check("host OCR text becomes a digest-bound first-class record with an event")

        # context now serves the sidecar and reports its full byte binding.
        served = call(root, "context", order=order)
        assert served["source_text"] == text and served["extraction_required"] is False, served
        assert served["extraction"] == {"kind": "ocr", "extractor": "ppocrv6-small", "version": "1",
                                        "bound_sha256": png_sha, "source_sha256": png_sha}, served["extraction"]
        assert served["order"]["id"] == order

        # read-source stays on the byte channel: it still reports non-textual and
        # no extraction_required flip -- the two channels are deliberately split.
        raw_view = call(root, "read-source", id="raw/窑口照片.png")
        assert raw_view["textual"] is False and raw_view["extraction_required"] is True, raw_view
        check("context serves sidecar text with a five-field binding; read-source channel unchanged")

        # Verbatim replay is a no-op; a different text on the same channel is a
        # conflict that must not overwrite; a different channel is refused.
        catalog = (root / "index.mbt.md").read_bytes()
        replay = call(root, "extraction-submit", source="raw/窑口照片.png", kind="ocr",
                      extractor="ppocrv6-small", version="1", text=text, at="2026-11-02T09:00:00Z")
        assert replay["replayed"] is True
        assert (root / "index.mbt.md").read_bytes() == catalog
        conflict = call(root, "extraction-submit", source="raw/窑口照片.png", kind="ocr",
                        extractor="ppocrv6-small", version="1", text="改写后的正文",
                        at="2026-11-02T09:30:00Z", error="extraction_conflict")
        assert sidecar(root, png_sha)["text"] == text, conflict
        exists = call(root, "extraction-submit", source="raw/窑口照片.png", kind="ocr",
                      extractor="tesseract", version="5", text=text, at="2026-11-02T09:40:00Z",
                      error="extraction_exists")
        assert exists["error"].startswith("extraction_exists"), exists
        # The lifecycle detail is not part of the code but is visible to humans.
        assert "ppocrv6-small:1" in exists["error"], exists
        check("verbatim replay no-ops; same-channel different-text conflicts; new channel exists")

        # Tampering the source bytes stops every dependent read at the vault,
        # exactly like the embedding/authoring tamper precedents (the raw digest
        # check in submit is shadowed by verify, which is why the decisive binding
        # is the catalog lookup by the *current* digest in context).
        (root / "raw/窑口照片.png").write_bytes(png_bytes() + b"\x00tamper")
        call(root, "context", order=order, error="source_missing_or_changed")
        call(root, "extraction-submit", source="raw/窑口照片.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text=text, at="2026-11-02T11:00:00Z",
             error="source_missing_or_changed")
        check("tampered bytes refused by verify (source_missing_or_changed) before submit")

        # After rescan the source has a NEW digest; the old sidecar is keyed to the
        # old hash, so a fresh order reports extraction_required again rather than
        # resurrecting the stale text, and lint flags the now-drifted sidecar.
        # (Only one order may be active at a time, so the fresh one is cancelled
        # before any further context call.)
        new_order = call(root, "scan")["orders"][0]
        fresh = call(root, "context", order=new_order)
        assert fresh["extraction_required"] is True and fresh["source_text"] is None, fresh
        assert fresh["extraction"] is None
        # A host-dropped file at the new digest's path is not a registered record:
        # context must keep demanding extraction rather than serving its text.
        new_sha = hashlib.sha256(png_bytes() + b"\x00tamper").hexdigest()
        injected = root / "state/extractions" / (new_sha + ".json")
        injected.parent.mkdir(parents=True, exist_ok=True)
        injected.write_text(json.dumps({
            "source": "raw/窑口照片.png", "source_sha256": new_sha, "kind": "ocr",
            "extractor": "ppocrv6-small", "version": "1", "text": "未登记注入",
            "submitted_at": "2026-11-02T10:30:00Z"}, ensure_ascii=False), encoding="utf-8")
        unregistered = call(root, "context", order=new_order)
        assert unregistered["extraction_required"] is True, unregistered
        assert unregistered["source_text"] is None and unregistered["extraction"] is None, unregistered
        injected.unlink()
        lint = call(root, "lint")
        assert any(v["predicate"] == "extraction_source_drift" for v in lint["violations"]), lint
        call(root, "cancel", order=new_order)
        check("rescan moves the digest; stale sidecar no longer applies; unregistered files never serve text; lint reports drift")

        # OOXML originals keep the engine's own deterministic channel and cannot
        # be overridden by an external extraction.
        (root / "raw/窑口记录.docx").write_bytes(docx_bytes("引擎自抽正文"))
        order_docx = call(root, "scan")["orders"][0]
        call(root, "extraction-submit", source="raw/窑口记录.docx", kind="ocr",
             extractor="ext", version="1", text="外部结果", at="2026-11-02T10:00:00Z",
             error="extraction_override")
        docx_context = call(root, "context", order=order_docx)
        assert docx_context["extraction"] == {"kind": "office-word", "extractor": "corridor-office-v1"}, docx_context
        assert "引擎自抽正文" in docx_context["source_text"]
        call(root, "cancel", order=order_docx)

        # A textual source already serves its own bytes: the sidecar channel is
        # only for non-textual binary/image inputs.
        (root / "raw/笔记.md").write_text("文本正文\n", encoding="utf-8")
        order_md = call(root, "scan")["orders"][0]
        call(root, "extraction-submit", source="raw/笔记.md", kind="ocr",
             extractor="ext", version="1", text="x", at="2026-11-02T10:00:00Z",
             error="extraction_source_textual")
        check("OOXML submit refused (extraction_override); office self-extraction intact; textual refused")

        # The lifecycle is one-way per digest (finding #3): forget does NOT
        # reopen a sidecar, and because `scan` refuses to re-register identical
        # bytes over a revoked entry, the only recovery is replacing the bytes.
        (root / "raw/款识.png").write_bytes(png_bytes() + b"\x00seal-a")
        seal_a = hashlib.sha256(png_bytes() + b"\x00seal-a").hexdigest()
        call(root, "scan")
        call(root, "extraction-submit", source="raw/款识.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text="初版释读", at="2026-11-02T11:10:00Z")
        call(root, "forget", source="raw/款识.png", at="2026-11-02T11:15:00Z")
        call(root, "scan")
        # Same bytes after forget: still refused -- the tombstone keeps the
        # source revoked, so the hint's recovery path is byte replacement.
        call(root, "extraction-submit", source="raw/款识.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text="初版释读", at="2026-11-02T11:20:00Z",
             error="extraction_source_stale")
        # And swapping the channel on the revoked source is refused too (stale
        # gate fires before the exists gate).
        call(root, "extraction-submit", source="raw/款识.png", kind="ocr",
             extractor="other", version="9", text="初版释读", at="2026-11-02T11:21:00Z",
             error="extraction_source_stale")
        lint_after_forget = call(root, "lint")
        assert any(v["predicate"] == "extraction_source_stale" for v in lint_after_forget["violations"]), lint_after_forget
        # Replace the bytes: scan registers the new digest, and booking against
        # it works -- the old sidecar stays on record as drift, never as text.
        (root / "raw/款识.png").write_bytes(png_bytes() + b"\x00seal-b")
        seal_b = hashlib.sha256(png_bytes() + b"\x00seal-b").hexdigest()
        seal_order = call(root, "scan")["orders"][0]
        rebooked = call(root, "extraction-submit", source="raw/款识.png", kind="ocr",
                        extractor="ppocrv6-small", version="2", text="改版释读",
                        at="2026-11-02T11:25:00Z")
        assert rebooked["path"] == "state/extractions/" + seal_b + ".json", rebooked
        served_seal = call(root, "context", order=seal_order)
        assert served_seal["source_text"] == "改版释读" and served_seal["extraction_required"] is False, served_seal
        assert served_seal["extraction"]["bound_sha256"] == seal_b
        assert sidecar(root, seal_a)["text"] == "初版释读"
        call(root, "cancel", order=seal_order)
        check("forget does not reopen a sidecar; identical-byte rescan stays refused; byte replacement rebooks on the new digest")

        # The text cap counts UTF-8 BYTES, the transport's unit (finding #4):
        # 349,526 CJK chars are 1,048,578 bytes -- over the 1 MiB limit -- while
        # a character count would call them under it. The request line stays
        # inside the native 2 MiB ceiling, so this refusal comes from the engine
        # with a stable code, not from the transport.
        (root / "raw/长文.png").write_bytes(png_bytes() + b"\x00long")
        long_sha = hashlib.sha256(png_bytes() + b"\x00long").hexdigest()
        call(root, "scan")
        oversized = "陶" * 349526
        assert len(oversized.encode("utf-8")) == 1048578 and len(oversized) < 1048576
        call(root, "extraction-submit", source="raw/长文.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text=oversized, at="2026-11-02T11:30:00Z",
             error="extraction_text_invalid")
        fitting = "陶" * 349525 + "a"
        call(root, "extraction-submit", source="raw/长文.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text=fitting, at="2026-11-02T11:31:00Z")
        assert sidecar(root, long_sha)["text"] == fitting
        check("1 MiB text cap counts UTF-8 bytes (CJK over-cap refused with the engine's stable code)")

        # An event file on disk without its registered sidecar is an orphan the
        # channel must not adopt: recording the audit trail and the record are
        # one transaction, so disagreement is a refusal, not a silent overwrite.
        (root / "raw/残卷.png").write_bytes(png_bytes() + b"\x00orphan")
        orphan_sha = hashlib.sha256(png_bytes() + b"\x00orphan").hexdigest()
        call(root, "scan")
        stray = root / "state/events" / ("extraction-submit-" + orphan_sha + ".json")
        stray.write_text(json.dumps({"op": "extraction-submit", "source": "raw/残卷.png",
                                     "source_sha256": orphan_sha, "extractor": "x",
                                     "version": "1", "at": "2026-11-02T11:40:00Z"},
                                    ensure_ascii=False), encoding="utf-8")
        call(root, "extraction-submit", source="raw/残卷.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text="正文", at="2026-11-02T11:41:00Z",
             error="extraction_event_conflict")
        stray.unlink()
        call(root, "extraction-submit", source="raw/残卷.png", kind="ocr",
             extractor="ppocrv6-small", version="1", text="正文", at="2026-11-02T11:42:00Z")
        check("orphan event without registered sidecar refused (extraction_event_conflict)")

        # The filename hash and the content source_sha256 lock each other: a
        # hand-edit that moves one without the other is refused by validate_record
        # even after the catalog row hash is recomputed so the bytes themselves
        # verify. (Same catalog-tamper technique as record_validation_e2e.py.)
        sidecar_file = root / "state/extractions" / (png_sha + ".json")
        original_sidecar = sidecar_file.read_text(encoding="utf-8")
        catalog_original = (root / "index.mbt.md").read_text(encoding="utf-8")
        forged = json.loads(original_sidecar)
        forged["source_sha256"] = "0" * 64
        forged_text = json.dumps(forged, ensure_ascii=False)
        sidecar_file.write_text(forged_text, encoding="utf-8")
        forged_hash = hashlib.sha256(forged_text.encode("utf-8")).hexdigest()
        rows = catalog_original.splitlines()
        wanted = '"state/extractions/' + png_sha + '.json"'
        for i, line in enumerate(rows):
            if line.strip().startswith("entry(") and wanted in line:
                # The only standalone 64-hex quoted argument on the row is sha256
                # (id/path embed the digest inside a longer string), so count=1
                # pins exactly the content-hash field.
                rows[i] = re.sub(r'"[0-9a-f]{64}"', '"%s"' % forged_hash, line, count=1)
                break
        else:
                raise AssertionError("sidecar catalog row not found")
        (root / "index.mbt.md").write_text("\n".join(rows) + "\n", encoding="utf-8")
        call(root, "verify", error="extraction_record_identity_invalid")
        sidecar_file.write_text(original_sidecar, encoding="utf-8")
        (root / "index.mbt.md").write_text(catalog_original, encoding="utf-8")
        check("sidecar filename/content digest lock enforced (hand-edited record refused)")

        # A pack/unpack round trip keeps the sidecar as a registered record and
        # serves it in the restored vault: state/extractions is on the shared
        # directory whitelist, so the pack whitelist accepts it.
        call(root, "rebuild")
        assert call(root, "verify")["violations"] == []
        blob = call(root, "pack", output="exports/roundtrip.mcpack")
        restored = Path(work) / "restored"
        restored.mkdir()
        for directory in ["raw", "wiki", "views", "vectors", "staging", "state/transactions/history", "imports"]:
            (restored / directory).mkdir(parents=True, exist_ok=True)
        (restored / "imports/roundtrip.mcpack").write_bytes((root / blob["output"]).read_bytes())
        call(restored, "unpack", file="imports/roundtrip.mcpack")
        call(restored, "rebuild")
        assert (restored / "state/extractions" / (png_sha + ".json")).exists()
        restored_index = (restored / "index.mbt.md").read_text(encoding="utf-8")
        assert "state/extractions/" + png_sha + ".json" in restored_index
        assert sidecar(restored, png_sha)["text"] == text
        check("pack/unpack round trip preserves the digest-bound sidecar record")

    print("extraction sidecar e2e: intake, replay, conflict, exists, override, drift, one-way lifecycle, byte cap and pack round trip passed")


if __name__ == "__main__":
    main()
