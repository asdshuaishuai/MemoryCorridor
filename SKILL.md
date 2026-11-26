# MemoryCorridor Agent 使用指南

面向外部 Agent/宿主的操作指南：如何驱动 MemoryCorridor 引擎完成摄入、检索与维护。所有操作名、字段与边界均以 [协议与工单](docs/protocol.md) 为准；本文件只是入口摘要。引擎由 MoonBit 实现，**不调用模型或网络**：分析、总结、向量生成和联网检索都由外部调用方完成，引擎只做校验、记账与确定性检索（CLI/MCP 接收数据，不接收可执行回调）。

## 连接与会话

- 运行 `_build/native/debug/build/cli/cli.exe`：stdin 每行一个 JSON 请求，stdout 恰好一个终态 JSON，编译器日志走 stderr，EOF 或 `:exit` 退出。请求上限 2 MiB，单文件上限 16 MiB。
- 首选会话模式：先发 `{"op":"session-open","vault":"/absolute/my-vault"}`，之后请求可省略 `vault`，`session-close` 释放会话锁；跨 vault 请求会被拒绝。兼容模式下每个请求自带同一 `vault` 也可以，但不能中途切换。
- `list-tools`（或 `help`）无需 vault，返回全部操作的允许字段和 JSON Schema；先发现字典再调用。MCP 形态工具名加 `corridor_` 前缀、连字符转下划线（如 `corridor_read_page`），schema 与 CLI 同源。
- 同步日志式进度：CLI 请求加 `progress:true` 会在唯一终态响应前输出 `started|completed|failed` 事件；MCP 在 `_meta.progressToken` 存在时发送标准 `notifications/progress`。省略则保持每请求一行。

## 摄入闭环

把原件放进 `raw/` 后按序调用，工单依次进入 `pending → context-ready → analysis-done → committed`（终止为 `cancelled`）：

1. `init` 初始化 vault 并写入 `purpose.md`；`scan` 登记原件及其 SHA-256，产生工单。
2. `plan` 列出可继续的非终态工单；`context` 按 `order` 读取研究目标、来源全文与既有页面哈希，并返回 `context_token`。
3. `analysis-submit` 提交分析（`entities`/`concepts`/`conflicts`/`summary`）；`conflicts` 在提交时变成持久审核项。同一 vault 同时只允许一个非终态工单进入分析。
4. `draft-submit` 提交 1..32 项页面，每项精确为 `{id,kind,title,sources,tags,body}`；引擎校验来源/互链后写入内容寻址 staging，返回可传给 `commit` 的 `pages` 清单和 `published:false`。模型不能指定路径或跳过编译提交。
5. `commit` 携带该清单正式发布；未提交 source-summary 时引擎生成明确标注的来源元数据兜底页。

幂等约定：自动宿主应在 `analysis-submit`、`draft-submit`、`commit` 中回传 `context_token`（固定来源/页面的登记版本，上下文变化会要求重新分析）；其中 `draft-submit` 的 `context_token` 必填、缺失即拒绝，只有 `analysis-submit`/`commit` 的旧式手工调用可省略。已提交工单的 `commit` 重放不重新发布内容。外部模型只能生成分析文本和页面正文，系统操作全部走引擎。

## 检索与读取

- `search` 是主入口：`budget` 1..65536、`limit` 1..100、`hops` 0..2、`dedup` 默认 `exact`（可 `similar` 合并分词序列相同的排版变体，双侧 ≥64 UTF-8 字节）、`spread` 默认 `ranked`（可 `even` 均分预算）。命中按图边权（互链 3.0、共同来源 4.0）除以跳跃距离补入上下文候选；`hits` 本身仍是关键词/向量排名。可选 `query_vector` 或 `vector_candidates` 参与融合，两者互斥。
- 响应的 `used` 精确等于所有块 `text` 的 UTF-8 字节数；`estimated_tokens`/`truncated` 是启发式成本参考，不是特定模型的 tokenizer 值，预算语义始终是 UTF-8 字节。`excerpt` 最多 360 UTF-8 字节。
- 正文区间一律是**解析后 `Page.body` 的 UTF-8 字节半开区间**（`offset_unit:"body_utf8_bytes"`），不是 frontmatter、UTF-16 或原文件字节位置；按区间截取即可重建引用文本。
- 读取面：`read-page` 按页 id 读正文与证据、`read-source` 按 id 读 raw 原件、`page-history` 看页面版本时间线、`topics` 只读浏览 `synthesis` 主题层、`tree`/`graph`/`neighbors`/`path`/`weighted-path`/`insights` 探索图。`read-source` 可选 `start`/`end`（0..16777216，与 evidence 锚点同约定）精确核对字节；整篇读取按 65536 字节截断并置 `truncated`；binary/image 只报告体积并置 `extraction_required`，抽取由宿主负责：宿主跑完 OCR/PDF 抽取后用 `extraction-submit`（`source/kind/extractor/version/text/at`）入账，`context` 即返回该正文与 `extraction:{kind,extractor,version,bound_sha256,source_sha256}`；sidecar 与登记字节哈希强绑定，来源撤销或字节漂移后不再命中，OOXML 走引擎自抽通道不可被外部覆盖（`extraction_override`）。
- 证据：`evidence-submit` 提交 1..128 项 `{source,body_start,body_end,quote}`，必须满足 `utf8_slice(body,start,end)==quote`；可选 `source_start/source_end/source_quote` 进一步核验 raw 原文区间。相同内容重试返回 `replayed`；来源撤销或漂移后记录保留但显式 `valid:false`。

