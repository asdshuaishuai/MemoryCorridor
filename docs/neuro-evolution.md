# 神经进化子系统：非单调的情感 / 人格 / 成长 / 身体

> 状态：**v1 已实现（续三十）**。已交付快环（有界情感/冲动/关系）、固定窗口离线
> 评估、精英/锦标赛/交叉/排名自适应变异/移民、化石层、最佳检查点与回归回滚、手动
> 回滚，以及 `evo-policy` 默认关闭开关与 23 项封闭参数表。核心零模型、零网络、零
> 时钟；随机性只来自文件内 xorshift128。
>
> 续三十二已补：饱和度检测（连续 3 代无提升 → 变异 ×1.5 + 额外移民 + `evo-saturation`
> 事件）与只读 `evo-checkpoint` / `evo-fossils`。
> 续三十三至三十七已补：主动式 outbox（due/open/complete/fail/list）、送达确认
> `evo-proactive-ack`、过期租约接管、宿主主动驱动。拟人化表达帧与最小 daemon 周期
> 是**固定点**，设计见 [soul-layer.md](soul-layer.md)，尚未实现前不写成已交付。
> 未实现（明确延后，见 §十二/§十三）：独立 `checkpoint.json` 与 `evaluation/<gen>.json`、
> 场景轮换调度器、批量 observe、NEAT/拓扑变异、语言头、LLM 标注者。
> 定位：本子系统是**记忆/资料系统的放大器与主动性调度层**，不是 SoulFlow 灵魂本体的复刻。
>
> 目标：让「情感冲动、人格、成长、身体」这些**慢变量**由本地计算与持续进化驱动，
> 不把它们的控制权交给 LLM。LLM 最多是可选的标注者/评审者，**不是必需环节**。
> 硬约束：**不能都是好的**——系统必须能变差、会淘汰、会回滚，且把失败当作一等状态。

## 一、参考来源与许可（只借鉴思想/模式）

| 来源 | License | 借鉴内容（本次设计采用） |
| --- | --- | --- |
| RSIGame（arXiv 2609.39045，`WenyiWU0111/RSIGame`） | 仅思想 | 局部 explore→diagnose→improve；全局质量跟踪、**最佳检查点保留**、**饱和/回归检测**；经验内化（把成功经验固化进生成器） |
| kibotu/NeuralNetworkEvolution（`js/GeneticAlgorithm.js`） | Apache-2.0 | 扁平权重数组基因组；锦标赛选择 k=3；均匀交叉（逐权重 50/50）；**按排名自适应变异幅度**（实际代码 0.1→0.5）；精英保留 + 顶级 10% 免变异；淘汰父代 |
| yushuosun/neural-sandbox（Foragers demo） | MIT | 精英克隆 + 后代高斯变异；**固定窗口评估**；按适应度排序选择；7 感知 → 8 tanh 隐层 → 2 输出的极小控制器形态 |
| muellerberndt/cadence | GPL-3.0 | **只借鉴「快系统执行 + 慢系统修正」思想，不使用任何代码** |

本工程设计不复制上述任何代码；GPL 项目仅作概念参考。

## 二、为什么是进化，而不是「提示词人格」

- 这些层是**控制问题**：状态有边界、有延迟、有资源代价，且没有监督标签。
- LLM 每次调用代价高、非确定、可被提示词改写；把它放在快环里等于把「她此刻什么感受」
  交给一个外部服务。设计上让快环**完全本地、确定、可重放**，LLM 只在慢环可选出现。
- 进化允许**变差**：选择压力、回归、灭绝是系统的一部分，而不是被包装成「持续提升」。
  这正是「不能都是好的」的工程含义。

## 三、总体架构：快环 / 慢环 / 化石层

