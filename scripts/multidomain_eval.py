#!/usr/bin/env python3
"""Deterministic multi-domain retrieval and context-cost baseline on native vaults."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"


def call(root, op, **fields):
    run = subprocess.run(
        [str(EXE)],
        input=json.dumps({"op": op, "vault": str(root), **fields}, ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=30,
    )
    value = json.loads(run.stdout)
    assert value["ok"], value
    return value["result"]


domains = [
    {
        "source": "raw/physics.md",
        "page": "concepts/physics-energy",
        "title": "光合作用中的能量转换",
        "terms": "光合作用 叶绿体 光能 化学能",
        "body": "光合作用在叶绿体中把光能转换为化学能，并通过电子传递形成能量载体。该页保留实验来源和版本证据。",
    },
    {
        "source": "raw/medicine.md",
        "page": "concepts/medicine-vaccine",
        "title": "疫苗与免疫记忆",
        "terms": "疫苗 免疫记忆 抗体 免疫系统 antibody",
        "body": "疫苗训练免疫系统形成免疫记忆，后续遇到相同抗原时可以更快地产生抗体。The antibody response is evidence-bound；结论需要区分实验和临床证据。",
    },
    {
        "source": "raw/software.md",
        "page": "concepts/software-vector",
        "title": "暴力向量检索",
        "terms": "暴力向量 余弦相似度 向量空间 检索后端 vector backend",
        "body": "暴力向量检索扫描同一向量空间中的记录并计算余弦相似度；a Vector backend can be replaced independently from model supply。",
    },
    {
        "source": "raw/food.md",
        "page": "concepts/food-fermentation",
        "title": "发酵温度与酵母活性",
        "terms": "发酵 温度 酵母 活性 面团",
        "body": "发酵温度会影响酵母活性和面团膨胀速度；记录温度、时间和原料比例才能复现实验。",
    },
]
questions = [
    ("光合作用", "concepts/physics-energy", "raw/physics.md"),
    ("免疫记忆", "concepts/medicine-vaccine", "raw/medicine.md"),
    ("余弦相似度", "concepts/software-vector", "raw/software.md"),
    ("发酵温度", "concepts/food-fermentation", "raw/food.md"),
    ("vector backend", "concepts/software-vector", "raw/software.md"),
    ("antibody", "concepts/medicine-vaccine", "raw/medicine.md"),
]

with tempfile.TemporaryDirectory(prefix="corridor-multidomain-") as work:
    root = Path(work)
    call(root, "init", purpose="多领域检索与来源装配基线")
    for domain in domains:
        (root / domain["source"]).parent.mkdir(parents=True, exist_ok=True)
        (root / domain["source"]).write_text(domain["terms"] + "\n" + domain["body"] + "\n")

    orders = call(root, "scan")["orders"]
    for order in orders:
        context = call(root, "context", order=order)
        domain = next(domain for domain in domains if domain["source"] == context["order"]["source"])
        token = context["context_token"]
        call(root, "analysis-submit", order=order, context_token=token,
             analysis={"entities": [], "concepts": domain["terms"].split(), "conflicts": [], "summary": "fixture"})
        staged = root / "staging" / order / "page.md"
        staged.parent.mkdir(parents=True, exist_ok=True)
        staged.write_text(
            "---\ntype: concept\ntitle: " + json.dumps(domain["title"], ensure_ascii=False) +
            "\nsources: [" + json.dumps(domain["source"]) + "]\n---\n" + domain["body"] + "\n"
        )
        call(root, "commit", order=order, context_token=token,
             pages=[{"id": domain["page"], "path": "wiki/" + domain["page"] + ".md",
                     "staged": str(staged.relative_to(root))}], at="2026-10-16")

    rows = []
    for query, expected, source in questions:
        result = call(root, "search", query=query, limit=3, budget=512, hops=0)
        hits = [hit["id"] for hit in result["hits"]]
        blocks = [block for block in result["context"]["blocks"] if block["id"] == expected]
        assert hits and expected in hits, (query, hits)
        assert len(blocks) == 1 and source in blocks[0]["sources"], (query, blocks)
        assert blocks[0]["body_start"] < blocks[0]["body_end"]
        rows.append({
            "query": query,
            "expected": expected,
            "hits": hits,
            "recall_at_3": expected in hits,
            "source_attached": source in blocks[0]["sources"],
            "context_used": result["context"]["used"],
        })

    budgets = {}
    for budget in [64, 128, 256, 512, 1024]:
        result = call(root, "search", query="检索", limit=10, budget=budget, hops=0)
        used = result["context"]["used"]
        assert used <= budget
        budgets[str(budget)] = {"used": used, "blocks": len(result["context"]["blocks"])}
    call(root, "verify")

report = {
    "date": "2026-10-16",
    "dataset": "four owned deterministic domain fixtures; native ingestion and retrieval",
    "question_count": len(rows),
    "recall_at_3": sum(row["recall_at_3"] for row in rows) / len(rows),
    "source_attachment_rate": sum(row["source_attached"] for row in rows) / len(rows),
    "questions_sha256": hashlib.sha256(json.dumps(questions, ensure_ascii=False).encode()).hexdigest(),
    "budget_samples": budgets,
    "scope": "retrieval/provenance and UTF-8 budget baseline; no model quality or semantic entailment claim",
    "results": rows,
}
output = REPO / "docs/multidomain-quality-report.json"
output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({key: value for key, value in report.items() if key not in {"results", "budget_samples"}}, ensure_ascii=False, indent=2))
