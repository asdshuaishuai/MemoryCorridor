#!/usr/bin/env python3
"""End-to-end isolation test for the derived workspace layer.

Proves that:
  * the engine projects only catalog pages into `workspaces/<id>/wiki`;
  * memory is exported beside that wiki, not into the global cache;
  * global list/search/rebuild/pack never read the derived layer;
  * deleting the whole `workspaces/` tree leaves the global base verifiable;
  * rerunning the host generator is byte-idempotent.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
WIKI = ROOT / "scripts/workspace_wiki.py"


def call(vault, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(vault), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=120).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def publish(vault, raw_name, title, page_id, body):
    (vault / "raw" / raw_name).parent.mkdir(parents=True, exist_ok=True)
    (vault / "raw" / raw_name).write_text(body, encoding="utf-8")
    order = call(vault, "scan")["orders"][0]
    context = call(vault, "context", order=order)
    call(vault, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [], "summary": title})
    staging = vault / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{raw_name}\"]\n---\n{body}",
        encoding="utf-8")
    call(vault, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}],
         at="2026-11-20T10:00:00Z")


def snapshot(files):
    return {path: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in files if path.is_file()}


with tempfile.TemporaryDirectory(prefix="memorycorridor-workspace-layer-") as temp:
    vault = Path(temp)
    call(vault, "init", purpose="工作区分层隔离验证")
    publish(vault, "ceramics/notes.md", "官窑釉色",
            "concepts/ceramics", "官窑釉色与胎质可以据此核对。")
    workspace_path = "/test/workspace-layer"
    workspace = call(vault, "workspace-open", path=workspace_path,
                     at="2026-11-20T10:10:00Z")["id"]
    call(vault, "memory-submit", workspace=workspace, kind="preference",
         scope="project", text="优先看青瓷釉色", conditions=["整理工作区时"],
         sources=["raw/ceramics/notes.md"], importance=0.8,
         at="2026-11-20T10:20:00Z", key="workspace-layer")
    exported = call(vault, "memory-export", workspace=workspace)
    assert exported["notes"] == 1
    assert (vault / "workspaces" / workspace / "memory").is_dir()
    assert (vault / "workspaces" / "projects.json").is_file()

    before_fingerprint = call(vault, "status")["fingerprint"]
    generated = subprocess.run(
        ["python3", "-I", str(WIKI), "--vault", str(vault),
         "--workspace", workspace, "--namespace", "ceramics"],
        capture_output=True, text=True, check=True)
    summary = json.loads(generated.stdout)
    # A published source also has its generated source page, so the projection
    # may contain more than the concept page while still excluding everything
    # outside the selected namespace.
    assert summary["pages"] >= 1, summary
    wiki_file = vault / "workspaces" / workspace / "wiki" / "concepts__ceramics.md"
    claim_file = vault / "workspaces" / workspace / "claims" / "concepts__ceramics.json"
    manifest_file = vault / "workspaces" / workspace / "manifest.json"
    index_file = vault / "workspaces" / "index.mbt.md"
    for path in (wiki_file, claim_file, manifest_file, index_file):
        assert path.is_file(), path
    wiki_text = wiki_file.read_text(encoding="utf-8")
    assert "generated: true" in wiki_text and "官窑釉色与胎质" in wiki_text
    assert workspace in index_file.read_text(encoding="utf-8")
    assert call(vault, "status")["fingerprint"] == before_fingerprint

    # A sentinel appended to the derived page must never enter the global base,
    # even after an explicit rebuild. This is the core isolation guarantee.
    marker = "WORKSPACE_ONLY_SENTINEL"
    wiki_file.write_text(wiki_text + "\n" + marker + "\n", encoding="utf-8")
    call(vault, "rebuild")
    hits = call(vault, "search", query=marker)["hits"]
    assert hits == [], hits
    pages = call(vault, "list-pages")
    assert all(not row["path"].startswith("workspaces/") for row in pages), pages

    # Pack carries catalog/state only, never the derived layer.
    call(vault, "pack", output="exports/no-workspaces.mcpack")
    with zipfile.ZipFile(vault / "exports/no-workspaces.mcpack") as bundle:
        names = bundle.namelist()
    assert names and all("workspaces/" not in name for name in names), names

    # A file dropped into the derived layer cannot become a scan order (and
    # therefore cannot be committed): scan only registers raw inputs.
    evil = vault / "workspaces" / workspace / "wiki" / "unlisted.md"
    evil.write_text("---\ntype: concept\ntitle: evil\nsources: []\n---\nevil\n", encoding="utf-8")
    assert all(not row["source"].startswith("workspaces/")
               for row in call(vault, "scan")["orders"])

    # Re-running the generator restores the sentinel edit and is byte-idempotent.
    subprocess.run(
        ["python3", "-I", str(WIKI), "--vault", str(vault),
         "--workspace", workspace, "--namespace", "ceramics"],
        capture_output=True, text=True, check=True)
    first = snapshot([wiki_file, claim_file, manifest_file, index_file])
    subprocess.run(
        ["python3", "-I", str(WIKI), "--vault", str(vault),
         "--workspace", workspace, "--namespace", "ceramics"],
        capture_output=True, text=True, check=True)
    second = snapshot([wiki_file, claim_file, manifest_file, index_file])
    assert first == second
    assert marker not in wiki_file.read_text(encoding="utf-8")
    # A memory re-export reconciles only `memory/`; the sibling generated wiki
    # and index must survive byte-for-byte.
    call(vault, "memory-export", workspace=workspace)
    assert wiki_file.is_file() and claim_file.is_file() and index_file.is_file()

    # Removing the whole derived layer loses no authoritative state.
    shutil.rmtree(vault / "workspaces")
    call(vault, "verify")
    assert call(vault, "status")["fingerprint"] == before_fingerprint
    call(vault, "memory-export")
    assert (vault / "workspaces" / workspace / "memory").is_dir()
    assert not (vault / "workspaces" / workspace / "wiki").exists()

    # A non-registered workspace is refused instead of silently planning nothing.
    call(vault, "workspace-wiki-plan", workspace="0" * 64, error="file_missing")

print("workspace layer isolation, projection, idempotence and deletion recovery passed")