```
事件（感知/交互/身体指标）
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ 快系统（每次事件，确定、本地、无模型）        │
  │  genome → 小网络 → 状态增量/冲动增益          │
  │  硬边界钳制（状态范围、冲动速率、NaN 拒绝）     │
  └────────────────────────────────────────────┘
        │  记录窗口（固定长度 W 的事件轨迹）
        ▼
  ┌────────────────────────────────────────────┐
  │ 慢系统（宿主 tick，离线、可选择不跑）          │
  │  固定窗口评估 → 多目标适应度 → 选择/交叉/变异   │
  │  全局质量：最佳检查点、回归/饱和检测、回滚       │
  │  经验内化：把稳定有效的基因片段固化进种子库      │
  └────────────────────────────────────────────┘
        │
        ▼
  ┌────────────────────────────────────────────┐
  │ 化石层（永不删除）                            │
  │  灭绝谱系、回归代、失败窗口摘要、触发原因        │
  └────────────────────────────────────────────┘
```

- 快系统每事件只做一次小矩阵乘（12–16 维隐层量级），CPU 微秒级；不依赖网络。
- 慢系统由宿主按「tick」触发（引擎无时钟/无线程）；可完全离线运行。
- 化石层是「不能都是好的」的审计证据：失败不被洗白。

## 三·五、隔离的层级（v1 实测口径）

实现与独立审计把「不影响其他模块」拆成三层，避免含糊：

1. **代码级**：除接线文件（session/tools/schema/records）外，任何模块不出现 evo
   标识符、不调用 evo；生产 dispatch 调用恰一处。静态扫描门禁保证。
2. **行为级**：evo 关闭时六个非 policy op 全部 `evo_disabled`、零写入、零计算，
   指纹与 `index.mbt.md` 字节不变；启用后，`dream-plan`/`page-redundancy`/
   `impact-audit`/`inbox`/`graph`/`stats` 等业务的**非指纹字段逐字段相同**；
   wiki/raw/非 evo 事件零字节变化。
3. **容器级（如实记录，v1 不消除）**：evo 记录作为 `state/` 持久记录，与其它所有
   state 记录一样参与目录指纹、`verify`、`read-log`、`pack` 与缓存失效。因此
   enable→disable 之后，`status` 的 `index_cache`、`search` 的 `cache_rebuilt`、
   `read-log` 行数会与「从未启用」的金库不同——这是持久记录的容器语义，不是 evo
   专用行为耦合。若需要字节级隔离，v2 可把 evo 状态移到 vault 外的 sidecar 存储
   （代价：pack/unpack 不再覆盖它），本设计不宣称已实现。

另外，v1 已修一处真实安全缺口：pending 建议记录损坏时，`evo-policy(enabled=false)`
**仍必须可用**（安全开关豁免，损坏记录只对启用/改参 fail-closed）。

## 四、状态分层（本设计的控制对象）

| 层 | 状态（有界） | 快系统如何更新 | 慢系统进化什么 |
| --- | --- | --- | --- |
| 情感/冲动 | 情感三维 `v/a/d`（连续，[-1,1]）+ 冲动累积器 [0,1] | 事件 → 基因网络输出增量；衰减/基线回归；过阈值产生冲动 | 增益、衰减率、基线、阈值敏感度 |
| 人格 | 4–6 维慢特质（如探索性/稳定性/亲和性/表达性），[-1,1] | 不每事件变；只作为网络的条件输入 | 特质向量本身（逐代可漂移，但受速率上限） |
| 成长 | 每个交互对象的关系向量（信任/熟悉/张力），[0,1] | 交互结果 → 增量，受人格调制 | 学习率、遗忘率、信任恢复曲线 |
| 身体 | 疲劳/压力 [0,1]（来自宿主 CPU/内存/延迟/预算） | 指标 → 低通滤波；疲劳抬高冲动阈值 | 映射权重、恢复速率、阈值抬升斜率 |

**边界不在基因里**：状态钳制、NaN/无穷拒绝、冲动速率上限由引擎硬编码；基因无论怎么
变异都无法关闭它们——这防止「进化出一个坏掉的灵魂」。

## 五、基因组与控制器

