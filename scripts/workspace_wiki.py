#!/usr/bin/env python3
"""Generate the derived workspace layer from the global knowledge base.

The engine owns selection (`workspace-wiki-plan`) and the authoritative memory
export (`memory-export`). This host script only writes the projection:

    workspaces/
    ├── index.mbt.md
    └── <workspace-id>/
        ├── memory/<note-id>.md      (written by memory-export)
        ├── wiki/<page-id>.md        (generated here)
        ├── claims/<page-id>.json    (generated here)
        └── manifest.json            (generated here)

Nothing here becomes catalog input. The global base stays the only authority,
and deleting `workspaces/<id>/wiki` or the whole `workspaces/` tree loses
nothing that `memory-export` plus this script cannot rebuild.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CLI = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(cli: Path, vault: Path, op: str, **fields):
    request = {"op": op, "vault": str(vault), **fields}
    completed = subprocess.run(
        [str(cli)], input=json.dumps(request) + "\n",
        capture_output=True, text=True, timeout=120, check=True)
    value = json.loads(completed.stdout)
    if not value.get("ok"):
        raise SystemExit(f"{op}: {value.get('error')}")
    return value["result"]


def front_matter(text: str):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 4)
    if end < 0:
        return {}, text
    header = {}
    for line in text[4:end].splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            header[key.strip()] = value.strip().strip('"\'')
    return header, text[end + 5:]


def page_document(vault: Path, workspace: str, row: dict):
    source = vault / row["path"]
    if not source.is_file():
        raise SystemExit(f"derived page source missing: {row['path']}")
    meta, body = front_matter(source.read_text(encoding="utf-8"))
    title = meta.get("title") or row["id"]
    lines = [
        "---",
        f"type: {row['kind']}",
        f"title: {json.dumps(title, ensure_ascii=False)}",
        "generated: true",
        f"derived_from: {json.dumps(row['path'], ensure_ascii=False)}",
        f"workspace: {workspace}",
        f"page_id: {json.dumps(row['id'], ensure_ascii=False)}",
        f"page_sha256: {row['sha256']}",
        f"stale: {str(row['stale']).lower()}",
        f"sources: {json.dumps(row['sources'], ensure_ascii=False)}",
        "---",
        body.rstrip() + "\n",
    ]
    return "\n".join(lines)


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_if_changed(path: Path, content: str) -> bool:
    if path.is_file() and path.read_text(encoding="utf-8") == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return True


def generate_workspace(cli: Path, vault: Path, workspace: str,
                       namespace: str | None, pages: list[str]) -> dict:
    plan = call(cli, vault, "workspace-wiki-plan", workspace=workspace,
                namespace=namespace, pages=pages, limit=500)
    wiki_dir = vault / "workspaces" / workspace / "wiki"
    claims_dir = vault / "workspaces" / workspace / "claims"
    wiki_dir.mkdir(parents=True, exist_ok=True)
    claims_dir.mkdir(parents=True, exist_ok=True)
    expected_wiki = set()
    expected_claims = set()
    claims_by_page = {row["page"]: row for row in plan["claims"]}
    files = {}
    written = 0
    for row in plan["pages"]:
        filename = row["id"].replace("/", "__") + ".md"
        relative = f"workspaces/{workspace}/wiki/{filename}"
        content = page_document(vault, workspace, row)
        expected_wiki.add(filename)
        if write_if_changed(vault / relative, content):
            written += 1
        files[relative] = digest(content)
        claim_name = row["id"].replace("/", "__") + ".json"
        claim_text = json.dumps(claims_by_page[row["id"]], ensure_ascii=False,
                                indent=2, sort_keys=True) + "\n"
        expected_claims.add(claim_name)
        claim_relative = f"workspaces/{workspace}/claims/{claim_name}"
        if write_if_changed(vault / claim_relative, claim_text):
            written += 1
        files[claim_relative] = digest(claim_text)
    # Only this workspace's generated wiki/claims are reconciled. Memory is the
    # engine's export and is left untouched.
    for directory, expected in ((wiki_dir, expected_wiki), (claims_dir, expected_claims)):
        for path in directory.iterdir():
            if path.is_file() and path.name not in expected:
                path.unlink()
    manifest = dict(plan["manifest"])
    manifest["files"] = dict(sorted(files.items()))
    manifest["wiki"] = f"workspaces/{workspace}/wiki"
    manifest["claims"] = f"workspaces/{workspace}/claims"
    manifest["memory"] = f"workspaces/{workspace}/memory"
    manifest_text = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if write_if_changed(vault / "workspaces" / workspace / "manifest.json", manifest_text):
        written += 1
    return {"workspace": workspace, "pages": len(plan["pages"]),
            "written": written, "manifest": manifest}


def rebuild_index(vault: Path) -> int:
    rows = []
    root = vault / "workspaces"
    for manifest_path in sorted(root.glob("*/manifest.json")):
        try:
            rows.append(json.loads(manifest_path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    lines = [
        "# 工作区索引",
        "",
        "> 本文件由 `scripts/workspace_wiki.py` 派生，只索引 `workspaces/` 分层；",
        "> 不是全局知识目录，不替代根目录 `index.mbt.md`。",
        "",
    ]
    if not rows:
        lines.append("（尚未生成任何工作区投影。）")
    for row in rows:
        lines.extend([
            f"## `{row['workspace']}`",
            "",
            f"- path: `{row['path']}`",
            f"- pages: {row['pages']}（shared {row['shared']}）",
            f"- wiki: `{row['wiki']}`",
            f"- memory: `{row['memory']}`",
            f"- manifest: `workspaces/{row['workspace']}/manifest.json`",
            "",
        ])
    content = "\n".join(lines).rstrip() + "\n"
    write_if_changed(root / "index.mbt.md", content)
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--namespace")
    parser.add_argument("--pages", action="append", default=[])
    parser.add_argument("--cli", default=str(DEFAULT_CLI))
    args = parser.parse_args()
    cli = Path(args.cli)
    if not cli.is_file() and not cli.with_suffix(".exe").is_file():
        raise SystemExit(f"cli not found: {cli} (build with `moon build --target native cli`)")
    if cli.with_suffix(".exe").is_file():
        cli = cli.with_suffix(".exe")
    vault = Path(args.vault)
    generated = generate_workspace(cli, vault, args.workspace, args.namespace, args.pages)
    workspaces = rebuild_index(vault)
    print(json.dumps({**generated, "indexed_workspaces": workspaces}, ensure_ascii=False))


if __name__ == "__main__":
    main()
