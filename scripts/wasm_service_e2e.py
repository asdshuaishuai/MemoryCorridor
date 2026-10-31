#!/usr/bin/env python3
"""Drive the full engine through the wasm service (wasmtime + corridor-host).

The module under test is the same agent/vault/index stack the native CLI
links; the difference is that every filesystem touch, the vault lock and the
`moon check` subprocess cross the corridor-host import boundary implemented by
hosts/wasm-host.py. This gate pins that boundary: intake work orders, the
real compiler callback, drift/tamper refusal, the agent face (memory, inbox)
and a two-process vault lock race.
"""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
HOST = REPO / "hosts" / "wasm-host.py"
MODULE = REPO / "_build/wasm/debug/build/wasm/wasm.wasm"
CHECKS = []


def ensure_wasmtime():
    """Re-exec under a venv that has wasmtime, creating it on first use."""
    try:
        import wasmtime  # noqa: F401
        return
    except ImportError:
        pass
    venv = Path.home() / ".cache" / "memorycorridor" / "wasmtime-venv"
    py = venv / "bin" / "python"
    if not py.exists():
        import venv as venv_mod
        venv_mod.create(venv, with_pip=True)
        subprocess.run([str(py), "-m", "pip", "install", "--quiet", "wasmtime"], check=True)
    os.execv(str(py), [str(py), __file__, *sys.argv[1:]])


class Service:
    """One long-running wasm instance behind hosts/wasm-host.py."""

    def __init__(self, root):
        self.root = root
        self.log = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            [sys.executable, str(HOST), "--module", str(MODULE), "--root", str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, text=True, bufsize=1,
        )

    def call(self, op, *, error=None, request_id_echo=True, **args):
        request = {"op": op, "vault": str(self.root), "request_id": len(CHECKS), **args}
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 60)[0]:
            raise AssertionError(f"response timed out: {op}")
        line = self.process.stdout.readline()
        assert line, f"host exited on {op}"
        value = json.loads(line)
        if request_id_echo:
            # An oversized request cannot be parsed, so its id cannot be
            # echoed — the native CLI answers those with request_id null too.
            assert value["request_id"] == request["request_id"], value
        if error:
            assert not value["ok"] and error in value["error"], value
            return value
        assert value["ok"], value
        return value["result"]

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=30) == 0
        self.log.seek(0)
        log = self.log.read()
        assert "Traceback" not in log, log
        self.log.close()


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def prepare(session, order):
    session.call("context", order=order)
    session.call("analysis-submit", order=order, analysis={
        "entities": [], "concepts": ["能量", "共享"], "conflicts": [], "summary": "资料分析",
    })


def commit(session, order, pages):
    directory = session.root / "staging" / order
    directory.mkdir(parents=True, exist_ok=True)
    declarations = []
    for i, (pid, title, sources, body) in enumerate(pages):
        staged = directory / f"{i}.md"
        staged.write_text(
            "---\ntype: concept\ntitle: " + title + "\nsources: " +
            json.dumps(sources, ensure_ascii=False) + "\n---\n" + body + "\n",
            encoding="utf-8",
        )
        declarations.append({"id": pid, "path": f"wiki/{pid}.md", "staged": str(staged.relative_to(session.root))})
    return session.call("commit", order=order, pages=declarations, at="2026-10-30")


