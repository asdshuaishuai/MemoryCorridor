# 分期验收册（对照 PROPOSAL §14 逐条）

生成方式：每个验收条目列出 PROPOSAL 原文、实现落点与**可重放的证据**
（verify.sh 内的脚本/测试，或 docs 记录 + 其数据文件）。判定只有三种：
`pass`（证据在当前 HEAD 的门禁里）、`pass(with scope note)`（承诺范围内
成立，范围外如实标注）、`open`（未取得，不写作已完成）。全部门禁条目由
`./scripts/verify.sh` 一次性执行；下表证据路径均可点开。

## P0 文学化索引与编译闭环

| 验收门（PROPOSAL 原文摘要） | 实现与证据 | 判定 |
| --- | --- | --- |
| 知识库基线回归（续八十一） | 知识库权威回到 `specs/engine/design.md` §0：`index.mbt.md` 是唯一目录入口（可编辑、可编译、增量重建），正文独立；知识页只经 LLM 两步工单产生；OKF 仅作互操作、`pack` 不是 OKF。新增 `docs/retrieval.md` 只描述派生检索；删除混合知识/记忆/检索方案文档。`memory-export` 移出知识 `index/` 到 `.corridor/memory/`，并新增「导出前后 `.corridor/` 之外字节不变」守卫。死代码清理：删除生产环境仅测试使用的 `index.search` 包装与 `retrieval.index_path/clear_cache/search_chunks/chunk_of`。`e2e.py`、`interop_e2e.py`、`retrieval_e2e.py`、`memory_e2e.py` 全过 | pass(scope note：检索保留；未改知识页编译/写入路径) |
| 假 Agent：两份 raw → 工单 → 正文 + index.mbt.md → 检索 → 来源撤销与脏页标记 | `scripts/e2e.py`（摄入闭环、检索、撤销传播、stale 标记全程） | pass |
| 类型错误拒绝、缺文件/哈希漂移拒绝 | `scripts/record_validation_e2e.py`、`scripts/tamper_e2e.py`、`read-source` 区间越界（`docs/protocol.md`） | pass |
| 提交中断恢复 | `agent/transaction_safety_wbtest.mbt`（每个发布点崩溃注入）+ `scripts/lifecycle_e2e.py` | pass |
| 缓存删除重建后保留审核/工单 | `scripts/lifecycle_e2e.py` 的 `.corridor/` 删除重建段；state 白名单 `core/records.mbt` + `core/state_dirs_wbtest` | pass |
| verify 自校准 | `scripts/verify_e2e` 面：`e2e.py`/`lint_predicates_e2e.py` 的违规注入必须被 verify/lint 报出 | pass |
| 字典与 CLI/help 对账 | `scripts/mcp_e2e.py`（三面计数 94 断言，散文按实跑重算）+ `docs/protocol.md` 字典节 | pass |
| 提交前编译声明并验证来源/内容/路径/基线 | `base/literal.mbt` 词法读取器 + `decl/catalog.mbt` token 流比对 + `authoring_e2e.py`（编译器失败/重试/回执重放） | pass |
| 中断恢复、幂等重试、外部编辑冲突实测 | `e2e.py` 的 edited/stale 输入竞态、`session_e2e.py`、`concurrent_e2e.py`（1/2/4/8 进程锁竞争） | pass |

## P1 检索与维护

