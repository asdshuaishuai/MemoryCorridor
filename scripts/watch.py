#!/usr/bin/env python3
"""Thin file-change host; all adoption/validation remains in the MoonBit engine."""
import argparse
import hashlib
import json
from pathlib import Path
import select
import subprocess
import time

parser = argparse.ArgumentParser(description="Watch a vault and recheck changed content")
parser.add_argument("vault", type=Path)
parser.add_argument("--interval", type=float, default=0.5)
parser.add_argument("--once", action="store_true", help="perform one refresh and exit")
parser.add_argument("--view", help="compile a specific views/*.mbt.md source")
parser.add_argument("--cli", type=Path, help="path to the corridor CLI executable")
args = parser.parse_args()
if args.interval < 0.1:
    parser.error("--interval must be >=0.1 seconds")
default_view = "views/library.mbt.md"
view_name = args.view or default_view
view_path = Path(view_name)
if args.view is not None and (view_path.is_absolute() or "\\" in view_name or
                              view_path.parts[:1] != ("views",) or
                              not view_name.endswith(".mbt.md") or
                              any(part in ("", ".", "..") for part in view_path.parts)):
    parser.error("--view must be a vault-relative views/*.mbt.md path")
root = args.vault.resolve(strict=True)
selected_view = root / view_path
exe = (args.cli or (Path(__file__).resolve().parents[1] / "_build/native/debug/build/cli/cli.exe")).resolve(strict=True)
process = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)


def snapshot():
    files = [root / "index.mbt.md", root / "purpose.md"]
    for directory in ["raw", "wiki", "views"]:
        if (root / directory).exists():
            files.extend(p for p in (root / directory).rglob("*") if p.is_file()
                         and not (directory == "views" and "_build" in p.relative_to(root).parts))
    return {str(p): ("symlink" if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest())
            for p in files if p.exists()}


previous = None
try:
    while True:
        current = snapshot()
        if current != previous:
            process.stdin.write(json.dumps({"op": "refresh", "vault": str(root)}) + "\n")
            process.stdin.flush()
            if not select.select([process.stdout], [], [], 30)[0]:
                raise RuntimeError("engine response timed out; watcher stops without starting a second writer")
            response = process.stdout.readline()
            if not response:
                raise RuntimeError("engine exited")
            value = json.loads(response)
            # Compare against the inputs we actually sent. A post-response
            # snapshot could swallow an edit made during compilation.
            previous = current
            if value["ok"] and (args.view is not None or selected_view.is_file()):
                process.stdin.write(json.dumps({"op": "render-view", "vault": str(root), "view": view_name}) + "\n")
                process.stdin.flush()
                if not select.select([process.stdout], [], [], 30)[0]:
                    raise RuntimeError("view compiler timed out")
                visual_line = process.stdout.readline()
                if not visual_line:
                    raise RuntimeError("view compiler exited")
                visual = json.loads(visual_line)
                value["result"]["visual"] = visual
                if not visual.get("ok"):
                    # Keep the successful refresh details for diagnostics, but
                    # expose the visual compiler failure as the watch result.
                    value["ok"] = False
                    value["error"] = visual.get("error", "view_compile_failed")
                    if "error_code" in visual:
                        value["error_code"] = visual["error_code"]
                    if "hint" in visual:
                        value["hint"] = visual["hint"]
            print(json.dumps(value, ensure_ascii=False), flush=True)
            if args.once:
                raise SystemExit(0 if value["ok"] else 1)
        time.sleep(args.interval)
except KeyboardInterrupt:
    pass
finally:
    process.stdin.close()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=10)
