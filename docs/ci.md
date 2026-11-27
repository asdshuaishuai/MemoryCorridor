# Continuous verification

`.github/workflows/verify.yml` has two independent jobs, each with its own
budget:

- `verify` runs the complete `scripts/verify.sh` gate on Ubuntu. It installs
  the MoonBit toolchain version pinned in `.moonbit-version` through the
  official Unix installer (the repository does not vendor the toolchain, but
  pins the version so CI matches the locally verified gate). The gate includes
  the wasm service e2e (`scripts/wasm_service_e2e.py`), which bootstraps a
  wasmtime venv on the runner, and the 252-entry mutation gate. Budget:
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

Local changes use the tiered gate: `scripts/quick_verify.sh` runs `moon check
--deny-warn`, `moon test`, the native build, and the focused e2e set
(`e2e.py`, `interop_e2e.py`, `retrieval_e2e.py`, `embedding_e2e.py`,
`os_embed_e2e.py`, `os_embed_probe_e2e.py`, `vector_engine_e2e.py`,
`memory_e2e.py`, `dream_e2e.py`, `workspace_layer_e2e.py`,
`project_wiki_bench.py`, `ocr_native_e2e.py`). The full `scripts/verify.sh`
(including the mutation matrix and all WASM/Web faces) is reserved for release,
nightly and CI; it is not the per-change default.

`os_embed_e2e.py` distinguishes a missing adapter (SKIP, with the
`scripts/build_os_embed.sh` hint) from a present binary whose `--probe` exits 2
or emits no `os-embed/v1` verdict (FAIL, with the same build hint); a valid
verdict with `available:false` (or an unavailable `zh` row) is a SKIP naming the
probe reason. The two
host-only probe gates, `os_embed_probe_e2e.py` and `vector_engine_e2e.py`, run
on Linux as well: their contract branches use stub adapters plus the native CLI,
and only the macOS live branch needs the OS engine. `vector_engine_e2e.py`'s
live branch also fails a present-but-stale adapter with the build hint, and its
live `ensure` check removes the canonical binary, rebuilds it from the
checked-in Swift source, and restores the original; a custom `OS_EMBED_BIN`
skips that check. `os_embed_probe_e2e.py` guards the Swift adapter's imports
and probe tokens and bans fetch tokens in the gate files; `vector_engine_e2e.py`
guards the helper and its own source against network tokens and does the same
gate check. None of these paths downloads a model or touches the network. `ocr_native_e2e.py` uses a stub adapter and runs on Linux and macOS; the real `ocr_e2e.py` is optional and SKIPs unless a locally built adapter and ONNX Runtime are present (it never fetches them).

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
