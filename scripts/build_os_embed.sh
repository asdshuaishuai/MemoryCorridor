#!/bin/sh
# Build the macOS NLEmbedding host adapter. Linux/Windows hosts can supply an
# equivalent adapter implementing the same stdin/stdout contract.
set -eu
cd "$(dirname "$0")/.."
if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found; install Xcode Command Line Tools" >&2
  exit 2
fi
mkdir -p adapters/os-embed
swiftc -O adapters/os-embed/main.swift -o adapters/os-embed/os-embed
adapters/os-embed/os-embed --selftest