| 验收门 | 实现与证据 | 判定 |
| --- | --- | --- |
| 暴力搜索与参考实现对照 | `retrieval_e2e.py` + `index/*_wbtest`（BM25/混合/向量后端矩阵） | pass |
| 模型空间隔离/向量失效/后端覆盖与回退 | `embedding_e2e.py`、`provider_e2e.py`、`provider_jobs_e2e.py`（注册/心跳/租约/撤销） | pass |
| 外部向量空间协议（默认仍文本为核心） | 协议面：`embedding_e2e.py` 多模态段用宿主手工向量覆盖能力封闭词表、image items、字节版本锁、无图页跳过与 `page-redundancy cosine_floor`（默认 0.92，视觉面建议 ≥0.995，响应回显生效值）；仓库不附带 CLIP/bge 模型适配器，真模型面由宿主自行提供，不入门禁 | pass(scope note：仅协议与手工向量；中文跨模态模型不在仓库内，不写成已交付) |
| 宿主系统向量探针（host-only，续八十五） | 契约/不可用分支：`scripts/os_embed_probe_e2e.py`（入 `verify.sh`/`quick_verify.sh`）用 stub 覆盖 `os-embed/v1` 字段类与不变量、`available:false`/`reason:"engine_absent"`、stub exit 2、`fingerprints`/目录字节不变、providers/events/vectors/pending 零写入、`retrieve` 仍 `algo`/`no_system_engine`、`search` 仍 `not_provided`（macOS 与 Linux 均可，只要 native CLI 可构建）；`scripts/vector_engine_e2e.py` 覆盖 `scripts/vector_engine.py` 的 probe/ensure/query-text/register 与不可用零写入，并含无网络静态守卫、macOS live `ensure` 删除标准适配器二进制后由源码重建再还原、陈旧/损坏适配器 FAIL 提示与 en 512 query-text 断言。实测分支：macOS 有构建物时逐语言 batch oracle（zh 640 / en 512）与 probe 一致，`register` 仅在 available 时写 provider | pass(with scope note：不可用分支是 stub，不是“引擎存在但不可用”的真机；正探针不切换 lane、不自动注册；Windows/WASM 运行时不在门禁平台；e2e 不是已交付宿主，`hosts/` 无 probe 消费者；工作流已跑 `scripts/quick_verify.sh`（exit 0），CI run 45924159800（a6c4b09）verify/release 双 success，完整 mutation 矩阵随全量门禁通过——两个新 e2e 已接入门禁文件) |
| 梦境轮次与 RSI 保留门禁（续二十八） | 协议/状态面：`dream_e2e.py`（只读 dream-plan 确定性、指纹绑定、重放先于基线、lint 与证据丢失双门禁拒绝、终态重放、记录篡改分支、pack/unpack 往返、只读字节不变）+ `dream_wbtest.mbt`（身份派生/策略封闭/schema 面）+ `transaction_safety_wbtest.mbt` 中断恢复（0..5 写点）；真模型无关：核心零模型调用 | pass(scope note：梦境只做确定性机会汇总与保留记账，创意改写由宿主经既有 commit 流提交；多机阈值仍 open) |
| RSI 任务出箱与驱动语义（续二十九） | `dream_work_e2e.py`（去重/背压、驱动租约与过期接管、结构化 judgments/proposals、未清工单禁 retained、终态重放、记录篡改分支、pack/unpack、只读字节不变）+ `dream_work_wbtest.mbt`（任务身份/结果封闭/schema） | pass(scope note：页面文本仍由外部驱动生成并经既有 commit 应用，引擎只收结构化提案) |
| RSI 到期契约（续三十一） | `dream_e2e.py` 第 9 段：policy 默认/写入/重放/越界拒绝；`dream-due` 在无开轮时为 due、开一轮后 `open_rounds_capacity` 拒绝、关闭后（冷却 0）恢复 due；`dream_wbtest` 覆盖严格 ISO 解析与参数边界 | pass |
| 自进化饱和度与只读审计（续三十二） | `evo_wbtest` 覆盖 `evo_no_improve_step` 的耐心/重置/首代语义；`evo_e2e.py` 覆盖 `evo-checkpoint`/`evo-fossils` 字段与只读字节不变，三面计数 115 | pass |
| RSI 宿主自治驱动（续三十四） | `rsi_driver_e2e.py`（policy 到期→plan→open→work-open→claim→mock LLM judgments→complete→retained；outcome.drivers 记录驱动；无到期机会时零写 no-op；知识漂移时降级 rejected）+ `dream_e2e.py` 回归（`dream-list` 跳过 policy.json）+ mutation「dream-list 必须跳过节奏记录」| pass(scope note：真实模式只提交结构化 judgments；页面暂存与 commit 仍由宿主负责，驱动不写知识页) |
| 主动跟进链（续五十一） | `evo_followup_e2e.py`（已投递父→跟进、父回复+用户原话进 prompt、链深 8、在飞背压、未投递父拒绝）+ 2 条 mutation | pass(scope note：跟进请求仍需宿主触发；不是自动多轮对话) |
| 确定性随机留出（续五十六） | `evo_wbtest`（split 覆盖/大小 11-5/确定性/非时间后缀）+ `evo_e2e` 评估回归 + 2 条 mutation（固定后缀/无留出） | pass |
| 多轮用户对话输入契约（续五十五） | `evo_thread_e2e.py`（open/replay/already-open/delivered-parent 门禁、append 重放/role/text 校验/16 轮上限、close 终态与重放、list 只读、daemon 开口开线程+用户消息追加 user 轮）+ 3 条 mutation | pass(scope note：线程是 state 不是知识页；文字不进 wiki/来源) |
| 真实路径离线可测（续五十四） | `nlp_real_path_e2e.py`（本地 OpenAI 兼容服务：affect/expand llm、非法 JSON 失败关闭、RSI judgments+失败记录、evo 文本+ack） | pass(scope note：HanLP 真实模型仍 SKIP；LLM 路径用本地服务，不连外网) |
| sidecar 容器级隔离（续六十二切片二） | `evo_e2e.py` 18a2（纯 evo 序列指纹/目录字节不变、state/evo 零残留）+ 18c（legacy 金库自动迁移：记录进 sidecar、金库副本与目录行删除、迁移后策略可用）+ pack 段（解包金库无 evo 状态）+ `evo_sidecar_wbtest`（4 发布点崩溃前滚、篡改/冲突/保留路径失败关闭）+ 3 条 mutation | pass |
| RSI 正式模式提案补全（续五十三） | `rsi_driver_e2e.py` 4c（`parse_judgments` 收 page{title,body}、拒空标题/越界键/非对象、无 page 默认）+ 第 4 段 mock 提案回归 | pass(scope note：真实 LLM 路径 CI 仍只测解析契约，不连网) |
| NLP 基础强化（续五十二） | `nlp_adapter_e2e.py`（英文否定/程度双检、auto 回退、消息文件轮转不重放）+ `search_expansion_e2e.py`（单条扩展失败记入 errors 继续） | pass(scope note：lexicon 仍是确定性兜底；HanLP 真实模型路径 CI 干净 SKIP) |
| 主动表达连续性（续五十） | `evo_proactive_e2e.py`（首轮投递后，driver-c 的 mock 输出带 `·续`，证明历史来自已 ack 回复并进入 prompt）+ daemon 回归 | pass(scope note：单轮承接；多轮用户对话契约未实现) |
| 检索查询扩展接入（续四十九） | `search_expansion_e2e.py`（auto 扩展、逐条 engine 查询、按页合并去重、matched_query/expansion_source、知识页只读） | pass(scope note：宿主层合并；引擎 search 仍单 query 执行，证据/预算闸不变) |
| HanLP 进入宿主 NLP 主体（续四十八） | `nlp_adapter_e2e.py`（auto：HanLP 优先、lexicon 兜底带 `auto_fallback` 标记、边界与确定性；显式 lexicon 回归）+ `nlp_adapter_hanlp_e2e.py`（未安装干净 SKIP） | pass(scope note：主体在宿主层；MoonBit 核心仍只有自研词法/检索；1.x 便携数据包外的模型许可由启用者核对) |
| RSI staged 提案（续四十七） | `rsi_driver_e2e.py` 第四段（`--propose` 写 `staging/dream-work/<id>.md`、proposals 登记、wiki 零写、retained 仍成立） | pass(scope note：只产 staging 草稿；应用必须走 commit，driver 不写 wiki) |
| HanLP 可选 provider（续四十六） | `nlp_adapter_hanlp_e2e.py`（未安装干净 SKIP；安装后 provider 契约：affect 分词打分/expand 词级同义替换）+ `nlp_adapter_e2e.py` 回归 | pass(scope note：不捆绑、CI 不下载；模型许可由启用者核对) |
| 宿主 NLP 适配器（续四十五） | `nlp_adapter_e2e.py`（lexicon 正/负/中性、边界与确定性；查询扩展保留原查询；daemon 消息文件游标去重、跨 tick 新消息、知识页零写）+ 文档 | pass(scope note：lexicon 为小型离线词表，不宣称通用情感分析；LLM provider 可选且失败关闭) |
| 夜间队列（续四十四） | `evo_night_e2e.py`（22:00 安静只 deferred、无请求；07:00 `woke_from_night` + ack + 清零；跨 daemon 重启状态保留）+ `evo_schedule/daemon` 回归 | pass(scope note：意图队列，不是消息队列；多轮主动应答未实现) |
| daemon 反思/凝练调度（续四十三） | `evo_schedule_e2e.py`（模拟时钟三拍：反思/凝练在 0/2 拍运行、1 拍跳过、状态时间戳）+ `evo_daemon_e2e.py` 回归 | pass(scope note：宿主侧调度；夜间队列/多轮主动应答未实现) |
| RSI 跨轮复盘（续四十二） | `dream_retro_e2e.py`（空基线、保留率分母为 closed、delta 求和、driver 成功率、work_by_kind、last、确定性、只读）+ mutation「保留率不得用全部轮次」 | pass(scope note：只读聚合；不自动调整策略) |
| 知识结果适应度（续四十一） | `evo_outcome_e2e.py`（outcome 进窗口、每成员 `knowledge`/`has_outcome`、成员间有差异、重放、越界拒绝）+ `evo_wbtest` 对齐函数 + 3 条 mutation（成员输出/失配惩罚/窗口携带） | pass(scope note：仅窗口带非零 outcome 时启用 0.10 权重；旧窗口零影响) |
| 最小数字灵魂 daemon（续四十） | `evo_daemon_e2e.py`（感知→mock 主动应答+ack→表达帧→retained RSI 轮次→第二轮冷却/轮次结果回灌→关闭 `evo_disabled` 停止）+ 桥/表达 e2e | pass(scope note：参考宿主 daemon；真实 LLM、投递通道与渲染由宿主配置) |
| 拟人化表达帧（续三十九） | `evo_expression_e2e.py`（中性 idle/calm、到期 speak/open_palm、韵律与能量边界、确定性重放、只读字节不变、关闭后 `evo_disabled`）+ `evo_wbtest` 标签/姿态/手势/表情映射 + 2 条 mutation | pass(scope note：引擎只出 token；文案和渲染由宿主/LLM 负责) |
| 知识—情感桥（续三十八） | `evo_knowledge_bridge_e2e.py`（`dream-plan` 未覆盖来源→`evo-observe` task/novel、步数单调、轮次 delta 回灌且游标去重、知识页零写、关闭 evo 后桥在 `evo_disabled` 停止）+ 桥脚本静态检查 | pass(scope note：桥是宿主适配层，只写 evo 状态；不做页面提案或 commit) |
| 主动驱动投递闭环（续三十七） | `evo_proactive_e2e.py`（`--ack` 后 delivered 计数与 `delivered_at`；重启驱动清理自己过期 claimed 并记录失败原因）+ 3 条引擎侧 ack/接管 mutation | pass(scope note：stdout 作为参考投递通道；真实宿主应在实际发送后自行 ack) |
| 主动式租约过期接管（续三十六） | `evo_proactive_e2e.py`（过期 claimed 不计 pending、`due.expired=1`、open 同 id 接管 `reclaimed:true`、旧驱动 not_owner、新驱动完成）+ mutation「过期不得阻塞」「过期必须接管」 | pass |
| 主动式应答送达确认（续三十五） | `evo_proactive_e2e.py`（claimed/failed 不可 ack、早于 closed_at 拒绝、同 at 重放、二次投递拒绝、`delivered/undelivered` 计数）+ mutation「ack 仅 done」「不得二次投递」「不得早于回复」 | pass(scope note：ack 表示宿主已投递；引擎不判断用户是否真正看到) |
| 情感人格主动式应答（续三十三） | `evo_proactive_e2e.py`（情感/冲动状态自主触发 due、1 条背压、8 步冷却、driver+lease 归属与过期、complete/fail 重放、关闭开关后五 op 全部 `evo_disabled`、宿主驱动 `--mock --once` 真实发起并回写、list 只读）+ `evo_wbtest`（主动式判定/身份/结果边界）+ mutation 冷却门与 pending 背压 | pass(scope note：引擎只写结构化请求，LLM 调用在宿主驱动；v1.2 为单次主动发起，不做会话内多轮) |
| 来源撤销矩阵 | `source_deletion_e2e.py`、`revocation_lifecycle_e2e.py`（页面/证据/记忆/影响全传播） | pass |
| 冻结问题集的检索与知识质量对照 | 检索：`quality_eval.py` + `multidomain_eval.py`（四领域 fixtures，`docs/quality-report.json`、`docs/multidomain-quality-report.json`）；模型生成知识 A/B：`model_quality_eval.py`（**双领域**：龙泉青瓷 + 光合与产量，`docs/model-quality-report.json`） | pass(with scope note：报告只测检索/溯源记账，不断言语义正确性——scope 字段写明) |
| 真实资料 | 语料为仓库自有的 PROPOSAL/LICENSE 与领域 fixture（自撰确定性文本），数据集字段如实记录；外部真实原件经 OCR/PDF 通道进入：`adapters/ocr-rs` + IRS 真实 PDF 验证记录在 `docs/ocr.md` | pass |
| 神经进化：情感/冲动快环与非单调慢环（续三十） | `evo_e2e.py`（默认关闭与开关门禁、23 项封闭参数、init/observe 重放与冲突、同种子双金库逐字节一致、窗口完整性、真实适应度下降→回归→回滚、化石/回滚计数对账、手动回滚、记录篡改分支、`content_changed` 全局完整性、pack/unpack 后继续 observe、跨模块只读对比）+ `evo_wbtest.mbt`（rng/身份/权重 binary32/参数表/控制器钳制/冷却/适应度罚分/精英下限/锦标赛/变异幅度/交叉/回归耐心/化石原因/计数对账/schema/门禁/人工闸/篡改关闭/任意写点崩溃恢复）+ 静态单向扫描与 8 条变异 | pass(scope note：v1 无饱和度检测、独立 checkpoint/fossils op、场景轮换与批量 observe；随机留出为时间后缀 30%，均如实记录在 `docs/neuro-evolution.md`) |

