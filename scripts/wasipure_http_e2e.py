#!/usr/bin/env python3
"""Drive the pure-WASI HTTP transport: wasmtime hosts wasipure.wasm with a
POSIX listener inherited at fd 3 (-S listenfd=y, systemd convention), the
module serves the eight read-only routes over real TCP, and engine dispatch
runs through the same WASI storage as the stdio face.

The startup receipt is part of the direct-run contract: the driver runs
`moon check --deny-warn --target-dir .corridor/compiler index.mbt.md` on the
built vault and passes `--index-sha <sha256>` so the module can verify the
catalog bytes without spawning a compiler.
"""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / "_build/wasm/debug/build/wasipure/wasipure.wasm"
WASMTIME = os.environ.get("WASMTIME", "/opt/homebrew/bin/wasmtime")
CHECKS = []


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def build_vault(root):
    """Build the vault content via the stdio face (separate module runs)."""
    sys.path.insert(0, str(REPO / "scripts"))
    from wasipure_e2e import PureSession  # reuse the batch driver
    s = PureSession(root, root.parent)
    s.call("init", purpose="wasipure http")
    (root / "raw/甲.md").write_text("# 光合作用\n叶绿体转换光能。\n", encoding="utf-8")
    s.call("scan")
    planned = {o["source"]: o["id"] for o in s.call("plan")}
    order = planned["raw/甲.md"]
    s.call("context", order=order)
    s.call("analysis-submit", order=order, analysis={
        "entities": [], "concepts": ["能量"], "conflicts": [], "summary": "资料分析"})
    staged = root / "staging" / order
    staged.mkdir(parents=True, exist_ok=True)
    (staged / "0.md").write_text(
        "---\ntype: concept\ntitle: 光合作用能量\nsources: [\"raw/甲.md\"]\n---\n叶绿体通过光合作用转换能量。\n",
        encoding="utf-8")
    s.call("commit", order=order, at="2026-10-31", pages=[
        {"id": "concepts/能量", "path": "wiki/concepts/能量.md",
         "staged": f"staging/{order}/0.md"}])
    s.call("rebuild")
    return s.compile_round_trips


def spawn_server(root, port, index_sha):
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen(8)
    fd = sock.fileno()
    os.set_inheritable(fd, True)

    def preexec():
        if fd != 3:
            os.dup2(fd, 3)
        os.set_inheritable(3, True)

    env = dict(os.environ)
    env["LISTEN_FDS"] = "1"
    env.pop("LISTEN_PID", None)
    proc = subprocess.Popen(
        [WASMTIME, "run", "-S", "listenfd=y", "--dir=" + str(root),
         str(MODULE), "--serve", str(port), "--index-sha", index_sha],
        pass_fds=(fd,), preexec_fn=preexec, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    sock.close()
    return proc


def http_get(port, target, method="GET"):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.request(method, target)
    response = conn.getresponse()
    body = response.read()
    conn.close()
    return response.status, body


def wait_port(port, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            probe = socket.socket()
            probe.settimeout(1)
            probe.connect(("127.0.0.1", port))
            probe.close()
            return True
        except OSError:
            time.sleep(0.3)
    return False


def main():
    assert MODULE.exists(), f"module missing: {MODULE}"
    port = 18790
    with tempfile.TemporaryDirectory(prefix="memorycorridor-wasipure-http-") as work:
        root = Path(work) / "vault"
        root.mkdir()
        rounds = build_vault(root)

        index_sha = None
        for candidate in (root / ".corridor").glob("*.mbt.md"):
            pass
        import hashlib
        index_sha = hashlib.sha256((root / "index.mbt.md").read_bytes()).hexdigest()

        proc = spawn_server(root, port, index_sha)
        try:
            assert wait_port(port), "http server did not start"

            status, body = http_get(port, "/api/status")
            assert status == 200, (status, body[:200])
            payload = json.loads(body)
            assert payload["ok"] is True and payload["result"]["pages"] == 1
            check("/api/status 200 with engine payload")

            status, body = http_get(port, "/api/search?q=光合作用")
            assert status == 200
            hits = json.loads(body)["result"]["hits"]
            assert hits and hits[0]["id"] == "concepts/能量"
            check("/api/search CJK query hit")

            status, body = http_get(port, "/api/page?id=concepts/能量")
            assert status == 200 and "光合作用" in body.decode("utf-8")
            status, body = http_get(port, "/api/lint")
            assert status == 200
            status, body = http_get(port, "/api/tree")
            assert status == 200
            status, body = http_get(port, "/api/topics")
            assert status == 200
            check("page/lint/tree/topics routes over TCP")

            status, body = http_get(port, "/api/nope")
            assert status == 404
            status, body = http_get(port, "/api/status?extra=1", method="POST")
            assert status == 405
            status, body = http_get(port, "/api/page")
            assert status == 400
            check("404/405/400 refusals mirror the native transport")

            # Drift: external page edit must flip /api/search to 409 until restore.
            page = root / "wiki/concepts/能量.md"
            original = page.read_text(encoding="utf-8")
            page.write_text(original + "外部追加。\n", encoding="utf-8")
            status, body = http_get(port, "/api/search?q=光合作用")
            assert status == 409, (status, body[:200])
            page.write_text(original, encoding="utf-8")
            status, body = http_get(port, "/api/search?q=光合作用")
            assert status == 200
            check("drift flips search to 409; restore clears it over TCP")
        finally:
            proc.terminate()
            try:
                out = proc.communicate(timeout=10)[0].decode("utf-8", "replace")
            except subprocess.TimeoutExpired:
                proc.kill()
                out = ""
            assert "Trap" not in out and "panicked" not in out, out[-500:]
    print("wasipure http e2e: boundary scenarios passed")


if __name__ == "__main__":
    main()
