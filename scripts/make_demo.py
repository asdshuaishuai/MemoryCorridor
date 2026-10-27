#!/usr/bin/env python3
"""Build a reviewable sample from this repository's real proposal/license.

The sample covers every layer a reader can exercise: material pages, the
synthesis topic layer `topics` browses, and the memory notes `memory-prefetch`
ranks. Without the last two the demo would return empty responses for them.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("output", type=Path)
args = parser.parse_args()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
process = subprocess.Popen([str(REPO / "_build/native/debug/build/cli/cli.exe")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)


def call(op, **fields):
    process.stdin.write(json.dumps({"op": op, "vault": str(root), **fields}, ensure_ascii=False) + "\n")
    process.stdin.flush()
    value = json.loads(process.stdout.readline())
    assert value["ok"], value
    return value["result"]


call("init", purpose="理解 MemoryCorridor 的编译式知识设计、检索接口和来源维护约束。")
shutil.copyfile(REPO / "PROPOSAL.md", root / "raw/项目方案.md")
shutil.copyfile(REPO / "LICENSE", root / "raw/LICENSE.txt")
call("scan")
for order in call("plan"):
    call("context", order=order["id"])
    call("analysis-submit", order=order["id"], analysis={"entities": [], "concepts": [], "conflicts": [], "summary": "人工整理的真实项目资料参考摘要"})
    declarations = []
    if order["source"] == "raw/项目方案.md":
        summaries = [
            ("concepts/文学化目录", "文学化目录", "# 把目录交给编译器\n\nindex.mbt.md 是经过 MoonBit 编译检查的知识目录，保存稳定标识、路径、来源依赖和内容哈希。知识正文保留在独立 Markdown 文件中。\n\n编译检查类型与声明结构；引擎继续验证文件是否存在、哈希是否一致，以及来源引用是否有效。\n\n## 关联知识\n[[concepts/向量检索|阅读向量检索]] · [[concepts/来源失效|理解来源维护]]"),
            ("concepts/向量检索", "向量检索", "# 可替换的搜索后端\n\n默认后端采用暴力余弦扫描。EmbeddingProvider 负责向量生成接口，VectorSearchBackend 负责检索，两者分别抽象。外部宿主提供模型向量。\n\n不同模型空间、维度和页面版本需要分别验证，旧版本向量不参与当前正文搜索。"),
            ("concepts/来源失效", "来源失效与维护", "# 知识需要持续维护\n\n撤销原始来源后，直接依赖页和经互链传播的依赖页会标记失效。失效页面继续保留以供检查，但不参与关键词与向量检索。\n\n.corridor 只保存可重建缓存。工单、审核决定和事务恢复日志存放在 state 目录。\n\n## 再次编译\n[[concepts/文学化目录|回到文学化目录]]"),
        ]
        for pid, title, body in summaries:
            staged = root / "staging" / order["id"] / (pid.split("/")[-1] + ".md")
            staged.write_text("---\ntype: concept\ntitle: " + title + '\nsources: ["raw/项目方案.md"]\ntags: ["引擎设计"]\n---\n' + body + "\n")
            declarations.append({"id": pid, "path": "wiki/" + pid + ".md", "staged": str(staged.relative_to(root))})
    call("commit", order=order["id"], pages=declarations, at="2026-10-16")

# A synthesis page is the semantic layer `topics` browses, and memory notes are
# the durable judgments `memory-prefetch` ranks. Without them the demo cannot
# show either layer, so a reader of the quickstart sees empty responses.
overview = call("overview-suggest", at="2026-11-03T09:00:00Z")
call("overview-apply", id=overview["id"], text=(
    "---\ntype: synthesis\ntitle: 编译式知识设计\n"
    "sources: [\"raw/项目方案.md\"]\ntags: [\"引擎设计\"]\n---\n"
    "# 编译式知识设计\n\n"
    "MemoryCorridor 把知识目录交给 MoonBit 编译器检查，正文保留在独立 Markdown 文件中，"
    "检索与来源维护由引擎确定性完成。\n\n"
    "## 关联知识\n"
    "[[concepts/文学化目录|文学化目录]] · [[concepts/向量检索|向量检索]] · "
    "[[concepts/来源失效|来源失效与维护]]\n"
), at="2026-11-03T09:30:00Z")

for kind, text, conditions, key in [
    ("preference", "阅读引擎设计时先看文学化目录，再看检索与来源维护",
     ["阅读本项目设计文档时"], "reading-order"),
    ("constraint", "涉及来源的结论必须能回到 raw 原文核对，不能只引用页面正文",
     ["撰写或评审知识页时"], "source-verification"),
    ("decision", "演示 vault 只使用仓库内真实资料，不引入外部样例数据",
     ["构建演示或测试资料时"], "demo-sources"),
]:
    call("memory-submit", kind=kind, scope="workspace", text=text,
         conditions=conditions, sources=[], at="2026-11-03T10:00:00Z", key=key)

# One note bound to a registered source, so `valid` / `source_hashes` and the
# drift detection are visible rather than always empty.
call("memory-submit", kind="fact", scope="workspace",
     text="方案文档给出分期边界；引用其中结论前先回原文核对",
     conditions=["引用方案文档结论时"], sources=["raw/项目方案.md"],
     at="2026-11-03T10:05:00Z", key="proposal-fact")

# An open research topic, so `inbox` shows real pending work instead of an
# always-empty list. The engine only records the queue;联网检索由宿主完成。
call("research-topic", topic="MoonBit 文学化目录的编译期校验边界",
     queries=["文学化目录 编译检查", "index.mbt.md 校验"], at="2026-11-03T10:10:00Z",
     key="literate-boundary")

# Two competing judgments under the same conditions: A5's Autodream keeps both
# sides and marks the group for human confirmation instead of picking a winner.
# Without this pair `memory-conflicts` is always empty in the demo.
call("memory-submit", kind="fact", scope="workspace",
     text="官窑断代的首要依据是胎质致密度",
     conditions=["判断官窑断代依据时"], sources=[], at="2026-11-03T10:25:00Z",
     key="dating-a")
call("memory-submit", kind="fact", scope="workspace",
     text="官窑断代的首要依据是釉层厚度与开片形态",
     conditions=["判断官窑断代依据时"], sources=[], at="2026-11-03T10:26:00Z",
     key="dating-b")

# A reworded duplicate under a different condition, so it is not a conflict: the
# same tokens in different bytes. `memory-candidates` proposes merging it into
# the keeper, which is the other half of Autodream consolidation.
reworded = "官窑记录的器形与釉色特征可以据此核对，包括胎质、釉层厚度与开片形态，便于断代参考"
call("memory-submit", kind="fact", scope="workspace",
     text=reworded.replace("，", "；"),
     conditions=["核对釉色时"], sources=[], at="2026-11-03T10:27:00Z",
     key="reworded-a")
call("memory-submit", kind="fact", scope="workspace",
     text=reworded.replace("，", "、"),
     conditions=["撰写展陈说明时"], sources=[], at="2026-11-03T10:28:00Z",
     key="reworded-b")

# Material that arrives after the topic was frozen is exactly what A5's Diff
# Engine reports: the research topic's frozen inputs no longer match the vault.
# Without this the demo never shows `impact-audit` or `inbox` drift, which are
# the headline surfaces of the change-impact work.
(root / "raw" / "断代依据.md").write_text("官窑断代依据胎质与釉层厚度。\n")
order = call("scan")["orders"][0]
context = call("context", order=order)
call("analysis-submit", order=order, context_token=context["context_token"],
     analysis={"entities": [], "concepts": ["断代依据"], "conflicts": [],
               "summary": "断代依据"})
staging = root / "staging" / order
staging.mkdir(parents=True, exist_ok=True)
(staging / "page.md").write_text(
    "---\ntype: concept\ntitle: 断代依据\n"
    "sources: [\"raw/断代依据.md\"]\n---\n官窑断代依据胎质与釉层厚度。\n"
)
call("commit", order=order,
     pages=[{"id": "concepts/dating", "path": "wiki/concepts/dating.md",
             "staged": f"staging/{order}/page.md"}], at="2026-11-03T10:20:00Z")
audit = call("impact-audit", at="2026-11-03T10:30:00Z")
assert audit["opened"] >= 1, audit
print(root / "state/impacts")

call("view-init")
call("render-view")
# The web service verifies before every read, so the retrieval cache has to be
# built here. Without it `serve.py` answers 409 for every route.
call("rebuild")
print(root / ".corridor/viewer.html")
process.stdin.close()
assert process.wait(timeout=10) == 0