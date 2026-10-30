# 验证记录与未覆盖范围

日期：2026-10-17，macOS/POSIX，MoonBit 2026-09-20 工具链。完整入口为 `NODE_BINARY=/path/to/node22-or-later ./scripts/verify.sh`；`NODE_BINARY` 仅用于 WASM 实例化 e2e（需要 JS 引擎宿主），浏览器检查是纯 Python 标准库实现，不需要 Node。

> 本文是**当时那个时间点的记录**，不是活文档。其中的测试数与源码比例只对 2026-10-17 的树有效；当前门禁组成与比例以 `./scripts/verify.sh` 的实际输出和 `specs/engine/implementation-audit.md` 为准。因此本文不随 native 发布包分发。

自动门禁包括：

- native `moon check --deny-warn`、MoonBit 纯函数测试和 CLI/MCP 构建。
- 临时文件夹中的真实 CLI、MoonBit 子进程、目录编译、二进制原件、页面/原件变化、工单串行与幂等、外部编辑与 OS flock。
- 来源撤销（共享页与互链传播）、关键词/向量失效、模型空间隔离、外部后端替换、缓存删除/损坏与持久人工决定；HumanGate 质量审核还验证孤儿/稀疏标签、legacy/invalid 证据锚点、缺少有效证据、证据补交后的新快照和重放。
- raw 物理删除的 stale 来源保留、`source-missing` 事件、重复扫描幂等和新哈希重新登记，见 `scripts/source_deletion_e2e.py`。
- evidence 可选精确 raw UTF-8 锚点、错引拒绝和来源漂移失效，见 `scripts/evidence_source_e2e.py`；旧四字段记录继续兼容。
- 页面生命周期 E2E 验证显式归档/恢复、依赖失效传播、正文/来源校验、事件保留和幂等重放，见 `scripts/page_lifecycle_e2e.py`。
- 检索上下文：真实编译工单生成的长页后段证据、关键词/RRF 摘要、多页预算、完整正文与重复段落去重、显式 `dedup:"similar"`/`spread:"even"` 组合（分词序列相等的排版变体合并、来源独立保留、非法 choice 拒绝、漂移后不合并）、启发式 `estimated_tokens`/`truncated` 与块级估算一致性、图扩展按边权×跳跃⁻¹ 的确定性排序、各重复页的独立来源；UTF-8 区间从原文重建、400 个连续小预算反例、MCP 对照、重复页外部修改拒绝和来源撤销。CJK 分词在汉字/假名/谚文音节上使用一元+二元组，日文子串查询经真实工单 e2e 验证。见 [装配规格](../specs/engine/retrieval-context.md)。
- 每个事务发布中断点的恢复，已发布/未发布的真实磁盘日志恢复，恢复冲突保留人工修改，编译期间来源变更及编译拒绝不发布。
- 原件/人类正文实时刷新、视觉声明实际编译、错误声明保留上次输出、无效知识目录显式只读快照及正文漂移拒绝。
- 文学化目录/视觉源的多 `mbt` 块组合：首块 IR 解析、后续块共享定义、未闭合块拒绝、首块闭合围栏后紧跟裸文本的畸形 Markdown 拒绝（`catalog_literate_tail`/`view_literate_tail`，带结构化 `violations` 与修复提示，合法说明与围栏块仍保留）和真实 MoonBit 编译失败不发布；词法器另有缩进 ≤3 空格、4 空格/Tab 非围栏、波浪线围栏、超长开启围栏、长于开启的闭合、短闭合/脏闭合/异标记拒绝、空块、CRLF、信息串变体与 EOF 辅助块矩阵，以及 `replace_first_checked` 的逐字节保留、无尾换行和 CRLF 往返断言。
- 确定性模糊语料：400 个种子化随机文本文档验证词法器不 panic 且 `replace_first_checked` 对可解析文档字节幂等；目录与视图各 160 个确定性单字符变异验证解析器不 panic、被接受的输入重新规范化后可再次解析。它不是通用模糊测试框架，不替代覆盖率或无界随机探索。
- 依赖边界：`scripts/dep_audit.py` 检查 MoonBit 包单向依赖、纯引擎不导入 native 边界、模型/网络 SDK 禁止清单和第三方许可证/来源文件；它已纳入 `scripts/verify.sh`。
- 视觉声明 features：自定义只启用路由的 view 不生成搜索控件，page-data 写入能力列表，运行时按能力关闭富文本与格式化。
- MCP 初始化、工具调用、通知、非法请求、schema 与 CLI 对账；所有已声明 CLI 工具的未知字段前置拒绝。
- 增量 embedding 计划：确定性有界 Unicode 文本、模型/维度/正文版本隔离、编译失败不发布、来源变化拒绝提交，详见 [向量供给](../specs/engine/embedding.md)。
- provider 生命周期与执行交接：真实磁盘注册、相同请求幂等、配置冲突、心跳、embedding/search 空间绑定、撤销拒绝、当前页面版本和 embedding 输入文本校验、provider-job open/claim/heartbeat/complete/cancel/fail、租约抢占/续租/过期失败、embedding 向量原子发布、search 候选校验、失败后保持 pending、失败终态重放和审计记录，见 `scripts/provider_e2e.py` 与 `scripts/provider_jobs_e2e.py`；任务路径已纳入事务及 pack/unpack 白名单。
- Agent 编写协议：真实磁盘上的输入版本令牌、结构化草稿整批校验、暂存与编译发布、失败续传、外部编辑/来源竞态，见 [编写协议](../specs/engine/authoring.md)。
- 精简 Web 服务：HTTP 读取/搜索和直接 native 调用对照、固定 vault、参数/路径约束、`dedup`/`spread`/`provider` 检索字段对齐、body/来源漂移拒绝、登记后刷新及编译失败保留旧输出，见 [服务说明](web.md)。
- 确定性 ZIP 与 Python 标准库/独立编码器交叉核对，全部解包发布中断点恢复、二进制/工单/草稿/视觉源一致性及敌意容器拒绝。
- native 分发包回归会重复构建 tar.gz，核对字节级确定性、manifest 逐文件哈希/大小、许可与精简 Web/监听适配器的完整性，并验证旁路 SHA-256 文件。
- `lint` 白盒回归覆盖 evidence 正文 UTF-8 范围漂移，以及 schema 合法但引用页面不可解析的 evidence 记录（`evidence_reference_unresolvable`）；native evidence 回归继续覆盖精确 raw 锚点错引、来源漂移和失效传播。
- 状态事件回归拒绝未知 `op`、未知字段、缺少必填字段和伪造内容寻址路径，并以完整 `refresh` 夹具覆盖事务中断后的回滚/前滚；provider、研究、导入和页面生命周期事件均通过真实流程重新核对。
- CI 配置在 Ubuntu 重放完整 `verify.sh` 并产出 Linux native 分发包（`dist/` 归档 + 校验和上传为 artifact）；Windows 新增 native job（官方 PowerShell 安装器、`moon check/test/build`、分发包脚本）和既有 `clang-cl` 语法 job，但尚未从本仓执行，Windows native 运行时证据仍未取得。见 [CI 说明](ci.md)。
- OKF v0.2/普通 Markdown 导入导出实际磁盘核对：未知 YAML 与原件保留、标准 sources 对象、断链审核、原始/编辑往返、二进制资源、部分导出重试、外部编辑冲突、编译失败和输入竞态均已验证。
- 两种 WASM 实际实例化、零 imports、UTF-8/中文/非 BMP 字符、长页查询摘要、360 字节边界、向量、非法输入和字典一致性。
- WASM classic/WASM-GC 快照会话实际验证创建/恢复路径与正文哈希、宿主编译回调、索引最后发布、编译失败、重放和外部冲突；不把内存会话写成 native 磁盘等价物。
- 真实项目固定 6 查询的检索/来源装配小样；报告保留数据哈希。
- 多领域基线已用真实 native 工单覆盖物理、医学、软件、食品四类资料，固定中英文问题检查 top-3 召回、来源绑定和 64..1024 字节预算上限；报告见 [multidomain-quality-report.json](multidomain-quality-report.json)。不宣称模型生成质量或事实正确性。
- 规模诊断脚本已用真实 16/64/128 页长页 vault 测量关键词、暴力向量、混合检索、ranked/even/similar 配额对比及 1/2/4/8 进程锁竞争，结果见 [规模基线](../specs/engine/scale.md) 和 [本机报告](scale-benchmark.json)。这是趋势基线，不是跨平台性能或并发 SLA。
- 敌意 native 门禁覆盖未知字段、路径穿越、检索预算/限制、向量维度、重复 frontmatter、无效视觉声明、原件 symlink 和超长请求；每次拒绝都核对 vault 快照，见 [敌意输入](../specs/engine/adversarial.md)。
- 按产品实现的非空非注释行检查 MoonBit >85%，平台/MCP/SDK/监听器/Web 传输及内嵌 JS/CSS 均计入；当时 native 门禁包含 96 项 MoonBit 测试，源码比例约 87.31%（source audit 口径）；这两个数字随后已增长，见上方的时点说明。
- `scripts/platform_smoke.sh` 已纳入门禁：当前 POSIX 文件适配 C 语法检查通过；Windows 分支只有在调用方提供 `WINDOWS_CC` 和 Windows sysroot 时才执行，默认明确显示 skipped。

