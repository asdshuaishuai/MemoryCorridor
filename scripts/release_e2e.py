#!/usr/bin/env python3
"""Smoke-test release determinism and manifest coverage."""
import hashlib
import json
import subprocess
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corridor-release-e2e-") as work:
    output = Path(work)
    for _ in range(2):
        subprocess.run(["python3", str(ROOT / "scripts/release.py"), "--skip-build", "--output", str(output)], cwd=ROOT, check=True, capture_output=True, text=True)
    archives = sorted(output.glob("*.tar.gz"))
    assert len(archives) == 1
    archive = archives[0]
    first = archive.read_bytes()
    subprocess.run(["python3", str(ROOT / "scripts/release.py"), "--skip-build", "--output", str(output)], cwd=ROOT, check=True, capture_output=True, text=True)
    assert archive.read_bytes() == first
    with tarfile.open(archive, "r:gz") as bundle:
        manifest = json.loads(bundle.extractfile("manifest.json").read())
        names = {item.name for item in bundle.getmembers() if item.isfile()}
        assert {row["path"] for row in manifest["files"]} | {"manifest.json"} == names
        for row in manifest["files"]:
            data = bundle.extractfile(row["path"]).read()
            assert len(data) == row["size"] and hashlib.sha256(data).hexdigest() == row["sha256"]
    checksum = (output / (archive.name + ".sha256")).read_text().split()[0]
    assert checksum == hashlib.sha256(first).hexdigest()
print("Deterministic native release archive, manifest and checksum: passed")
