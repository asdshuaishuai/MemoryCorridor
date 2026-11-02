#!/bin/sh
# Fetch the official ONNX Runtime dylib used by adapters/ocr-rs (load-dynamic).
# The 43 MB Microsoft build is redistributed under MIT; it is NOT vendored in
# git (too heavy) - this script pins it by checksum instead. Models live in
# adapters/ocr-rs/models (Apache-2.0) and are embedded into the binary at
# compile time.
set -eu
VERSION=1.31.1
SHA256_ARM64="2e1344a1926ee50eb25b38153cb6992c3567515aef0e677a1a520a1798896d6f"
SHA256_X64="PENDING_X86_64_CHECKSUM"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/adapters/ocr-rs/runtime"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PKG="onnxruntime-osx-arm64-$VERSION.tgz"; SHA="$SHA256_ARM64" ;;
  x86_64) PKG="onnxruntime-osx-x86_64-$VERSION.tgz"; SHA="$SHA256_X64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$PKG" "https://github.com/microsoft/onnxruntime/releases/download/v$VERSION/$PKG"
echo "$SHA  $TMP/$PKG" | shasum -a 256 -c -
tar xzf "$TMP/$PKG" -C "$TMP"
mkdir -p "$DEST"
cp -L "$(find "$TMP" -name "libonnxruntime.$VERSION.dylib" -type f | head -1)" "$DEST/libonnxruntime.dylib"
echo "ok: $DEST/libonnxruntime.dylib"
