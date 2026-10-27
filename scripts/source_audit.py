#!/usr/bin/env python3
"""Count owned product implementation lines; test/build/docs/data do not count."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PACKAGES = ["base", "core", "decl", "vault", "index", "agent", "platform", "nativehost", "cli", "mcp", "visual", "wasm", "pack", "interop"]
counts = {}
details = {}


def count(path):
    text = path.read_text()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    lines = [line.strip() for line in text.splitlines()]
    return sum(bool(line) and not line.startswith(("//", "#include", "# ")) for line in lines)


for directory in PACKAGES:
    for p in (ROOT / directory).glob("*"):
        if p.suffix not in [".mbt", ".c"] or p.name.endswith(("_wbtest.mbt", "_test.mbt")):
            continue
        language = "MoonBit" if p.suffix == ".mbt" else "C"
        lines = count(p)
        if p.suffix == ".mbt":
            embedded = sum(line.lstrip().startswith("#|") for line in p.read_text().splitlines())
            if embedded:
                lines -= embedded
                counts["JavaScript/CSS"] = counts.get("JavaScript/CSS", 0) + embedded
                details[str(p.relative_to(ROOT)) + " (embedded web runtime)"] = embedded
        counts[language] = counts.get(language, 0) + lines
        details[str(p.relative_to(ROOT))] = lines
# The watcher is a shipped runtime adapter, so it belongs in the denominator.
for adapter in [ROOT / "scripts/watch.py", ROOT / "scripts/serve.py"]:
    if adapter.exists():
        lines = count(adapter)
        counts["Python"] = counts.get("Python", 0) + lines
        details[str(adapter.relative_to(ROOT))] = lines
for adapter in (ROOT / "sdk").glob("*.mjs"):
    lines = count(adapter)
    counts["JavaScript"] = counts.get("JavaScript", 0) + lines
    details[str(adapter.relative_to(ROOT))] = lines
for adapter in (ROOT / "integrations").rglob("*.mjs"):
    lines = count(adapter)
    counts["JavaScript"] = counts.get("JavaScript", 0) + lines
    details[str(adapter.relative_to(ROOT))] = lines
ratio = counts.get("MoonBit", 0) / sum(counts.values())
result = {"policy": "owned implementation nonblank/noncomment lines v1", "by_language": counts,
          "moonbit_ratio": ratio, "required": ">0.85", "files": details}
print(json.dumps(result, ensure_ascii=False, indent=2))
assert ratio > 0.85, "MoonBit product source ratio must exceed 85%"

# Dependency directions are data, not a claim inferred from directory names.
allowed = {"base": [], "core": ["base"], "decl": ["base", "core"],
           "vault": ["base", "core", "decl", "visual", "pack"], "index": ["base", "core"],
           "agent": ["base", "core", "decl", "vault", "index", "visual", "pack", "interop"],
           "platform": ["base"], "visual": ["base", "core", "vendor/reader"],
           "nativehost": ["base", "agent", "platform", "vault"],
           "cli": ["base", "agent", "nativehost"], "mcp": ["base", "agent", "nativehost"],
           "wasm": ["base", "core", "decl", "index", "agent", "visual"], "pack": ["base"], "interop": ["base"]}
for package, dependencies in allowed.items():
    imports = re.findall(r'"memorycorridor/([^"]+)"', (ROOT / package / "moon.pkg").read_text())
    assert set(imports) <= set(dependencies), (package, imports)
    if package not in ["platform", "nativehost"]:
        for p in (ROOT / package).glob("*.mbt"):
            assert 'extern "' not in p.read_text(), p
