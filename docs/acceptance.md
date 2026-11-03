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
| 来源撤销矩阵 | `source_deletion_e2e.py`、`revocation_lifecycle_e2e.py`（页面/证据/记忆/影响全传播） | pass |
| 冻结问题集的检索与知识质量对照 | 检索：`quality_eval.py` + `multidomain_eval.py`（四领域 fixtures，`docs/quality-report.json`、`docs/multidomain-quality-report.json`）；模型生成知识 A/B：`model_quality_eval.py`（**双领域**：龙泉青瓷 + 光合与产量，`docs/model-quality-report.json`） | pass(with scope note：报告只测检索/溯源记账，不断言语义正确性——scope 字段写明) |
| 真实资料 | 语料为仓库自有的 PROPOSAL/LICENSE 与领域 fixture（自撰确定性文本），数据集字段如实记录；外部真实原件经 OCR/PDF 通道进入：`adapters/ocr-rs` + IRS 真实 PDF 验证记录在 `docs/ocr.md` | pass |

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

## 仍 open 的诚实清单

1. 多机集群阈值实测（需要第三台机器的运行者；CI 双 OS 证据之外不做宣称）。
2. 改写/同义级语义去冗余——设计上不在核心内（PROPOSAL 373 行原文自带此限定）。
3. macOS 设备原生 Vision OCR 第二后端——用户标记待定，未实现即不宣称
   （`docs/ocr.md` 记为评估挂起）。