| 增量核对与规模（续七十一） | `@platform.signature` 变化信号 + `@vault.VerifyMemo`（同请求前后采样一致才复用、页面互链须活跃）；`e2e.py` 固定同尺寸改写并还原 mtime、符号链接替换、删除三场景；WASM 三面 `stat→None` 全量。600 页库 fingerprints 332→16 ms、search 523→44 ms、lint 3.7→0.42 s | pass |
| context 范围与 lint 分组（续七十二） | `context scope=related|all`（默认 related，64 页上限，`pages_total`/`pages_omitted` 如实，`page_hashes` 完整）+ `agent/context_wbtest.mbt` 三测试 + e2e 断言；`lint` 冗余页按词元序列哈希 O(N) 分组 | pass(scope note：all 仍受上限约束，被省略页数如实报告) |
| 分块检索内核与双路兜底（续七十三/七十四/八十四） | `retrieval/`（MoonRetrieve 0.6.0 分块 BM25 + 算法向量哈希特征 + 固定 k=60 RRF）；`retrieval_wbtest.mbt` 7 测试（唯一标识、存取/篡改/陈旧、命名空间、制品自洽拒绝、特征、向量路召回文本路漏掉的截断标识符、宿主页排序替换算法路）；`e2e.py` 块级 retrieve/命名空间/非法前缀；`embedding_e2e.py` 用手工 provider 向量在平台无关路径覆盖 system 路与首块映射；`os_embed_e2e.py` 在 macOS 验证 `NLEmbedding` 适配器驱动 `search` 与 `retrieve` 的 system 路（`vector:"system"`/`provider_vectors`、`vector_space` 回显、内容版本失效），非 macOS 显式 SKIP；120 页 × 32 KiB 库 search 21 ms、retrieve 3 ms，600 页 retrieve 12 ms；制品 v5 主文件 + `fts.vectors.bin` 旁车，超 16 MiB 上限降级为进程内集合且 lint 报 `file_too_large` | pass(scope note：系统向量由宿主提供，默认仍算法兜底 `vector:"algo"`/`no_system_engine`；块级系统向量排序未实现，页级命中映射首块 `<page>#0`；jieba 词级路因依赖与固定 core 不兼容暂缓) |
| 情感主动发言门控（续七十六） | `evo-activity` + `last_activity_at` 单调活动戳；`evo-proactive-due` 同时要求冲动与 ≥1800 s 空闲并返回 `idle` 明细，效价单独不再触发，缺失活动戳失败关闭；`evo-thread-append role=user` 与 `evo-proactive-followup` 同事务计入活动；`evo_daemon --activity-file` presence 上报。`evo_wbtest` 2 个集成测试 + 纯门测试 + `evo_daemon_e2e` presence 段 + 5 条 mutation | pass(scope note：空闲阈值当前为常量 1800 s；按工作区/用户配置化待后续) |
| 工作区登记（续七十五，记忆隔离切片一） | `workspace-open`/`workspace-list` + `state/workspaces/<sha256>.json`（路径闭校验、内容寻址 id、同 at 零写重放、较新 at 仅刷新、较早 at 拒绝、`last_opened_at >= created_at`）；`workspaces_wbtest.mbt` 5 测试 + `memory_e2e.py` 工作区段与 pack 往返 + 6 条 mutation；三面工具计数 134 | pass(scope note：登记是记忆隔离的锚点；梦境 RSI 接工作区尚未交付，不写成已完成) |
| 情感主动发言接入工作区记忆（续七十九） | `evo_agent_driver --workspace` 与 `evo_daemon --workspace` 把已登记工作区传给 `memory-prefetch`，主动/跟进提示词获得有界记忆线索；未提供工作区时明确降级为「没有相关记忆线索」，不跨工作区猜测。`nlp_real_path_e2e.py` 注册工作区并写入线索笔记，断言提示词包含该线索且不再出现无线索文案；daemon/followup/proactive 三个 e2e 回归 | pass(scope note：线索仍由宿主注入，核心不调用模型；梦境 RSI 的工作区化未交付) |
| 助理导出（续七十八） | `memory-export` 生成 `.corridor/memory/projects.json` 与 `.corridor/memory/<workspace>/<id>.md`：仅 active 项目级笔记，会话级只计数；派生物重复运行零写、离开 active 集合即删文件、`workspace` 限定只整理本目录。`agent/memory_export_wbtest.mbt` 3 测试（项目/会话分离、幂等与陈旧清理、工作区限定）；`memory_e2e.py` 导出段 + wasm 两面 `memory-export` 可达；4 条导出 mutation + 1 条 wasm 读缓冲守护（64 KiB 初值） | pass(scope note：导出是 `.corridor/` 派生视图，不是知识页、不是 OKF、不是权威；续八十二已迁到 `workspaces/<id>/memory`，外部编辑在下次导出时被覆盖/清除) |
| 陪伴记忆 M1：元数据与身份（续八十） | 笔记记录 v3、`note_hash` v4 新增可选 `importance`（0..1）、`emotion`（valence/arousal/dominance 各 −1..1 + 可选标签）、`episodic`/`promoted_at`；`use_count` 为非身份用量信号，`memory-use` 单调累加且同一 `at` 重放不重复计数；`memory-supersede` 继承未显式覆盖的元数据；导出 frontmatter 同步。`agent/memory_wbtest.mbt` 3 测试（身份绑定与篡改拒绝、请求与记录双层边界、use_count 重放）覆盖直接 `validate_record`；5 条 mutation（哈希绑定、importance 边界、emotion 轴边界、计数递增、supersede 继承） | pass(scope note：只存宿主提供的元数据，不推断情感；M2/M3/M4 已在续八十二交付) |
| 陪伴记忆 M2/M4/M3（续八十二） | 笔记记录 v4、`note_hash` v5 新增身份字段 `layer`（judgment/session_summary/episode/profile；summary 限 session、profile/episode 限 project、episode 仅由提升产生）。`memory-prefetch rank=weighted` 必填显式 `now`，按 0.35 相关 + 0.30 强度 + 0.35 重要性重排并返回 `score_components`/`tier`，默认 BM25 不变。`memory-candidates` 必填显式 `now`：core（pinned/importance≥0.8/episode）永不提名，important/normal 分层阈值，prune 返回 `tier/decay/strength/score/age_days` 与 `never_used/decayed`，不自动删除。`memory-promote` 以 importance≥0.7 或情感强度≥0.7 为门，supersede 生成 episode 并写 `memory-promote` 事件，旧记录保留。`agent/memory_wbtest.mbt` 5 测试、`memory_e2e.py` 回归；三面工具 135（最终 139） | pass(scope note：排序/衰减只做确定性算法，不调模型；weighted/衰减均要求宿主显式时钟) |
| 梦境笔记与工作区 RSI（续八十二） | `state/dream-notes/<id>.json`（v1）内容寻址记录，`dream-note-submit/list/resolve`：输入页面/记忆哈希、claims 证据绑定、applied 必须指向真实页面或活动记忆的匹配 hash；梦境只提案，应用走 commit/memory-*。`dream-plan/open/work-open` 可绑定已登记 workspace，记录记忆 metrics、把 memory_merge/prune/conflict/source_stale/promote 加入工单；`dream-close` retained 拒绝冲突/失效/漂移/剪枝债务回退；`dream-retro` 汇总笔记状态。`agent/dream_notes_wbtest.mbt` 2 测试 + `dream_e2e.py`；三面工具 139 | pass(scope note：梦境内核零模型；笔记不自动写入 wiki 或记忆) |
| 工作区分层（续八十二） | 记忆本体仍在 `state/memory`；`memory-export` 迁到 `workspaces/<id>/memory`，`workspaces/projects.json`，只整理 memory 目录。只读 `workspace-wiki-plan` 按 raw namespace/显式页/一跳共享页选页，返回页面哈希、claims、manifest 与 `workspaces/index.mbt.md` 文本；`scripts/workspace_wiki.py` 写 `wiki/`、`claims/`、`manifest.json` 与索引，`scripts/workspace_layer_e2e.py` 证明全局 search/list/pack 不含派生层、派生哨兵不进入目录、删除 `workspaces/` 后全局 verify 绿、重跑字节幂等 | pass(scope note：`workspaces/` 全部可重建，不是第二权威；AGENTS.md 标记块未自动写入) |
| 原生 OCR/PDF 直接集成（续八十七） | `nativehost/ocr.mbt` + `platform/fs.c` 的 `mc_ocr`：native 宿主在 `scan`/`refresh` 按导入的 PDF/图片工单发现 `MEMORYCORRIDOR_OCR_BIN` 或同目录 `ocr-adapter` 时，自动执行适配器、校验 `sha256 == order.source_hash`、经既有 `extraction-submit` 入账 sidecar；`context` 直接返回 `source_text`，未成功时再兜底重试；文本层 PDF 映射 `lopdf`，图片/扫描 PDF 映射 `ppocrv4-mobile-ocr-rs`；无适配器/失败/`MEMORYCORRIDOR_OCR=off` 回退 `extraction_required:true`，`read-source` 不变。`scripts/ocr_native_e2e.py` 8 项 stub 用例入 `quick_verify.sh` 与 `verify.sh`；`scripts/ocr_e2e.py` 用真实适配器覆盖导入即调度、图片/扫描 PDF/文本层 PDF/颠倒图；`scripts/extraction_e2e.py` 保持手工 sidecar 回归。ONNX Runtime 默认由 `adapters/ocr-rs/build.rs` 嵌入适配器（启动提取到 0600 临时文件后 dlopen），release 只带 `bin/ocr-adapter`；工具数仍 139（无新 op） | pass(scope note：OCR 是唯一模型例外，仅 nativehost 执行；WASM 面不提供；不自动写 wiki，页面仍由 LLM 两步工单产生；扫描 PDF 仅抽取页内最大内嵌图，多页扫描不完整) |
| 项目自身 wiki 能力实测（续八十二） | `scripts/project_wiki_bench.py` 把本仓库 10 份项目文档经真实两步摄入生成 20 个知识页，注册本仓库为工作区、写入 4 条项目记忆（含 1 条 episode），再执行 `memory-export`、`workspace-wiki-plan` 与 `scripts/workspace_wiki.py`；生成 20 个 wiki/claims 文件，全局指纹不变。小样本固定查询：知识 search/retrieve 与记忆 BM25/weighted 均 top-5 命中；时延与字节数见 [project-wiki](project-wiki.md) | pass(scope note：确定性宿主摘要代替外部 LLM，结果只验证工程链路与当前样本，不外推语义质量/跨机器性能) |
| 记忆按工作区/会话隔离（续七十七） | 笔记记录 v2 + `note_hash` v3 绑定 workspace/scope/session，路径 `state/memory/<workspace>/<id>.json`；`scope` 仅 `project`/`session`（session 必填且 project 禁填），写入要求 `workspace-open` 已登记，读取/预取/冲突只在该工作区可见范围内，跨工作区 id 读取统一 `entry_not_found`；重复/冲突分组只在同工作区且同可见范围内成立；`status`/`stats`/`inbox` 的 workspace/session 可选，省略 workspace 时记忆计数为零且 inbox 不列记忆条目。`agent/memory_wbtest.mbt` 3 个隔离测试（跨工作区不可见、同判断两库互不干扰、未登记拒绝）+ 既有作用域化用例；`memory_e2e.py`、`inbox_e2e.py`、`record_validation_e2e.py`、`tamper_e2e.py`、`lifecycle_e2e.py`、`revocation_lifecycle_e2e.py`、`lint_predicates_e2e.py`、`impact_e2e.py`、`source_deletion_e2e.py`、`scale_benchmark.py`、`mcp_e2e.py`、`make_demo.py` 全量作用域化；6 条隔离 mutation | pass(scope note：按既定决策不兼容旧版无工作区记忆，历史数据为零；助理导出已由续七十八交付，梦境 RSI 绑定工作区集合留待 2 期) |

