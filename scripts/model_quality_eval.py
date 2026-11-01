#!/usr/bin/env python3
"""Model-generated knowledge quality/cost comparison, measured by the engine.

The sample pages were generated in-session by the assistant model from the
owned source corpus below, then frozen as fixtures: the script replays the
real intake loop (scan -> context -> analysis -> drafts -> commit) twice over
the same sources, differing only in generation strategy —

  A 无锚点: paraphrased pages, no evidence anchors, no cross links on the
    synthesis page, one source left uncited;
  B 精确锚点: pages carry sentences verbatim from the sources; the harness
    locates the quotes and submits exact UTF-8 evidence anchors per page.

Every number reported comes from engine ops (quality-audit debts, evidence
claims, lint, search recall, context estimated_tokens). This measures
retrievability and provenance bookkeeping, not factual correctness of the
generated text: no semantic entailment is claimed.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / "_build/native/debug/build/cli/cli.exe"

SOURCES = {
    "raw/窑口.md": (
        "# 龙泉窑口记录\n\n"
        "哥窑窑址在龙泉大窑村，鼎盛于南宋。\n\n"
        "哥窑以开片釉闻名，紫口铁足是其辨识特征。\n\n"
        "弟窑即龙泉窑，釉色以粉青与梅子青为上。\n\n"
        "梅子青釉需龙窑后段缓冷区烧成，还原气氛充足。\n"
    ),
    "raw/釉料.md": (
        "# 釉料配方记录\n\n"
        "粉青釉以石灰碱釉为基，钾长石约占三成。\n\n"
        "釉灰由石灰石与凤尾草炼制，提供钙助熔。\n\n"
        "粉青呈色依赖铁还原，铁含量约百分之一点五。\n\n"
        "升温过快则釉面提前玻化，开片变粗。\n"
    ),
    "raw/窑变.md": "# 窑变记录\n\n窑变釉在一次烧成中偶然生成，色斑分布不可预设计。\n",
    "raw/工序.md": (
        "# 工序记录\n\n"
        "坯体先经素烧，温度约八百度，便于施釉。\n\n"
        "施釉以浸釉为主，厚釉需三到四次上釉。\n\n"
        "每次上釉后须阴干，阴干不足则釉面开裂。\n\n"
        "复烧入龙窑，一段一千二百八十度还原，后段缓冷出梅子青。\n"
    ),
}

# Strategy B pages: sentences are verbatim source substrings so exact anchors
# can be located; the (body quote, source quote) pairs feed evidence-submit.
STRATEGY_B = {
    "entity/哥窑": {
        "title": "哥窑",
        "sources": ["raw/窑口.md"],
        "tags": ["青瓷", "窑口"],
        "claims": [
            {"body": "哥窑窑址在龙泉大窑村，鼎盛于南宋。", "source": "raw/窑口.md",
             "quote": "哥窑窑址在龙泉大窑村，鼎盛于南宋。"},
            {"body": "哥窑以开片釉闻名，紫口铁足是其辨识特征。", "source": "raw/窑口.md",
             "quote": "哥窑以开片釉闻名，紫口铁足是其辨识特征。"},
        ],
        "body": (
            "哥窑窑址在龙泉大窑村，鼎盛于南宋。\n\n"
            "哥窑以开片釉闻名，紫口铁足是其辨识特征。\n"
        ),
    },
    "concepts/粉青": {
        "title": "粉青釉",
        "sources": ["raw/釉料.md", "raw/窑口.md"],
        "tags": ["青瓷", "釉料"],
        "claims": [
            {"body": "粉青呈色依赖铁还原，铁含量约百分之一点五。", "source": "raw/釉料.md",
             "quote": "粉青呈色依赖铁还原，铁含量约百分之一点五。"},
            {"body": "釉灰由石灰石与凤尾草炼制，提供钙助熔。", "source": "raw/釉料.md",
             "quote": "釉灰由石灰石与凤尾草炼制，提供钙助熔。"},
        ],
        "body": (
            "粉青釉以石灰碱釉为基，钾长石约占三成。\n\n"
            "釉灰由石灰石与凤尾草炼制，提供钙助熔。\n\n"
            "粉青呈色依赖铁还原，铁含量约百分之一点五。\n\n"
            "参见 [[entity/哥窑]] 的窑口背景。\n"
        ),
    },
    "concepts/二次素烧": {
        "title": "二次素烧工序",
        "sources": ["raw/工序.md"],
        "tags": ["青瓷", "工序"],
        "claims": [
            {"body": "坯体先经素烧，温度约八百度，便于施釉。", "source": "raw/工序.md",
             "quote": "坯体先经素烧，温度约八百度，便于施釉。"},
            {"body": "施釉以浸釉为主，厚釉需三到四次上釉。", "source": "raw/工序.md",
             "quote": "施釉以浸釉为主，厚釉需三到四次上釉。"},
        ],
        "body": (
            "坯体先经素烧，温度约八百度，便于施釉。\n\n"
            "施釉以浸釉为主，厚釉需三到四次上釉。\n"
        ),
    },
    "synthesis/青瓷工艺链": {
        "title": "青瓷工艺链",
        "sources": ["raw/工序.md", "raw/窑口.md", "raw/釉料.md"],
        "tags": ["青瓷", "工艺"],
        "claims": [
            {"body": "复烧入龙窑，一段一千二百八十度还原，后段缓冷出梅子青。", "source": "raw/工序.md",
             "quote": "复烧入龙窑，一段一千二百八十度还原，后段缓冷出梅子青。"},
        ],
        "extra": True,
        "body": (
            "从素烧到厚釉再到复烧，青瓷工艺链参见 [[concepts/二次素烧]]、"
            "[[concepts/粉青]] 与 [[entity/哥窑]]。\n\n"
            "复烧入龙窑，一段一千二百八十度还原，后段缓冷出梅子青。\n"
        ),
    },
    "concepts/窑变": {
        "title": "窑变釉",
        "sources": ["raw/窑变.md"],
        "tags": ["青瓷", "釉料"],
        "claims": [
            {"body": "窑变釉在一次烧成中偶然生成，色斑分布不可预设计。", "source": "raw/窑变.md",
             "quote": "窑变釉在一次烧成中偶然生成，色斑分布不可预设计。"},
        ],
        "body": "窑变釉在一次烧成中偶然生成，色斑分布不可预设计。\n",
    },
}

# Strategy A pages: ungrounded paraphrase — key retrieval terms drift away
# (素烧/八百 became 低温预烧), the synthesis page is left unlinked (orphan),
# tags are unique (sparse), and raw/釉料.md is never cited (unreferenced).
STRATEGY_A = {
    "entity/哥窑": {
        "title": "哥窑",
        "sources": ["raw/窑口.md"],
        "tags": ["美学"],
        "body": (
            "这是一处历史悠久的南方名窑，遗存位于浙南山村。\n\n"
            "其器物表面带有天然纹路，口沿与底足呈现独特色泽。\n"
        ),
    },
    "concepts/粉青": {
        "title": "粉青釉",
        "sources": ["raw/窑口.md"],
        "tags": ["美学"],
        "body": (
            "这种釉色温润如玉，是传统审美中的上品。\n\n"
            "它的形成与金属呈色剂和助熔材料有关。\n"
        ),
    },
    "concepts/二次素烧": {
        "title": "二次素烧工序",
        "sources": ["raw/工序.md"],
        "tags": ["美学"],
        "body": (
            "坯体要先在低温下预烧一次，之后再上釉。\n\n"
            "上釉可以分多轮进行，轮次越多釉层越厚。\n"
        ),
    },
    "synthesis/青瓷工艺链": {
        "title": "青瓷工艺链",
        "sources": ["raw/工序.md"],
        "tags": ["美学"],
        "body": (
            "整体流程概括为成型、预烧、上釉与 final 高温烧成四个阶段，"
            "烧成曲线对最终品质影响很大。\n"
        ),
    },
    "concepts/窑变": {
        "title": "窑变釉",
        "sources": ["raw/窑变.md"],
        "tags": ["美学"],
        "body": "这类釉色的斑纹是烧造时的偶然产物，无法事先设计。\n",
    },
}

QUESTIONS = [
    {"query": "粉青釉 呈色", "expected": "concepts/粉青", "source": "raw/釉料.md"},
    {"query": "哥窑 辨识特征", "expected": "entity/哥窑", "source": "raw/窑口.md"},
    {"query": "素烧 温度", "expected": "concepts/二次素烧", "source": "raw/工序.md"},
    {"query": "厚釉 上釉 次数", "expected": "concepts/二次素烧", "source": "raw/工序.md"},
    {"query": "梅子青 龙窑 缓冷", "expected": "synthesis/青瓷工艺链", "source": "raw/窑口.md"},
    {"query": "釉灰 炼制", "expected": "concepts/粉青", "source": "raw/釉料.md"},
]


def batch(requests):
    process = subprocess.run(
        [str(CLI)], input="".join(json.dumps(r, ensure_ascii=False) + "\n" for r in requests),
        capture_output=True, text=True, check=True)
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    assert len(responses) == len(requests), (len(responses), len(requests))
    for r in responses:
        assert r["ok"], r
    return responses


def page_text(id, title, sources, tags, body):
    kind = {"concepts": "concept", "entity": "entity", "synthesis": "synthesis"}[id.split("/")[0]]
    front = {"type": kind, "title": title,
             "sources": json.dumps(sources, ensure_ascii=False)}
    if tags:
        front["tags"] = json.dumps(tags, ensure_ascii=False)
    lines = ["---"] + [f"{k}: {v}" for k, v in front.items()] + ["---", ""]
    return "\n".join(lines) + body


def run_strategy(work, strategy, with_anchors):
    root = Path(work)
    root.mkdir(parents=True, exist_ok=True)
    batch([{"op": "init", "vault": work, "purpose": "模型生成质量对照"}])
    for path, text in SOURCES.items():
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    scanned = batch([{"op": "scan", "vault": work}])[0]["result"]["orders"]
    assert len(scanned) == len(SOURCES), scanned
    orders = {o["source"]: o["id"] for o in batch([{"op": "plan", "vault": work}])[0]["result"]}
    assert len(orders) == len(SOURCES), orders
    context_tokens = 0
    for source, order in sorted(orders.items()):
        context = batch([{"op": "context", "vault": work, "order": order}])[0]["result"]
        # The model-facing intake payload: source text, attached prior pages
        # and purpose — its UTF-8 size is the caller's real input cost.
        context_tokens += len(context["source_text"].encode())
        context_tokens += sum(len(p["text"].encode()) for p in context["pages"])
        context_tokens += len(context["purpose"].encode())
        batch([{"op": "analysis-submit", "vault": work, "order": order,
                "analysis": {"entities": ["哥窑"] if "窑口" in source else [],
                             "concepts": ["粉青", "二次素烧"], "conflicts": [],
                             "summary": f"分析{source}的可锚定事实"}}])
        staging = root / "staging" / order
        staging.mkdir(parents=True, exist_ok=True)
        pages = []
        for i, (pid, page) in enumerate(sorted(strategy.items())):
            # Commit each page exactly once, under its LAST source's order, so
            # earlier orders publish the pages its wikilinks point at.
            if source != sorted(page["sources"])[-1]:
                continue
            staged = staging / f"{i}.md"
            staged.write_text(page_text(pid, page["title"], page["sources"], page.get("tags", []), page["body"]), encoding="utf-8")
            pages.append({"id": pid, "path": f"wiki/{pid}.md", "staged": str(staged.relative_to(root))})
        if pages:
            batch([{"op": "commit", "vault": work, "order": order, "pages": pages, "at": "2026-11-01"}])
    entries = {e["id"]: e for e in batch([{"op": "list-pages", "vault": work}])[0]["result"]}
    evidence_items = 0
    if with_anchors:
        for pid, page in STRATEGY_B.items():
            body = batch([{"op": "read-page", "vault": work, "id": pid}])[0]["result"]["text"]
            body = body.split("---\n", 2)[-1].encode()
            items = []
            for claim in page["claims"]:
                source_bytes = SOURCES[claim["source"]].encode()
                body_start = body.find(claim["body"].encode())
                source_start = source_bytes.find(claim["quote"].encode())
                assert body_start >= 0 and source_start >= 0, (pid, claim)
                items.append({"source": claim["source"], "body_start": body_start,
                              "body_end": body_start + len(claim["body"].encode()),
                              "quote": claim["body"],
                              "source_start": source_start,
                              "source_end": source_start + len(claim["quote"].encode()),
                              "source_quote": claim["quote"]})
            evidence_items += len(items)
            batch([{"op": "evidence-submit", "vault": work, "page": pid,
                    "page_hash": entries[pid]["sha256"], "items": items}])
    batch([{"op": "rebuild", "vault": work}])
    assert batch([{"op": "verify", "vault": work}])[0]["result"]["violations"] == []
    lint = batch([{"op": "lint", "vault": work}])[0]["result"]
    assert lint["status"] == "clean" and lint["errors"] == 0, lint
    audit = batch([{"op": "quality-audit", "vault": work, "at": "2026-11-01"}])[0]["result"]
    debts = {}
    for issue in audit["issues"]:
        debts[issue["predicate"]] = debts.get(issue["predicate"], 0) + 1
    stats = batch([{"op": "stats", "vault": work}])[0]["result"]
    generated_bytes = sum(len(p["body"].encode()) for p in strategy.values())
    searches = batch([{"op": "search", "vault": work, "query": q["query"], "limit": 3} for q in QUESTIONS])
    results = []
    for q, response in zip(QUESTIONS, searches, strict=True):
        result = response["result"]
        hits = [h["id"] for h in result["hits"]]
        blocks = [b for b in result["context"]["blocks"] if b["id"] == q["expected"]]
        attached = bool(blocks) and q["source"] in blocks[0]["sources"]
        results.append({"query": q["query"], "hits": hits[:3],
                        "recall_at_3": q["expected"] in hits, "source_attached": attached})
    evidence = stats["evidence"]
    return {
        "strategy": "B 精确锚点" if with_anchors else "A 无锚点",
        "pages": len(entries), "generated_body_bytes": generated_bytes,
        "context_input_bytes": context_tokens,
        "evidence_items": evidence_items,
        "evidence": evidence,
        "quality_debts": debts, "review_debt": stats["review_debt"],
        "recall_at_3": sum(r["recall_at_3"] for r in results) / len(results),
        "source_attachment_rate": sum(r["source_attached"] for r in results) / len(results),
        "search": results,
    }


def main():
    assert CLI.exists(), "build first: moon build --target native cli"
    with tempfile.TemporaryDirectory(prefix="corridor-model-quality-") as work:
        unanchored = run_strategy(work + "/a", STRATEGY_A, with_anchors=False)
        anchored = run_strategy(work + "/b", STRATEGY_B, with_anchors=True)
    assert unanchored["evidence"]["invalid_claims"] == 0 and anchored["evidence"]["invalid_claims"] == 0
    assert anchored["evidence"]["exact_source_claims"] >= 5 and anchored["evidence"]["valid_claims"] >= 5
    assert unanchored["evidence"]["claims"] == 0
    assert anchored["quality_debts"].get("missing_evidence", 0) == 0
    assert unanchored["quality_debts"].get("missing_evidence", 0) >= 4
    assert unanchored["quality_debts"].get("orphan_page", 0) >= 1
    assert unanchored["quality_debts"].get("unreferenced_source", 0) >= 1
    assert anchored["recall_at_3"] == 1.0 and anchored["source_attachment_rate"] == 1.0
    report = {
        "date": "2026-11-01",
        "dataset": "owned 龙泉青瓷 craft corpus; assistant-model-generated pages frozen as fixtures",
        "pages_sha256": hashlib.sha256(
            json.dumps({"A": STRATEGY_A, "B": STRATEGY_B, "sources": SOURCES},
                       ensure_ascii=False, sort_keys=True).encode()).hexdigest(),
        "question_count": len(QUESTIONS),
        "strategies": {"A_无锚点": unanchored, "B_精确锚点": anchored},
        "scope": "model pages were generated in-session and replayed deterministically; "
                 "engine metrics (provenance, HumanGate debts, recall, token estimates) are "
                 "deterministic measurements; no semantic entailment claim",
    }
    (REPO / "docs/model-quality-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    summary = {k: v for k, v in report.items() if k not in ("strategies",)}
    summary["A_无锚点"] = {k: unanchored[k] for k in
                          ("quality_debts", "recall_at_3", "generated_body_bytes")}
    summary["B_精确锚点"] = {k: anchored[k] for k in
                           ("quality_debts", "recall_at_3", "generated_body_bytes")}
    summary["evidence"] = {"A": unanchored["evidence"], "B": anchored["evidence"]}
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
