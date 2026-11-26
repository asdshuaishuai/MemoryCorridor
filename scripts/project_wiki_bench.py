#!/usr/bin/env python3
"""Generate a real workspace wiki from this repository's own documents.

The engine still does not call a model: this script is the host side. It feeds
selected project documents through the normal two-step ingestion (scan →
context → analysis-submit → draft-submit → commit), registers this repository
as a workspace, writes project memories, then runs workspace-wiki-plan and the
host generator. It measures ingestion, projection, recall and latency.

Run:
    python3 -I scripts/project_wiki_bench.py
    python3 -I scripts/project_wiki_bench.py --json
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
WIKI = ROOT / "scripts/workspace_wiki.py"
PROJECT = ROOT

# Each tuple is a real project document, a stable page id, a title, and the
# deterministic host-side summary (the stand-in for an external LLM analysis).
DOCS = [
    ("README.md", "concepts/project-overview", "MemoryCorridor 项目总览",
     "MemoryCorridor 是 MoonBit 实现的知识与记忆引擎。知识库保持全局通用，"
     "工作区 wiki 是从全局知识派生的投影，记忆本体独立存放在 state/memory。"
     "交付面包括 native CLI、MCP、WASM 服务、本地 Web 只读浏览和确定性检索。"),
    ("PROPOSAL.md", "concepts/product-scope", "产品范围与架构",
     "产品范围是独立引擎与精简 Web 服务，不包含桌面应用。分层为 base、core、"
     "decl/visual/pack、vault/index、agent、nativehost、CLI/MCP；核心零模型零网络，"
     "模型推理、联网检索和向量生成由外部宿主提供。"),
    ("docs/protocol.md", "concepts/protocol-boundaries", "CLI 与 MCP 协议边界",
     "CLI 与 MCP 共享同一 MoonBit 工具字典和 JSON Schema。stdin 每行一个 JSON 请求，"
     "stdout 一个终态响应；未知字段、未知操作和类型错误明确拒绝。MCP 工具名使用 "
     "corridor_ 前缀，写到同一引擎。"),
    ("docs/memory.md", "concepts/memory-model", "分层记忆模型",
     "记忆笔记以 state/memory 为唯一权威，记录包含 scope、layer、importance、emotion、"
     "episodic 和 use_count。memory-prefetch 支持 BM25 与加权排序，weighted 需要显式 now；"
     "memory-candidates 按 core、important、normal 三层给出衰减建议；memory-promote "
     "把高强度判断提升为 episode。"),
    ("docs/dream.md", "concepts/dream-rsi", "梦境 RSI 与笔记",
     "梦境轮次记录在 state/dreams，梦境笔记记录在 state/dream-notes。dream-note-submit "
     "绑定输入页面和记忆哈希与 claims 证据，dream-note-resolve 只允许 retained、rejected "
     "或 applied；笔记只提案，知识应用走 commit，记忆应用走 memory-*。"),
    ("docs/retrieval.md", "concepts/retrieval", "检索子系统",
     "检索是派生层：MoonRetrieve 分块 BM25 与算法向量按 RRF 融合，缓存位于 .corridor。"
     "search 返回页面命中，retrieve 返回块级命中，context 在预算内装配。检索不是知识权威，"
     "不自动写 wiki，也不把工作区投影纳入全局检索。"),
    ("docs/acceptance.md", "concepts/workspace-layer", "工作区分层",
     "工作区分层包含 workspaces/<id>/memory、wiki、claims、manifest.json 和 "
     "workspaces/index.mbt.md。memory 是 state/memory 的导出，wiki 是全局页面投影，"
     "全部是派生物，不进入全局目录、检索和 pack；删除后全局 verify 仍然通过。"),
    ("docs/ci.md", "concepts/verification", "验证分级",
     "每次改动使用 quick_verify 运行 moon check、moon test 和聚焦 e2e；完整 verify.sh "
     "包含 249 条 mutation 与 WASM/Web 面，只在发布、夜间和 CI 执行。失败不得部分发布，"
     "事务恢复、幂等重试和外部编辑冲突都有测试。"),
    ("SKILL.md", "concepts/agent-skill", "Agent 使用指南",
     "Agent 通过 CLI 或 MCP 连接 MemoryCorridor，先发现工具字典，再按两步工单摄入知识。"
     "检索用 search、retrieve 和 memory-prefetch；维护用 memory-candidates、memory-promote、"
     "dream-note-submit 和 workspace-wiki-plan。模型判断在宿主，引擎只校验和记账。"),
    ("specs/engine/design.md", "concepts/design-baselines", "不可偏离的设计基线",
     "知识库基线包括文学化 index.mbt.md、LLM 两步工单、OKF 互操作和派生检索。"
     "记忆与知识权威分离，工作区投影是派生层；生成页面不能成为第二权威。"),
]

MEMORIES = [
    ("knowledge-global", "fact",
     "MemoryCorridor 的知识库保持全局通用，工作区 wiki 只是从全局页面派生的投影。",
     ["生成项目 wiki 时"], 0.9, {"valence": 0.7, "arousal": 0.5, "dominance": 0.6}),
    ("memory-authority", "constraint",
     "记忆本体只存放在 state/memory，workspaces 下的 memory 是导出视图，不能成为第二权威。",
     ["修改记忆存储时"], 0.95, {"valence": 0.2, "arousal": 0.8, "dominance": 0.8}),
    ("verify-tier", "decision",
     "每次改动运行 quick_verify，完整 verify 只在发布、夜间和 CI 执行。",
     ["提交前验证时"], 0.85, {"valence": 0.4, "arousal": 0.3, "dominance": 0.7}),
    ("isolation", "preference",
     "工作区 wiki 生成必须保证不进入全局目录、检索和 pack，删除 workspaces 后全局 verify 仍然通过。",
     ["生成工作区投影时"], 0.9, {"valence": 0.5, "arousal": 0.6, "dominance": 0.5}),
]

KNOWLEDGE_QUERIES = [
    ("全局知识库 工作区 派生 投影", "concepts/project-overview"),
    ("记忆 本体 layer episode 加权", "concepts/memory-model"),
    ("梦境 笔记 RSI 提案", "concepts/dream-rsi"),
    ("BM25 分块 向量 RRF 检索", "concepts/retrieval"),
    ("MCP CLI JSON Schema 工具", "concepts/agent-skill"),
    ("quick_verify 完整 verify 门禁", "concepts/verification"),
]

MEMORY_QUERIES = [
    ("记忆本体 第二权威 导出", "memory-authority"),
    ("quick_verify 发布 夜间", "verify-tier"),
    ("全局目录 检索 pack 隔离", "isolation"),
    ("知识库 全局通用 工作区 投影", "knowledge-global"),
]


def call(vault: Path, op: str, **fields):
    request = {"op": op, "vault": str(vault), **fields}
    started = time.perf_counter()
    completed = subprocess.run(
        [str(EXE)], input=json.dumps(request) + "\n",
        capture_output=True, text=True, timeout=120, check=True)
    elapsed = time.perf_counter() - started
    value = json.loads(completed.stdout)
    if not value.get("ok"):
        raise RuntimeError(f"{op}: {value.get('error')}")
    return value["result"], elapsed


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not EXE.is_file():
        raise SystemExit(f"cli not found: {EXE}; run `moon build --target native cli`")

    result = {"project": str(PROJECT), "sources": len(DOCS), "queries": {}}
    latencies = {"ingest": 0.0, "workspace_plan": 0.0, "wiki_generate": 0.0,
                 "memory_export": 0.0, "rebuild": 0.0}
    knowledge_latency = []
    memory_bm25_latency = []
    memory_weighted_latency = []
    knowledge_hits = 0
    chunk_hits = 0
    memory_bm25_hits = 0
    memory_weighted_hits = 0

    with tempfile.TemporaryDirectory(prefix="memorycorridor-project-wiki-") as temp:
        vault = Path(temp)
        call(vault, "init", purpose="以 MemoryCorridor 项目自身文档生成工作区 wiki")
        ingest_started = time.perf_counter()
        for index, (relative, page_id, title, summary) in enumerate(DOCS):
            source = PROJECT / relative
            target = vault / "raw" / "project" / f"{index:02d}-{source.name}"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
            scan, _ = call(vault, "scan")
            assert scan["orders"], (relative, scan)
            order = scan["orders"][0]
            context, _ = call(vault, "context", order=order)
            token = context["context_token"]
            call(vault, "analysis-submit", order=order, context_token=token,
                 analysis={"entities": [], "concepts": [title], "conflicts": [],
                           "summary": summary})
            draft, _ = call(vault, "draft-submit", order=order, context_token=token,
                            pages=[{"id": page_id, "kind": "concept", "title": title,
                                    "sources": [f"raw/project/{target.name}"],
                                    "tags": ["MemoryCorridor", "项目自身"],
                                    "body": f"## {title}\n\n{summary}"}])
            call(vault, "commit", order=order, context_token=token,
                 pages=draft["pages"],
                 at=f"2026-11-20T10:{index:02d}:00Z")
        latencies["ingest"] = (time.perf_counter() - ingest_started) * 1000
        call(vault, "rebuild")
        pages_result, elapsed = call(vault, "list-pages")
        latencies["rebuild"] = elapsed * 1000
        result["knowledge_pages"] = len(pages_result)
        result["knowledge_page_ids"] = [row["id"] for row in pages_result]

        workspace, _ = call(vault, "workspace-open", path=str(PROJECT),
                            at="2026-11-20T11:00:00Z")
        ws = workspace["id"]
        memory_ids = {}
        for index, (key, kind, text, conditions, importance, emotion) in enumerate(MEMORIES):
            row, _ = call(vault, "memory-submit", workspace=ws, kind=kind,
                          scope="project", text=text, conditions=conditions,
                          sources=[], importance=importance, emotion=emotion,
                          at=f"2026-11-20T11:{index + 1:02d}:00Z", key=key)
            memory_ids[key] = row["id"]
        # Promote the strongest project constraint: the ledger should show the
        # episode, while the old note remains as superseded history.
        promoted, _ = call(vault, "memory-promote", workspace=ws,
                           id=memory_ids["memory-authority"],
                           at="2026-11-20T11:10:00Z")
        memory_ids["memory-authority"] = promoted["record"]["id"]
        _, elapsed = call(vault, "memory-export", workspace=ws)
        latencies["memory_export"] = elapsed * 1000
        result["memory_notes"] = len(MEMORIES)
        result["episode_id"] = memory_ids["memory-authority"]

        plan_started = time.perf_counter()
        plan, _ = call(vault, "workspace-wiki-plan", workspace=ws,
                       namespace="project", limit=500)
        latencies["workspace_plan"] = (time.perf_counter() - plan_started) * 1000
        result["workspace_pages"] = len(plan["pages"])
        result["workspace_claims"] = len(plan["claims"])

        wiki_started = time.perf_counter()
        generated = subprocess.run(
            ["python3", "-I", str(WIKI), "--vault", str(vault),
             "--workspace", ws, "--namespace", "project"],
            capture_output=True, text=True, check=True)
        latencies["wiki_generate"] = (time.perf_counter() - wiki_started) * 1000
        wiki_summary = json.loads(generated.stdout)
        result["wiki_written"] = wiki_summary["written"]
        wiki_dir = vault / "workspaces" / ws / "wiki"
        claims_dir = vault / "workspaces" / ws / "claims"
        result["wiki_files"] = len(list(wiki_dir.glob("*.md")))
        result["claim_files"] = len(list(claims_dir.glob("*.json")))
        result["wiki_bytes"] = sum(path.stat().st_size for path in wiki_dir.glob("*.md"))
        result["memory_files"] = len(list((vault / "workspaces" / ws / "memory").glob("*.md")))
        result["index_bytes"] = (vault / "workspaces" / "index.mbt.md").stat().st_size
        result["manifest"] = (vault / "workspaces" / ws / "manifest.json").is_file()
        # The projection must not move the global catalog fingerprint.
        fingerprint_before, _ = call(vault, "status")
        assert fingerprint_before["fingerprint"] == plan["fingerprint"]
        result["catalog_unchanged"] = True

        knowledge_top5 = []
        for query, expected in KNOWLEDGE_QUERIES:
            hits, elapsed = call(vault, "search", query=query, limit=5)
            ids = [row["id"] for row in hits["hits"]]
            knowledge_latency.append(elapsed * 1000)
            if expected in ids[:5]:
                knowledge_hits += 1
            knowledge_top5.append({"query": query, "expected": expected,
                                   "top": ids[:5], "hit": expected in ids[:5]})
        chunk_rows = []
        chunk_latency = []
        for query, expected in KNOWLEDGE_QUERIES:
            retrieved, elapsed = call(vault, "retrieve", query=query, limit=5)
            pages = [row["page"] for row in retrieved["hits"]]
            chunk_latency.append(elapsed * 1000)
            hit = expected in pages[:5]
            chunk_hits += int(hit)
            chunk_rows.append({"query": query, "expected": expected,
                               "top_pages": pages[:5], "hit": hit})
        result["queries"]["chunks"] = {
            "hit_at_5": f"{chunk_hits}/{len(KNOWLEDGE_QUERIES)}",
            "latency_ms": round(sum(chunk_latency) / len(chunk_latency), 2),
            "rows": chunk_rows,
        }
        result["queries"]["knowledge"] = {
            "hit_at_5": f"{knowledge_hits}/{len(KNOWLEDGE_QUERIES)}",
            "latency_ms": round(sum(knowledge_latency) / len(knowledge_latency), 2),
            "rows": knowledge_top5,
        }

        memory_bm25_rows = []
        memory_weighted_rows = []
        for query, key in MEMORY_QUERIES:
            brief, elapsed = call(vault, "memory-prefetch", workspace=ws,
                                  query=query, limit=5)
            memory_bm25_latency.append(elapsed * 1000)
            ids = [row["id"] for row in brief["notes"]]
            hit = memory_ids[key] in ids[:5]
            memory_bm25_hits += int(hit)
            memory_bm25_rows.append({"query": query, "expected_key": key,
                                     "top": ids[:5], "hit": hit})
            weighted, elapsed = call(vault, "memory-prefetch", workspace=ws,
                                     query=query, limit=5, rank="weighted",
                                     now="2026-11-26T00:00:00Z")
            memory_weighted_latency.append(elapsed * 1000)
            weighted_ids = [row["id"] for row in weighted["notes"]]
            weighted_hit = memory_ids[key] in weighted_ids[:5]
            memory_weighted_hits += int(weighted_hit)
            memory_weighted_rows.append({"query": query, "expected_key": key,
                                         "top": weighted_ids[:5], "hit": weighted_hit,
                                         "tiers": [row.get("tier") for row in weighted["notes"]]})
        result["queries"]["memory_bm25"] = {
            "hit_at_5": f"{memory_bm25_hits}/{len(MEMORY_QUERIES)}",
            "latency_ms": round(sum(memory_bm25_latency) / len(memory_bm25_latency), 2),
            "rows": memory_bm25_rows,
        }
        result["queries"]["memory_weighted"] = {
            "hit_at_5": f"{memory_weighted_hits}/{len(MEMORY_QUERIES)}",
            "latency_ms": round(sum(memory_weighted_latency) / len(memory_weighted_latency), 2),
            "rows": memory_weighted_rows,
        }
        result["timings_ms"] = {key: round(value, 2) for key, value in latencies.items()}

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print("project wiki benchmark")
        print(json.dumps({
            "knowledge_pages": result["knowledge_pages"],
            "workspace_pages": result["workspace_pages"],
            "wiki_files": result["wiki_files"],
            "memory_files": result["memory_files"],
            "knowledge_recall_at_5": result["queries"]["knowledge"]["hit_at_5"],
            "chunk_recall_at_5": result["queries"]["chunks"]["hit_at_5"],
            "memory_bm25_recall_at_5": result["queries"]["memory_bm25"]["hit_at_5"],
            "memory_weighted_recall_at_5": result["queries"]["memory_weighted"]["hit_at_5"],
            "timings_ms": result["timings_ms"],
        }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