- 表示：**扁平 f32 数组**（固定拓扑），便于均匀交叉与逐权重变异。
- 拓扑（初始版本，可配）：
  - 输入：感知 16 维（事件类型 one-hot、显著性、情感刺激、身体 4 维、关系 4 维、上一步情感 3 维）
  - 隐层：12–16 tanh
  - 输出：情感增量 3 + 冲动增益 1 + 行动倾向 3 + 关系增量 1 + 疲劳耦合 1
- 权重初始化：Xavier 均匀；基因组只含权重（初版不含拓扑变异；NEAT 列为后续可选项）。
- 状态更新（快环，确定性）：
  `x' = clamp(x + α·tanh(W_h·h + W_x·x + b))`，冲动 `i' = clamp(i·decay + g·gain)`；
  `decay`、`gain`、`α` 由基因输出调制，但有硬上下限。

## 六、进化算子（具体参数）

| 算子 | 设计值 | 依据 |
| --- | --- | --- |
| 种群规模 | 16（可配 8–32） | 小到可离线跑，大到有选择压力 |
| 精英保留 | 前 17–25%（下限 2） | kibotu 的 35% 偏保守，这里按本项目调低以留探索空间 |
| 免变异保护 | 前 10%（下限 2） | kibotu 实际实现 |
| 选择 | 锦标赛 k=3 | kibotu |
| 交叉 | 均匀逐权重 50/50；交叉占比 ~65% | kibotu |
| 变异 | 逐权重概率 10–15%；幅度按排名 0.1（最优）→0.4（最差）；高斯 σ=幅度/3；权重钳制 [-4,4] | kibotu 的 rank-adaptive 幅度 + 沙盒的高斯变异 |
| 随机移民 | 每代 1–2 个全新基因组 | 防早熟收敛；保证非单调（新血可能更差或更好） |
| 评估窗口 | 固定 W=128 事件（或 3 个会话），另留 **held-out 窗口**（30%） | 沙盒固定窗口 + RSIGame 防过拟合 |
| 代数上限 | 单次 `evo-evolve` 只进 1 代；宿主决定节奏 | 引擎无时钟 |

## 七、适应度：多目标 + 硬约束（「不能都是好的」的核心）

适应度不是单一「越高越好」，而是**带冲突的多目标**，任何基因组都只能在其中取舍：

```
fitness = w_stab·stability + w_resp·responsiveness + w_grow·growth
        + w_nov·novelty
        − c_energy·energy_cost − c_imp·impulse_blowups
        − c_pos·always_positive_penalty − c_flat·flatness_penalty
```

- **stability**：状态不越界、不发散、无 NaN；违者直接死亡（不进下一代）。
- **responsiveness**：受扰动后回到基线的时间与超调（有下界也有上界——过慢/过冲都扣分）。
- **growth**：关系向量在良性交互中的增益（但允许信任下降；下降本身记录为成长事件）。
- **novelty**：行为多样性（与种群均值轨迹的距离）；防止全员同质。
- **energy_cost**：冲动次数/强度、状态更新计算量。
- **impulse_blowups**：单窗口冲动超速率上限的次数。
- **always_positive_penalty**：情感长期贴近上限（「永远开心」）扣分——**不允许系统性
  的正向漂移**；**flatness_penalty** 同理惩罚「永远无波动」。
- **held-out gap**：训练窗口与留出窗口的适应度差 > δ 时整体扣分（RSIGame 的过拟合教训）。

硬约束（不可进化关闭）：状态范围、NaN/无穷、冲动速率、每窗口计算预算。

## 八、非单调机制（显式清单）

1. **多目标冲突**：提高 responsiveness 往往牺牲 stability；无法同时最优。
2. **环境漂移**：每 E 代轮换评估场景（事件分布、身体压力、关系对象），上一代冠军可能
   直接失败；这是「好日子不会一直有」的机制化。
