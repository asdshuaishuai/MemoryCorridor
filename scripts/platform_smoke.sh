#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

${CC:-cc} -fsyntax-only platform/fs.c platform/socket.c
echo "POSIX native filesystem/socket C syntax: passed"

if [ -n "${WINDOWS_CC:-}" ]; then
  # The caller supplies a compiler with a Windows sysroot (for example a
  # MinGW clang wrapper). Platform-specific flags stay with that toolchain.
  ${WINDOWS_CC} -D_WIN32 -fsyntax-only platform/fs.c platform/socket.c
  echo "Windows native filesystem/socket C syntax: passed"
else
  echo "Windows native filesystem/socket C syntax: skipped (set WINDOWS_CC with a Windows sysroot)"
fi