实际浏览器检查另见 [视觉记录](visual-mbtmd.md)，富文本截图保留在 docs/reading-rich-wide.png 和 docs/reading-rich-mobile.png。`verify.sh` 经 scripts/reading_fixture.py `--with-map` 在有 Chrome 时自动运行纯 Python 标准库的 headless CDP 检查（scripts/reading_map_browser_cdp.py，2026-10-30 起以 `--window-size=1280,800` 固定视口，替代原先随环境漂移的默认窗口——Linux 下字体度量差异曾使溢出断言在 800px 级默认宽度上翻转），覆盖快照图渲染、边/节点/共享来源虚线、节点点击路由、水平不溢出（失败时报告最宽的越界元素）与 console 零错误；无 Chrome 二进制时显式跳过。Markdown/HTML、格式化切换、代码高亮、离线图片、隔离、深链和手机布局由浏览器工具执行的记录覆盖，不声称全部进入自动门禁。

精简 Web 服务再次通过同一浏览器脚本（使用分配的 loopback 端口），宽屏与手机检查通过，运行时错误 0，无外部依赖请求，见 [Web 浏览器记录](web-browser-check.json)、[宽屏截图](web-wide.png)和[手机截图](web-mobile.png)。绕过服务读取前的引擎验证，会使正文漂移后的 `/api/status` 断言失败；恢复后真实 HTTP 测试通过。