3. **全局回归检测（RSIGame）**：连续 K 代最优适应度低于最佳检查点 δ → 记
   `regression` 事件，种群回滚到最佳检查点（**回滚不是删除**：失败谱系进化石层）。
4. **饱和检测（续三十二已实现）**：连续 3 代 delta ≤ 0 → `evo-saturation` 事件，该代变异幅度 ×1.5、额外 +1 移民，`saturations_total` 累加、streak 清零。
5. **谱系灭绝**：未被选中的基因组死亡（记录谱系与死因）；不设「无限复活」。
6. **负向状态一等公民**：情感为负、信任下降、冲动爆发失败都写入 `decline events`，
   并影响后续动力学（scarring：负向记忆提高相关刺激的增益），不被「正能量」规则抹平。
7. **诚实报表**：`evo-evolve` 返回逐代 delta（含负值）、回归/饱和标记、化石计数——
   验收要求至少观察到一次真实的适应度下降与一次回滚。

## 九、持久化、确定性与可重放

- 记录（`state/evo/`，均参与目录/事务/pack 规则）：
  - `policy.json`（开关、23 项封闭参数、更新时间；默认关闭）
  - `state.json`（情感/冲动/身体/关系、环形窗口、窗口哈希、活跃基因组、最近一步结果）
  - `population.json`（代数、init 身份、成员、检查点、历史、回归/回滚/化石计数、最近评估与进化摘要）
  - `genomes/<id>.json`（扁平 f32 权重、出生代、父代、来源、权重字节哈希）
  - `fossils/<id>.json`（灭绝/回归/手动回滚谱系、死因、适应度与分项、窗口摘要）
  - `events/evo-*`（policy/init/evaluate/evolve/regression/rollback/fossilize）
- 确定性：每代种子 = `sha256(seed + ":" + generation)` 派生 xorshift128；选择/交叉/
  变异/移民全部用同一 PRNG 流；`evo-evolve` 同参重放返回 `replayed:true`；窗口以
  `window_sha256` 绑定，输入变化即拒绝。基因组身份只用 binary32 字节哈希派生，
  不使用 JSON 文本哈希。
- 同种子重放：同一 `seed`、同一策略与同一窗口在两个独立金库中重放，种子基因组、
  首代化石 id 与 `population.json` 逐字节相同；`evo-init` 的同
  `(seed, at, policy_hash)` 重放零写。`scripts/evo_e2e.py` 用双金库对照与指纹不变
  断言固定这两点。
- 快照：pack/unpack 后种群、检查点、化石、历史与窗口步数完整还原，并继续 `evo-observe`。

## 十、与引擎/其它子系统的接口

- v1 op：`evo-policy`（读/设开关与参数）、`evo-init`、`evo-observe`（快环一步）、
  `evo-evaluate`（窗口打分）、`evo-evolve`（一代/回归回滚）、`evo-status`、
  `evo-rollback`（手动回滚）；续三十二补 `evo-checkpoint`（检查点/历史/计数只读）与
  `evo-fossils`（化石列举只读）；续三十三补 `evo-proactive-due/open/complete/fail/list`
  （主动式 outbox：判定、认领、回写、失败与只读列举）；续三十五补
  `evo-proactive-ack`（宿主真正投递后的送达确认）；续三十六让 `open` 接管过期
  claimed 请求（同 id、换 driver/lease、`reclaimed:true`），`due` 区分 pending/expired。
- 与 SoulFlow 线：快环的情感/冲动输出可作为冲动 outbox 的来源。续三十三实现主动式
  outbox：`enabled=true` 时，情感/冲动状态可自主发起一次 LLM 调用——引擎只写结构化
  请求（`evo-proactive-open`），由宿主驱动（`scripts/evo_agent_driver.py`）认领、调用
  OpenAI 兼容端点并把 `{text,model}` 回写（`evo-proactive-complete`）。引擎零模型/零网络；
  关闭开关后所有 `evo-proactive-*` 立即 `evo_disabled`，循环停止。请求带 1 条背压、
  8 观察步冷却与 driver+lease 归属；**evo 仍不写入任何其它子系统状态**。
