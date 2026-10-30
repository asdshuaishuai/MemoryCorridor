#!/usr/bin/env python3
"""Build a deterministic native MemoryCorridor distribution archive."""
import argparse
import gzip
import hashlib
import json
import platform
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DOCS = ["README.md", "LICENSE", "NOTICE", "docs/protocol.md", "docs/web.md",
        "docs/visual-mbtmd.md", "docs/pack-format.md", "docs/wasm.md", "docs/release.md",
        "docs/ci.md", "docs/memory.md", "docs/extending.md"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def version():
    for line in (ROOT / "moon.mod").read_text(encoding="utf-8").splitlines():
        if line.startswith("version = "):
            return line.split('"', 2)[1]
    raise SystemExit("moon.mod has no version")


def binary(package, target):
    base = ROOT / "_build" / target / "debug" / "build" / package
    for name in (package, package + ".exe"):
        candidate = base / name
        if candidate.is_file():
            return candidate
    raise SystemExit(f"missing {package} executable; run moon build --target {target} cli mcp web")


def copy_file(stage, relative, destination=None):
    source = ROOT / relative
    if not source.is_file():
        raise SystemExit(f"missing release input: {relative}")
    target = stage / (destination or relative)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def make_archive(stage, output):
    with output.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=9, mtime=0, filename="") as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path in sorted(stage.rglob("*")):
                    relative = path.relative_to(stage)
                    info = archive.gettarinfo(str(path), arcname=str(relative))
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = 0
                    if path.is_file():
                        with path.open("rb") as handle:
                            archive.addfile(info, handle)
                    else:
                        archive.addfile(info)


def main():
    parser = argparse.ArgumentParser(description="Create a deterministic native engine distribution")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--target", choices=["native"], default="native")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if not args.skip_build:
        subprocess.run(["moon", "build", "--target", args.target, "cli", "mcp", "web"], cwd=ROOT, check=True)
    cli, mcp = binary("cli", args.target), binary("mcp", args.target)
    web = binary("web", args.target)
    tag = f"memorycorridor-{version()}-{args.target}-{platform.system().lower()}-{platform.machine().lower()}"
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f"{tag}.tar.gz"
    with tempfile.TemporaryDirectory(prefix="corridor-release-") as temporary:
        stage = Path(temporary) / tag
        copy_file(stage, "README.md")
        copy_file(stage, "LICENSE")
        copy_file(stage, "NOTICE")
        for document in DOCS[3:]:
            copy_file(stage, document)
        copy_file(stage, "scripts/watch.py", "scripts/watch.py")
        copy_file(stage, str(cli.relative_to(ROOT)), "bin/memorycorridor-cli" + (".exe" if cli.suffix == ".exe" else ""))
        copy_file(stage, str(mcp.relative_to(ROOT)), "bin/memorycorridor-mcp" + (".exe" if mcp.suffix == ".exe" else ""))
        copy_file(stage, str(web.relative_to(ROOT)), "bin/memorycorridor-web" + (".exe" if web.suffix == ".exe" else ""))
        for executable in (stage / "bin").iterdir():
            executable.chmod(0o755)
        rows = []
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                rows.append({"path": str(path.relative_to(stage)), "size": path.stat().st_size, "sha256": digest(path)})
        manifest = {"format": "memorycorridor-release", "version": version(), "target": args.target,
                    "platform": platform.system().lower(), "arch": platform.machine().lower(), "files": rows}
        (stage / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
        make_archive(stage, archive)
    checksum = digest(archive)
    (args.output / f"{archive.name}.sha256").write_text(f"{checksum}  {archive.name}\n", encoding="ascii")
    print(json.dumps({"ok": True, "archive": str(archive), "sha256": checksum, "files": len(rows)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
