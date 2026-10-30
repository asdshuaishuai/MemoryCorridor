# Native release package

`python3 scripts/release.py` builds `cli`, `mcp` and `web` for the current
MoonBit target and writes a deterministic `tar.gz` package under `dist/`. The
archive contains the native binaries (CLI, MCP and the loopback web server),
the `watch.py` adapter, a fixed selection of documents (`README.md`,
`docs/protocol.md`, `docs/web.md`, `docs/visual-mbtmd.md`, `docs/pack-format.md`,
`docs/wasm.md`, `docs/release.md`, `docs/ci.md`, `docs/memory.md`,
`docs/extending.md`), and the project `LICENSE` and `NOTICE` — not the whole
`docs/` tree. The tree ships documentation only: the verification and e2e
scripts that those documents reference (`scripts/verify.sh`,
`scripts/mutation_check.py`, `scripts/*_e2e.py`) live in the source repository,
not in this archive. `manifest.json` records the target, platform,
architecture, size, and SHA-256 of every payload file (the manifest describes itself by the archive checksum);
the adjacent `.sha256` file covers the archive itself.

The package is built for the host where the command runs. Cross-compilation is
not implied: a Linux package requires a MoonBit toolchain and native compiler
for that target. Use `--skip-build` only when the matching binaries
already exist under `_build/<target>/debug/build/`.

CI produces the Linux artifact from the same script: the Ubuntu job uploads
`memorycorridor-native-linux` (first green run 41050582660, 2026-10-30).
Windows packaging was removed with the Windows platform branches when the
project moved to WASM-runtime delivery (`docs/wasm.md`); each archive's
manifest records its own platform and architecture.

```sh
python3 scripts/release.py --output dist
tar -xzf dist/memorycorridor-*.tar.gz
./bin/memorycorridor-web /path/to/vault --port 8768
python3 scripts/watch.py /path/to/vault --cli ./bin/memorycorridor-cli --once
```

The release archive is byte-for-byte stable for the same inputs. The release
smoke test is part of `scripts/verify.sh`.
