# 分期验收册（对照 PROPOSAL §14 逐条）

生成方式：每个验收条目列出 PROPOSAL 原文、实现落点与**可重放的证据**
（verify.sh 内的脚本/测试，或 docs 记录 + 其数据文件）。判定只有三种：
`pass`（证据在当前 HEAD 的门禁里）、`pass(with scope note)`（承诺范围内
成立，范围外如实标注）、`open`（未取得，不写作已完成）。全部门禁条目由
`./scripts/verify.sh` 一次性执行；下表证据路径均可点开。

## P0 文学化索引与编译闭环

| 验收门（PROPOSAL 原文摘要） | 实现与证据 | 判定 |
| --- | --- | --- |
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
| 可选多模态向量空间（默认仍文本为核心） | 协议面：`embedding_e2e.py` 多模态段（能力封闭词表、image items、字节版本锁、无图页跳过——CI 恒跑）；真模型面：`multimodal_e2e.py`（CLIP ViT-B/32 int8 双塔以图搜图+跨模态检索+bge 文本面不受扰，缺模型显式 SKIP）；校准发现（扁平色红↔蓝 ≈0.925 恰压文本调参的 0.92 线，同图 ≈1.0）按实钉死，且续二十七已将其接口化为 `page-redundancy cosine_floor` 显式调档（默认 0.92，视觉面 ≥0.995，响应回显生效值） | pass(with scope note：跨模态查询文本塔为英文；中文图文召回由 OCR+bge 文本空间承担，Chinese-CLIP 重量替换项记录于 `docs/vector.md` 不入库) |
| 梦境轮次与 RSI 保留门禁（续二十八） | 协议/状态面：`dream_e2e.py`（只读 dream-plan 确定性、指纹绑定、重放先于基线、lint 与证据丢失双门禁拒绝、终态重放、记录篡改分支、pack/unpack 往返、只读字节不变）+ `dream_wbtest.mbt`（身份派生/策略封闭/schema 面）+ `transaction_safety_wbtest.mbt` 中断恢复（0..5 写点）；真模型无关：核心零模型调用 | pass(scope note：梦境只做确定性机会汇总与保留记账，创意改写由宿主经既有 commit 流提交；多机阈值仍 open) |
| RSI 任务出箱与驱动语义（续二十九） | `dream_work_e2e.py`（去重/背压、驱动租约与过期接管、结构化 judgments/proposals、未清工单禁 retained、终态重放、记录篡改分支、pack/unpack、只读字节不变）+ `dream_work_wbtest.mbt`（任务身份/结果封闭/schema） | pass(scope note：页面文本仍由外部驱动生成并经既有 commit 应用，引擎只收结构化提案) |
| 来源撤销矩阵 | `source_deletion_e2e.py`、`revocation_lifecycle_e2e.py`（页面/证据/记忆/影响全传播） | pass |
| 冻结问题集的检索与知识质量对照 | 检索：`quality_eval.py` + `multidomain_eval.py`（四领域 fixtures，`docs/quality-report.json`、`docs/multidomain-quality-report.json`）；模型生成知识 A/B：`model_quality_eval.py`（**双领域**：龙泉青瓷 + 光合与产量，`docs/model-quality-report.json`） | pass(with scope note：报告只测检索/溯源记账，不断言语义正确性——scope 字段写明) |
| 真实资料 | 语料为仓库自有的 PROPOSAL/LICENSE 与领域 fixture（自撰确定性文本），数据集字段如实记录；外部真实原件经 OCR/PDF 通道进入：`adapters/ocr-rs` + IRS 真实 PDF 验证记录在 `docs/ocr.md` | pass |
| 神经进化：情感/冲动快环与非单调慢环（续三十） | `evo_e2e.py`（默认关闭与开关门禁、23 项封闭参数、init/observe 重放与冲突、同种子双金库逐字节一致、窗口完整性、真实适应度下降→回归→回滚、化石/回滚计数对账、手动回滚、记录篡改分支、`content_changed` 全局完整性、pack/unpack 后继续 observe、跨模块只读对比）+ `evo_wbtest.mbt`（rng/身份/权重 binary32/参数表/控制器钳制/冷却/适应度罚分/精英下限/锦标赛/变异幅度/交叉/回归耐心/化石原因/计数对账/schema/门禁/人工闸/篡改关闭/任意写点崩溃恢复）+ 静态单向扫描与 8 条变异 | pass(scope note：v1 无饱和度检测、独立 checkpoint/fossils op、场景轮换与批量 observe；随机留出为时间后缀 30%，均如实记录在 `docs/neuro-evolution.md`) |

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

**仍 open（需要外部条件才能推进，不虚标）：**
1. 多机集群阈值实测（需要第三台机器的运行者；CI 双 OS 证据之外不做宣称）。

**已交付（续二十三）：** 改写/同义级语义去冗余——PROPOSAL 373 行原列为「不在核心
内」，用户 2026-11-03 指示开做后落地：只读 op `page-redundancy`（同空间向量余弦抓
改写 + 词元近似 + 共享来源，提议不决定、绝不写库）+ 确定性 lint 谓词 `redundant_page`。
证据：`agent/redundancy_wbtest.mbt`、`scripts/redundancy_e2e.py`、6 条变异守卫。
