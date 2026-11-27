#!/usr/bin/env python3
"""End-to-end checks for scripts/vector_engine.py on this host.

Contract branch (any platform with a built CLI): unavailable, stale and
malformed adapters produce deterministic JSON, exit 0, and leave the vault
byte-identical; query-text never synthesizes values.

Live branch (macOS with the built NLEmbedding adapter): probe/ensure/
query-text/register agree with the production adapter, registration writes a
provider only when the probe is available, and ensure really rebuilds the
canonical adapter from the checked-in Swift source when it is absent.

No model is downloaded here: the only build path is the existing
scripts/build_os_embed.sh, which compiles the checked-in Swift source.

Run:
  python3 -I scripts/vector_engine_e2e.py
"""
import json
import math
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
ENGINE = REPO / "scripts/vector_engine.py"
DEFAULT_OS_EMBED = REPO / "adapters/os-embed/os-embed"
OS_EMBED = Path(os.environ.get("OS_EMBED_BIN", DEFAULT_OS_EMBED))
PROBE_KEYS = {"available", "engine", "language", "dimensions", "reason"}


def run_engine(*args):
    return subprocess.run(
        [sys.executable, "-I", str(ENGINE), *args],
        capture_output=True, text=True, timeout=120)


def engine_json(*args, exit_code=0):
    completed = run_engine(*args)
    assert completed.returncode == exit_code, (args, completed.returncode,
                                               completed.stdout, completed.stderr)
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError((args, completed.stdout, completed.stderr)) from error