- 与 RSI 线：慢环的评估窗口与回归检测复用 dream 轮次的账本思路，但两者独立验收；
  evo 记录是普通 state 条目，因此每次写都会移动目录指纹，`impact-audit` 与 dream
  过期判定使用的知识指纹不含 state，不受影响。

## 十一、风险与对策

| 风险 | 对策 |
| --- | --- |
| 适应度被游戏（如永远低波动） | 多目标 + flatness/always-positive 惩罚 + held-out |
| 退化到一个「永远痛苦」的吸引子 | 情感硬边界 + 恢复力下界 + 允许干预（回滚/调阈值），并把「长期负向」记为好发失败模式 |
| 过拟合小窗口 | 固定窗口 + 留出窗口 + 场景轮换 |
| 计算成本 | 小网络 + 每代单步 + 宿主 tick；预算硬上限 |
| 进化不稳定/难复现 | 种子化 PRNG + 所有算子确定 + 回放测试 |
| 与 LLM 关系越界 | 快环零模型；慢环可由宿主选择是否请 LLM 做标注，但评估公式与选择压力始终本地 |

## 十二、验收状态：v1 已覆盖 / v2 延后

v1 已覆盖（证据见 `agent/evo_wbtest.mbt` 与 `scripts/evo_e2e.py`）：

- 默认关闭与开关门禁：6 个 evo op 在洁净金库上 `evo_disabled`，除 `policy.json` 外
  零读零写；`enabled=false` 是安全开关，在人工闸待办时仍可执行。
- 23 项封闭参数表、未知/缺键/越界/NaN/Inf/protect>elite 拒绝、init 后参数锁定、
  关闭再开启参数逐字节不变。
- 快环边界：情感/冲动/阈值钳制、非有限宿主信号拒绝、冷却违规只在真实违规时计数、
  live observe 与离线回放同一控制器。
- 固定窗口训练/时间后缀留出、稳定性/响应/成长/新颖度四项收益与能量/冷却/
  always-positive/flatness/held-out 罚分、检查点只在非 lethal 且更优时更新。
- 第一代真实灭绝：精英=2、protected=2、extinct=6、至少一条 `not_selected` 化石、
  精英基因组字节不变、首代 delta=0。
- 同种子确定性：第二个独立金库用相同 seed/策略/窗口重放，种子基因组、首代
  `rng_seed`、化石 id、全部基因组与 `population.json` 逐字节一致；init 同参重放
  零写。
- 真实非单调证据（`scripts/evo_e2e.py` 步 12-13）：连续压力窗口使最优适应度下跌
  超过 0.05 → `evo-regression` → 连续回归达到耐心 → 自动回滚到检查点，失败谱系
  以 `regression_rollback` 化石保留；`evo-status` 对账化石/回归/回滚计数。
- 手动回滚即时 noop、评估/进化后成功、`manual_rollback` 化石、同 at 重放。
- 记录篡改精确分支码、基因组字节篡改 `content_changed`、pack/unpack 后继续 observe。

v1.1 已覆盖（续三十二，证据见 `evo_wbtest` 的 `evo_no_improve_step` 与 `evo_e2e`）：

- 饱和状态机：耐心 3 代、触发后 streak 清零、首代不饱和；触发代 `saturated:true`、
  变异 ×1.5、额外移民、`evo-saturation` 事件与 `saturations_total` 计数。
- `evo-checkpoint` / `evo-fossils` 只读 op：返回检查点/历史/计数与按 id 排序的化石；
  调用前后 `index.mbt.md` 字节不变。

v1.2 已覆盖（续三十三，证据见 `scripts/evo_proactive_e2e.py` 与 `evo_wbtest`）：

- 主动式闸门：情感/冲动达到阈值或上次触发跨过最近请求时才 `due`；冷却 8 个观察步、
  1 条 pending/claimed 背压；关闭 evo 后五个主动式 op 全部 `evo_disabled`。
