#!/usr/bin/env python3
"""End-to-end acceptance for the HTML engine channel (续十七).

HTML originals: fetching is host-side, but the projection to visible text is
deterministic engine work -- `context` serves the extracted body with
`extraction:{kind:"html", extractor:"corridor-html-v1"}`, the sidecar channel
refuses to shadow it (`extraction_override`), and `read-source` keeps the raw
bytes auditable. The published page then carries the extraction citation
end to end: commit -> rebuild -> verify -> search.

Run: python3 scripts/htmldoc_e2e.py
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
CHECKS = []

PAGE = ("""<!DOCTYPE html><html lang="zh"><head><meta charset="utf-8">"""
        """<title>青瓷窑口小记</title><style>.x{color:red}</style></head>"""
        """<body><h1>窑口</h1><template><p>幻影模板文本</p></template>"""
        """<p>龙泉窑青瓷以粉青与梅子青<strong>著称</strong>。</p>"""
        """<p>釉料以石灰<b>碱</b>釉为基。</p>"""
        """<script>if (a<b) { 幻影脚本(); }</script>"""
        """<ul><li>铁还原呈色</li><li> potassium feldspar 三成</li></ul>"""
        """<pre>  保留缩进
原文</pre></body></html>""").encode("utf-8")


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


def main():
    if not CLI.exists():
        print("SKIP: build the CLI first (moon build --target native cli)")
        return 0
    with tempfile.TemporaryDirectory(prefix="corridor-htmldoc-") as work:
        root = Path(work) / "vault"
        root.mkdir()
        ok(root, "init", purpose="青瓷 HTML 通道")
        (root / "raw").mkdir(exist_ok=True)
        (root / "raw/窑口笔记.html").write_bytes(PAGE)
        ok(root, "scan")
        order = ok(root, "plan")[0]
        assert order["source"] == "raw/窑口笔记.html", order

        # engine channel: visible text only, title leads, script/style/nav
        # interior never appears, pre keeps its indentation
        ctx = ok(root, "context", order=order["id"])
        text = ctx["source_text"]
        assert ctx["extraction_required"] is False
        assert ctx["extraction"] == {"kind": "html", "extractor": "corridor-html-v1"}, ctx["extraction"]
        assert "窑口" in text and "龙泉窑青瓷以粉青与梅子青著称" in text, text
        assert "幻影模板文本" not in text and "color:red" not in text and "菜单不该出现" not in text, text
        assert "  保留缩进\n原文" in text, text
        check("context serves the deterministic html projection with its own extractor tag")

        # raw bytes stay auditable through the registered-bytes channel
        raw = ok(root, "read-source", id="raw/窑口笔记.html")
        assert raw["text"].startswith("<!DOCTYPE html>") and "<script>" in raw["text"], raw["text"][:60]
        assert "幻影脚本" in raw["text"] and "幻影模板文本" in raw["text"]  # bytes are bytes; projection is context's job
        check("read-source reports the original bytes (dual-channel invariant)")

        # the sidecar channel refuses to shadow the engine extraction
        v = cli(root, "extraction-submit", source="raw/窑口笔记.html", kind="html",
                extractor="readability", version="1", text="外部正文", at="2026-11-02")
        assert not v["ok"] and v["error_code"] == "extraction_override", v
        check("extraction-submit cannot override the html engine channel")

        # publish a page citing the HTML source and confirm retrieval
        ok(root, "analysis-submit", order=order["id"],
           analysis={"entities": ["龙泉窑"], "concepts": ["粉青"], "conflicts": [],
                     "summary": "窑口与釉色（HTML 摄入）"})
        staging = root / "staging" / order["id"]
        staging.mkdir(exist_ok=True)
        (staging / "0.md").write_text(
            '---\ntype: concept\ntitle: 梅子青\ntags: ["青瓷"]\nsources: ["raw/窑口笔记.html"]\n---\n'
            "梅子青为龙泉窑青瓷代表釉色，铁还原呈色。\n", encoding="utf-8")
        ok(root, "commit", order=order["id"],
           pages=[{"id": "concepts/梅子青", "path": "wiki/concepts/梅子青.md",
                   "staged": f"staging/{order['id']}/0.md"}], at="2026-11-02")
        ok(root, "rebuild")
        assert ok(root, "verify")["violations"] == []
        hits = ok(root, "search", query="梅子青 铁还原")["hits"]
        assert hits and hits[0]["id"] == "concepts/梅子青", hits
        check("committed page over an HTML source is published, verified and retrieved")

        # a malformed original fails the request instead of serving partial text
        (root / "raw/坏页.html").write_bytes(b"<html><body><p>x</p><script>unclosed")
        ok(root, "scan")
        orders2 = {o["source"]: o["id"] for o in ok(root, "plan")}
        v = cli(root, "context", order=orders2["raw/坏页.html"])
        assert not v["ok"] and v["error"] == "html_unterminated_script", v
        # refuse the page's order so the vault closes clean afterwards
        ok(root, "cancel", order=orders2["raw/坏页.html"])
        check("unclosed script refuses context, never a truncated body")
        ok(root, "rebuild")
        assert ok(root, "verify")["violations"] == []
    print(f"htmldoc e2e: {len(CHECKS)} checks passed (engine html channel accepted)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