## 终身记忆与宿主判断边界

- `memory-submit` 记录记忆笔记：`kind` 取 `preference`/`decision`/`constraint`/`fact`/`goal`；`workspace` 必须已由 `workspace-open` 登记；`scope` 仅接受 `project`（工作区长期可见）或 `session`（必须带会话 id）。`text` ≤4096 字符、`conditions` ≤16 条、`sources` ≤32 个。可选 `layer` 取 `judgment`（默认）/`session_summary`（仅 session）/`profile`（仅 project），`episode` 只能经 `memory-promote` 产生；`importance`、`emotion`、`layer` 都进入身份哈希。同 key 新内容自动 supersede 并保留双向链，不同 key 但内容相同会拒绝并交给宿主判断。
- `memory-prefetch` 是只读候选排序：种子 `query` 或 `page`（用该页 title+body 作确定性种子）二选一，`limit` 1..50 默认 10，`kinds` 可过滤；默认 `rank:"bm25"`，显式 `rank:"weighted"` 时必须给 `now`（严格 ISO-8601 UTC），按 0.35 相关 + 0.30 强度 + 0.35 重要性排序，每条候选带 `score_components` 与 `tier`。返回始终带 `overview`。**`selection:"host_required"`——哪些候选被采信完全由宿主决定**，`conflicted`/`valid:false` 项不应作为依据。
- `memory-candidates`（必须显式 `now`）列出可合并的近重复组和按衰减提名的精简候选：core（pinned/importance≥0.8/episode）永不提名，important/normal 使用不同阈值，prune 带 `tier/decay/strength/score/age_days` 与 `never_used`/`decayed`。它只报信号，不自动删除；解决靠 `memory-supersede`、`memory-archive` 或 `memory-restore`。`memory-promote` 把 importance≥0.7 或情感强度≥0.7 的 active 判断提升为 episode（旧记录保留为 superseded）。
- `memory-conflicts` 列出同 kind 同条件但正文不同的竞争判断。`memory-use` 由宿主显式回报哪些笔记被前台用过（`memory-prefetch` 不会自动记录），供衰减/归档决策。`memory-export` 把项目级 active 记忆投影到 `workspaces/<id>/memory/`，它是派生物，不是第二权威。
- `workspace-wiki-plan` 只读计算工作区 wiki 投影：按 `raw/<namespace>/` 来源、显式 `pages` 与一跳共享来源页选页，返回页面/来源哈希、claims、manifest 与 `workspaces/index.mbt.md` 文本。宿主脚本 `scripts/workspace_wiki.py` 再写 `workspaces/<id>/wiki`、`claims`、`manifest.json` 和索引；`workspaces/` 不进入全局目录、检索或 pack。
- `dream-note-submit` 记录梦境提案（`insight`/`consolidation`/`episode_candidate`/`profile_candidate`/`session_summary`），绑定输入页面/记忆哈希与 claims 证据；`dream-note-list` 过滤；`dream-note-resolve` 只允许 retained/rejected/applied，applied 必须指向真实页面或活动记忆的匹配 hash。笔记只提案：知识应用走 `commit`，记忆应用走 `memory-*`。
- `inbox` 是只读汇总：打开的 change-impact、pending 审核、`proposed` 研究/目标/综述工单、失效页面、未登记来源、记忆冲突与来源失效的记忆笔记，每条带建议操作；**items 为空即无需主动介入**。
- `impact-audit` 比较持久化工单冻结的输入与当前 vault，只把漂移记为候选（`opened`/`updated`/`resolved`/`replayed`），宿主用 `impact-resolve` 记录处理决定，之后只有输入再次变化才重新打开。`execution:"host_required"` 只出现在记录计划等待宿主执行的写操作上（`purpose-suggest`、`overview-suggest`、`research-topic`、`review-resolve`、`impact-resolve`），读操作没有这个含义。
- 需要模型或联网的环节一律由宿主完成：`research-topic` 只生成查询工单，宿主联网后把结果写入 `raw/`、再 `scan`，最后 `research-complete` 或 `research-cancel` 关闭；`purpose-suggest`/`overview-suggest` 冻结上下文供宿主生成建议，人工确认后 `purpose-apply`/`overview-apply` 原子发布；向量由宿主经 `embedding-plan` → 外部模型 → `embedding-submit` 供给。