- 归属与恢复：`evo-proactive-open` 原子认领（driver+lease），仅持有者可在租约内
  complete/fail；同载荷重放零写；失败原因进入记录与事件。
- 宿主驱动：`scripts/evo_agent_driver.py` 轮询 due → open → 调 LLM（测试用 mock，
  无网络）→ complete；引擎侧无模型/网络调用，`evo-proactive-list` 只读。

v1.3 已覆盖（续三十五，证据见 `scripts/evo_proactive_e2e.py`）：

- 送达确认：`evo-proactive-ack` 只接受 `done` 回复；同 `at` 重放零写，不同 `at`
  的二次投递按 `evo_proactive_already_delivered` 拒绝，早于 `closed_at` 的确认拒绝。
- `evo-proactive-list` 增加 `delivered_at` 与 `delivered/undelivered` 计数；驱动在
  `complete` 时不自动 ack——是否已真正交给用户由宿主决定（引擎不猜测投递）。
- 旧记录缺少 `delivered_at` 时按未送达读取，升级不破坏既有 outbox。
- 参考驱动 `scripts/evo_agent_driver.py` 支持 `--ack`（stdout 即投递通道时，打印成功后
  确认送达）与启动时清理自己过期的 claimed 占位（失败原因
  `driver lease expired before delivery`），崩溃重启不会永久占住唯一在飞槽位。

v1.4 已覆盖（续三十六，证据见 `scripts/evo_proactive_e2e.py`）：

- 过期接管：claimed 租约到期后不再计入 `pending` 背压；`evo-proactive-open` 在同一 id
  上更换 driver/lease 并返回 `reclaimed:true`，写 `evo-proactive-reclaim` 身份事件；
  旧持有者在新租约下 complete 按 `evo_proactive_not_owner` 拒绝。
- 没有过期占位时行为不变（`reclaimed:false`）；未过期占位仍按
  `evo_proactive_backpressure` 拒绝，避免两个驱动同时回答同一请求。

v1.5 知识—情感桥（续三十八，宿主侧，证据见 `scripts/evo_knowledge_bridge_e2e.py`）：

- `scripts/evo_knowledge_bridge.py` 把 `dream-plan` 的确定性机会集映射为
  `evo-observe`：缺陷类（lint/stale/sparse）用 `task` + 负价，未覆盖来源/缺失向量用
  `novel`；salience/valence 按 kind 与 severity 固定映射。
- 已关闭轮次的 `outcome.delta` 回灌为观察，按 `(closed_at,id)` 游标去重；重复 tick
  不会重复计同一轮结果。
- 桥只写 `state/evo`，不写知识页；关闭 evo 后桥在 `evo_disabled` 停止。
- 这是「情感为记忆服务」的最小闭环：知识张力 → 情感状态 → 主动判定；表达帧与
  daemon 周期见 [soul-layer.md](soul-layer.md)（续三十九/四十）。

v1.6 拟人化表达（续三十九，证据见 `scripts/evo_expression_e2e.py` 与 `evo_wbtest`）：

- 只读 `evo-expression` 把情感/身体状态映射为结构化表达帧：posture、
  emotion_label、prosody（rate/pitch/volume）、gesture、expression、will_initiate、
  energy。`will_initiate` 复用主动式闸门；引擎只出 token，文案与渲染在宿主/LLM。
- 阈值映射是纯函数并有 wbtest；e2e 固定中性帧、到期说话帧、确定性与只读字节不变。
- 这是 [soul-layer.md](soul-layer.md) 的「拟人化表达」固定点；daemon 周期在续四十。

v1.7 最小 daemon（续四十，宿主侧）：

- `scripts/evo_daemon.py`：一个进程、一个循环、一张调度表。每 tick 先清理自己过期的
  claimed 占位，再跑知识—情感桥、主动应答（complete + ack）、表达帧，最后在
  `dream-due` 到期时跑一轮 RSI driver。
