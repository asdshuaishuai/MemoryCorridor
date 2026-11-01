# Continuous verification

`.github/workflows/verify.yml` has a single job:

- `linux` runs the complete `scripts/verify.sh` gate on Ubuntu, installs the
  MoonBit toolchain version pinned in `.moonbit-version` through the official
  Unix installer (the repository does not vendor the toolchain, but pins the
  version so CI matches the locally verified gate), then builds the
  deterministic native release archive with `scripts/release.py` and re-checks
  it with `scripts/release_e2e.py`. The archive and checksum are uploaded as
  `memorycorridor-native-linux`. The gate includes the wasm service e2e
  (`scripts/wasm_service_e2e.py`), which bootstraps a wasmtime venv on the
  runner. The job budget is `timeout-minutes: 120` (raised from 60 after the
  gate grew past one hour with 87 mutation rebuilds and the added evaluation
  suites; a run that hits the budget is reported as `cancelled`, which
  `gh run watch --exit-status` wrongly treats as success — check
  `gh run view` conclusions, not the watcher exit code).

Cross-platform delivery is the wasm service runtime's job: the engine module
runs under any WASM runtime with a thin host (see `docs/wasm.md`), so the
repository no longer carries Windows CI jobs or Windows branches in
`platform/fs.c` / `platform/socket.c`. The former `windows-native` job (it
failed at native link with unresolved Winsock symbols) and the
`windows-filesystem` clang-cl syntax check were removed together with those
branches; git history keeps both, and the first green Linux run remains
41050582660 (2026-10-30).
