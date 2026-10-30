#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

${CC:-cc} -fsyntax-only platform/fs.c platform/socket.c
echo "POSIX native filesystem/socket C syntax: passed"
