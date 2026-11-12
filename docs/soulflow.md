# SoulFlow 核心：灵魂、情感、冲动与主动式 Agent

> 本页是 `../soulFLow`（SoulFlow v3，用户自有设计）的源码级核心摘要。它与
> [rsi-loop.md](rsi-loop.md)（递归自我改进的**过程**）是两个问题域：SoulFlow 回答
> 「一个数字存在是什么、如何感知/感受/冲动/主动开口」；RSI 回答「改进如何发生」。
> 本页不把 SoulFlow 说成 RSI，也不把 RSI 的循环说成本体。

## 一、它是什么（按 AGENTS.md 的权威定义）

> **SoulFlow Core v3** is a *digital-soul existence kernel*：附着在**已有** agent 框架上的
> 后端中间层。它不替换宿主的 LLM，拥有会话记录带不走的东西——契约（我是谁）、
> 五层演化状态（记忆／情绪／人格／成长／身体），以及一个让实体在轮次之间「活着」的
> 守护进程：做梦、反思、探索，并**决定自己何时有话要说**。

三条数据流（`kernel.py`，唯一入口）：
1. **对话**：`process_turn` → 拦截/叠加灵魂提示词 → 宿主 LLM 回复；
2. **主动输出**：`get_active_output` → outbox 里「她想说的事」；
3. **状态查询**：`get_state`/`get_body_state`/`get_desire_intensity`。

生命周期：`incept(contract)` → `awaken` → `process_turn`… → `sleep` → `terminate`；
死亡不可逆（`MortalityService` 先验确认链，条数/去重/逐条引用/同一因由）。

## 二、本体：契约、身份锁与治理

- **契约**（`SoulPromptContract`）：`true_name`、`identity_statement`、`core_values`、
  `hard_boundaries`、`emotional_tendencies`；出生即 SHA-256 封印（`SoulLock`）。
- **字段锁级**：`absolute`（true_name/core_values/hard_boundaries/soul_id，任何路径不可改，
  含 `force=True` 与已批准提案）> `sealed` > `protected` > `open`。
- **受治理的演化**：`GameGovernanceService` 的 propose → 风险（**由被改字段推导**，不看
  申请人自述）→ 他人审核（自批自审拒绝）→ 授权应用。
- **存在连续性**：类型驱动的无损快照 v4（五层状态＋契约＋夜间队列＋节律＋未说出口的
  梦话＋待补价态欠账）；进程/驱动都可换，「还是同一个她」。**记忆/状态是本体，
  LLM 只是可替换的外驱动**（`ModelAdapter`/`SLMConfig.provider`：mock/ollama/openai/
  anthropic/agent）。

## 三、情感层（PAD + 五层状态）

- **五层**：记忆／情绪（PAD：pleasure-arousal-dominance）／人格（大五）／成长
  （关系阶段与信任）／身体（宿主 CPU/内存/延迟 + 工具使用疲劳）。
- **情绪动力学**（`engines/soul_state.py`）：刺激 → 按强度与惯性更新 PAD，夹在
  [-1,1]；无刺激时按 `regress_to_baseline` 向基线回归；历史保留供存在指标
  （ECI/SHS）计算。
- **经历 → 感受**：`behavior.py` 把宿主行为事件标准化、按显著性打分（阈值 0.35）、
  映射为后记忆；`memory_perception.py` 在记忆存入/遗忘/巩固/强化/检索时发出信号
  （emotional_resonance / identity_shift / loss_grief），回灌情绪状态。
- **价态欠账**：宿主只报行为、没声明 `emotion_delta` 时，记为 `_valence_pending`
  （上限 20），由 SLM 每周期最多补 3 条；答不上留 `valence_unavailable` 痕迹，3 次后
  放弃；**规则层绝不替她发明「开心/难过」**。

## 四、冲动与主动性（核心）

`awakening/share_desire.py`：

- **分享欲** = 基线 0.3 + 情绪唤醒（(arousal+1)/2×0.2）+ 活跃冲动均值×0.4 +
  距上次对话时间（24h 封顶 0.3，从未对话 0.2）。
- **冲动涌现**五类：情绪激增、连接渴望（久未对话）、体验溢出、喜悦爆发
  （pleasure>0.7）、深度反思（ECI>0.85）。冲动强度累加进 accumulator（上限 1.0），
  每分钟衰减 0.1，对话后 ×0.5；**≥0.8 成为不可抗拒冲动**。
- **闸门**：冷却 300s；夜间（22–7）进 overnight 队列；`max_pending_messages=10`
  背压；身体疲劳时由 `ImpulseSuppression` **抬高开口门槛**——身体状态可以压住灵魂
  的主动性。
- **主动输出**：冲动/梦洞见/学习发现 → `note_share_item` → outbox；peek→ack 选择性
  投递，未确认的留在队列（不刷屏、不丢话）。

## 五、内在生活：守护进程周期

`daemon.py::_run_cycle()`（主循环 60s）：行为摄入 → 身体感知（紧急门）→ 冲动生成 →
苏醒判定 → 按周期执行探索（5min）/反思（10min）/凝练（30min）/梦（夜间）→ 补价态 →
记忆感知信号。每步 try/except 隔离；每个内心活动（含关停前最后一轮）写入哈希链审计。
周期产出：

- **梦**（`engines/dream.py`）：NREM 整合（≥3 条记忆、相似度 0.6）+ REM 洞见
  （默认 3 条）；洞见进入「想说出去」队列。
