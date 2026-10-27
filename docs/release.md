# Native release package

`python3 scripts/release.py` builds `cli` and `mcp` for the current MoonBit
target and writes a deterministic `tar.gz` package under `dist/`. The archive
contains the native binaries, the read-only `serve.py` and `watch.py` adapters,
the whole `docs/` tree (protocol, web, visual-mbtmd, pack format, WASM, CI, release,
memory-layer design, extension checklist), and the project notices. The tree ships
documentation only: the verification and e2e scripts that those documents reference
(`scripts/verify.sh`, `scripts/mutation_check.py`, `scripts/*_e2e.py`) live in the
source repository, not in this archive. `manifest.json`
records the target, platform, architecture, size, and SHA-256 of every payload file (the manifest describes itself by the archive checksum);
the adjacent `.sha256` file covers the archive itself.

The package is built for the host where the command runs. Cross-compilation is
not implied: a Windows or Linux package requires a MoonBit toolchain and native
compiler for that target. Use `--skip-build` only when the matching binaries
already exist under `_build/<target>/debug/build/`.

CI produces per-host artifacts from the same script: the Ubuntu job uploads
`memorycorridor-native-linux` and the Windows job (configured but not yet run
from this repository) uploads `memorycorridor-native-windows`; each archive's
manifest records its own platform and architecture. Building both on one host
would require cross toolchains and is not provided.

```sh
python3 scripts/release.py --output dist
tar -xzf dist/memorycorridor-*.tar.gz
python3 scripts/serve.py /path/to/vault --cli ./bin/memorycorridor-cli
python3 scripts/watch.py /path/to/vault --cli ./bin/memorycorridor-cli --once
```

The release archive is byte-for-byte stable for the same inputs. The release
smoke test is part of `scripts/verify.sh`.
