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
# macOS packages ship lib/; the manylinux release ships lib64/
LIBDIR="$PREFIX/lib"
[ -d "$LIBDIR" ] || LIBDIR="$PREFIX/lib64"
"$CXX" -std=c++17 -O2 -o "$OUT" "$ROOT/hosts/corridor-wedge.cpp" \
  -I"$PREFIX/include" -L"$LIBDIR" -lwasmedge \
  -Wl,-rpath,"$LIBDIR"
echo "ok: $OUT"
