#!/usr/bin/env python3
"""Contract and reference-flow test for the host-side `adapters/os-embed/os-embed --probe` verdict.

This is deliberately not a shipped host: hosts/ contains no probe consumer. It
(1) validates the versioned verdict with a stub adapter, (2) proves that an
unavailable or failed probe leaves the vault byte-identical and that the engine
still reports the algorithm lane, and (3) on macOS with a built adapter uses the
production one-item batch as the oracle for each language's probe verdict.

The engine never calls the adapter and never reads a probe: detection and the
provider registration are host-side only.

Run:
  python3 -I scripts/os_embed_probe_e2e.py
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"
OS_EMBED = Path(os.environ.get("OS_EMBED_BIN", REPO / "adapters/os-embed/os-embed"))
PROBE_VERSION = "os-embed/v1"
REASONS = {"engine_absent", "dimension_mismatch", "platform_unsupported"}
DECLARED = {"zh": 640, "en": 512}


def validate_verdict(value):
    """Validate only the schema-validated class; engine/platform/os_version are
    informational and intentionally not checked."""
    assert isinstance(value, dict), value
    assert value.get("probe") == PROBE_VERSION, value
    available = value.get("available")
    assert isinstance(available, bool), value
    reason = value.get("reason")
    assert reason is None or isinstance(reason, str), value
    if reason is not None:
        assert reason in REASONS, value
    languages = value.get("languages")
    assert isinstance(languages, list) and languages, value
    for row in languages:
        assert isinstance(row, dict), row
        assert isinstance(row.get("language"), str) and row["language"], row
        assert isinstance(row.get("available"), bool), row
        row_reason = row.get("reason")
        assert row_reason is None or isinstance(row_reason, str), row
        if row_reason is not None:
            assert row_reason in REASONS, row
        assert row["available"] == (row_reason is None), row
        dimensions = row.get("dimensions")
        if row["available"]:
            assert isinstance(dimensions, int) and not isinstance(dimensions, bool), row
            assert dimensions > 0, row
        else:
            assert dimensions is None, row
    assert available == any(row["available"] for row in languages), value
    assert (reason is None) == available, value
    if not available:
        first_unusable = next(row for row in languages if not row["available"])
        assert reason == first_unusable["reason"], value
    return value


def run_probe(binary):
    """Reference host probe step. Returns (verdict_or_None, argv)."""
    argv = [str(binary), "--probe"]
    completed = subprocess.run(
        argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
    if completed.returncode != 0:
        return None, argv
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None, argv
    return validate_verdict(value), argv


def write_stub(directory, name, body):
    path = Path(directory) / name
    path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def snapshot(vault):
    return {
        path.relative_to(vault).as_posix(): path.read_bytes()
        for path in sorted(vault.rglob("*"))
        if path.is_file()
    }


def static_guards():
    source = (REPO / "adapters/os-embed/main.swift").read_text(encoding="utf-8")
    for token in ("os-embed/v1", "engine_absent", "dimension_mismatch"):
        assert token in source, token
    imports = [line.strip() for line in source.splitlines() if line.startswith("import ")]
    assert imports == ["import Foundation", "import NaturalLanguage"], imports
    for gate in (REPO / "scripts/verify.sh", REPO / "scripts/quick_verify.sh"):
        text = gate.read_text(encoding="utf-8")
        for token in ("fetch_bge", "fetch_clip", "build_os_embed"):
            assert token not in text, (gate.name, token)


def oracle(language):
    """Production one-item batch: the oracle for the probe's per-language verdict."""
    text = "龙泉窑青瓷釉色" if language == "zh" else "Longquan celadon glaze"
    completed = subprocess.run(
        [str(OS_EMBED), "--language", language],
        input=json.dumps([{"page": "q", "sha256": "0", "text": text}]),
        capture_output=True, text=True, timeout=120)
    if completed.returncode != 0:
        return False, None
    try:
        rows = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return False, None
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        return False, None
    values = rows[0].get("values")
    if not isinstance(values, list):
        return False, None
    return len(values) == DECLARED[language], len(values)


def live_branch():
    if sys.platform != "darwin":
        print(f"SKIP live oracle: probe targets macOS (platform is {sys.platform})")
        return
    if not OS_EMBED.is_file():
        print("SKIP live oracle: adapter not built (run scripts/build_os_embed.sh)")
        return
    verdict, _ = run_probe(OS_EMBED)
    if verdict is None:
        raise AssertionError(
            "adapter exists but --probe produced no os-embed/v1 verdict "
            "(stale build? run scripts/build_os_embed.sh)")
    rows = {row["language"]: row for row in verdict["languages"]}
    assert [row["language"] for row in verdict["languages"]] == ["zh", "en"], verdict
    for language in ("zh", "en"):
        row = rows[language]
        ok, length = oracle(language)
        assert row["available"] == ok, (language, row, ok)
        if row["available"]:
            assert row["dimensions"] == DECLARED[language], row
            assert length == DECLARED[language], (language, length)
    assert verdict["available"] == any(row["available"] for row in verdict["languages"])
    print(f"os embed probe e2e: live oracle passed "
          f"(zh={rows['zh']['available']}, en={rows['en']['available']})")