- 引擎仍无线程/时钟/网络；daemon 是宿主适配层。关闭 evo 后 daemon 以
  `stopped: evo_disabled` 干净退出；崩溃后靠租约/ack/接管恢复。
- 这是 [soul-layer.md](soul-layer.md) 的「daemon 周期」固定点；具体间隔与编排由宿主配置。

v1.8 知识结果适应度（续四十一，证据见 `scripts/evo_outcome_e2e.py` 与 `evo_wbtest`）：

- `evo-observe` 可选 `outcome`（-1..1）随窗口条目保存；它不进入控制器输入，只用于评估。
- `evo-evaluate` 的 `breakdown` 增加 `knowledge`/`has_outcome`：成员输出的情感价态与宿主
  知识结果的接近度（同号且幅度接近得分高），仅在有非零 outcome 的步上计分；窗口带
  outcome 时适应度加 `0.10 × knowledge`，旧窗口无 outcome 时该项为 0。
- 这把「情感为记忆服务」从输入层推进到选择压力层：不同成员在同一知识窗口下按
  情感-结果对齐度被区分，而不是所有成员共享同一个外部分数。

v1.9 daemon 调度（续四十三，宿主侧，证据见 `scripts/evo_schedule_e2e.py`）：

- `evo_daemon.py` 增加 `--reflect-every`（默认 600s）与 `--consolidate-every`
  （默认 1800s）：反思读 `dream-retro` 并写一条 `reflection` 观察；凝练在到期时跑
  一圈 RSI driver。两者不再每 tick 执行。
- `--now` + `--tick-seconds` + `--ticks` 提供模拟时钟；e2e 固定 10:00/10:01/10:02
  三拍，验证反思/凝练只在 0/2 拍运行、状态时间戳正确。
- 夜间队列与多轮主动应答仍未实现；当前 daemon 是单间隔/单进程参考实现。

v1.10 夜间队列（续四十四，宿主侧，证据见 `scripts/evo_night_e2e.py`）：

- `--quiet-start/--quiet-end`（默认 22–7）：安静时段不开主动请求，只累计
  `deferred` 意图并记录 `last_deferred_at`；感知/反思/凝练继续运行。
- 早上第一个非安静 tick 尝试开口；成功时标记 `woke_from_night`、ack 并清零队列。
  两次 daemon 调用共享 `.corridor/evo-daemon/state.json`，重启后意图仍在。
- 多轮对话式主动应答仍未实现。

v2 延后（未实现，不得写成已交付）：

- 独立 `checkpoint.json` 与 `evaluation/<gen>.json` 目录。
- 场景轮换调度器（v1 只有单一窗口，环境漂移由宿主追加新观察触发）。
- 随机留出切分与多窗口评估（v1 是窗口时间后缀 30%，文档如实标注）。
- 批量 observe/内存快路径（v1 固定一拍一条，身份与重放语义不因批处理改变）。
- NEAT/拓扑变异、基线进化、语言头、LLM 标注者、多轮对话式主动应答（v1.2 只做
  单次结构化请求的主动发起，不做会话内多轮）。
- 外部知识结果的更多来源（commit/检索命中）；当前只把轮次 delta 作为 outcome 传入，
  权重固定 0.10、未做成可调策略参数。

## 十三、明确不做（v1）

- 不训练语言模型、不做语言理解；语言头仅列为后续可选项。
- 不引入外部进化框架/代码；算子自研，模式参考上表（净室）。
- 不把「持续变好」写进任何报表；拒绝单调叙事——`evo-evolve` 返回可为负的 delta、
  回归标记与化石计数。
- 不做桌面应用、桌面控制器或专用桌面集成（AGENTS 明确不实现）。
- 不把 v2 清单中的能力写成已交付：场景轮换、随机留出、批量 observe、拓扑变异、
  语言头与 LLM 标注者均未实现（饱和检测与独立检查点/化石 op 已在续三十二交付，
  主动式 outbox 已在续三十三交付）。