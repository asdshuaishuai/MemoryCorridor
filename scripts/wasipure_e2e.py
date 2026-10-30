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
    print("wasipure direct-run e2e: boundary scenarios passed")


if __name__ == "__main__":
    ensure_wasmtime()
    main()