小样报告不能充当任意资料的质量保证。未验证的范围包括：多领域模型生成质量/成本、跨平台规模阈值和高并发排队服务、Windows/Linux native 分发、完整 CommonMark/YAML/Unicode 语言分词、浏览器中的原位知识写入与实时排名、大包/压缩容器和 WASM 内核内置持久事务。Node WASM 文件快照适配器的 PID 锁、死亡锁回收、原子替换、重启恢复和顺序冲突已由 `wasm_session_e2e.mjs` 覆盖；Web Locks + localStorage 适配器的哈希、CAS 冲突和无锁拒绝由 `wasm_web_storage_e2e.mjs` 覆盖。Windows native 分支已写入 `platform/fs.c`，但当前环境缺少 Windows sysroot，未纳入通过证据。OKF/Markdown 往返和普通容器路径已由独立磁盘测试覆盖；向量计划提供页面前缀，实际模型推理由外部调用方提供。

2026-10-16 按用户指示移除本次桌面集成 worktree、分支、桌面专用适配/测试/报告与相关分期任务；原应用 checkout 未修改。此前桌面测试数字不作为本独立引擎当前门禁记录。

源码计数是固定规则的工程门槛，不是覆盖率或实现质量分数。尚未交付的能力在 tasks.md 保持未勾选。

## 未触达的校验分支

`core/records.mbt` 与 `agent/` 下每个 `@base.fail(...)` 都是一条命名分支。一个分支没有任何测试引用时，移除它全套件照绿。

截至本文更新时：`core/records.mbt` 的 191 个分支与 49 个 lint 谓词**全部**有测试引用；`agent/` 层 156 个分支中 137 个有引用，剩余 19 个的触达路径与失败原因逐条登记在 [未触达的校验分支](unreachable-branches.md)。

该文档同时记录了本会话沉淀的触达手法（纯记录层字段篡改、选择性拆除、改序列化）与操作层面的坑（变异中断后必须重编译、catalog 副本过期、用例位置约束、事件定位必须用业务字段等）。改动 `record_validation_e2e.py` 前先读它。
