#!/usr/bin/env python3
"""Real Office originals through the intake loop.

The fixtures are produced with Python's zipfile at ZIP_DEFLATED, matching how
Word/Excel/PowerPoint actually write OOXML packages — this exercises the
engine's inflate path end to end, not just the STORE round trip available to
in-package tests. Covers: format detection at scan, deterministic extraction
served in `context`, extraction metadata, a committed page citing the binary
original, full verify, and a corrupt-entry archive refusing extraction with a
stable error family instead of returning partial text.
"""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
CHECKS = []


def call(root, op, **args):
    request = {"op": op, "vault": str(root), **args}
    process = subprocess.run([str(CLI)], input=json.dumps(request) + "\n", capture_output=True, text=True)
    assert process.stdout.strip(), process.stderr
    return json.loads(process.stdout.splitlines()[0])


def ok(root, op, **args):
    value = call(root, op, **args)
    assert value["ok"], value
    return value["result"]


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def docx_bytes(text):
    document = (
        '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body><w:p><w:r><w:t>" + text + "</w:t></w:r></w:p></w:body></w:document>"
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        archive.writestr("_rels/.rels", "<Relationships/>")
        archive.writestr("word/document.xml", document)
    return buffer.getvalue()


def xlsx_bytes(cell):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("xl/workbook.xml", '<workbook><sheets><sheet name="釉料" r:id="r1"/></sheets></workbook>')
        archive.writestr("xl/_rels/workbook.xml.rels",
                         '<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/></Relationships>')
        archive.writestr("xl/worksheets/sheet1.xml",
                         f"<worksheet><sheetData><row r=\"1\"><c><v>{cell}</v></c></row></sheetData></worksheet>")
    return buffer.getvalue()


def pptx_bytes(phrase):
    slide = ("<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\">"
            f"<p:cSld><p:sp><p:txBody><a:p><a:r><a:t>{phrase}</a:t></a:r></a:p></p:txBody></p:sp></p:cSld></p:sld>")
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("ppt/presentation.xml", "<p:presentation/>")
        archive.writestr("ppt/slides/slide1.xml", slide)
    return buffer.getvalue()


def main():
    assert CLI.exists(), "build first: moon build --target native cli"
    with tempfile.TemporaryDirectory(prefix="corridor-office-") as work:
        root = Path(work) / "vault"
        root.mkdir()
        ok(root, "init", purpose="青瓷工艺记录")
        (root / "raw/窑口记录.docx").write_bytes(docx_bytes("哥窑窑址在龙泉大窑村，鼎盛于南宋。"))
        (root / "raw/配方表.xlsx").write_bytes(xlsx_bytes("铁含量约百分之一点五"))
        (root / "raw/讲义.pptx").write_bytes(pptx_bytes("粉青釉以石灰碱釉为基"))
        ok(root, "scan")
        by_source = {order["source"]: order["id"] for order in ok(root, "plan")}
        assert {"raw/窑口记录.docx", "raw/配方表.xlsx", "raw/讲义.pptx"} <= set(by_source), by_source

        # Word original: full publication loop first (context → analysis →
        # commit), so the committed page cites binary bytes verified by the
        # engine's own zip reader.
        order = by_source["raw/窑口记录.docx"]
        word = ok(root, "context", order=order)
        assert "哥窑窑址在龙泉大窑村，鼎盛于南宋。" in word["source_text"], word["source_text"][:200]
        assert "xmlns" not in word["source_text"]  # markup is gone, text stays
        assert word["extraction_required"] is False
        assert word["extraction"] == {"kind": "office-word", "extractor": "corridor-office-v1"}
        ok(root, "analysis-submit", order=order, analysis={
            "entities": ["哥窑"], "concepts": ["窑址"], "conflicts": [], "summary": "窑口记录提取"})
        staging = root / "staging" / order
        staging.mkdir(exist_ok=True)
        (staging / "0.md").write_text(
            '---\ntype: concept\ntitle: 哥窑\nsources: ["raw/窑口记录.docx"]\n---\n'
            "哥窑窑址在龙泉大窑村，鼎盛于南宋。\n", encoding="utf-8")
        ok(root, "commit", order=order, pages=[
            {"id": "concepts/哥窑", "path": "wiki/concepts/哥窑.md", "staged": f"staging/{order}/0.md"}], at="2026-11-02")
        ok(root, "rebuild")
        assert ok(root, "verify")["violations"] == []
        hits = ok(root, "search", query="哥窑 窑址")["hits"]
        assert hits and hits[0]["id"] == "concepts/哥窑", hits
        source = ok(root, "read-source", id="raw/窑口记录.docx")
        assert source["format"] == "office-word", source
        assert source["extraction_required"] is True and source["text"] is None, source
        check("real deflated docx flows through intake, publication, verify and search")

        spreadsheet = ok(root, "context", order=by_source["raw/配方表.xlsx"])
        assert "# sheet 釉料" in spreadsheet["source_text"]
        assert "铁含量约百分之一点五" in spreadsheet["source_text"]
        assert spreadsheet["extraction"]["kind"] == "office-spreadsheet"
        ok(root, "cancel", order=by_source["raw/配方表.xlsx"])
        slides = ok(root, "context", order=by_source["raw/讲义.pptx"])
        assert "# slide 1" in slides["source_text"]
        assert "粉青釉以石灰碱釉为基" in slides["source_text"]
        assert slides["extraction"]["kind"] == "office-slides"
        ok(root, "cancel", order=by_source["raw/讲义.pptx"])
        check("xlsx and pptx originals extract with sheet/slide structure in context")

        # A corrupt entry (valid central directory, flipped payload byte)
        # must refuse with a stable error family instead of partial text.
        good = docx_bytes("这一页的字节已被破坏。")
        broken = bytearray(good)
        broken[len(good) // 2] ^= 0x40
        (root / "raw/破损.docx").write_bytes(bytes(broken))
        ok(root, "scan")
        fresh = {o["source"]: o["id"] for o in ok(root, "plan")}
        assert "raw/破损.docx" in fresh, fresh
        refused = call(root, "context", order=fresh["raw/破损.docx"])
        assert not refused["ok"] and refused["error_code"] in {
            "office_zip_crc", "inflate_truncated", "inflate_bad_code", "inflate_bad_distance",
            "inflate_bad_back_distance", "inflate_bad_tables", "inflate_bad_rle",
            "office_zip_invalid", "inflate_bad_block_type", "inflate_stored_length",
            "office_part_missing", "office_part_invalid",
        }, refused
        ok(root, "cancel", order=fresh["raw/破损.docx"])
        check("corrupt archive refuses context with a stable error family")
    print(f"office e2e: {len(CHECKS)} checks passed")


if __name__ == "__main__":
    main()
