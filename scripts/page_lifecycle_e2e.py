#!/usr/bin/env python3
"""Exercise explicit page archive/restore lifecycle on a real native vault."""
import json
from pathlib import Path
import select
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


class Session:
    def __init__(self, vault):
        self.vault = vault
        self.proc = subprocess.Popen([str(EXE)], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     text=True, bufsize=1)
        self.seq = 0

    def call(self, op, error=None, **args):
        request = {"op": op, "vault": str(self.vault), "request_id": self.seq, **args}
        self.seq += 1
        self.proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        assert select.select([self.proc.stdout], [], [], 20)[0], op
        result = json.loads(self.proc.stdout.readline())
        if error is not None:
            assert not result["ok"] and error in result["error"], result
            return result
        assert result["ok"], result
        return result["result"]

    def close(self):
        self.proc.stdin.close()
        assert self.proc.wait(timeout=10) == 0
        stderr = self.proc.stderr.read()
        assert "Panic" not in stderr and "Warning:" not in stderr, stderr


with tempfile.TemporaryDirectory(prefix="memorycorridor-page-lifecycle-") as temp:
    vault = Path(temp) / "vault"
    vault.mkdir()
    session = Session(vault)
    try:
        session.call("init", purpose="页面生命周期")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/source.md").write_text("页面来源。\n")
        order = session.call("scan")["orders"][0]
        session.call("context", order=order)
        session.call("analysis-submit", order=order,
                     analysis={"entities": [], "concepts": ["页面"], "conflicts": [], "summary": "页面"})
        staging = vault / "staging" / order
        staging.mkdir(parents=True, exist_ok=True)
        (staging / "page.md").write_text(
            "---\ntype: concept\ntitle: 生命周期页\nsources: [\"raw/source.md\"]\n---\n保留正文。\n"
        )
        session.call("commit", order=order,
                     pages=[{"id": "concepts/lifecycle", "path": "wiki/concepts/lifecycle.md",
                             "staged": f"staging/{order}/page.md"}], at="2026-10-17")

        archive = session.call("archive-page", id="concepts/lifecycle", at="2026-10-17T01:00:00Z",
                               reason="旧版本归档")
        assert archive["invalidated"] == ["concepts/lifecycle"]
        assert session.call("read-page", id="concepts/lifecycle")["stale"]
        replay = session.call("archive-page", id="concepts/lifecycle", at="2026-10-17T01:00:00Z",
                              reason="旧版本归档")
        assert replay["replayed"]
        session.call("archive-page", id="concepts/lifecycle", at="2026-10-17T01:01:00Z",
                     reason="重复归档", error="page_not_active")

        restored = session.call("restore-page", id="concepts/lifecycle", at="2026-10-17T02:00:00Z")
        assert restored["restored"] and not session.call("read-page", id="concepts/lifecycle")["stale"]
        assert session.call("restore-page", id="concepts/lifecycle", at="2026-10-17T02:00:00Z")["replayed"]

        session.call("forget", source="raw/source.md", at="2026-10-17T03:00:00Z")
        session.call("restore-page", id="concepts/lifecycle", at="2026-10-17T04:00:00Z",
                     error="page_sources_inactive")
        session.call("rebuild")
        session.call("verify")
    finally:
        session.close()

print("page lifecycle e2e: ok")
