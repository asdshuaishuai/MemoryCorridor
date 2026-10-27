# 多领域检索基线

## HumanGate 质量信号

`quality-audit` 在已验证图快照上产生非阻塞审核债务：`orphan_page`、`sparse_tag`、已登记但没有活跃知识页依赖的 raw 来源 `unreferenced_source`、仅有 legacy raw 锚点的页面 `legacy_evidence_anchor`、raw 原文锚点漂移/撤销/无法核验的页面 `invalid_evidence_anchor`，entity/concept/synthesis 页面缺少有效 `state/evidence/` 证据时的 `missing_evidence`，以及已有有效 claim 但正文区间没有覆盖全文时的 `evidence_coverage_gap`。source-summary 兜底页不触发这些页面级证据债务。每条审核保存问题定位和质量输入指纹；`review-list` 返回 `input_status`，输入变化后旧审核明确标为 `stale`，兼容旧记录标为 `unknown`。`stats/status.evidence.coverage.sources` 同时提供 direct/stale 依赖页和 `provenance_v1` 支持状态，帮助宿主识别来源失效或缺少证据的结构性问题；这仍不是语义质量分数。raw、purpose、页面和证据记录共同构成质量输入指纹；审核决定、事件和向量缓存不改变同一输入的重放结果，输入发生变化会生成新的快照审核记录。事实证据仍由外部 Agent 或人工提交，引擎只验证页面版本、来源和 UTF-8 正文区间，不判断语义蕴含。

`status`/`stats` 的 `evidence.coverage` 同时提供可重放的覆盖报告：每个页面报告正文 UTF-8 字节数、有效 claim 数、exact/legacy/invalid raw 锚点计数、有效区间并集字节数、万分比覆盖率、区间重叠数量和是否完整覆盖，并给出不含语义判断的 `provenance` 分级；每个 raw 来源报告同样的锚点计数、有效/无效 claim 与覆盖到的页面。区间并集用于避免重复计算重叠正文，覆盖率只衡量提交的字节范围，锚点强度也不能证明 claim 在语义上蕴含于来源。`evidence-replace` 将旧记录保留为 `superseded_by` 审计历史，但当前报告只计算未替换记录。来源撤销或页面版本变化后，记录保留但对应 claim 会进入无效统计。

scripts/multidomain_eval.py 用四个独立来源和四个知识页建立物理、医学、软件、食品领域的真实 native 工单闭环。固定问题覆盖中文和英文关键词，检查 top-3 召回、上下文来源绑定、正文 UTF-8 区间和不同预算下的装配上限。

运行：

    python3 scripts/multidomain_eval.py

报告写入 docs/multidomain-quality-report.json。它测量的是确定性分词、排名和来源装配，不包含外部模型生成、不判断事实正确性，也不代表任意资料的语义召回率。预算样本只统计块内引用与正文的 UTF-8 字节。
