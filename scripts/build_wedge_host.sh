#!/bin/sh
# Build the embedded WasmEdge host (hosts/corridor-wedge.cpp) for the
# host-free wasipure service module. Needs WasmEdge >= 0.18 dev files.
# WASMEDGE_PREFIX=/path/to/unpacked/sdk (with include/ + lib/) or system-wide.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${WASMEDGE_PREFIX:-/usr/local}"
CXX="${CXX:-clang++}"
OUT="$ROOT/_build/wedge/corridor-wedge"
mkdir -p "$ROOT/_build/wedge"
"$CXX" -std=c++17 -O2 -o "$OUT" "$ROOT/hosts/corridor-wedge.cpp" \
  -I"$PREFIX/include" -L"$PREFIX/lib" -lwasmedge \
  -Wl,-rpath,"$PREFIX/lib"
echo "ok: $OUT"
