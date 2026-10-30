# MemoryCorridor（记忆回廊）

将资料整理为可追溯、可检索、持续维护的知识。核心由 MoonBit 实现，不调用模型或网络。

当前已有可运行的 native 引擎、CLI/MCP、单 vault 进程会话、检索维护闭环、OKF/Markdown 互操作，以及由 `.mbt.md` 编译生成的富文本阅读页和精简本地 Web 服务。本项目只交付独立引擎与 Web 传输层，不包含桌面应用或专用桌面集成。完整分期方案见 [PROPOSAL.md](PROPOSAL.md)，逐项进度见 [tasks.md](specs/engine/tasks.md)，全量边界见 [实现审计](specs/engine/implementation-audit.md)。新增一类持久化工单的登记位置见 [扩展指南](docs/extending.md)，A5 理念的承接方式见 [记忆层说明](docs/memory.md)。

- `index.mbt.md` 是可由 MoonBit 检查的目录；每个条目显式登记 `format`，正文和原件保持独立 Markdown 或其他格式。已知文本格式会进入 Agent context，图片/binary 仍明确交给外部抽取。旧六字段目录可读取并在下一次生成时迁移为显式格式；文学化解析器会扫描整份文件的 MoonBit 围栏并拒绝未闭合块。
- `lint` 是不写入 vault 的诊断入口：目录语义、条目路径/格式/哈希、来源与正文漂移、页面 frontmatter/断链、state/vector/evidence 记录和检索缓存问题会以稳定排序的 `predicate/subject/path/detail/fix/severity` 返回；evidence 额外检查正文与精确 raw 锚点是否漂移；`verify` 仍是硬失败门禁。
- 工单分分析与页面提交两步，验证来源、内容哈希、互链、基线和实际编译结果，再通过可恢复事务发布。
- 页面支持显式 `archive-page` / `restore-page` 生命周期：归档传播依赖失效并保留正文与事件，恢复重新校验正文、来源和互链；两者都支持事务恢复与幂等重放。
- 默认中日韩/英文关键词倒排检索（汉字、假名、谚文音节的一元+二元组，拉丁词），可选外部向量和暴力余弦搜索；向量提供者与检索后端分别抽象。上下文定位查询证据、为多页分配预算，并对完全重复正文去重，保留每页来源和可核对的正文区间；显式 `dedup:"similar"` 还可合并分词序列相同的排版变体（大小写/空白/标点差异，双侧 64 字节门槛，来源独立保留），`spread:"even"` 按剩余候选均分预算，图邻居按「边权×跳跃⁻¹」排序补入（互链 3.0、共同来源 4.0），响应另带启发式 `estimated_tokens`/`truncated` 供成本核算。图支持互链/共同来源关系、无权和按关系权重的确定性最短路径，另有基础洞察；`quality-audit` 可把孤儿页、稀疏标签、未进入知识图的来源、证据覆盖缺口和缺少有效事实证据的页面记录为持久化 HumanGate 审核债务；四领域检索基线见 [quality.md](specs/engine/quality.md)。
- 终身记忆笔记以 `state/memory/<sha256>.json` 独立保存，吸收 A5「终身上下文」的分层做法：`purpose.md` 与 `wiki/overview.md` 作为始终进入上下文的概览层，记忆笔记是可按需读取的细节层，并显式登记 `conditions`（适用条件）与 `sources`（可核对的 raw 依据）。同 key 新内容原子 supersede 并保留旧记录，`memory-archive`/`memory-restore` 把长期不用的笔记移出默认预取范围；来源撤销后笔记保留历史但显式报告 `valid:false`；来源被整体改写则报 `drifted_sources`——两者都让 `valid:false`，因为笔记引用的证据已经不可核对。`memory-read` 按 id 读单条笔记，`memory-pin` 保护重要判断（pinned 笔记拒绝归档），`memory-use` 登记前台使用情况供宿主判断哪些笔记可归档。`memory-prefetch` 可按 `query` 或按某个知识页（用其 title+body 作确定性种子）给出 BM25 风格候选与 `overview`，`dedup:"similar"` 可合并改写变体（只影响候选集合，记录仍可恢复），`kinds` 可按类型过滤；`selection:"host_required"` 表示筛选仍由外部宿主决定。`memory-conflicts` 按 `kind` 与适用条件分组列出竞争的判断，`memory-prefetch` 随候选一并 surfaced；两侧都保留可读，收窄条件或归档某一侧即解除冲突。见 [记忆层说明](docs/memory.md)。- 确定性 `.mcpack` 保存原件、正文、工单、草稿与视觉源；解包校验后发布，支持中断恢复。见 [容器格式](docs/pack-format.md)。
- 研究目标、工单、审核和事件属于持久状态；`.corridor/` 仅缓存。撤销来源会传播失效，删除缓存不会丢人工决定。
- `read-source` 按 id 读取已登记 raw 来源及其哈希校验状态，可用 UTF-8 字节区间精确核对 evidence 锚点。
- `page-history` 按时间列出某页的发布、归档、恢复和来源撤销历史及各版本 SHA-256，供核对旧引用。
- `topics` 只读列出 `synthesis` 主题层页及其 wikilink 与来源，可先浏览主题再定位材料、回原文核对；来源撤销进入 `stale_sources` 而不被丢弃。
- `inbox` 只读汇总所有待宿主处理的工作：change-impact、审核债务、研究/目标/综述工单、失效页面和未登记来源，每条带建议操作（含记忆冲突、来源失效的记忆笔记这类待确认项）；一个主题只提议一次，空 inbox 表示无需主动介入。基线漂移后无法再应用的建议可用 `purpose-cancel`/`overview-cancel` 关闭，记录仍保留。
- `impact-audit` 把持久化工单冻结的输入与当前 vault 比较：研究主题的新材料、综述建议的目标/页面变化、以及人工改写的已发布综述都会记为 `state/impacts/` 的 change-impact；漂移消失自动关闭，宿主处理后按当时输入抑制重报，输入再次变化才重新打开。`impact-resolve` 记录宿主决定，`status/stats` 报告 `impacts.open`。
- 持久事件使用固定操作字典和逐操作字段集合；未知 `op`、未知字段、缺少必填字段或不匹配内容寻址路径的 `state/events/*.json` 会在验证阶段拒绝，避免伪造状态被当作审计记录保留。
- 研究空白可通过 `research-topic` 创建持久化主题/查询工单；外部 Agent 完成联网后将结果写入 `raw/`、调用 `scan`，再用 `research-complete` 或 `research-cancel` 关闭工单。引擎本身不联网。
- `purpose-suggest` 冻结目标与知识上下文供外部 Agent 生成建议，人工确认后由 `purpose-apply` 原子更新 `purpose.md`；旧基线或人类外部编辑会被拒绝。
- `overview-suggest` 冻结页面、来源和图上下文，外部 Agent 生成 `synthesis` Markdown 后由 `overview-apply` 原子发布 `wiki/overview.md`；状态会明确显示综述是否缺失或过期。
- `views/*.mbt.md` 定义标题、配色、面板布局和数据绑定，MoonBit 渲染为自包含 HTML；支持 Markdown/HTML 实际呈现、语言高亮、代码格式化、原文核对和来源跳转；`graph` 面板另有确定性环形快照图（实线互链、虚线共享来源、查表坐标、节点 hash 路由、孤立节点静态）。见 [视觉文档](docs/visual-mbtmd.md)。
- WASM 还提供 UTF-8 快照会话和宿主编译回调，同一会话内异步事务串行化并向持久化适配器提供 `base_revision`；Node 宿主可用 `sdk/wasm-node-storage.mjs` 保存完整快照，浏览器/Worker 可用 `sdk/wasm-web-storage.mjs` 通过 Web Locks 接入 `localStorage`，缺少锁能力时明确拒绝写入。见 [WASM 边界](docs/wasm.md)。
- 外部 Agent 通过通用 CLI/MCP 读取上下文、提交分析和结构化草稿，经 MoonBit 版本校验、编译和事务后发布。见 [编写协议](specs/engine/authoring.md)。
- CLI 可用 `progress:true` 请求结构化 started/completed/failed 事件；MCP `tools/call` 提供 `_meta.progressToken` 时映射为标准 `notifications/progress`，终态响应保持唯一。
- `embedding-plan` 按模型空间和页面哈希返回增量向量任务；外部调用方生成后提交，核心使用默认暴力搜索或替换后端。provider 支持注册、心跳、撤销、空间绑定和持久 job open/complete/cancel/fail；embedding job 完成时原子发布 `vectors/`，失败终态保留原因，实际模型进程仍由宿主运行。向量提交和查询支持可读的 `values` JSON 数组，以及 little-endian f32 Base64 的 `values_b64` 载荷。见 [向量供给](specs/engine/embedding.md)。
- 精简 Web 服务直接提供编译后的阅读页及 status/pages/page/search/tree/topics/lint JSON 接口，固定启动时指定的 vault；search 的预算、图扩展、去重/配额策略、向量与 provider 参数与 native 引擎对齐；`lint` 可在正文漂移或缓存损坏时返回只读诊断。见 [Web 服务说明](docs/web.md)。
- `scripts/release.py` 生成包含 CLI/MCP、精简 Web/监听适配器、协议文档、许可、逐文件清单和 SHA-256 的确定性 native 分发包；它只打包当前主机已构建的目标，不宣称跨平台交叉编译。见 [分发说明](docs/release.md)。
- `.github/workflows/verify.yml` 有三个 job：Ubuntu 跑 `./scripts/verify.sh` 全量验证并构建上传 `memorycorridor-native-linux` 分发包，`windows-native` 在 Windows 做原生 check/test/build 并上传 `memorycorridor-native-windows`，`windows-filesystem` 用 clang-cl 检查 `platform/fs.c` 语法。CI 迄今的运行中，两个构建 job 都因注册表依赖解析失败（`moonbitstack/moonyaml` 未找到）、新版工具链移除无参数 `moon install`，以及 latest 工具链把 `to_json()` 弃用告警在 `--deny-warn` 下变成错误而退出；现两个 moon job 只保留 `moon update`（依赖按需拉取），并按 `.moonbit-version` 把工具链固定在本机验证过的 `0.10.14+7d59c7ec9`（moon/moonrun 0.1.20260920），尚待首个绿运行。见 [CI 说明](docs/ci.md)。
- `scripts/scale_benchmark.py` 可在真实临时 vault 上测量不同规模的关键词/暴力向量/混合检索和 vault 锁竞争；结果是本机诊断基线，不是跨平台 SLA。见 [规模说明](specs/engine/scale.md)。
- OKF v0.2 与普通 Markdown 可从 `imports/*` 导入、向 `exports/*` 导出；原始文件、未知元数据和断链审核记录保留，导出拒绝覆盖冲突。见 [互操作设计](specs/engine/interop.md)。