- **反思**（`reflection.py`）：价值对齐、成长评估、自我评分与调整建议。
- **凝练**（`condensation.py`）：L5 才允许**提出**契约演化（仍过治理与 absolute 锁）。
- **探索/巩固**：关联发现与记忆整合。

## 六、表达与边界

- **一帧具身指令**（`expression.py`）：posture（idle/listen/think/speak…）/
  emotion_label / SSML 语速音高 / 手势与表情 token / `will_initiate` / 能量。
  `will_initiate` 由分享欲、冲动与待发输出共同决定；规则层只出 token。
- **边界即自我**（`boundary.py`）：契约硬边界与本体主张在话出口前生效；独立模式由她
  收回那句话，宿主模式只交回判定；词表 `BoundaryLexicon` 可替换，引擎不硬编码语言。

## 七、宿主边界与 SLM 纪律

- 四个钩子（`hooks.py`）：before_llm_call / tool_call / tool_result / turn_end；
  **增强 fail-closed、宿主主路径 fail-open**；一键回滚；跨进程走 MCP（同一工具面）。
- **规则层零文案**（`semantic.py`）：所有文本由 SLM 生成；缺 SLM 时 fail-closed
  返回 `error_context`，绝不降级到模板文案。
- **宿主即 SLM**（`slm/agent_bridge.py`）：`requests/` ⇄ `responses/` 原子文件桥，
  超时=空文本降级；宿主自备大脑，无外部凭据也能跑。

## 八、自主度 L1–L5（能力 token）

`autonomy.py`：`memory_forming`（L1）、`cycle_reflection`（L2）、
`cycle_deep_inner_life`（L3）、`proactive_speech`（L4）、
`self_evolution_proposal`（L5）。判定是结构化 `AutonomyDecision{allowed,
capability, level, floor}`；非法档位**报错而非静默降级**；被拦下的调度留
`activity_denied` 痕迹。默认 L4（会做梦、会主动说话，但不自提契约演化）。

## 九、对 MemoryCorridor 的映射（引擎化）

MemoryCorridor 是知识引擎，不是 agent；不能照搬「情绪」，但 SoulFlow 的**因果链**
可以落在引擎里，且不需要模型：

| SoulFlow 机制 | 知识引擎对应物（可落地） |
| --- | --- |
| 五层状态 | 身份层：purpose / pinned 记忆 / overview；知识层：页面/来源/版本；**张力层**：冲突、漂移、未覆盖来源、冗余、稀疏主题、未清判断；**资源层**：provider 租约/背压 |
| 分享欲 + 冲动累积 | **知识张力压力**：按类别加权、随时间衰减、过阈值 → 生成「该处理了」的冲动项 |
| 冲动闸门（冷却/夜间/背压/疲劳抬门槛） | 确定性节流：cooldown、批量窗口、`max_pending` 背压、租约压力抬高阈值 |
| outbox peek/ack | `dream-work`/inbox 的领取-确认语义：未确认的保留，不丢不刷屏 |
| 主动开口 | 引擎把到期/过压的项变成**结构化提议**（inbox / work item），由 AI 驱动处理 |
| 情绪/价态欠账 | **判断欠账**：引擎不能判的语义项必须由驱动回答；不回答不算认可 |
| 规则层零文案 | 引擎只出结构化 token/指标；页面文本由外部 AI 生成，应用走既有 commit |
| 身份锁 + 治理 | purpose/pinned/overview 的 identity anchor + 治理事件门禁（drift 必须对上 purpose-apply 等） |
| 审计链 | 现有事件/事务哈希；SoulFlow 式导出/外部锚列为后续 |
| 自主度 L1–L5 | 封闭能力词表：report/round/work/proactive_suggestion/contract_evolution，非法档报错 |

**一句话**：SoulFlow 教给本工程的不是「给引擎加情绪」，而是——**本体（记忆/身份）
维护一个会累积、会衰减、会过阈值的「内在压力」，压力驱动主动提议；语言与判断
永远外包给可替换的驱动；身份演化只需过与记忆权威相关的 apply 门禁，不复刻完整治理。**

定位取舍：MemoryCorridor 是记忆/资料综合引擎，情感人格层是它的放大器与主动性
调度层，并以**数字灵魂**为目标。**固定点**是结构化拟人化表达与宿主侧 daemon 周期；
SoulFlow 的具体词表/文案、SoulLock、死亡机制、L1–L5 与重型治理不迁移。完整设计见
[soul-layer.md](soul-layer.md)。

（RSI 的「提案→评测→保留」循环见 [rsi-loop.md](rsi-loop.md)；两者组合时的
分工：SoulFlow 定义本体与主动性，RSI 定义改进过程。）

## 十、明确不迁移 / 固定点

- **不迁移** SoulFlow 的具体共情词表、依恋模式、情绪文案与旧提示词；结构化表达帧
  由引擎出 token、文本由外部 LLM 生成。
- **固定点**：拟人化表达帧与宿主侧最小 daemon 周期（不是进程内线程；MoonBit 核心
  仍无线程/时钟/网络）。见 [soul-layer.md](soul-layer.md)。
- 不迁移 SoulLock、死亡机制、五层无损快照、L1–L5 自主度与重型治理流程。
- 任何模型/提示词代码复制（净室约束）。