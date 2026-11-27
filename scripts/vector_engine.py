#!/usr/bin/env python3
"""Host-side vector-engine helper for the optional OS sentence embedding model.

The MoonBit engine never calls a model, a network or an OS framework. This
script is the host seam in front of `adapters/os-embed/os-embed`:

  probe       report {available, engine, language, dimensions, reason}
  ensure      optionally compile the existing Swift adapter (no downloads)
  query-text  return {available, space, values} or available:false with no values
  register    call provider-register only when the probe is available

`probe`, `ensure` and `query-text` never write a vault. `register` is the only
action that writes, and an unavailable verdict never reaches the CLI, so the
vault stays byte-identical. Exit 0 means the action produced JSON: unavailable
is a successful detection, not an error, and a missing/bad adapter or a failed
build is reported in that JSON (`adapter_missing`/`probe_failed`/`build_failed`).
Exit 2 means the helper itself could not produce JSON: invalid usage or a
provider-register CLI failure.

Run:
  python3 -I scripts/vector_engine.py probe
  python3 -I scripts/vector_engine.py ensure
  python3 -I scripts/vector_engine.py query-text --text "..."
  python3 -I scripts/vector_engine.py register --vault /vault --provider os-nl \
      --at 2026-11-26T00:00:00Z
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
DEFAULT_BIN = REPO / "adapters/os-embed/os-embed"
DEFAULT_CLI = REPO / "_build/native/debug/build/cli/cli.exe"
PROBE_VERSION = "os-embed/v1"
REASONS = {"engine_absent", "dimension_mismatch", "platform_unsupported"}


def default_space_id(language):
    return f"os-nl-{language}-v1"


def emit(value):
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


def valid_verdict(value):
    """Accept only the versioned shape and its invariants."""
    if not isinstance(value, dict) or value.get("probe") != PROBE_VERSION:
        return False
    available = value.get("available")
    reason = value.get("reason")
    if not isinstance(available, bool) or not (reason is None or isinstance(reason, str)):
        return False
    if reason is not None and reason not in REASONS:
        return False
    languages = value.get("languages")
    if not isinstance(languages, list) or not languages:
        return False
    for row in languages:
        if not isinstance(row, dict):
            return False
        if not isinstance(row.get("language"), str) or not row["language"]:
            return False
        if not isinstance(row.get("available"), bool):
            return False
        row_reason = row.get("reason")
        if not (row_reason is None or isinstance(row_reason, str)):
            return False
        if row_reason is not None and row_reason not in REASONS:
            return False
        if row["available"] != (row_reason is None):
            return False
        dimensions = row.get("dimensions")
        if row["available"]:
            if not isinstance(dimensions, int) or isinstance(dimensions, bool) or dimensions <= 0:
                return False
        elif dimensions is not None:
            return False
    if available != any(row["available"] for row in languages):
        return False
    if (reason is None) != available:
        return False
    if not available:
        first_unusable = next(row for row in languages if not row["available"])
        if reason != first_unusable["reason"]:
            return False
    return True


def read_verdict(binary):
    """Return (verdict, failure_reason); failure_reason is a helper-local reason."""
    binary = Path(binary)
    if not binary.is_file():
        return None, "adapter_missing"
    try:
        completed = subprocess.run(
            [str(binary), "--probe"], stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None, "adapter_unavailable"
    if completed.returncode != 0:
        return None, "probe_failed"
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return None, "probe_invalid"
    if not valid_verdict(value):
        return None, "probe_invalid"
    return value, None


def verdict_for(binary, language):
    value, failure = read_verdict(binary)
    if failure is not None:
        return {"available": False, "engine": "os-embed", "language": language,
                "dimensions": None, "reason": failure}
    row = next((item for item in value["languages"] if item["language"] == language), None)
    if row is None:
        return {"available": False, "engine": "os-embed", "language": language,
                "dimensions": None, "reason": "language_missing"}
    engine = value.get("engine")
    if not isinstance(engine, str) or not engine:
        engine = "os-embed"
    if not row["available"]:
        return {"available": False, "engine": engine, "language": language,
                "dimensions": None, "reason": row["reason"]}
    return {"available": True, "engine": engine, "language": language,
            "dimensions": row["dimensions"], "reason": None}


def build_adapter():
    completed = subprocess.run(
        ["sh", str(REPO / "scripts/build_os_embed.sh")], cwd=REPO,
        capture_output=True, text=True, timeout=600)
    return completed.returncode == 0


def action_probe(args):
    return emit(verdict_for(args.bin, args.language))


def action_ensure(args):
    verdict = verdict_for(args.bin, args.language)
    if verdict["available"]:
        return emit(verdict)
    rebuildable = verdict["reason"] in {
        "adapter_missing", "adapter_unavailable", "probe_failed",
        "probe_invalid", "probe_version_mismatch"}
    # build_os_embed.sh writes the checked-in adapter's canonical path; a custom
    # --bin is the host's own binary and is never overwritten by this helper.
    custom = Path(args.bin).resolve() != DEFAULT_BIN.resolve()
    if sys.platform != "darwin" or args.no_build or custom or not rebuildable:
        return emit(verdict)
    if not build_adapter():
        verdict["reason"] = "build_failed"
        return emit(verdict)
    return emit(verdict_for(args.bin, args.language))


def action_query_text(args):
    verdict = verdict_for(args.bin, args.language)
    if not verdict["available"]:
        return emit({"available": False, "reason": verdict["reason"]})
    item = [{"page": "query", "sha256": "0", "text": args.text}]
    try:
        completed = subprocess.run(
            [str(args.bin), "--language", args.language],
            input=json.dumps(item, ensure_ascii=False), capture_output=True,
            text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return emit({"available": False, "reason": "batch_failed"})
    if completed.returncode != 0:
        return emit({"available": False, "reason": "batch_failed"})
    try:
        rows = json.loads(completed.stdout)
    except json.JSONDecodeError:
        return emit({"available": False, "reason": "batch_invalid"})
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        return emit({"available": False, "reason": "batch_invalid"})
    values = rows[0].get("values")
    if not isinstance(values, list) or len(values) != verdict["dimensions"]:
        return emit({"available": False, "reason": "dimension_mismatch"})
    if not all(isinstance(value, (int, float)) and not isinstance(value, bool)
               and math.isfinite(value) for value in values):
        return emit({"available": False, "reason": "batch_invalid"})
    space_id = args.space_id or default_space_id(args.language)
    return emit({"available": True,
                 "space": {"id": space_id, "dimensions": verdict["dimensions"]},
                 "values": values})


def action_register(args):
    verdict = verdict_for(args.bin, args.language)
    if not verdict["available"]:
        return emit({"available": False, "registered": False,
                     "reason": verdict["reason"]})
    space = {"id": args.space_id or default_space_id(args.language),
             "dimensions": verdict["dimensions"]}
    request = {"op": "provider-register", "vault": args.vault,
               "provider": args.provider, "kind": "embedding", "space": space,
               "capabilities": ["embed"], "at": args.at}
    try:
        completed = subprocess.run(
            [str(args.cli)], input=json.dumps(request, ensure_ascii=False) + "\n",
            capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        print("vector_engine register: CLI unavailable", file=sys.stderr)
        return 2
    try:
        response = json.loads(completed.stdout)
    except json.JSONDecodeError:
        print("vector_engine register: CLI returned no JSON", file=sys.stderr)
        return 2
    if completed.returncode != 0 or not response.get("ok"):
        print("vector_engine register: " + str(response.get("error")), file=sys.stderr)
        return 2
    return emit({"available": True, "registered": True, "provider": args.provider,
                 "space": space, "result": response.get("result")})


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action")

    def common(target):
        target.add_argument("--bin", default=os.environ.get("OS_EMBED_BIN", str(DEFAULT_BIN)))
        target.add_argument("--language", default="zh", choices=["zh", "en"])

    probe = sub.add_parser("probe")
    common(probe)

    ensure = sub.add_parser("ensure")
    common(ensure)
    ensure.add_argument("--no-build", action="store_true")

    query = sub.add_parser("query-text")
    common(query)
    query.add_argument("--text", required=True)
    query.add_argument("--space-id")

    register = sub.add_parser("register")
    common(register)
    register.add_argument("--vault", required=True)
    register.add_argument("--provider", required=True)
    register.add_argument("--space-id")
    register.add_argument("--at", required=True)
    register.add_argument("--cli", default=str(DEFAULT_CLI))

    args = parser.parse_args(argv)
    if args.action is None:
        parser.print_usage(sys.stderr)
        return 2
    actions = {"probe": action_probe, "ensure": action_ensure,
               "query-text": action_query_text, "register": action_register}
    return actions[args.action](args)


if __name__ == "__main__":
    sys.exit(main())