def write_stub(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def snapshot(vault):
    return {
        path.relative_to(vault).as_posix(): path.read_bytes()
        for path in sorted(vault.rglob("*"))
        if path.is_file()
    }


def static_guards():
    # Split the tokens so this guard's own source does not look like a fetch.
    forbidden = ("ur" + "llib", "req" + "uests", "http" + "://", "https" + "://",
                 "fetch_" + "bge", "fetch_" + "clip", "cu" + "rl", "wg" + "et")
    texts = {
        "vector_engine.py": ENGINE.read_text(encoding="utf-8"),
        "vector_engine_e2e.py": Path(__file__).read_text(encoding="utf-8"),
    }
    for name, text in texts.items():
        for token in forbidden:
            assert token not in text, (name, token)
    assert "build_os_embed.sh" in texts["vector_engine.py"]
    assert "os-embed/v1" in texts["vector_engine.py"]
    for gate in ("verify.sh", "quick_verify.sh"):
        text = (REPO / "scripts" / gate).read_text(encoding="utf-8")
        for token in ("fetch_" + "bge", "fetch_" + "clip"):
            assert token not in text, (gate, token)


def contract_branch(work):
    stub = write_stub(work, "unavailable", """cat <<'EOF'
{"probe":"os-embed/v1","available":false,"reason":"engine_absent","languages":[{"language":"zh","available":false,"dimensions":null,"reason":"engine_absent"},{"language":"en","available":false,"dimensions":null,"reason":"engine_absent"}],"engine":"stub","platform":"fixture-os","os_version":"1.0"}
EOF
""")
    failing = write_stub(work, "failing", "echo probe_failed >&2\nexit 2\n")
    malformed = write_stub(work, "malformed", "echo not-json\n")
    wrong = write_stub(
        work, "wrong-version",
        "echo '{\"probe\":\"os-embed/v0\",\"available\":false,\"reason\":\"engine_absent\",\"languages\":[]}'\n")

    value = engine_json("probe", "--bin", str(stub))
    assert set(value) == PROBE_KEYS, value
    assert value["available"] is False and value["dimensions"] is None, value
    assert value["reason"] == "engine_absent" and value["language"] == "zh", value

    value = engine_json("probe", "--bin", str(failing))
    assert set(value) == PROBE_KEYS and value["reason"] == "probe_failed", value

    value = engine_json("probe", "--bin", str(malformed))
    assert set(value) == PROBE_KEYS and value["reason"] == "probe_invalid", value

    value = engine_json("probe", "--bin", str(wrong))
    assert set(value) == PROBE_KEYS and value["reason"] == "probe_invalid", value

    value = engine_json("ensure", "--bin", str(stub), "--no-build")
    assert value["available"] is False and value["reason"] == "engine_absent", value

    value = engine_json("query-text", "--bin", str(stub), "--text", "龙泉窑")
    assert set(value) == {"available", "reason"}, value
    assert value["available"] is False and "values" not in value, value

    with tempfile.TemporaryDirectory(prefix="corridor-vector-contract-") as directory:
        vault = Path(directory) / "vault"
        vault.mkdir()

        def call(op, **fields):
            completed = subprocess.run(
                [str(CLI)], input=json.dumps({"op": op, "vault": str(vault), **fields}) + "\n",
                capture_output=True, text=True, check=True, timeout=120)
            response = json.loads(completed.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="向量引擎契约")
        before = snapshot(vault)
        value = engine_json("register", "--bin", str(stub), "--vault", str(vault),
                            "--provider", "os-nl", "--at", "2026-11-26T00:00:00Z")
        assert value["available"] is False and value["registered"] is False, value
        assert "space" not in value, value
        assert snapshot(vault) == before
        assert call("provider-list") == []
        assert not list((vault / "state/events").glob("provider-register-*.json"))

        value = engine_json("register", "--bin", str(failing), "--vault", str(vault),
                            "--provider", "os-nl", "--at", "2026-11-26T00:00:01Z")
        assert value["available"] is False and value["registered"] is False, value
        assert snapshot(vault) == before
        assert call("provider-list") == []


def live_ensure_build():
    """Remove the canonical binary and prove ensure rebuilds it from source."""
    if OS_EMBED.resolve() != DEFAULT_OS_EMBED.resolve():
        print("SKIP vector engine live ensure build: "
              "OS_EMBED_BIN points at a custom adapter")
        return
    with tempfile.TemporaryDirectory(prefix="corridor-vector-adapter-") as directory:
        backup = Path(directory) / "os-embed"
        shutil.copy2(OS_EMBED, backup)
        OS_EMBED.unlink()
        try:
            value = engine_json("ensure")
            assert value["available"] is True, value
            assert value["dimensions"] == 640, value
            assert OS_EMBED.is_file(), "ensure did not produce the adapter"
            print("vector engine e2e: ensure rebuilt the canonical adapter from source")
        finally:
            # Restore the original even if the rebuild failed, so a bad build
            # never changes what later checks (or the next gate run) execute.
            shutil.copy2(backup, OS_EMBED)


def live_branch():
    if sys.platform != "darwin":
        print(f"SKIP vector engine live branch: probe targets macOS (platform is {sys.platform})")
        return
    if not OS_EMBED.is_file():
        print("SKIP vector engine live branch: adapter not built (run scripts/build_os_embed.sh)")
        return
    value = engine_json("probe")
    assert set(value) == PROBE_KEYS, value
    if value["reason"] in {"probe_failed", "probe_invalid", "probe_version_mismatch"}:
        raise AssertionError(
            f"adapter exists but probe is stale/broken ({value['reason']}); "
            "run scripts/build_os_embed.sh")
    if not value["available"]:
        print(f"SKIP vector engine live branch: probe reports {value['reason']}")
        return
    assert value["dimensions"] == 640, value
    assert engine_json("probe", "--language", "en")["dimensions"] == 512

    value = engine_json("query-text", "--text", "龙泉窑青瓷釉色")
    assert set(value) == {"available", "space", "values"}, value
    assert value["space"] == {"id": "os-nl-zh-v1", "dimensions": 640}, value
    assert len(value["values"]) == 640, len(value["values"])
    assert all(isinstance(item, (int, float)) and not isinstance(item, bool)
               and math.isfinite(item) for item in value["values"])
    value = engine_json("query-text", "--language", "en", "--text", "Longquan celadon glaze")
    assert value["space"] == {"id": "os-nl-en-v1", "dimensions": 512}, value
    assert len(value["values"]) == 512, len(value["values"])

    with tempfile.TemporaryDirectory(prefix="corridor-vector-live-") as directory:
        vault = Path(directory) / "vault"
        vault.mkdir()

        def call(op, **fields):
            completed = subprocess.run(
                [str(CLI)], input=json.dumps({"op": op, "vault": str(vault), **fields}) + "\n",
                capture_output=True, text=True, check=True, timeout=120)
            response = json.loads(completed.stdout)
            assert response["ok"], response
            return response["result"]

        call("init", purpose="向量引擎实测")
        before = snapshot(vault)
        value = engine_json("register", "--vault", str(vault), "--provider", "os-nl",
                            "--at", "2026-11-26T00:00:00Z")
        assert value["available"] is True and value["registered"] is True, value
        assert value["space"] == {"id": "os-nl-zh-v1", "dimensions": 640}, value
        assert snapshot(vault) != before
        providers = call("provider-list")
        assert len(providers) == 1, providers
        assert providers[0]["provider"] == "os-nl", providers
        assert providers[0]["kind"] == "embedding", providers
        assert providers[0]["space"] == {"id": "os-nl-zh-v1", "dimensions": 640}, providers
        assert providers[0]["capabilities"] == ["embed"], providers
    live_ensure_build()
    print("vector engine e2e: live probe, ensure, query-text and register passed")


def main():
    if not CLI.is_file():
        print("SKIP vector_engine_e2e: build the CLI first "
              "(moon build --target native cli); the contract assertions did not run")
        return 0
    static_guards()
    with tempfile.TemporaryDirectory(prefix="corridor-vector-e2e-") as work:
        contract_branch(Path(work))
    live_branch()
    print("vector engine e2e: unavailable contract and no-write registration passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
