#!/bin/sh
# Fetch the pinned CLIP ViT-B/32 int8 ONNX multimodal pair (OpenAI weights,
# MIT) used by adapters/embed-rs in its OPTIONAL multimodal space. The text
# embedding pipeline keeps bge-small-zh-v1.5 as the default unchanged; these
# two towers (vision 89 MB + text 65 MB int8) give pages whose sources include
# an image a deterministic *visual* vector, searchable cross-modal with the
# text tower. Sourced from hf-mirror.com (Xenova pre-converted ONNX exports;
# ModelScope carries no ONNX here either). Pinned by SHA256, NOT vendored.
set -eu
BASE="https://hf-mirror.com/Xenova/clip-vit-base-patch32/resolve/main"
SHA_VISION="583fd1110a514667812fee7d684952aaf82a99b959760c8d7dca7e0ab9839299"
SHA_TEXT="73baab855d406190da9faa498cfedf65f15cf309f4cc7385b7b032e6d08e5c3a"
SHA_TOKENIZER="f7f3b7af117d467b58374797691a6438d3e6b9e9cef800dfd5dced7f697a90cd"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/adapters/embed-rs/clip"
mkdir -p "$DEST"
get() {
  curl -fsSL --retry 3 -o "$DEST/$1" "$BASE/$2"
  echo "$3  $DEST/$1" | shasum -a 256 -c -
}
get vision_model_quantized.onnx "onnx/vision_model_quantized.onnx" "$SHA_VISION"
get text_model_quantized.onnx "onnx/text_model_quantized.onnx" "$SHA_TEXT"
get tokenizer.json "tokenizer.json" "$SHA_TOKENIZER"
echo "ok: CLIP ViT-B/32 int8 ONNX pair at $DEST"
