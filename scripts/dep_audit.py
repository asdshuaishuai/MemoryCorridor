#!/usr/bin/env python3
"""Audit the engine dependency boundary and checked third-party licenses."""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]

ALLOWED_EXTERNAL = {
    "moonbitlang/core/",
    "moonbitstack/moonyaml",
}
FORBIDDEN_EXTERNAL_WORDS = (
    "openai", "anthropic", "llm", "model", "embedding", "network",
    "http", "https", "grpc", "curl", "reqwest",
)
LAYERS = {
    "base": 0,
    "core": 1,
    "decl": 2,
    "visual": 2,
    "pack": 2,
    "interop": 2,
    "vault": 3,
    "index": 3,
    "agent": 4,
    "wasm": 4,
    "platform": 5,
    "nativehost": 5,
    "cli": 6,
    "mcp": 6,
}
SAME_LAYER_ALLOWED = {("wasm", "agent"), ("nativehost", "platform")}
REQUIRED_LICENSES = {
    "moonbitstack/moonyaml": ROOT / "licenses/moonyaml-Apache-2.0.txt",
    "memorycorridor/vendor/reader": ROOT / "vendor/reader/provenance.json",
}


def package_imports(path):
    text = path.read_text(encoding="utf-8")
    match = re.search(r"\bimport\s*\{(.*?)\}", text, re.DOTALL)
    if not match:
        return []
    return re.findall(r'"([^"]+)"', match.group(1))


def main():
    violations = []
    graph = {}
    seen_external = set()
    package_files = sorted(ROOT.rglob("moon.pkg"))
    for package_file in package_files:
        package = package_file.parent.relative_to(ROOT).as_posix()
        imports = package_imports(package_file)
        graph[package] = imports
        for dependency in imports:
            if dependency.startswith("memorycorridor/"):
                target = dependency.removeprefix("memorycorridor/")
                if target not in LAYERS and target != "vendor/reader":
                    violations.append(f"{package}: unknown first-party package {dependency}")
                elif target in LAYERS:
                    source_layer = LAYERS.get(package)
                    target_layer = LAYERS[target]
                    if source_layer is None:
                        violations.append(f"{package}: package has no layer declaration")
                    elif target_layer > source_layer or (
                        target_layer == source_layer and (package, target) not in SAME_LAYER_ALLOWED
                    ):
                        violations.append(f"{package}: forbidden dependency direction -> {dependency}")
                continue
            seen_external.add(dependency)
            if not any(dependency == prefix or dependency.startswith(prefix) for prefix in ALLOWED_EXTERNAL):
                violations.append(f"{package}: unapproved external dependency {dependency}")
            if any(word in dependency.lower() for word in FORBIDDEN_EXTERNAL_WORDS):
                violations.append(f"{package}: model/network dependency refused {dependency}")

    for dependency, license_path in REQUIRED_LICENSES.items():
        if not license_path.is_file() or license_path.stat().st_size == 0:
            violations.append(f"{dependency}: missing license/provenance file {license_path.relative_to(ROOT)}")

    # The pure engine packages must not import the native platform boundary.
    pure_packages = {"base", "core", "decl", "visual", "pack", "interop", "vault", "index", "agent", "wasm"}
    for package in pure_packages:
        for dependency in graph.get(package, []):
            if dependency in {"memorycorridor/platform", "memorycorridor/nativehost"}:
                violations.append(f"{package}: pure package imports native boundary {dependency}")

    report = {
        "packages": len(package_files),
        "external_dependencies": sorted(seen_external),
        "allowed_external_prefixes": sorted(ALLOWED_EXTERNAL),
        "violations": violations,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if violations:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