## P2 互操作

| 验收门 | 实现与证据 | 判定 |
| --- | --- | --- |
| pack 两次字节一致 | `pack_e2e.py` + `wasm_service_e2e.py` 大容器双跑（≥3 MiB 原件）+ wasipure 面双跑 | pass |
| OKF bundle 往返 | `interop_e2e.py`（OKF/native_links 双向，未知键引号往返保真测试） | pass |
| MCP 字典与 CLI 对账 | `mcp_e2e.py`（tools/list 与 schema 逐字节、错误信封、progressToken 通知） | pass |
| 视觉目录/搜索/详情数据一致、编译错误隔离 | `visual/*_wbtest` + `web_e2e.py`（三视图同一快照源）+ `decl/visual` 非规范拒绝矩阵 | pass |

## P3 生态

| 验收门 | 实现与证据 | 判定 |
| --- | --- | --- |
| wasm ABI 与 CI 断言 | `wasm/`+`wasipure/` 双产物构建入 CI；`wasm_service_e2e.py`（corridor-host）与 `wasipure_e2e.py`（免宿主 wasmtime 直跑，含 --mcp） | pass |
| 视图与正文单一事实源约束 | `views/*.mbt.md` 生成视图不等于权威页面源：`index/context.mbt` 快照注入 + `visual/declaration.mbt` 字面量契约 + `unregistered_e2e.py` | pass |
| 真实 HTTP 与浏览器验证 | `web_e2e.py`（真实 socket 起服务、HEAD/431/host 门等敌意面）+ `reading_map_browser_cdp.py`（浏览器 CDP 阅读路径）+ CI 无浏览器时显式 SKIP 策略（`docs/ci.md`） | pass |
| Louvain 观察 | `index/*` 图扩展/洞察 + `graph_probe.py`（确定性社区输出入 lint/insight） | pass |