需要已安装 MoonBit 工具链；当前验证 macOS/POSIX。首次构建（克隆后先同步注册表索引，`moon.mod` 声明的依赖由构建命令按需拉取）：

```sh
moon update
moon build --target native cli mcp
mkdir -p /tmp/my-vault
_build/native/debug/build/cli/cli.exe
```

在该进程输入：

```json
{"op":"init","vault":"/tmp/my-vault","purpose":"研究目标"}
{"op":"list-tools"}
```

将资料放进 `/tmp/my-vault/raw/` 后调用 scan，通过 context / analysis-submit / draft-submit / commit 完成摄入（draft-submit 把结构化页面写入 staging，commit 校验并发布）。参数、页面格式、监听和失败恢复详见 [协议与工单](docs/protocol.md)。外部模型与二进制文档抽取由宿主提供。

运行精简 Web 服务：

```sh
python3 scripts/make_demo.py /tmp/corridor-demo
_build/native/debug/build/web/web.exe /tmp/corridor-demo --port 8768
```

浏览器打开 `http://127.0.0.1:8768/`。也可直接离线打开 `.corridor/viewer.html`。页面源仍是 vault 中的 `views/library.mbt.md`，没有独立前端项目。demo 同时包含四份概念页与一份主题综述页、七条记忆笔记（其中一条绑定 raw 来源，`dating-a`/`dating-b` 构成同条件冲突组，`reworded-a`/`reworded-b` 是仅标点不同的合并候选）、一个开放的研究工单，以及该工单冻结后新增材料造成的 baseline-drift，可直接试 `topics`、`memory-prefetch`（可用 `page` 指定某一页作种子）、`inbox`、`memory-list`、`memory-conflicts`、`memory-candidates` 和 `read-source`：

