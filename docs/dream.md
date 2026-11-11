# 梦境与 RSI（续二十八）

本页记录引擎的「梦境轮次」面。它不是让模型训练模型，而是把**改进轮次**变成
持久、可审计、可重放的引擎记录；AGENTS 边界不变——MoonBit 核心不调模型、
不联网，创意改写由宿主经既有 commit 流程提交。

## 三篇工作 → 本工程落点

| 来源 | 核心机制 | 本工程落点 |
| --- | --- | --- |
| [Dream-RSI](https://arxiv.org/abs/2609.14858) | 把历史发现树当 replay simulator，在模拟器里低成本「做梦」评估探索策略，再上线并扩充模拟器 | `dream-plan`：只读地在**已实现的知识状态**上汇总确定性改进机会与指标；宿主无需付出在线试错成本就能看到「哪里值得改」 |
| [RSI-Anything](https://arxiv.org/abs/2610.13912) | 更新后的策略-模型对要过组件/兼容性检查才保留 | `dream-close` 的 `retained` 门禁：当前 `lint_errors` 与 `uncovered_sources` 相对轮次基线不得增加，否则 `dream_compat_lint_regression` / `dream_compat_evidence_loss` |
| [Harness²](https://arxiv.org/abs/2610.14224) | 任务级 propose/probe/compose + 跨任务经验抽取的持续改进 harness | `state/dreams` 轮次账本 + `dream-list`：每轮绑定指纹、策略、机会哈希与前后 metrics 差值（`outcome.delta`），供跨轮经验汇总 |

三篇仅参考**思想**；未复制任何代码或提示词（净室约束）。

## 数据面

`state/dreams/<id>.json`（id 由 `baseline`/`policy`/`space`/`at` 派生）：

```json
{
  "id": "…64 hex…", "at": "2026-11-11T01:00:00Z",
  "baseline": "…目录指纹…", "policy": {"cosine_floor": 0.995}, "space": null,
  "metrics": {"pages": 2, "stale_pages": 0, "lint_errors": 0, "lint_warnings": 0,
              "redundant_pages": 0, "uncovered_sources": 1, "sparse_topics": 0,
              "missing_vectors": 0},
  "opportunities_hash": "…全量机会集规范哈希…",
  "status": "open", "closed_at": null, "decision": null, "note": null, "outcome": null
}
```

状态机只有 `open → retained | rejected`；关闭后不可重开（同参重放除外）。
事件成对写入 `state/events/dream-open-*` / `state/events/dream-close-*`，路径
绑定记录身份，与其它持久工单同一套目录/事务/pack 规则。

## 一次典型轮次

```sh
# 1. 做梦（只读）
echo '{"op":"dream-plan","vault":"/abs/vault","space":{"id":"demo-v1","dimensions":2}}' | corridor-cli
# 2. 开轮（绑定当前指纹）
echo '{"op":"dream-open","vault":"/abs/vault","baseline":"<fingerprint>",
       "policy":{"cosine_floor":0.995},"at":"2026-11-11T01:00:00Z"}' | corridor-cli
# 3. 宿主经普通 commit/编辑流程应用改进（可多次）
# 4. 收轮：retained 必须通过兼容性门禁；rejected 也记录 outcome
echo '{"op":"dream-close","vault":"/abs/vault","id":"<id>","decision":"retained",
       "at":"2026-11-11T02:00:00Z","note":"dedupe + fill coverage"}' | corridor-cli
# 5. 跨轮经验
echo '{"op":"dream-list","vault":"/abs/vault"}' | corridor-cli
```

## 确定性指标

八项计数全部由现有只读面复合而成，无随机性、无模型：
`pages`/`stale_pages` 来自条目集合；`lint_errors`/`lint_warnings` 与
`redundant_pages` 来自 `lint` 谓词；`uncovered_sources` 为无任何页面引用的
raw；`sparse_topics` 为链接少于两条的综述页；`missing_vectors` 与
`embedding-plan` 同口径（给 `space` 时才有值）。`report_hash` 对全量机会集
规范化哈希，因此不同 `limit` 的读取共享同一报告身份。

## lint

- `dream_round_stale`（warning）：`open` 轮次的 baseline 已不等于当前指纹，
  提示关闭或按新基线重开——轮次经验必须收口，不能悬空。

## 边界

- 引擎只做「机会汇总 + 保留记账 + 门禁」，创意改写、模型推理与成本都由宿主；
- 多机集群阈值仍属外部条件，未宣称；
- 与 `page-redundancy`/`memory-candidates` 同哲学：**候选只是提议，不能自动改写知识**。