## 每期门禁共性（PROPOSAL §14 末段）

check 0 警告（`--deny-warn`，CI 冷缓存亦强制）、纯函数/磁盘/MCP/WASM 门禁、
受检文学化范围、提交故障注入、e2e 金样、全命令敌意语料（`adversarial_e2e.py`
+ 字典-实现对账）、依赖方向（`dep_audit.py`/`source_audit.py`）、>85% 占比
（当前 0.938）、文档对账：全部在 `verify.sh` 单入口，本地 macOS(arm64) 与
GitHub Actions(linux) 同一脚本、同一断言。

## 跨机器阈值（394 遗留项）的如实记录

- 确定性阈值（请求行 131072、pack 16 MiB、EXTRACTION 1 MiB UTF-8 字节、
  office 展开 32 MiB、OCR 25 MP/20000 px、租约 60 s）的**边界行为**由 e2e 与
  wbtest 钉住，在两类机器（本机 darwin arm64、CI linux x86_64）上以同一
  `verify.sh` 全绿——这构成"阈值行为跨机器一致"的证据。
- **性能量纲的跨机器阈值**（时延 SLA、吞吐基线）不宣称：本机规模基线见
  `docs/scale.md`（16/64/128 页与锁竞争），CI 只报告通过与否。多机集群
  阈值需要真实多机数据，本仓库不含该能力，条目保持 `open` 的部分见下。

