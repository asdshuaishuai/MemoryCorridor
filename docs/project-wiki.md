# 以项目自身为例：工作区 wiki 生成与召回实测

本文件记录一次可复现的能力测试：把 MemoryCorridor 自己的项目文档作为
`raw/project/` 来源，走完整的两步知识摄入，然后以本仓库路径注册工作区，
导出记忆并生成工作区 wiki。测试脚本是
[`scripts/project_wiki_bench.py`](../scripts/project_wiki_bench.py)。

这不是模型质量评测：引擎零模型，脚本用**确定性的宿主侧摘要**代替外部 LLM
生成的 analysis/page 文本。它验证的是摄入、目录、检索、记忆、投影和隔离
这条工程链路，以及当前实现的实际耗时；换成真实模型只改变摘要文本，不改变
这些边界。

## 方法

- 输入：`README.md`、`PROPOSAL.md`、`docs/protocol.md`、`docs/memory.md`、
  `docs/dream.md`、`docs/retrieval.md`、`docs/acceptance.md`、`docs/ci.md`、
  `SKILL.md`、`specs/engine/design.md` 共 10 份项目文档。
- 每份文档依次执行 `scan → context → analysis-submit → draft-submit → commit`；
  每个概念页只引用自己的 raw 来源，未提交 source-summary 时由引擎生成来源
  兜底页。因此最终知识页为 10 个概念页 + 10 个来源页 = 20 页。
- 工作区路径使用本仓库真实绝对路径（`workspace-open`），写入 4 条项目记忆
  （3 条普通/约束/偏好 + 1 条高重要性约束提升为 episode），再执行
  `memory-export`、`workspace-wiki-plan(namespace="project")` 和
  `scripts/workspace_wiki.py`。
- 召回 query 见脚本；知识检索检查 `search`/`retrieve` 的 top-5 是否包含预期
  页面，记忆检查 `memory-prefetch` 的 BM25 与 weighted top-5 是否包含预期 key。
- 全程临时 vault，不修改本仓库；生成后断言全局目录指纹不变。

## 实测结果（2026-11-26，Apple M4 arm64）

| 指标 | 结果 |
| --- | --- |
| 输入来源 | 10 份项目文档 |
| 知识页 | 20（10 概念 + 10 来源页） |
| 工作区投影页 | 20 |
| 生成 wiki / claims 文件 | 20 / 20 |
| 工作区记忆导出 | 4 条（含 1 条 episode） |
| wiki 总字节 | 12,602 B |
| `workspaces/index.mbt.md` | 631 B |
| 摄入总耗时（10 轮 scan→commit） | 2.3–2.8 s（多次运行） |
| workspace-wiki-plan | 21–27 ms |
| 生成 wiki/claims/manifest/index | 65–81 ms |
| memory-export | 22–29 ms |
| 知识 `search` 召回@5 | 6/6 |
| 块级 `retrieve` 召回@5 | 6/6 |
| 记忆 BM25 召回@5 | 4/4 |
| 记忆 weighted 召回@5 | 4/4 |
| 知识 search / retrieve 平均时延 | 36.4 ms / 27.0 ms |
| 记忆 BM25 / weighted 平均时延 | 22.9 ms / 23.2 ms |
| 全局目录指纹变化 | 无 |

摄入耗时包含 10 次顺序 commit 的候选目录编译检查；它不是大库吞吐基准。
生成耗时包含从模板写 wiki、claims、manifest 与索引，重复运行对相同内容零写。

## 召回查询（脚本内固定）

知识：

- `全局知识库 工作区 派生 投影` → `concepts/project-overview`
- `记忆 本体 layer episode 加权` → `concepts/memory-model`
- `梦境 笔记 RSI 提案` → `concepts/dream-rsi`
- `BM25 分块 向量 RRF 检索` → `concepts/retrieval`
- `MCP CLI JSON Schema 工具` → `concepts/agent-skill`
- `quick_verify 完整 verify 门禁` → `concepts/verification`

记忆：

- `记忆本体 第二权威 导出` → `memory-authority`（提升后的 episode）
- `quick_verify 发布 夜间` → `verify-tier`
- `全局目录 检索 pack 隔离` → `isolation`
- `知识库 全局通用 工作区 投影` → `knowledge-global`

## 解释与边界

- 6/6 和 4/4 只说明在这个 20 页、4 条记忆的小样本上，固定查询词与页面/笔记
  文本有足够词元重叠；不代表开放域语义召回质量。真实模型接入后应另做
  语义评测，不能把本表当作模型效果。
- 工作区 wiki 是派生物，不进入全局 `search`/`retrieve`/`pack`；隔离由
  `scripts/workspace_layer_e2e.py` 用派生哨兵和删除恢复单独验证。
- 生成脚本只写 `workspaces/<id>/wiki`、`claims`、`manifest.json` 与
  `workspaces/index.mbt.md`；不写 `wiki/`、不改 `index.mbt.md`。`AGENTS.md`
  标记块仍由宿主项目自行维护。
- 这是单机小样本基线；跨机器、千页级库的时延不能外推。

复现：

```sh
MOON_HOME=$HOME/.moon-pinned \
  $HOME/.moon-pinned/bin/moon build --target native cli
python3 -I scripts/project_wiki_bench.py --json
```

脚本退出码非零即表示摄入、投影、指纹不变或召回断言失败。