## 推荐 Agent 工作流

1. `session-open` 固定 vault；需要项目级记忆时先 `workspace-open`（路径由宿主规范化）。
2. 对话开始前用 `memory-prefetch`（可带 `page` 种子）取有界记忆线索；把实际使用的 id 用 `memory-use` 回报。需要更强的时间/重要性排序时显式 `rank:"weighted"` + `now`。
3. 需要整理时调用 `memory-candidates`（显式 `now`）；确认后的合并/纠正走 `memory-supersede`，高价值判断走 `memory-promote`，不要删除未确认笔记。
4. 需要生成工作区 wiki 时调用 `workspace-wiki-plan`（`workspace` + `namespace` 或 `pages`），把返回的 pages/claims/manifest/index_text 交给 `scripts/workspace_wiki.py` 写派生物；随后用 `memory-export` 生成记忆投影。
5. 梦境轮次用 `dream-plan`/`dream-open`（可绑定 workspace）取机会，宿主完成建议后用 `dream-note-submit` 记提案，`dream-note-resolve` 只接受真实页面/记忆哈希；知识应用仍走 `commit`，记忆应用走 `memory-*`。
6. 提交前 `lint`/`verify`；长驻宿主用 `inbox` 排空审核、来源和记忆债务。

CLI 例子（每行一个请求，`vault` 已在会话中时可省略）：

```json
{"op":"memory-prefetch","vault":"/abs/vault","workspace":"<id>","query":"项目 wiki 隔离","rank":"weighted","now":"2026-11-26T00:00:00Z","limit":5}
{"op":"workspace-wiki-plan","vault":"/abs/vault","workspace":"<id>","namespace":"project"}
{"op":"dream-note-submit","vault":"/abs/vault","workspace":"<id>","round":"<round>","kind":"insight","title":"...","body":"...","inputs":{"pages":[],"notes":[]},"claims":[],"at":"2026-11-26T00:00:00Z"}
```

MCP 工具名对应 `corridor_memory_prefetch`、`corridor_workspace_wiki_plan`、`corridor_dream_note_submit`；参数相同，先 `tools/list` 发现 schema。

## 错误与门禁

- 失败信封固定为 `{ok:false,error,error_code,hint,request_id}`：`error` 是可读详情，`error_code` 是稳定分类，`hint` 给下一步修复动作，`request_id` 原样返回。结构性拒绝附带 `violations:[{predicate,detail,fix,page?}]`，按项修复即可；CLI 与 MCP 用同一 MoonBit 生成逻辑。未知 op、未知字段和类型错误一律拒绝。
- `verify` 是硬失败门禁；`lint` 是只读诊断入口，目录或内容损坏时也能运行，返回 `status/errors/warnings/violations`，每条含 `predicate/subject/path/detail/fix/severity`。lint 的 warning 不等于 verify 通过。
- 人类编辑 `purpose.md` 或知识页必须显式 `refresh` 采纳；直接改写 `state/` 记录会被 `content_changed` 拒绝。页面生命周期用 `archive-page`/`restore-page`，来源撤销用 `forget`（黏性：写回相同字节不会自动复活）。

## 明确的边界

- 引擎没有内嵌任何模型：语义总结、向量、冲突取舍、"是否值得建议" 都是宿主/模型的判断，引擎只提供候选、校验和账本。
- WASM 入口只依赖纯核心，只执行纯函数 op：目录/页面/视图解析、关键词与向量检索、上下文装配、`graph` 系图查询和视觉渲染，以及 UTF-8 快照会话（配宿主编译回调，事务在实例内串行执行）；memory/impact/inbox 等需要 vault 磁盘或持久工单的操作都不在此面，宿主应改用 CLI/MCP。详见 [WASM 边界](docs/wasm.md)；完整操作面在 native CLI/MCP。
- 引擎交付独立服务与 Web 传输层；跨 vault 用户级记忆未实现（`scope` 仅 `project`/`session`），实现进度见 [tasks.md](specs/engine/tasks.md)。
