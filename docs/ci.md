# Continuous verification

`.github/workflows/verify.yml` has two independent jobs, each with its own
budget:

- `verify` runs the complete `scripts/verify.sh` gate on Ubuntu. It installs
  the MoonBit toolchain version pinned in `.moonbit-version` through the
  official Unix installer (the repository does not vendor the toolchain, but
  pins the version so CI matches the locally verified gate). The gate includes
  the wasm service e2e (`scripts/wasm_service_e2e.py`), which bootstraps a
  wasmtime venv on the runner, and the 213-entry mutation gate. Budget:
  `timeout-minutes: 300`.
- `release` independently builds the deterministic native release archive with
  `scripts/release.py`, re-checks it with `scripts/release_e2e.py`, and uploads
  the archive and checksum as `memorycorridor-native-linux`. Budget:
  `timeout-minutes: 60`.

The split exists because verify alone already runs close to four hours on a
hosted runner: with packaging appended to the same job, a 240-minute budget was
exhausted by the release step after the verify step had already succeeded,
reporting the whole run as `cancelled`. A run that hits a job budget is still
reported as `cancelled`, which `gh run watch --exit-status` wrongly treats as
success — check `gh run view` conclusions, not the watcher exit code.

Cross-platform delivery is the wasm service runtime's job: the engine module
runs under any WASM runtime with a thin host (see `docs/wasm.md`), so the
repository no longer carries Windows CI jobs or Windows branches in
`platform/fs.c` / `platform/socket.c`. The former `windows-native` job (it
failed at native link with unresolved Winsock symbols) and the
`windows-filesystem` clang-cl syntax check were removed together with those
branches; git history keeps both, and the first green Linux run remains
41050582660 (2026-10-30).

Flake note: `reading_fixture --with-map` launches headless Chrome and speaks CDP
over a hand-rolled WebSocket. Earlier CI runs failed with
`chrome did not expose a debugging port` when Chrome took longer than the old
10-second window. The launcher now waits up to 30 seconds and prefers the
`DevToolsActivePort` file written by Chrome, with stderr retained in the error
for diagnosis. This was an environment startup race, not a product failure.
