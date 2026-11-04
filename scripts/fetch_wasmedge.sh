#!/bin/sh
# Fetch the official WasmEdge runtime that corridor-wedge links against.
# The ~176 MB libwasmedge is an Apache-2.0 product of its own with its own
# distribution channel; like ONNX Runtime for OCR, it is pinned by checksum
# and NOT folded into the release tarball. After running this, build the
# embedded host with: WASMEDGE_PREFIX=<dest> sh scripts/build_wedge_host.sh
set -eu
VERSION=0.18.1
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)
    PKG="WasmEdge-$VERSION-darwin_arm64.tar.gz"
    SHA="32165a058abee03718f8fa3b7ffd64e5133443486f54a5b79221910fb1ae0628"
    ;;
  x86_64)
    PKG="WasmEdge-$VERSION-manylinux_2_28_x86_64.tar.gz"
    SHA="ec97ccfc172a1fbb2116e9dd00ca12d41f9f9ad3d7b1c89a63b8477703fa67c9"
    ;;
  *)
    echo "unsupported arch: $ARCH (this fetch pins darwin arm64 and linux x86_64 for WasmEdge $VERSION)" >&2
    exit 1
    ;;
esac
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/adapters/wasm-runtime}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$PKG" "https://github.com/WasmEdge/WasmEdge/releases/download/$VERSION/$PKG"
echo "$SHA  $TMP/$PKG" | shasum -a 256 -c -
mkdir -p "$DEST"
tar xzf "$TMP/$PKG" -C "$DEST"
echo "ok: WasmEdge $VERSION at $DEST (bin/ + lib/ or lib64/ + include/)"