## 范围决定与仍 open 的诚实清单

**已按用户决定移出范围（不是缺口，是取舍）：**
- macOS 设备原生 Vision OCR 第二后端——2026-11-03 用户决定放弃：引擎整体运行
  在 wasm 沙盒上，接 OS 级能力与「跨平台 = 任意 WASM 运行时 + 薄宿主」的架构
  相悖；OCR 用已定的 PP-OCRv4 mobile 低成本模型即可（`docs/ocr.md`）。
- 引擎内建 OS/模型后端仍在范围外；但宿主适配器（`adapters/os-embed` 的
  NLEmbedding、`adapters/ocr-rs`）是引擎外的宿主件。nativehost 只通过 platform
  的受控子进程调用本地 OCR 适配器、校验 digest 并走既有 sidecar 通道；核心不
  链接模型代码，WASM 不提供。`adapters/os-embed/os-embed --probe` 的可用性
  检测同样在宿主侧，引擎不读取、不链接；这与放弃“引擎内建 Vision OCR”不矛盾，
  不能把适配器模型本身记成核心能力。

**仍 open（需要外部条件才能推进，不虚标）：**
1. 多机集群阈值实测（需要第三台机器的运行者；CI 双 OS 证据之外不做宣称）。

**已交付（续二十三）：** 改写/同义级语义去冗余——PROPOSAL 373 行原列为「不在核心
内」，用户 2026-11-03 指示开做后落地：只读 op `page-redundancy`（同空间向量余弦抓
改写 + 词元近似 + 共享来源，提议不决定、绝不写库）+ 确定性 lint 谓词 `redundant_page`。
证据：`agent/redundancy_wbtest.mbt`、`scripts/redundancy_e2e.py`、6 条变异守卫。