```sh
_build/native/debug/build/cli/cli.exe <<'EOF'
{"op":"topics","vault":"/tmp/corridor-demo"}
{"op":"memory-prefetch","vault":"/tmp/corridor-demo","page":"overview"}
{"op":"inbox","vault":"/tmp/corridor-demo"}
{"op":"memory-list","vault":"/tmp/corridor-demo"}
{"op":"memory-conflicts","vault":"/tmp/corridor-demo"}
{"op":"memory-candidates","vault":"/tmp/corridor-demo"}
{"op":"read-source","vault":"/tmp/corridor-demo","id":"raw/项目方案.md","start":0,"end":19}
EOF
```

验证入口为 `./scripts/verify.sh`（仅 WASM 实例化 e2e 需要 Node.js 22+ 作为 JS 引擎宿主，可通过 NODE_BINARY 指定；浏览器检查是纯 Python 标准库实现，不再需要 Node）。已验证纯函数测试、真实磁盘/编译器/进程锁与恢复、MCP 生命周期和字典/schema 对账、WASM 双产物，以及实际浏览器中的宽屏/手机 Web 交互。源码占比由 `scripts/source_audit.py` 检查，计入 C/Python/JavaScript 适配及内嵌 JS/CSS，排除测试、文档、生成样例和用户数据，门槛为 MoonBit >85%。

[富文本宽屏截图](docs/reading-rich-wide.png) · [富文本手机截图](docs/reading-rich-mobile.png) · [真实项目检索小样报告](docs/quality-report.json) · [WASM 边界](docs/wasm.md)

质量报告使用固定问题和人工参考页，只验证该真实项目样本的检索/来源装配；尚不证明模型生成知识的语义正确率，也不以小样推断普遍效果。首版视觉页面使用受控 `.mbt.md` DSL；WASM 持久文件系统、多平台分发与广泛质量/成本验收按后续阶段推进。

MIT；独立实现，无 llm_wiki 的 GPL 代码继承。许可与来源说明见 [NOTICE](NOTICE)。
