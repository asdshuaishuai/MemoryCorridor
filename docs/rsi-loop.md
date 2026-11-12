# 递归自我改进（RSI）：过程设计，不是本体设计

> 边界说明：本页只讨论 **RSI（递归自我改进的过程）**，参考三篇论文：
> RSI-Anything（arXiv 2610.13912）、Harness²（arXiv 2610.14224）、
> Dream-RSI（arXiv 2609.14858）。它与「数字存在本体」（SoulFlow 那条线，见
> [soulflow.md](soulflow.md)）是**两个不同的问题域**：RSI 回答「改进如何发生」，
> 本体论回答「改进的对象是谁、跨驱动/重启如何仍是同一个它」。两页不混写。

## 一、三篇 RSI 各自解决什么

| 工作 | 机制 | 对引擎的要求 |
| --- | --- | --- |
| **RSI-Anything** | 预测世界模型指导动作与学习数据选择；策略/工作流更新后，经过**组件与兼容性检查**才保留；跨版本累计提升 | 一个可验证的「保留」闸门：更新前后必须可比较，且退化必须被拒绝 |
| **Harness²** | 任务级递归：Propose → Probe → Compose，对比式修正无需 ground-truth verifier；跨任务抽取经验更新「改进 harness」 | 轮次化的提案/试验/结论记录，跨轮可对比（轮次账本 + 前后指标） |
| **Dream-RSI** | 用历史发现树当 replay simulator，在模拟器里低成本「做梦」评估探索策略，再上线并扩充模拟器 | 一个只读的「梦境报告」：在已实现状态上计算机会与指标，不付在线试错成本 |

共同点：**RSI 不定义本体，它定义的是「在某个持久状态上反复提案-评估-保留」的循环**。
循环需要四件东西：可描述的状态、确定性评估器、保留门禁、轮次账本。

## 二、MemoryCorridor 已具备的 RSI 地基（续二十八）

| RSI 要素 | 本工程实现 |
| --- | --- |
| 可描述的状态 | 目录指纹（每笔提交绑定 baseline）；页面内容版本锁；向量/来源版本 |
| 确定性评估器 | `dream-plan`：八项 metrics（lint 错误/警告、冗余页、未覆盖来源、漂移页、稀疏主题、缺失向量）+ 排序机会集 + 跨 limit 稳定 `report_hash` |
| 保留门禁 | `dream-close(retained)`：lint 错误与未覆盖来源相对轮次基线不得回退（`dream_compat_lint_regression` / `dream_compat_evidence_loss`） |
| 轮次账本 | `state/dreams/<id>.json`（指纹/策略/机会哈希/前后 delta）+ `dream-list`；事件 `dream-open`/`dream-close` 身份绑定 |

这半场是「静」的：引擎测量、记账、守门；**不生成任何改写**——改写属于外部驱动。

## 三、「动」的任务出箱（续二十九已交付）

RSI 的循环要真的转起来，外驱动需要知道「现在该处理什么、做到哪、欠什么答案」。
本工程已有同类先例：`embedding-plan → embedding-submit`、`extraction-submit`、
`provider-job-*`。续二十九把同样的「结构化任务出箱」用于知识改进：

```
dream-work-open   {baseline, at, limit?}     # 从当前机会集生成任务；按机会 key 去重；
                                             # max_pending 背压（默认 10，超限拒绝）
dream-work-claim  {id, driver, lease_until, at}
dream-work-complete {id, result, at}         # 只收结构化提案：
                                             #   judgments: {机会 key → 结构化回答}
                                             #   proposals: [{page, kind, staged_path}]
dream-work-fail   {id, reason, at}
dream-work-list                              # 队列视图（含背压计数/过期租约）
```

约束：
1. **引擎不评测语义、不写文案**：任务只带结构化字段；提案只收结构，页面文本由驱动
   在宿主侧生成，应用仍走既有 commit。
2. **AI 缺席是降级不是崩溃**：超时/失败留痕；未完成的工作项或未回答的 `judgments`
   使 `dream-close(retained)` 被 `dream_compat_unresolved` 拒绝——**不能把“没回答”
   当成“认可”**。
3. **驱动可替换**：租约过期允许新驱动接管；工作项记录 `driver` 身份，轮次
   `outcome` 汇总 `drivers` 集合，供跨驱动经验比较。
4. **确定性**：任务排序、机会 key、背压计数全部由引擎计算，不依赖模型。
5. **知识指纹**：工作入箱只改变 state 簿记，因此轮次另存「知识指纹」（排除 state 条目）
   作为开箱校验基准；页面/来源漂移才会使轮次过期。
6. **簿记噪声不入箱**：`cache_missing`/`cache_invalid`/`dream_round_stale` 等引擎内部
   告警保留在 metrics，但不会变成改进任务（写任务会再次触发它们，形成自指噪声）。

## 三·五、到期契约（续三十一已交付）

宿主不再猜「何时该开轮」：`dream-policy` 持久化 `due_after_seconds` /
`min_opportunities` / `max_open_rounds`，`dream-due {at}` 汇总开轮数、待处理工单、
机会数与最近关闭时间，返回 `{due,reasons,next_due_in_seconds}`。冷却算术只接受严格
`YYYY-MM-DDTHH:MM:SSZ`；非规范时间按无冷却处理并在文档标注。引擎仍无线程/时钟，
调度器在宿主侧。

## 四、验收草案（RSI 侧）

- `dream_work_wbtest`：机会 key 去重、背压上限、租约接管、未清 judgments 门禁。
- `dream_work_e2e.py`：due/open → peek → claim(A) → 过期 → claim(B) 接管 →
  complete（含 judgments）→ 宿主 commit 应用 → close(retained) 通过；
  删一条 judgment → retained 被拒；任务失败 → 轮次保持 open，可重试；
  pack/unpack 后工作项可读；只读 op 字节不变。
- mutation：背压失效、欠账门禁失效、租约接管失效、任务去重失效。
- 三面计数同步，MCP 传输扫描自动覆盖。

## 五、明确不做

- 不在引擎内跑模型/世界模型/提示词（RSI-Anything 的预测器由宿主提供）；
- 不引入 daemon/线程：宿主 tick；引擎只判「到期/背压/欠账」；
- 不把「保留」实现成自动合并：候选只是提议，应用必须走既有写事务；
- 本体连续性（身份锚、治理）不属于 RSI 过程，见 [soulflow.md](soulflow.md) 与
  单独的后续续条目；本页不宣称。