def main():
    assert MODULE.exists(), f"module missing; run: moon build --target wasm wasm ({MODULE})"
    with tempfile.TemporaryDirectory(prefix="memorycorridor-wasm-") as work:
        root = Path(work) / "vault"
        root.mkdir()
        s = Service(root)
        try:
            # Empty vault invariants.
            s.call("init", purpose="植物能量知识")
            s.call("search", query="空库")
            assert s.call("verify")["violations"] == []
            assert s.call("status")["index_cache"] == "valid"
            lint = s.call("lint")
            assert lint["status"] == "clean" and lint["errors"] == 0
            s.call("init", error="vault_already_initialized")
            unknown = s.call("status", bogus_field="x", error="unknown_field")
            assert unknown["error_code"] == "unknown_field"
            check("empty vault invariants, init refusal and unknown-field refusal over wasm")

            # Full intake loop: scan → context → analysis → staging → commit.
            (root / "raw/甲.md").write_text("# 光合作用\n叶绿体转换光能。\n", encoding="utf-8")
            (root / "raw/乙.txt").write_text("共享能源研究：保存来源证据。\n", encoding="utf-8")
            assert len(s.call("scan")["orders"]) == 2
            planned = {o["source"]: o["id"] for o in s.call("plan")}
            first, second = planned["raw/甲.md"], planned["raw/乙.txt"]
            prepare(s, first)
            s.call("context", order=second, error="another_order_active")
            commit(s, first, [("concepts/能量", "光合作用能量", ["raw/甲.md"], "叶绿体通过光合作用转换能量。")])
            prepare(s, second)
            commit(s, second, [("concepts/共享", "共享能源", ["raw/甲.md", "raw/乙.txt"], "跨资料的共享能源知识。[[concepts/能量]]")])
            assert len(s.call("list-pages")) == 4
            assert s.call("search", query="光合作用")["hits"][0]["id"] == "concepts/能量"
            s.call("check-index")
            s.call("verify")
            check("intake work orders through the host storage and compiler callbacks")

            # The compile callback is a real moon subprocess on the host side.
            index_source = (root / "index.mbt.md").read_text(encoding="utf-8")
            (root / "index.mbt.md").write_text(
                index_source + "\n```mbt check\nfn broken_helper() -> Int { missing_symbol() }\n```\n",
                encoding="utf-8")
            s.call("search", query="光合作用", error="moon_check_failed")
            (root / "index.mbt.md").write_text(index_source + "Glued remark", encoding="utf-8")
            rejected = s.call("status", error="catalog_literate_tail")
            assert any(v["predicate"] == "catalog_literate_tail" for v in rejected["violations"])
            (root / "index.mbt.md").write_text(index_source, encoding="utf-8")
            s.call("verify")
            check("broken literate helper refuses via the host moon subprocess; tail glue refused")

            # Agent face on wasm: memory, inbox.
            s.call("memory-submit", kind="preference", scope="workspace",
                   text="优先安排光合作用实验", conditions=["规划实验时"], sources=["raw/甲.md"],
                   at="2026-10-30T09:00:00Z", key="photosynthesis-preference")
            notes = s.call("memory-list")
            assert notes["notes"] and notes["notes"][0]["valid"] is True
            inbox = s.call("inbox")
            assert isinstance(inbox["items"], list)
            prefetch = s.call("memory-prefetch", query="光合作用 实验", limit=5)
            assert prefetch["candidates"] >= 1 and prefetch["notes"][0]["conflicted"] is False
            check("memory layer and inbox answer through the wasm dispatch")

            # External drift must be refused by the engine hashing host reads.
            page = root / "wiki/concepts/能量.md"
            original = page.read_text(encoding="utf-8")
            page.write_text(original + "外部追加的句子。\n", encoding="utf-8")
            s.call("status", error="content_changed")
            page.write_text(original, encoding="utf-8")
            s.call("rebuild")
            s.call("verify")
            check("external page drift refused; rebuild after restore clears it")

            # MCP stdio 直跑：同一 corridor.wasm 以 JSON-RPC 信封服务。握手
            # initialize → notifications/initialized（静默，由下一行的 id 顺序
            # 证明）→ tools/list 93 工具 → tools/call；进度令牌产生
            # notifications/progress 行；信封行为与 native MCP 传输一致。
            mcp = subprocess.Popen(
                [sys.executable, str(HOST), "--module", str(MODULE), "--root", str(root),
                 "--mcp"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, bufsize=1)
            def mcp_send(rpc):
                mcp.stdin.write(json.dumps(rpc, ensure_ascii=False) + "\n")
                mcp.stdin.flush()
            def mcp_read():
                assert select.select([mcp.stdout], [], [], 30)[0], "mcp reply timed out"
                line = mcp.stdout.readline()
                assert line, "mcp host exited"
                return json.loads(line)
            try:
                mcp_send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                    "protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "e2e"}}})
                init = mcp_read()
                assert init["result"]["protocolVersion"] == "2024-11-05"
                # 握手未收尾前 tools/* 必须拒绝
                mcp_send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                early = mcp_read()
                assert early["error"]["data"]["error_code"] == "initialization_required"
                # 通知（无 id）不产生响应行：下一个可读行必须是 id=3 的回复
                mcp_send({"jsonrpc": "2.0", "method": "notifications/initialized"})
                mcp_send({"jsonrpc": "2.0", "id": 3, "method": "tools/list"})
                tools = mcp_read()
                assert tools["id"] == 3
                assert len(tools["result"]["tools"]) == 93
                # 进度令牌：tools/call 产生 started/completed 通知行 + 回复行
                mcp_send({"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                    "name": "corridor_status", "arguments": {"vault": str(root)},
                    "_meta": {"progressToken": "t1"}}})
                started = mcp_read()
                assert started["method"] == "notifications/progress"
                assert started["params"]["progressToken"] == "t1"
                assert started["params"]["progress"] == 0
                done = mcp_read()
                assert done["method"] == "notifications/progress"
                assert done["params"]["progress"] == 1 and done["params"]["message"] == "completed"
                call_status = mcp_read()
                assert call_status["id"] == 4
                assert call_status["result"]["isError"] is False
                assert call_status["result"]["structuredContent"]["result"]["index_cache"] == "valid"
                # 未知工具 → JSON-RPC error 信封（工具名翻译失败在 dispatch 前）
                mcp_send({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
                    "name": "corridor_nope", "arguments": {"vault": str(root)}}})
                unknown = mcp_read()
                assert unknown["error"]["data"]["error_code"] == "unknown_tool"
                # 重复 initialize → already_initialized
                mcp_send({"jsonrpc": "2.0", "id": 6, "method": "initialize", "params": {
                    "protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "e2e"}}})
                again = mcp_read()
                assert again["error"]["data"]["error_code"] == "already_initialized"
                # 行上限：--mcp 面经 input_load 达 16 MiB，超限由宿主直写
                # 回复（模块 canonical 路径被绕过）。信封必须与模块侧
                # canonical 形态逐字节一致：键序 error,id,jsonrpc，data 携
                # error_code/hint，id 为 null，不回显 request_id。
                mcp.stdin.write(json.dumps(
                    {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {
                        "name": "corridor_status",
                        "arguments": {"vault": str(root), "pad": "x" * (16 * 1024 * 1024)}}},
                    ensure_ascii=False) + "\n")
                mcp.stdin.flush()
                assert select.select([mcp.stdout], [], [], 30)[0], "overflow reply timed out"
                overflow_raw = mcp.stdout.readline()
                overflow_expected = (
                    '{"error":{"code":-32700,'
                    '"data":{"error_code":"input_overflow",'
                    '"hint":"根据 error_code 修正请求；必要时先读取 status 或 context"},'
                    '"message":"input_overflow"},'
                    '"id":null,"jsonrpc":"2.0"}\n')
                assert overflow_raw == overflow_expected, overflow_raw[:200]
                check("MCP stdio transport over the same corridor.wasm: handshake gate, silent notifications, progress notices, error envelopes, canonical 16 MiB overflow envelope")
            finally:
                mcp.terminate()
                err = mcp.stderr.read()
                assert "Traceback" not in err, err[-500:]

            # corridor-host 面大容器同等验证：多 MiB 原件 → pack 确定性双跑
            # 字节一致 → 宿主复制到空 vault 的 imports/ → unpack 恢复 →
            # 检索与读源（sha256、字节数）parity。
            big_bytes = bytes([137, 80, 78, 71, 13, 10, 26, 10]) + bytes(3 * 1024 * 1024) + b"corridor-host-pack"
            (root / "raw/大容器.png").write_bytes(big_bytes)
            s.call("scan")
            s.call("rebuild")
            s.call("verify")
            # pack 拒绝覆盖已有导出，因此确定性双跑用两个输出名
            s.call("pack", output="exports/大容器.mcpack")
            pack_one = (root / "exports" / "大容器.mcpack").read_bytes()
            assert len(pack_one) >= len(big_bytes)
            s.call("pack", output="exports/大容器二.mcpack")
            assert (root / "exports" / "大容器二.mcpack").read_bytes() == pack_one
            host_b = Path(work) / "vault-host-b"
            (host_b / "imports").mkdir(parents=True)
            (host_b / "imports" / "大容器.mcpack").write_bytes(pack_one)
            other = Service(host_b)
            try:
                other.call("unpack", file="imports/大容器.mcpack")
                other.call("rebuild")
                hits = other.call("search", query="光合作用")["hits"]
                assert hits and hits[0]["id"] == "concepts/能量"
                src_a = s.call("read-source", id="raw/大容器.png")
                src_b = other.call("read-source", id="raw/大容器.png")
                assert src_a["registered_sha256"] == src_b["registered_sha256"]
                assert src_a["bytes"] == src_b["bytes"] == len(big_bytes)
            finally:
                other.close()
            check("corridor-host face packs and unpacks a multi-megabyte container with byte parity")

            # A raw payload larger than the 1 MiB initial read buffer forces
            # the host_call_buffer retry protocol to grow to the exact size;
            # digest and verify re-read the whole file through the same path.
            big_body = "# 大来源\n" + ("光合作用数据段落。" * 90000)
            assert len(big_body.encode("utf-8")) > 1024 * 1024
            (root / "raw/大.md").write_text(big_body, encoding="utf-8")
            s.call("scan")
            big_orders = {o["source"]: o["id"] for o in s.call("plan")}
            assert "raw/大.md" in big_orders
            s.call("rebuild")
            s.call("verify")
            excerpt = s.call("read-source", id="raw/大.md", start=0, end=27)
            assert excerpt["text"].startswith("# 大来源") and excerpt["truncated"] is False
            s.call("read-source", id="raw/大.md", start=0, end=999999999,
                   error="source_range_invalid")
            check("multi-megabyte source round-trips through the host read retry")

            # Segmented request load: a multi-megabyte text op crosses the old
            # 2 MiB request ceiling; past 16 MiB (the single-file limit) the
            # module answers with the canonical input_overflow envelope.
            huge_text = "检索结论需要进一步核对。" * 200000
            assert len(huge_text.encode("utf-8")) > 2 * 1024 * 1024
            s.call("backfill", title="大回填", text=huge_text)
            assert s.call("status")["active_sources"] >= 4
            s.call("rebuild")
            s.call("verify")
            s.call("backfill", title="超大回填", text="x" * (16 * 1024 * 1024 + 1),
                   error="input_overflow", request_id_echo=False)
            check("segmented request load carries multi-megabyte text; 16 MiB refused")

            # A symlinked source must be refused (O_NOFOLLOW), not silently
            # read as absent: the scan op fails naming read_refused.
            outside = Path(work) / "外部.md"
            outside.write_text("外部内容\n", encoding="utf-8")
            os.symlink(outside, root / "raw/链接.md")
            s.call("scan", error="read_refused")
            (root / "raw/链接.md").unlink()
            s.call("verify")
            check("symlinked source refused by the host instead of read as absent")

            # Two host processes race for the vault lock (flock across processes).
            s.call("session-open")
            other = Service(root)
            try:
                locked = other.call("session-open", error="vault_locked")
                assert locked["error_code"] == "vault_locked"
            finally:
                other.close()
            s.call("session-close")
            reopened = Service(root)
            try:
                reopened.call("session-open")
                reopened.call("session-close")
            finally:
                reopened.close()
            check("second host process refused by the vault flock; release lets it in")
        finally:
            s.close()
    print("wasm service e2e: boundary scenarios passed")


if __name__ == "__main__":
    ensure_wasmtime()
    main()
