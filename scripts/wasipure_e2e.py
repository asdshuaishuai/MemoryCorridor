#!/usr/bin/env python3
"""Drive the pure-WASI service module under plain wasmtime (no custom host).

The wasipure module imports only wasi_snapshot_preview1: the vault directory
arrives as a WASI preopen, the vault lock is a lease lockfile, and compile
verification uses the receipt protocol — an op that needs the compiler fails
with `compile_required: <path> <sha256>`, and the calling side runs
`moon check --deny-warn --target-dir .corridor/compiler <path>` itself, then
resends the op with receipts:[{path, sha256, ok:true}]. The module keeps no
state between runs, so every batch replays prior idempotent ops — which is
also what makes the stateless model safe.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / "_build/wasm/debug/build/wasipure/wasipure.wasm"
CHECKS = []


def ensure_wasmtime():
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


def run_batch(module_path, root, requests, work):
    """One module run over the request lines; returns the response list."""
    print(f"  [batch] {len(requests)} requests, root={root}")
    lint_req = [r for r in requests if r["op"] == "lint"]
    if lint_req:
        print("  [lint receipts]", json.dumps(lint_req[-1].get("receipts")))
    from wasmtime import Engine, Store, Module, Linker, WasiConfig

    engine = Engine()
    module = Module.from_file(engine, str(module_path))
    store = Store(engine)
    linker = Linker(engine)
    wasi = WasiConfig()
    root.mkdir(parents=True, exist_ok=True)
    if not root.is_dir():
        raise AssertionError(f"root missing before preopen: {root}")
    wasi.preopen_dir(str(root), ".")
    stdin_path = work / "requests.jsonl"
    stdin_path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in requests), encoding="utf-8")
    stdout_path = work / "responses.jsonl"
    wasi.stdin_file = str(stdin_path)
    wasi.stdout_file = str(stdout_path)
    wasi.stderr_file = str(work / "stderr.log")
    store.set_wasi(wasi)
    linker.define_wasi()
    instance = linker.instantiate(store, module)
    instance.exports(store)["_start"](store)
    responses = []
    for line in stdout_path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            responses.append(json.loads(line))
    assert len(responses) == len(requests), (
        f"response count {len(responses)} != requests {len(requests)}")
    return responses


def run_mcp_batch(module_path, root, requests, work):
    """One --mcp module run: JSON-RPC lines in, every reply line out."""
    from wasmtime import Engine, Store, Module, Linker, WasiConfig

    engine = Engine()
    module = Module.from_file(engine, str(module_path))
    store = Store(engine)
    linker = Linker(engine)
    wasi = WasiConfig()
    root.mkdir(parents=True, exist_ok=True)
    wasi.preopen_dir(str(root), ".")
    wasi.argv = ["wasipure.wasm", "--mcp"]
    stdin_path = work / "mcp-requests.jsonl"
    stdin_path.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in requests), encoding="utf-8")
    stdout_path = work / "mcp-responses.jsonl"
    wasi.stdin_file = str(stdin_path)
    wasi.stdout_file = str(stdout_path)
    wasi.stderr_file = str(work / "mcp-stderr.log")
    store.set_wasi(wasi)
    linker.define_wasi()
    instance = linker.instantiate(store, module)
    instance.exports(store)["_start"](store)
    return [json.loads(line) for line in stdout_path.read_text(encoding="utf-8").splitlines() if line.strip()]


class PureSession:
    """Accumulates requests; each call replays the whole batch under wasmtime.

    compile_required is handled transparently: the driver runs the real
    `moon check` in the vault and resends with a receipt bound to the current
    file bytes.
    """

    def __init__(self, root, work):
        self.root = root
        self.work = work
        self.requests = []
        self.receipts = {}  # path → sha256 verified by a real moon check
        self.compile_round_trips = 0

    def call(self, op, *, error=None, receipts=None, auto_receipt=True, **args):
        request = {"op": op, "vault": str(self.root), "request_id": len(CHECKS), **args}
        if receipts is not None:
            request["receipts"] = receipts
        elif self.receipts:
            request["receipts"] = [{"path": p, "sha256": s, "ok": True} for p, s in sorted(self.receipts.items())]
        self.requests.append(request)
        responses = run_batch(MODULE, self.root, self.requests, self.work)
        last = responses[-1]
        while auto_receipt:
            # compile_required surfaces two ways: a top-level error envelope,
            # or (for diagnostic ops like lint) an ok:true response with the
            # fault embedded as a catalog_compile violation detail.
            pending = None
            if not last.get("ok") and str(last.get("error_code", "")).startswith("compile_required"):
                pending = last["error"]
            else:
                res = last.get("result")
                if isinstance(res, dict):
                    for v in res.get("violations", []):
                        if str(v.get("detail", "")).startswith("compile_required"):
                            pending = v["detail"]
            if pending is None:
                break
            print("  [receipt round trip]", pending[:90])
            parts = pending.split()
            path, sha = parts[1], parts[2]
            moon = subprocess.run(
                ["moon", "check", "--deny-warn", "--target-dir", ".corridor/compiler", path],
                cwd=self.root, capture_output=True, text=True)
            assert moon.returncode == 0, f"moon check failed: {moon.stderr[:300]}"
            self.receipts[path] = sha
            request["receipts"] = [{"path": p, "sha256": s, "ok": True} for p, s in sorted(self.receipts.items())]
            self.compile_round_trips += 1
            responses = run_batch(MODULE, self.root, self.requests, self.work)
            last = responses[-1]
        if error:
            assert not last.get("ok") and error in last.get("error", ""), last
            return last
        assert last.get("ok"), last
        return last["result"]


def check(name):
    CHECKS.append(name)
    print("  ok:", name)


def main():
    assert MODULE.exists(), f"module missing; run: moon build --target wasm wasipure ({MODULE})"
    with tempfile.TemporaryDirectory(prefix="memorycorridor-wasipure-") as work:
        root = Path(work) / "vault"
        s = PureSession(root, Path(work))
        # Empty vault invariants; the init receipt round trip happens here.
        s.call("init", purpose="wasipure 直跑")
        assert s.compile_round_trips >= 1
        s.call("search", query="空库")
        assert s.call("status")["index_cache"] == "valid"
        lint = s.call("lint")
        assert lint["status"] == "clean" and lint["errors"] == 0, f"lint={json.dumps(lint, ensure_ascii=False)[:600]}"
        s.call("init", error="vault_already_initialized")
        check("init through the compile_required receipt protocol; empty-vault invariants")

        # A forged receipt (path matches, sha256 does not) must be rejected:
        # wasi_check recomputes sha256 from the CURRENT bytes; lint surfaces
        # the refusal as an ok:true response with a catalog_compile violation.
        forged = s.call("lint", auto_receipt=False, receipts=[
            {"path": "index.mbt.md", "sha256": "0" * 64, "ok": True}])
        details = [v.get("detail", "") for v in forged.get("violations", [])]
        assert any(d.startswith("compile_required: index.mbt.md") for d in details), forged
        check("forged receipt rejected: sha256 recomputed from current bytes")

        # An ok:false receipt (a failed moon check) must not pass verification:
        # resend with the REAL sha256 but ok:false and expect the refusal to
        # persist (compile_required embedded in lint violations).
        lint0 = s.call("lint", auto_receipt=False, receipts=[])
        details0 = [v.get("detail", "") for v in lint0.get("violations", [])]
        assert any(d.startswith("compile_required: index.mbt.md") for d in details0), lint0
        sha = details0[0].split()[2]
        refused = s.call("lint", auto_receipt=False, receipts=[
            {"path": "index.mbt.md", "sha256": sha, "ok": False}])
        refused_details = [v.get("detail", "") for v in refused.get("violations", [])]
        assert any(d.startswith("moon_check_failed") for d in refused_details), refused
        check("ok:false receipt fails compile verification")

        # Intake loop across stateless batches (idempotent replay per batch).
        (root / "raw/甲.md").write_text("# 光合作用\n叶绿体转换光能。\n", encoding="utf-8")
        (root / "raw/乙.txt").write_text("共享能源研究：保存来源证据。\n", encoding="utf-8")
        assert len(s.call("scan")["orders"]) == 2
        planned = {o["source"]: o["id"] for o in s.call("plan")}
        first, second = planned["raw/甲.md"], planned["raw/乙.txt"]
        print("  [tree before context]:", sorted(str(q.relative_to(root)) for q in root.rglob("*")))
        s.call("context", order=first)
        s.call("analysis-submit", order=first, analysis={
            "entities": [], "concepts": ["能量"], "conflicts": [], "summary": "资料分析"})
        staged = root / "staging" / first
        staged.mkdir(parents=True, exist_ok=True)
        (staged / "0.md").write_text(
            "---\ntype: concept\ntitle: 光合作用能量\nsources: [\"raw/甲.md\"]\n---\n叶绿体通过光合作用转换能量。\n",
            encoding="utf-8")
        s.call("commit", order=first, at="2026-10-31", pages=[
            {"id": "concepts/能量", "path": "wiki/concepts/能量.md", "staged": f"staging/{first}/0.md"}])
        s.call("context", order=second)
        s.call("analysis-submit", order=second, analysis={
            "entities": [], "concepts": ["共享"], "conflicts": [], "summary": "资料分析"})
        staged = root / "staging" / second
        staged.mkdir(parents=True, exist_ok=True)
        (staged / "0.md").write_text(
            "---\ntype: concept\ntitle: 共享能源\nsources: [\"raw/甲.md\", \"raw/乙.txt\"]\n---\n跨资料的共享能源知识。[[concepts/能量]]\n",
            encoding="utf-8")
        s.call("commit", order=second, at="2026-10-31", pages=[
            {"id": "concepts/共享", "path": "wiki/concepts/共享.md", "staged": f"staging/{second}/0.md"}])
        assert len(s.call("list-pages")) == 4
        assert s.call("search", query="光合作用")["hits"][0]["id"] == "concepts/能量"
        s.call("check-index")
        s.call("verify")
        check("work-order intake across stateless batch replays with lease locks")

        # Agent face through WASI storage.
        s.call("memory-submit", kind="preference", scope="workspace",
               text="优先安排光合作用实验", conditions=["规划实验时"], sources=["raw/甲.md"],
               at="2026-10-31T09:00:00Z", key="photosynthesis-preference")
        assert s.call("memory-list")["notes"][0]["valid"] is True
        assert isinstance(s.call("inbox")["items"], list)
        check("memory layer and inbox through the pure-WASI dispatch")

        # External drift refusal and restore.
        page = root / "wiki/concepts/能量.md"
        original = page.read_text(encoding="utf-8")
        page.write_text(original + "外部追加的句子。\n", encoding="utf-8")
        s.call("status", error="content_changed")
        page.write_text(original, encoding="utf-8")
        s.call("rebuild")
        s.call("verify")
        check("external page drift refused; rebuild after restore clears it")

        # 大容器：二进制原件入 vault → pack 确定性双跑字节一致 → 宿主复制
        # 到空 vault 的 imports/ → unpack 恢复 → 检索/读源 parity。二进制
        # 字节经 read_bytes/write_bytes 走满 16 MiB 通道。
        (root / "raw/小图.png").write_bytes(bytes([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 250]))
        s.call("scan")
        s.call("verify")
        packed = s.call("pack", output="exports/快照.mcpack")
        pack_a = (root / "exports" / "快照.mcpack").read_bytes()
        assert len(pack_a) > 0
        # 同批重放：pack 确定性 → 字节一致
        # pack 拒绝覆盖已有导出；确定性重放须改输出名让 pack 真实重跑
        replay_reqs = []
        for r in s.requests:
            r = dict(r)
            if r.get("op") == "pack":
                r["output"] = "exports/快照-replay.mcpack"
            replay_reqs.append(r)
        replay = run_batch(MODULE, root, replay_reqs, Path(work))
        pack_b = (root / "exports" / "快照-replay.mcpack").read_bytes()
        assert pack_a == pack_b, "pack must be byte-deterministic"

        vault_b = Path(work) / "vault-b"
        (vault_b / "imports").mkdir(parents=True)
        (vault_b / "imports" / "快照.mcpack").write_bytes(pack_a)
        b = PureSession(vault_b, Path(work))
        b.call("unpack", file="imports/快照.mcpack")
        b.call("rebuild")
        hits = b.call("search", query="光合作用")["hits"]
        assert hits and hits[0]["id"] == "concepts/能量"
        src_a = s.call("read-source", id="raw/小图.png")
        src_b = b.call("read-source", id="raw/小图.png")
        assert src_a["registered_sha256"] == src_b["registered_sha256"]
        assert src_a["bytes"] == src_b["bytes"] and src_a["bytes"] == 12
        check("pack deterministic + unpack parity across vaults through the 16 MiB byte channel")
        # 租约锁并发接管：A 进程 session-open 持锁（.corridor-lock 含到期
        # 时刻）；B 进程同库 session-open 拒绝 vault_locked；把锁文件改写为
        # 已过期租约后 B 接管成功；锁文件内容不可解析（未知持有人）时仍拒绝。
        lock_root = Path(work) / "vault-lock"
        holder = PureSession(lock_root, Path(work))
        holder.call("session-open")
        assert (lock_root / ".corridor-lock").exists()
        rival = PureSession(lock_root, Path(work))
        locked = rival.call("session-open", error="vault_locked")
        assert "vault_locked" in locked["error"]
        # 未知持有人（不可解析内容）不可抢占
        (lock_root / ".corridor-lock").write_text("garbage-holder", encoding="utf-8")
        rival.call("session-open", error="vault_locked")
        # 未过期但可解析的租约同样不可抢占
        (lock_root / ".corridor-lock").write_text('{"lease_until_ns": 9999999999999999999}', encoding="utf-8")
        rival.call("session-open", error="vault_locked")
        # 过期租约 → 接管成功，且新租约到期时刻更晚（崩溃恢复语义）
        (lock_root / ".corridor-lock").write_text('{"lease_until_ns": 1}', encoding="utf-8")
        takeover = run_batch(MODULE, lock_root, [
            {"op": "session-open", "vault": str(lock_root)}], Path(work))
        assert takeover[-1]["ok"], takeover[-1]
        token = json.loads((lock_root / ".corridor-lock").read_text(encoding="utf-8"))
        assert token["lease_until_ns"] > 1
        # 再次过期 → 新进程接管并在同一批内 open→close 正常释放
        (lock_root / ".corridor-lock").write_text('{"lease_until_ns": 1}', encoding="utf-8")
        release = run_batch(MODULE, lock_root, [
            {"op": "session-open", "vault": str(lock_root)},
            {"op": "session-close", "vault": str(lock_root)},
        ], Path(work))
        assert release[-1]["ok"], release[-1]
        assert not (lock_root / ".corridor-lock").exists()
        check("lease lock: rival refused while held, unknown/unexpired holder not preemptible, expired lease taken over, release clears the lockfile")

        # --mcp 纯 WASI JSON-RPC 信封面：同一 _start、同一 service_run。
        # 握手门（initialize 前 tools/* 拒绝）、通知静默（由行序证明）、
        # 进度令牌（started/completed 通知夹回复行）、回执回合（纯 WASI 面
        # 无进程内编译器，init 报 compile_required 后宿主代跑 moon check、
        # 经 tools/call arguments 携 receipts 重发）。
        mcp_root = Path(work) / "vault-mcp"
        mcp_requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2024-11-05", "capabilities": {},
                "clientInfo": {"name": "e2e"}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {
                "name": "corridor_init",
                "arguments": {"vault": str(mcp_root), "purpose": "纯 WASI MCP"}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {
                "name": "corridor_status", "arguments": {"vault": str(mcp_root)},
                "_meta": {"progressToken": "t9"}}},
        ]
        mcp_lines = run_mcp_batch(MODULE, mcp_root, mcp_requests, Path(work))
        assert mcp_lines[0]["result"]["protocolVersion"] == "2024-11-05"
        assert mcp_lines[1]["error"]["data"]["error_code"] == "initialization_required"
        # 通知静默：第三行必须是 id=3 的 tools/list 回复
        assert mcp_lines[2]["id"] == 3 and len(mcp_lines[2]["result"]["tools"]) == 93
        init_reply = mcp_lines[3]
        assert init_reply["result"]["isError"] is True
        fault = init_reply["result"]["structuredContent"]["result"]["error"]
        assert fault.startswith("compile_required: "), fault
        parts = fault.split()
        moon = subprocess.run(
            ["moon", "check", "--deny-warn", "--target-dir", ".corridor/compiler", parts[1]],
            cwd=mcp_root, capture_output=True, text=True)
        assert moon.returncode == 0, f"moon check failed: {moon.stderr[:300]}"
        mcp_requests[4]["params"]["arguments"]["receipts"] = [
            {"path": parts[1], "sha256": parts[2], "ok": True}]
        mcp_lines = run_mcp_batch(MODULE, mcp_root, mcp_requests, Path(work))
        assert mcp_lines[3]["result"]["isError"] is False, mcp_lines[3]
        # 进度令牌：started/completed 两行通知夹着 status 回复行
        assert mcp_lines[4]["method"] == "notifications/progress"
        assert mcp_lines[4]["params"]["progress"] == 0
        assert mcp_lines[5]["method"] == "notifications/progress"
        assert mcp_lines[5]["params"]["progress"] == 1
        assert mcp_lines[6]["id"] == 5
        assert mcp_lines[6]["result"]["isError"] is False
        # 纯 WASI 面无进程内编译器：index_cache 保持 missing_or_invalid，
        # 但 dispatch 结果必须真实（fingerprint 由回执验证过的候选产出）。
        assert mcp_lines[6]["result"]["structuredContent"]["result"]["fingerprint"]
        assert len(mcp_lines) == 7, mcp_lines
        check("pure-WASI --mcp face: handshake gate, silent notifications, receipt round trip, progress notices")
    print("wasipure direct-run e2e: boundary scenarios passed")


if __name__ == "__main__":
    ensure_wasmtime()
    main()
