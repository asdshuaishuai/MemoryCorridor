#!/bin/sh
# Tiered local gate: the full verify.sh (all e2e + mutation matrix + WASM/Web
# faces) is for release/nightly/CI. This script is the per-change gate.
set -eu
cd "$(dirname "$0")/.."
# Local machines may have an unpinned `moon` on PATH before the project's
# pinned toolchain. Prefer ~/.moon-pinned when present; CI has no such directory
# and falls back to the installed pinned `moon`.
MOON_BIN="${MOON_BIN:-}"
if [ -z "$MOON_BIN" ]; then
  if [ -x "$HOME/.moon-pinned/bin/moon" ]; then
    MOON_BIN="$HOME/.moon-pinned/bin/moon"
  else
    MOON_BIN="moon"
  fi
fi
"$MOON_BIN" check --target native --deny-warn
"$MOON_BIN" test --target native
"$MOON_BIN" build --target native cli mcp web
python3 scripts/e2e.py
python3 scripts/interop_e2e.py
python3 scripts/retrieval_e2e.py
python3 scripts/memory_e2e.py
python3 scripts/dream_e2e.py
python3 scripts/workspace_layer_e2e.py
python3 scripts/project_wiki_bench.py
