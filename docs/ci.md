# Continuous verification

`.github/workflows/verify.yml` has three jobs:

- `linux` runs the complete `scripts/verify.sh` gate on Ubuntu, installs MoonBit
  through the official Unix installer (the repository does not vendor the
  toolchain), then builds the deterministic native release archive with
  `scripts/release.py` and re-checks it with `scripts/release_e2e.py`. The
  archive and checksum are uploaded as `memorycorridor-native-linux`.
- `windows-native` installs MoonBit through the official Windows installer
  (`https://cli.moonbitlang.com/install/powershell.ps1`), then runs
  `moon check --target native --deny-warn`, `moon test --target native`,
  `moon build --target native cli mcp`, and the same deterministic release
  scripts with `python`. The archive and checksum are uploaded as
  `memorycorridor-native-windows`.
- `windows-filesystem` keeps the standalone `clang-cl /D_WIN32 /Zs platform/fs.c`
  syntax check for the Windows filesystem adapter.

Evidence status: the Linux job mirrors the gate that already passes locally on
macOS/POSIX. The `windows-native` job has not been executed from this
repository yet (GitHub Actions only runs after a push), so Windows native MoonBit
runtime, transaction and release behavior are configured but unverified; the
`tasks.md` cross-platform item stays open until a green Windows run is recorded.
The POSIX path in `platform/fs.c` and the Windows UTF-16/reparse-point/atomic
replace/lock branches are both committed, and `scripts/platform_smoke.sh`
executes the Windows branch only when a Windows compiler/sysroot is provided.