def main():
    if not CLI.is_file():
        print("SKIP os_embed_probe_e2e: build the CLI first (moon build --target native cli); "
              "the contract assertions did not run")
        return 0
    static_guards()
    with tempfile.TemporaryDirectory(prefix="corridor-os-probe-") as work:
        root = Path(work)
        vault = root / "vault"
        vault.mkdir()

        def call(op, error=None, **fields):
            completed = subprocess.run(
                [str(CLI)], input=json.dumps({"op": op, "vault": str(vault), **fields}) + "\n",
                capture_output=True, text=True, check=True, timeout=120)
            value = json.loads(completed.stdout)
            if error:
                assert not value["ok"] and error in value["error"], value
                return value
            assert value["ok"], value
            return value["result"]

        call("init", purpose="系统向量探针契约")
        (vault / "raw").mkdir(exist_ok=True)
        (vault / "raw/x.md").write_text("龙泉窑青瓷釉色记录。\n", encoding="utf-8")
        call("scan")
        order = call("plan")[0]["id"]
        call("context", order=order)
        call("analysis-submit", order=order,
             analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "系统向量探针"})
        pages = []
        for index, (page_id, body) in enumerate([
                ("concepts/a", "龙泉窑的青瓷以粉青和梅子青两种釉色最为著名"),
                ("concepts/b", "梅子青与粉青是龙泉窑青瓷最具代表性的釉色")]):
            staged = vault / f"staging/{order}/{index}.md"
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(
                f'---\ntype: concept\ntitle: t{index}\nsources: ["raw/x.md"]\n---\n'
                + body + "\n", encoding="utf-8")
            pages.append({"id": page_id, "path": f"wiki/{page_id}.md",
                          "staged": f"staging/{order}/{index}.md"})
        call("commit", order=order, pages=pages, at="2026-11-26T00:00:00Z")
        call("rebuild")

        fixtures = {
            "probe": PROBE_VERSION,
            "available": False,
            "reason": "engine_absent",
            "languages": [
                {"language": "zh", "available": False, "dimensions": None,
                 "reason": "engine_absent"},
                {"language": "en", "available": False, "dimensions": None,
                 "reason": "engine_absent"},
            ],
            "engine": "stub",
            "platform": "fixture-os",
            "os_version": "1.0",
        }
        unavailable = write_stub(
            root, "probe-unavailable", "cat <<'EOF'\n" + json.dumps(fixtures) + "\nEOF\n")
        failing = write_stub(root, "probe-fails", "echo probe_failed >&2\nexit 2\n")

        def assert_no_writes(label):
            providers = vault / "state/providers"
            assert not providers.exists() or not list(providers.glob("*.json")), label
            assert not list((vault / "state/events").glob("provider-register-*.json")), label
            assert not list((vault / "vectors").glob("*.json")), label
            assert not (vault / "state/transactions/pending.json").exists(), label

        def assert_lanes(label):
            fallback = call("retrieve", query="龙泉窑青瓷釉色", limit=5)["lanes"]
            assert fallback["vector"] == "algo", (label, fallback)
            assert fallback["reason"] == "no_system_engine", (label, fallback)
            status = call("search", query="龙泉窑青瓷釉色")
            assert status["vector_status"] == "not_provided", (label, status)

        fingerprints = call("fingerprints")
        before = snapshot(vault)
        verdict, argv = run_probe(unavailable)
        assert verdict is not None and verdict["available"] is False
        assert verdict["reason"] == "engine_absent", verdict
        assert all(str(vault) not in argument for argument in argv), argv
        assert snapshot(vault) == before
        assert call("fingerprints") == fingerprints
        assert_no_writes("unavailable stub")
        assert_lanes("unavailable stub")

        before = snapshot(vault)
        verdict, argv = run_probe(failing)
        assert verdict is None
        assert all(str(vault) not in argument for argument in argv), argv
        assert snapshot(vault) == before
        assert call("fingerprints") == fingerprints
        assert_no_writes("exit-2 stub")
        assert_lanes("exit-2 stub")

    live_branch()
    print("os embed probe e2e: contract, unavailable reference flow and static guards passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
