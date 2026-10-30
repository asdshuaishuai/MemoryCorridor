# Continuous verification

`.github/workflows/verify.yml` has three jobs:

- `linux` runs the complete `scripts/verify.sh` gate on Ubuntu, installs the
  MoonBit toolchain version pinned in `.moonbit-version` through the official
  Unix installer (the repository does not vendor the toolchain, but pins the
  version so CI matches the locally verified gate), then builds the
  deterministic native release archive with `scripts/release.py` and re-checks
  it with `scripts/release_e2e.py`. The archive and checksum are uploaded as
  `memorycorridor-native-linux`.
- `windows-native` installs the same pinned toolchain through the official
  Windows installer (`https://cli.moonbitlang.com/install/powershell.ps1` with
  `MOONBIT_INSTALL_VERSION` read from `.moonbit-version`), then runs
  `moon check --target native --deny-warn`, `moon test --target native`,
  `moon build --target native cli mcp`, and the same deterministic release
  scripts with `python`. The archive and checksum are uploaded as
  `memorycorridor-native-windows`.
- `windows-filesystem` keeps the standalone `clang-cl /D_WIN32 /Zs platform/fs.c`
  syntax check for the Windows filesystem adapter.

Evidence status: the Linux job went fully green in run 41050582660 (2026-10-30),
producing the `memorycorridor-native-linux` archive artifact — it mirrors the
gate that already passes locally on macOS/POSIX. The `windows-native` job now
executes but fails at the native link step: `platform/socket.c` references
Winsock symbols (`send`, `WSAStartup`, ...) that are left unresolved when
linking `web.exe` (14 unresolved externals; likely a missing `ws2_32` link
input). With no Windows environment available to verify a link-config fix, the
job stays red and the `tasks.md` cross-platform item stays open until a green
Windows run is recorded.
The POSIX path in `platform/fs.c` and the Windows UTF-16/reparse-point/atomic
replace/lock branches are both committed, and `scripts/platform_smoke.sh`
executes the Windows branch only when a Windows compiler/sysroot is provided.
