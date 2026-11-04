#!/bin/sh
# Fetch the pinned bge-small-zh-v1.5 ONNX embedding model (Apache-2.0, BAAI)
# used by adapters/embed-rs. Sourced from the domestic HuggingFace mirror
# (hf-mirror.com) since ModelScope carries only safetensors, not ONNX.
# int8-quantized = 23.9 MB (well under the 100 MB budget); runs on the same
# ONNX Runtime OCR already introduced. Pinned by SHA256, NOT vendored in git.
set -eu
BASE="https://hf-mirror.com/Xenova/bge-small-zh-v1.5/resolve/main"
SHA_MODEL="b9837c19ce154ff0726d398ee77abbc03a7faf0476c6f93016c84e531be7ebb5"
SHA_TOKENIZER="48cea5d44424912a6fd1ea647bf4fe50b55ab8b1e5879c3275f80e339e8fae26"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/adapters/embed-rs/model"
mkdir -p "$DEST"
get() {
  curl -fsSL --retry 3 -o "$DEST/$1" "$BASE/$2"
  echo "$3  $DEST/$1" | shasum -a 256 -c -
}
get model_int8.onnx "onnx/model_int8.onnx" "$SHA_MODEL"
get tokenizer.json "tokenizer.json" "$SHA_TOKENIZER"
echo "ok: bge-small-zh-v1.5 int8 ONNX at $DEST"
