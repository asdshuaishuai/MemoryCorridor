# CLI、MCP 与工单

开发工具链：MoonBit `moon 0.1.20260920` / `moonc v0.10.14+7d59c7ec9`。目前验证 macOS/POSIX native。引擎不内嵌工具链；初始化、状态变更、页面渲染以及目录文本变化后的首次读取会调用本机 `moon check --deny-warn`。成功结果写入可重建的 `.corridor/catalog-compile.json`，绑定完整 `index.mbt.md` 字节哈希和目录 IR 指纹，后续读取复用收据，收据缺失/损坏/不匹配会重新编译。编译失败不会让运行期解析首个目录块绕过后续 `mbt` 代码块。

## CLI

运行 `_build/native/debug/build/cli/cli.exe`；stdin 每行一个 JSON 请求，stdout 恰好一个终态 JSON。编译器日志走 stderr；EOF 或 `:exit` 退出。首选会话模式是一个进程绑定一个 vault：先发送 `session-open`，随后请求可省略 `vault`，`session-close` 释放会话锁，跨 vault 请求会被拒绝。为兼容旧宿主，未显式打开时首个带 `vault` 的请求会绑定该根目录；后续 legacy 请求仍须携带同一 `vault`，每次操作单独持有 OS 写锁，不能切换到其他 vault。请求上限 2 MiB，单文件上限 16 MiB。wasm 服务面（见 docs/wasm.md）的请求经宿主分段装载达同一 16 MiB 上限，超限回复 `input_overflow` 且不回显 request_id（与 native 对超长请求的行为一致）。

```json
{"op":"session-open","vault":"/absolute/my-vault"}
{"op":"init","purpose":"研究目标"}
{"op":"scan","vault":"/absolute/my-vault"}
{"op":"plan","vault":"/absolute/my-vault"}
{"op":"context","vault":"/absolute/my-vault","order":"64位工单哈希"}
{"op":"analysis-submit","vault":"/absolute/my-vault","order":"64位工单哈希","analysis":{"entities":[],"concepts":[],"conflicts":[],"summary":"分析"}}
{"op":"commit","vault":"/absolute/my-vault","order":"64位工单哈希","pages":[],"at":"2026-10-16"}
{"op":"search","query":"知识","budget":4096}
{"op":"session-close"}
```

成功响应为 `{ok:true,op,result,request_id}`，失败为 `{ok:false,error,error_code,hint,request_id}`；`error` 保留详细可读文本，`error_code` 是稳定分类，`hint` 给出下一步修复动作。结构性拒绝还会附带 `violations:[{predicate,detail,fix,page?}]`，便于 Agent 逐项修复；CLI 与 MCP 使用同一 MoonBit 生成逻辑。`request_id` 可选并原样返回。`list-tools` 无需 vault，返回允许字段和 JSON Schema。未知操作、未知字段及类型错误均拒绝。

进度是显式结构化事件，不写入终态结果也不混入普通日志。CLI 请求增加 `progress:true` 后，会在唯一终态响应前输出 `{"event":"progress","op":...,"phase":"started|completed|failed","request_id":...}`；省略该字段保持每请求一行的兼容行为。MCP `tools/call` 在 `_meta.progressToken` 存在时发送标准 `notifications/progress`，`progress` 为 `0` 或 `1`，终态响应仍只有一个。

字典 schema 会准确区分数组元素：`queries`、`sources`、`capabilities` 是字符串数组，`pages`、`items` 是对象数组；`space`、`query_vector`、`vector_candidates`、provider job 的 `request/result` 是对象。整数参数还携带与引擎一致的 `minimum/maximum`：`read-log.limit` 为 `0..1000`，搜索 `limit` 为 `1..100`、`budget` 为 `1..65536`、`hops` 为 `0..2`，图 `hops` 为 `0..8`，`embedding-plan.limit` 为 `1..128`，`memory-prefetch.limit` 为 `1..50`，`read-source` 的 `start`/`end` 为 `0..16777216`。CLI 与 MCP 从同一 MoonBit 字典生成并在门禁中逐项对账。

## 页面生成与来源

`raw/` 原件可以是任意格式，以原始字节 SHA-256 登记。目录行的 `format` 是已验证的内容契约：Markdown/HTML、图片和代码语言分别记录为 `markdown`、`html`、`image` 或语言名，未知后缀为 `binary`；视觉服务和工单上下文都使用该登记值，不在运行时重新猜测。已知文本格式的 `context` 返回 `source_text`；图片和 `binary` 返回 null 和 `extraction_required:true`，由宿主负责提取，不能假称可直接全文搜索。旧版六字段目录缺少 `format` 时按 `kind/path` 推导并可读取，重新生成目录会写入七字段行。

raw 条目的 `id` 必须与 `path` 完全相同。页面 `sources[]`、事实证据和来源失效传播都以这个相对路径作为稳定引用；目录如果把同一原件登记成不同 id/path，校验会拒绝，`lint` 会返回 `raw_identity_mismatch`。

`index.mbt.md` 和 `views/*.mbt.md` 的目录/视图 IR 来自第一个 `mbt check` 代码块；后续 `mbt`/`mbt check` 块由 MoonBit 一起编译，可提供共享辅助定义和测试，但不改变引擎提取的 IR。代码块外的 Markdown 是可编辑说明，会被编译器忽略但仍随源文件保存。解析器统一接受 LF/CRLF，避免 Windows 编辑器产生的换行差异造成编译器与运行期分叉。首块内非字面量、不闭合代码块和不规范声明会拒绝；首个受检块闭合围栏之后的任何内容都必须以空行分隔（下一个字符为换行或文件结束）；紧跟围栏的裸文本按畸形 Markdown 拒绝（目录返回 `catalog_literate_tail`，视图返回 `view_literate_tail`，修复指引是补一个空行），不会静默当成无关注释；后续块的语法/类型由 `moon check` 拒绝。引擎提交或缓存重建只替换首个规范 IR 块，保留前后 Markdown 和辅助块；这些说明和辅助块不参与目录指纹。

工单依次进入 `pending → context-ready → analysis-done → committed`，终止也可为 `cancelled`。同一 vault 同时只允许一个非终态工单进入分析。`context` 提供研究目标、原始来源及既有页面全文/哈希，避免覆盖式重写。上下文变化会要求重新分析。分析里的 `conflicts` 在提交时变成持久化审核项。

`context` 还返回 `context_token` 和稳定的 `source_summary_id`。自动宿主应在 `analysis-submit`、`draft-submit`、`commit` 中回传该 token；它固定所有来源/页面/目标的登记版本与失效状态，拒绝模型调用期间的变动或被另一客户端刷新的旧上下文。分析和提交的旧式手工调用可以省略 token。已提交工单的 `commit` 重放不重新发布内容。

工单记录新增 `context_version`；旧记录缺失时按空串读取，下一次 `context` 会刷新版本并要求重新分析，避免沿用没有完整元数据基线的旧分析。

`draft-submit` 接收 `order`、必填 `context_token` 及 1..32 项 `pages`。每项精确为 `{id,kind,title,sources,tags,body}`；所有字段必填，`sources/tags` 为字符串数组，`body` 不含 frontmatter。引擎生成规范 frontmatter，保留已有页路径或为新页派生 `wiki/<id>.md`，校验来源/互链/上下文后才写入 `staging/<order>/generated/<hash>.md`。批次文本上限 1 MiB，整批校验失败不写草稿；成功返回可传给 `commit` 的 `pages` 清单和 `published:false`，不改变权威目录。模型不能指定路径或跳过正式编译提交。

Agent 写入 `staging/<order>/page.md` 后提交：

```json
{"op":"commit","vault":"/absolute/my-vault","order":"...","at":"2026-10-16","pages":[{"id":"concepts/example","path":"wiki/concepts/example.md","staged":"staging/.../page.md"}]}
```

页面前导只支持 `type`、`title`、`sources`、`tags`。字符串支持 JSON 双引号和 YAML 单引号；数组支持 JSON/YAML inline list 或 YAML block list，但未知字段和复杂 YAML 结构仍拒绝。页面类型为 `entity` / `concept` / `source-summary` / `synthesis` / `query`。来源必须包含当前工单原件；未失效页面的所有来源和 wikilink 必须有效。

```markdown
---
type: concept
title: 示例
sources: ["raw/example.md"]
tags: ["研究"]
---
正文与 [[concepts/another|其他页面]]。
```

链接以稳定 id 定位；支持显示别名和标题锚点（`[[page#标题|跳转]]`）。锚点只影响视觉路由，目录依赖仍只记录页面 id；片段必须非空、不能含第二个 `#` 或换行，渲染器按标题 slug 定位并在刷新后滚动。代码围栏与简单行内代码中的链接不参与依赖检查。`[[x|待建]]` 仍然要求 x 存在。

没有提交 source-summary 时，引擎生成一页明确标为“未生成语义摘要”的来源元数据页；不会把分析字段当作已核实的总结。已提交工单重试不重复记账。提交和取消后保留 staging 草稿供检查；当前没有自动清理策略。

## 外部编辑、恢复与缓存

`scan` 登记原件版本变化、取消过时工单并传播失效；遇到未登记的知识页修改会拒绝。`refresh` 显式登记已注册页面和 purpose.md 的人类编辑，校验来源及互链后重建缓存；暂不自动登记新建的未注册知识页。

`python3 scripts/watch.py /absolute/my-vault` 持续监听，`--once` 执行一次。存在默认视觉声明时同时重新编译视图；可用 `--view views/custom.mbt.md` 选择另一份视觉源。失败时顶层响应为 `ok:false`、退出码非零，并保留上次 HTML；下一次文件变化继续尝试。监听只负责发现变化，校验与发布由 MoonBit 执行。

提交先验证拟发布内容，再编译候选目录，重新检查来源/基线，然后写入 `state/transactions/pending.json`。正文和状态写入后，根目录最后发布。恢复按根目录的旧/新版本回滚或前滚；成功恢复会先把方向和原始 journal 写入内容寻址的 `state/transactions/history/<sha256>.json`，再移除 pending 日志，重复恢复保持幂等，历史内容冲突则保留 pending 并拒绝继续。发现外部编辑会保留日志并报冲突，不猜测覆盖。对外部编辑器而言，这不是多个文件的瞬时快照原子性。

`state/orders`、`state/reviews`、`state/research`、`state/suggestions`、`state/overview`、`state/evidence`、`state/memory`、`state/impacts`、`state/providers`、`state/provider-jobs`、`state/events` 以及 `state/transactions/history` 为权威记录；`state/transactions/pending.json` 是进行中的恢复日志；`.corridor/` 可整目录删除。`status` 会验证权威声明/正文并报告 `index_cache:valid` 或 `missing_or_invalid`，但不自动重建；`rebuild` 恢复缓存，`verify` 检查缓存缺失或损坏；`search` 可按需重建。缓存含算法版本、输入指纹及内容校验，不能替代文件版本检查。

`memory-candidates` 无参数，列出记忆整合候选而不做决定：`merge` 给同 token 不同字节的近重复组（`duplicate`/`keeper`/`reason:"similar_text"`，keeper 是组内 id 较小者），`prune` 给从未被宿主报告使用过的笔记（`reason:"never_used"`）。冲突中的笔记两项都不提名（丢掉一侧会藏住宿主必须确认的竞争判断）；pinned 不提名为 prune；已 supersede/archive 的是历史，不提名；来源失效或漂移的需要 `memory-supersede` 而非删除，不提名为 prune（该债务由 `inbox` 负责）；已参与 merge 的笔记不再提名 prune，否则会与它所并入的 keeper 自相矛盾。引擎只记录「宿主报告过使用」这一事实，不做 recency 阈值判断。只有 **kind 与 scope 都相同**才算重复——同样的词在不同 kind 下是不同类别的判断，合并会静默丢掉该区别；`memory-prefetch` 的 `dedup:"similar"` 应用同一条规则。
与 `memory-prefetch(dedup:"similar")` 共用 `@index.similar_eligible/similar_tokens/similar_merge`，两个面对同一对笔记给出一致答案；差别只是本 op 不需要种子。只读，不写 vault，也不返回 `execution:"host_required"`。
`lint` 是只读诊断入口，允许在目录或内容损坏时运行，不替代 `verify` 的硬失败门禁。它在能解析文学化目录时继续检查目录语义、raw 来源哈希、页面正文哈希、页面 frontmatter、来源/互链、state/vector/evidence/memory/impact 记录和 `.corridor/fts.json`；evidence 还会报告正文 UTF-8 锚点漂移、精确 raw 锚点漂移、引用页面无法解析的记录（`evidence_reference_unresolvable`），以及页面/来源撤销造成的陈旧状态；impact 额外报告 `impact_subject_missing` 与 `impact_no_drift`；memory 额外报告来源撤销或漂移造成的 `memory_source_stale`，单条记录无法表达的跨记录不变量（`memory_supersede_origin_missing`、`memory_supersede_target_missing`、`memory_supersede_link_asymmetric`、`memory_duplicate_note`、`memory_key_ambiguous`），以及 warning 级 `memory_conflict`。无法解析时至少报告目录语法问题，并尝试报告文学化编译问题。响应含 `status`、`errors`、`warnings`、`violations` 和兼容的 `stale` 字段；每条诊断固定包含 `predicate`、`subject`、`path`、`detail`、`fix`、`severity`，按这些字段稳定排序。`lint` 不写入 vault，也不把 warning 当作 `verify` 成功。

`state/events/` 只接受引擎已定义的事件操作；未知 `op` 会被 `verify`/`lint` 拒绝，不会被当作可保留的扩展事件。每个已知 `op` 还使用固定的顶层字段集合并检查必填字段、哈希、路径、时间、数组和嵌套空间；未知字段、缺少必填字段或不匹配内容寻址文件名同样拒绝。provider job、导入、建议、质量审核、证据、provider 注册、审核决议、研究、摄入等可由事件字段确定文件名的操作会核对完整路径；`refresh`/`forget` 等路径还依赖提交前后的全量 vault 指纹，仍通过字段和事务基线校验。事件字段按实际操作包括 provider job 生命周期、导入、目标/综述建议、质量审核、证据提交/替换、provider 注册、刷新、审核决议、研究工单、摄入和来源撤销。

目录损坏时，`read-last-valid` 可显式读取缓存的上次有效目录与正文，响应标记只读快照；所有引用仍重新核验，不能用旧目录掩盖正文漂移。缓存也被删掉时需先修复权威目录。

`forget` 保留原件与撤销标记，使依赖页和沿互链传播的页面失效并退出搜索。原件内容不变不会被 scan 自动复活；这不是备份或原件的物理擦除。`scan` 发现 raw 文件物理删除时也保留 stale 来源条目，并写入内容寻址的 `state/events/source-missing-*.json`；重复扫描不会重复记账，文件以新哈希重新出现时会创建新的来源版本和工单。

`archive-page` 接收页面 `id`、`at` 和人类 `reason`，在一次事务中将页面标记为失效、传播互链依赖、写入 `state/events/page-archive-*.json` 并刷新目录/日志；正文文件和来源原件保留。相同请求重放不重复写入，已失效页面拒绝新的归档请求。`restore-page` 只能恢复存在归档事件、正文哈希未变且所有来源仍有效的页面，并重新执行互链校验；来源已撤销或正文漂移时拒绝恢复。恢复事件同样持久化，页面归档不会自动恢复其下游依赖页。

## 检索、图与维护

- `search` 使用中日韩字符一元/二元组（汉字、假名、谚文音节，含半角片假名）与拉丁词倒排索引，可选 `query_vector:{space:{id,dimensions},values}` 或 `query_vector:{space,values_b64}`，以 RRF 融合关键词与暴力余弦结果。`values_b64` 是 RFC 4648 Base64 的 binary32 little-endian 字节，长度必须为 `dimensions*4`；`values` 与 `values_b64` 二选一。宿主也可提交 `vector_candidates:{space,hits:[{id,score}]}` 覆盖本次查询的本地暴力扫描，并用可选 `provider` 绑定 active search provider；引擎会校验空间、活跃页面、重复 id、有限分数和最多 100 个候选，再按候选顺序参与融合。两种向量输入互斥。命中后按图边权（互链 3.0、共同来源 4.0）除以跳跃距离打分，最多 `hops` 跳补入上下文候选并按分数降序、同分按 id 排序；`hits` 本身仍是关键词/向量排名。`embedding-submit` 接收 `{space,items:[{page,sha256,values|values_b64}]}`，可选 `provider` 绑定 active embedding provider；不同空间及旧页面向量隔离。没有模型向量或外部候选时只走关键词。关键词缓存标记为 `text-index-v3`，算法变化会使旧缓存失效并重建。
- `embedding-plan` 接收 `{space,limit?,provider?}`，按页面 id 排序返回缺失或旧版本的活跃页面向量任务；provider 存在时必须已注册且空间/能力匹配。批次默认 8、范围 1–128。结果含 `items:[{page,sha256,text,truncated}]`、`remaining`、`text_recipe` 与目录指纹。文本采用 `title-body-prefix16KiB-v1`，保留标题与正文的完整字符 UTF-8 前缀，最多 16 KiB；正文原件和关键词索引不截断。宿主应把文本配方计入空间 id，调用外部模型后经 `embedding-submit` 发布。无向量任务时不写入状态。
- `provider-register` 持久化 provider 名称、`embedding`/`search` 类型、能力、空间和 `memorycorridor-provider-v1` 协议；相同完整请求重放幂等，不同配置拒绝。`provider-heartbeat` 更新 active provider 的 `last_seen`，`provider-unregister` 标记 revoked 并保留事件。`provider-job-open` 创建带输入摘要和幂等键的 pending 执行信封，并绑定当前活跃页面版本；embedding 任务还必须原样携带 `embedding-plan` 生成的文本和截断标记。宿主先用 `provider-job-claim(id, worker, lease_until, at)` 原子领取任务，再用 `provider-job-heartbeat` 续租；有效租约内只有同一 worker 能完成或取消，过期领取可被新 worker 接管。`provider-job-complete`、`provider-job-cancel` 或 `provider-job-fail` 关闭它；领取者可以在租约过期后用 fail 明确记录超时。失败原因可记录超时、进程错误或协议错误，所有终态可重放且不能交叉覆盖。embedding job 的完成结果会在同一事务中校验并写入 `vectors/`；search job 的完成结果会校验空间、活跃页面、分数和重复项后保存。记录位于 `state/providers/` 和 `state/provider-jobs/`，参与目录指纹、事务恢复和 pack。引擎只管理生命周期、任务状态、租约和载荷校验，实际进程启动、推理、流式调度和模型成本仍由宿主负责。
- `EmbeddingProvider` 与 `VectorSearchBackend` 为独立 MoonBit 回调接口。嵌入式宿主可替换；CLI/MCP 接收数据，不接收可执行回调，也不调用模型或网络。
- `search.result.hits[].excerpt` 最多 360 UTF-8 字节，按不同查询词覆盖数选择段落；长段落定位最长匹配词附近，同分取较早段落。无词匹配（包括纯向量查询）取正文前缀。保留完整 Unicode 字符；排名规则不变。
- `search.result.context` 提供来源、路径、页面哈希、截断标记和该页的 `evidence` sidecar（含逐项 `valid` 与 UTF-8 区间）；`budget` 1..65536，按引用与正文的 UTF-8 字节总和保守计量；不是特定模型的精确 token 数，也不计 JSON 元数据。先装配排名候选，再补最多 2 跳图邻居。`spread` 默认 `ranked`：尚有候选时为当前页分配剩余预算的一半，至少容纳引用与一个 Unicode 字符；末页可用余额，短页释放余额。`spread:"even"` 改为按剩余候选均分剩余预算（同样至少容纳引用与一个 Unicode 字符），紧凑预算下覆盖更多排名页但每页更少。
- 上下文使用同一查询定位规则，`body_start/body_end` 为解析后 `Page.body` 的 UTF-8 半开区间，`offset_unit:"body_utf8_bytes"`；从页面正文按该区间截取即可重建引用后的文本。它不是 frontmatter、UTF-16 或原文件字节位置。`used` 精确等于所有块 `text` 的 UTF-8 字节数。响应另返回启发式 `estimated_tokens`（`estimate_recipe:"cjk_char_latin_word_v1"`：CJK/假名/谚文字符各 1、拉丁/数字词各 1，标点空白不计）、每块 `estimated_tokens` 和顶层 `truncated`（任一块未装完整正文）；它用于宿主成本核算，不是特定模型 tokenizer 的精确值，也不改变以 UTF-8 字节为单位的预算语义。
- 完整正文逐字相同的候选只装配一次；块内 `duplicates` 保留其他页的 `{id,path,sha256,sources,origin}`。部分逐字相同的段落从后续正文选择中排除，重复项同时出现在顶层和块内 `paragraph_duplicates`，包含页面、段落哈希、`paragraph_start/end` UTF-8 区间、来源和命中类型。各页版本独立，不合并为主页面来源。默认 `dedup:"exact"` 只做逐字合并，不做语义近似判断；显式 `dedup:"similar"` 额外把**分词序列完全相同且两侧各 ≥64 UTF-8 字节**的正文/段落合并（大小写、空白、标点等排版差异可以命中；改变任意字母、数字或 CJK 字符、词序或增删内容都不会命中），合并项记入 `similar_duplicates`/`similar_paragraph_duplicates`（含 `similarity:1` 和段落 `keeper_id`），被合并页的版本与来源独立保留。这是确定性的词典级近似，不是模型语义判断。`strategy` 标识实际规则：默认 `ranked_halves_exact_body_paragraph_v1`；opt-in 组合为 `<exact|similar>_body_paragraph_<ranked|even>_v2`。来源/正文变化与失效仍在装配前核验。见 [检索上下文规格](../specs/engine/retrieval-context.md)。
- `graph` 输出互链有向边与共享来源边（权重分别为 3.0 和 4.0，与检索扩展共用同一强度定义）；`neighbors` / `path` 探索时按无向图遍历。`weighted-path` 把边权作为路径代价计算确定性最短无向路径（互链 3 比共同来源 4 更便宜，权重相同按页面 id 解 tie）。`tree` 返回可直接消费的层级树 `{name,dirs[],pages[]}`，根节点名为 `wiki`；目录按名称排序，页面按 `index` 优先、名称和 id 排序，并保留 `id/title/path/kind/stale`。来源撤销后的页面仍出现在树中并标记 `stale:true`。`insights` 给出孤儿、跨类型连接、稀疏标签、确定性连通分量、节点 degree/weighted_degree、edge_kinds，以及基于边权和稳定标签 tie-break 的 `communities:[{id,members,weight}]`；社区分析是可解释的加权标签传播启发式，不宣称语义聚类或模型质量。
- `quality-audit` 接收显式 `at`，在当前已验证图快照上把孤儿页、稀疏标签、已登记但没有活跃知识页依赖的 raw（`unreferenced_source`）、仅有 legacy raw 锚点的页面（`legacy_evidence_anchor`）、raw 原文锚点漂移/撤销/无法核验的页面（`invalid_evidence_anchor`）、已有有效 claim 但正文覆盖不完整的页面，以及没有有效事实证据的 entity/concept/synthesis 页面转为持久 `state/reviews/` HumanGate 债务；每条审核记录保存 `predicate/subject/page/source/input_fingerprint`，`review-list` 额外返回 `input_status`（`current`/`stale`/`unknown`），让历史决议与当前输入变化可区分。它不阻塞结构提交，按 raw/purpose/page/evidence 输入指纹内容寻址并支持相同请求重放。source-summary 兜底页不要求语义证据或覆盖报告。审核仍通过 `review-resolve` 由宿主或人类决定。
- `research-topic` 接收主题、1..16 个查询、显式时间和可选幂等键，写入 `state/research/<hash>.json` 并追加事件；相同键和相同内容重试返回 `replayed`，同键不同内容拒绝。它只生成宿主执行队列，不联网、不调用模型；宿主完成外部检索后把结果写入 `raw/`，再调用 `scan`。`research-complete` 只接受已登记且仍有效的 raw 路径并将工单置为 `completed`；`research-cancel` 关闭未完成工单；两种终态转移均追加事件并支持相同请求重放。
- `purpose-suggest` 冻结当前 `purpose.md` 哈希、vault 基线、图和洞察，写入 `state/suggestions/<hash>.json`；外部宿主据此生成建议，人类确认后调用 `purpose-apply`。应用前必须同时匹配目标哈希和去除建议自身记录后的上下文基线，更新与事件在同一事务中发布；目标发生外部变化时拒绝，避免覆盖人类编辑。
- `overview-suggest` 冻结 purpose 哈希、所有活跃知识页哈希、vault 基线、图和洞察，写入 `state/overview/<hash>.json`；外部宿主提交完整 `synthesis` Markdown 到 `overview-apply`。页面来源必须是当前有效 raw，wikilink 必须通过常规页面校验，更新 `wiki/overview.md`、目录视图、建议状态和事件在同一事务中发布。`status/stats` 根据冻结输入报告 `missing`、`pending`、`current` 或 `stale`。
- `evidence-submit` 接收 `page`、当前页面 `page_hash`，以及 `items` 数组内的 1..128 个 `{source,body_start,body_end,quote}`（`source_start`/`source_end`/`source_quote` 可选）。每个来源必须是当前有效 raw；同一来源可以提供多个独立正文区间，但完全重复的 claim 会被拒绝。范围是解析后 `Page.body` 的 UTF-8 字节半开区间，必须满足 `utf8_slice(body,start,end)==quote`。可选的 `source_start/source_end/source_quote` 三字段会进一步要求 `utf8_slice(raw_text,source_start,source_end)==source_quote`，并在返回中标记 `source_quote_verified:true`；省略时兼容旧记录但不宣称原文区间已核验。返回的 `source_anchor` 将 provenance 强度明确标为 `exact`、`legacy` 或 `invalid`，不代表语义蕴含。记录按内容寻址写入 `state/evidence/<sha256>.json`，同时追加事件；相同内容重试返回 `replayed`。`evidence-list` 和 `read-page.evidence` 返回证据及逐项 `valid`，页面版本、正文范围、来源原文漂移或来源撤销后保留记录但显式标记失效。`status/stats` 返回证据记录的 `records/valid/invalid` 以及 exact/legacy/invalid raw 锚点计数。
- `evidence-replace` 接收相同页面和 claims 字段以及旧证据 id `previous`。新记录必须通过 exact/legacy raw 校验；旧记录页面版本必须一致且未被替换。引擎在同一事务中写入新内容寻址记录、`evidence-replace` 事件，并给旧记录加 `superseded_by`。旧 JSON 永久保留用于审计和 pack，但当前 `evidence-list`、检索来源和覆盖统计只计算未被替换的记录；相同请求幂等重放，旧记录或页面版本不匹配会拒绝。
- `memory-submit` 记录终身记忆笔记：`kind` 取 `preference`/`decision`/`constraint`/`fact`/`goal`，`scope` 仅接受 `workspace`，`text` ≤4096 且不含 CR，`conditions` ≤16 条适用条件（各 ≤256、不含换行），`sources` ≤32 个 raw 路径。记录内容寻址写入 `state/memory/<sha256>.json`：`note_hash` 绑定 kind/scope/text/conditions/sources/source_hashes，`id` 再绑定幂等 `key`，因此适用条件和来源版本都属于笔记身份的一部分。同 key 同内容重试返回 `replayed`；同 key 新内容在同一事务中把旧记录标为 `superseded` 并写 `superseded_by`/`supersedes` 双向链，旧 JSON 保留用于审计；仅当该 key 已有 active 记录时自动 supersede，出现多条 active 记录则拒绝 `memory_key_ambiguous`。不同 key 但内容完全相同拒绝 `memory_duplicate_text`，是否合并由宿主判断。来源只登记在 JSON 内（state 条目不能携带目录 sources），撤销或漂移在读取时计算：笔记保留历史，同时显式报告 `valid:false` 与 `invalid_sources`。
- `memory-supersede` 按显式 `id` 替换笔记，继承其 `kind`/`scope`，`key` 省略时沿用旧键；已 superseded 或已 archived 的笔记拒绝，离开归档状态必须先 `memory-restore`。`memory-archive`/`memory-restore` 在 `active` 与 `archived` 之间转移，把笔记移出或移回默认预取范围，`archived_at` 随之写入或清空；重复归档或重复恢复返回 `replayed`，事件路径由 `at` 派生，因此每次状态转移必须提供新的时间戳。读取时区分两种失效：`invalid_sources` 是来源缺失或已撤销，`drifted_sources` 是来源仍在但字节已变（与记录时的 SHA-256 不同）；`valid` 同时覆盖两者。`inbox` 的 `memory-source-stale` 条目用 `source-revoked-or-drifted` 与 `source-bytes-changed` 两种 reason 分别对应，`lint` 报告 `memory_source_stale` 与 `memory_source_drift`，`stats.memory` 分别计数 `invalid`/`drifted`。没有 `source_hashes` 的旧记录按路径判定，仍然可读。

`memory-list` 返回全部笔记、supersede 链、`valid`、`invalid_sources`、`drifted_sources`、`pinned`、`last_used_at` 与 `counts.active/archived/superseded/invalid/drifted`。`memory-read` 按 id 读单条笔记（含 `conditions`、`pinned`、`conflicted` 与来源失效状态），避免为读一条判断而列出整个记忆集。`memory-pin` 设置或清除 `pinned`：pinned 笔记拒绝 `memory-archive`，对应 A5「保护低频但重要的记忆」；相同请求重试返回 `replayed`，事件为 `state/events/memory-pin-<id>-<hash(pinned+at)>.json`。
- `memory-prefetch` 使用与页面检索相同的分词，对 `active`（显式 `archived=true` 时为非 superseded）笔记做 BM25 风格候选排序。种子查询二选一：`query` 由宿主给出，或 `page` 指定一个知识页，用该页 `title` + `body`（截断到 4096 字符）作确定性种子——对应 A5 预取代理「结合当前对话筛选相关内容」，宿主不必从页面里自行提炼关键词。两者同时给出或都缺失都会拒绝；`page` 必须指向已登记知识页。响应以 `query_seed` 标明用了哪一种（`query` 或 `page:<id>`），`limit` 1..50 默认 10，并按约 4096 估算 token 的预算跳过放不下的候选且置 `truncated`。`dedup` 默认 `none`；显式 `similar` 按页面检索同一套规则合并改写变体（分词序列相等且双侧 UTF-8 字节数 ≥64），保留排名靠前的一条并在 `similar_duplicates` 中报告 `{duplicate,keeper}`；相同正文在提交时已被拒绝，因此不提供 `exact`。`kinds` 可按 `preference`/`decision`/`constraint`/`fact`/`goal` 过滤候选，空数组不过滤。返回带 `score`、`conditions`、`valid`、`invalid_sources`、`conflicted` 的笔记，`conflicts` 与 `conflict_counts` 给出检索结果内部同条件冲突的分组，以及始终包含的 `overview`（`purpose`、`synthesis`、`synthesis_status`）。`selection:"host_required"` 明确候选筛选与使用方式仍由外部宿主的预取代理决定；引擎不调用模型，也不把候选当作已采纳的理解。
- `memory-conflicts` 列出全部冲突候选：`kind` 相同、适用条件集合相同（顺序不影响分组）但正文不同的 `active` 笔记归为一组，每组带 `kind`、`conditions` 和逐条 `conflicted:true` 的笔记视图。`superseded`/`archived` 笔记不参与分组，因此替换或归档某一侧会解除冲突；收窄某一侧的适用条件同样解除冲突，因为分组键包含条件。完全相同的正文不算冲突（属于重复，由提交时拒绝）。冲突是待确认的审核债务而非错误：lint 以 warning 报告 `memory_conflict` 并列出相关笔记 id，`status/stats` 的 `memory.conflicted` 计数，两侧记录都保留可读，由宿主通过 `memory-supersede` 或 `memory-archive` 解决。
- `impact-audit` 接收显式 `at`，比较持久化工单冻结的输入与当前 vault，把漂移记录为 `state/impacts/<sha256>.json`。`research` 主题按创建时记录的 `inputs_hash`（purpose、raw、页面、向量的知识指纹，不含 state 记录）比较，因此新登记的材料会产生 `baseline-drift`，而新增工单、建议或再次审计都不会。`overview-suggestion` 按冻结的 `purpose_hash` 与 `page_hashes` 比较，分别产生 `purpose-drift` 与 `page-drift`。`overview-synthesis` 只在没有任何 applied 记录匹配当前 `wiki/overview.md` 时报告 `synthesis-drift`，因此发布更新的综述不会累积记录。记录按 `kind/subject/cause` 内容寻址，一个工单一条；漂移消失时自动置为 `resolved`（`dismissed` 为空），同一漂移重现会重新打开。返回的四个计数语义明确：`opened` 为新建或重新打开的记录数，`updated` 为已有 open 记录因输入再次变化而被刷新的次数（`created_at` 保留，`updated_at` 前进），`resolved` 为漂移消失后自动关闭的次数，`replayed` 为与上次完全相同的次数。`impact-audit` 是只读式的活视图：重复执行不写入、不改变指纹，全部重放时返回 `committed:false`。显式 `key` 只在记录首次创建时生效，用于让宿主控制幂等键。
- `impact-resolve` 记录宿主已处理某条 impact 的决定，写入 `note` 并把 `dismissed` 设为该记录当时的 `current`。此后只有输入再次变化才会重新打开这条 impact——重新提出已被处理的建议必须说明出现了实质变化。相同决定重试返回 `replayed`。`impact-list` 返回全部记录、`subject_present` 与 `counts`；记录参与目录指纹、事务恢复和 pack 往返，open/host-resolved（带 `dismissed`）/auto-resolved 三种状态都完整恢复；`status/stats` 的 `impacts` 报告 `open/resolved/total` 与按 cause 的打开计数。
- `inbox` 是只读汇总入口，把待宿主处理的工作一次列出：打开的 change-impact、`quality-audit` 产生的 pending 审核、`proposed` 研究/目标/综述工单、被来源撤销或互连失效的页面，以及存在但未登记的 raw 文件。`memory-conflicts` 分组出的竞争记忆判断、绑定来源已撤销或漂移的 `memory-source-stale` 记忆笔记也作为待确认项列入，因为它们需要人或宿主确认，而不是静默取舍。每条含 `kind`、`subject`（目录路径）、`reason`、`detail`、`next`（建议操作）和 `created_at`；按 `kind`+`subject`+`reason` 稳定排序，重复调用结果与 vault 指纹都不变。一个 subject 只会被提议一次：若它已有专门条目，漂移原因并入该条目的 `drift` 字段，不再单列 `impact` 条目。已完成、已关闭或已被覆盖的工作不会出现；`items` 为空表示没有值得主动介入的事项。它不调用模型，也不替宿主决定是否执行。
- `purpose-cancel` 与 `overview-cancel` 关闭尚未应用的对应建议工单，写入 `closed_at` 并把状态置为 `cancelled`（`result_hash` 保持为 null）。基线已漂移的建议永远无法应用，取消是把它移出待处理集合的唯一方式；记录与冻结上下文保留用于审计和 pack。相同请求重试返回 `replayed`，已进入终态的建议拒绝。事件分别为 `state/events/purpose-cancel-<id>-<hash(at)>.json` 与 `state/events/overview-cancel-<id>-<hash(at)>.json`。
- `topics` 是只读的主题浏览层，对应 A5 Context 索引中「语义节点按主题组织成可逐层浏览的层次」：只列出 `synthesis` 页（`wiki/overview.md` 与宿主提交的综述页），每条含 `title`、`links`（wikilink 目标）、`sources`、`stale_sources`、`stale`、`sha256` 和 `body_bytes`。entity/concept/source-summary/query 是材料层，不出现在主题列表中。宿主因此可以先浏览主题、再定位材料页、最后回 `raw/` 原文核对，而不必逐页读取。来源被撤销时该来源进入 `stale_sources` 而不是被静默丢弃，同时 `stale` 置真。按页 id 稳定排序，重复调用结果与 vault 指纹都不变。
- `memory-pin` 之外的状态记录都不可被外部直接编辑：任何 op 都以 `@vault.verify` 开头，人工改写 `state/` 记录会以 `content_changed` 拒绝，且 lint 报告 `content_hash_drift`；恢复登记字节后才能继续。`purpose.md` 与知识页的人类编辑则必须显式走 `refresh` 采纳。

- `page-history` 按时间列出某页的完整生命周期：每次 `commit` 记录它发布的页面 SHA-256 与来源，`archive-page`/`restore-page` 记录当时哈希与原因，`forget` 在该页被牵连失效时记录被撤销的来源。对应 A5 Workspace Wiki「页面保留来源引用和版本历史，供用户查阅、核查和修正」。返回 `current`（路径、kind、当前 SHA-256、失效状态、来源）与按 `at` 稳定排序的 `versions`；事件按内容寻址，因此排序键是调用方提供的时间戳。`pages` 字段对本变更前已写入的 `ingest` 事件可缺省，旧事件仍然可读，只是没有逐页历史。

- `execution:"host_required"` 只出现在记录了计划、等待宿主执行的写操作上（`purpose-suggest`、`overview-suggest`、`research-topic`、`review-resolve`、`impact-resolve`）。所有只读操作都不返回该字段——读到它就意味着引擎在等宿主动作，读操作没有这个含义。

- `read-source` 按 id 读取已登记 raw 来源，对应 A5「回原文核对」与 Diff Engine「必要时回查原文」：引擎此前只登记、哈希和引用来源，从不下发字节，宿主只能自行读盘且无法判断读到的是否就是目录登记的那份。返回登记 `format`、`registered_sha256`、`stale`、`verified`（当前 digest 是否仍匹配）、`present` 与 `bytes`；文本来源附 `text`，`binary`/`image` 只报告体积并置 `extraction_required`，抽取交外部调用方。可选 `start`/`end` 取 UTF-8 字节半开区间（与 evidence 锚点同一约定），用于精确核对 `source_start/source_end`；整篇读取按 65536 字节截断并置 `truncated`，显式区间不截断。撤销后的来源保留墓碑条目，读取会报告 `stale:true` 而不是假装字节仍然有效。

- `memory-use` 登记本次前台用到过的记忆笔记（`ids` 1..64、显式 `at`），把 `last_used_at` 写为报告时间。这是 A5 Autodream「长期未用于前台交互的普通记忆应归档」所需要的信号——引擎无法从只读的 prefetch 推断使用情况，因此由宿主显式回报。一次批量报告只写一个事件（`state/events/memory-use-<hash(ids+at)>.json`），整批原子落地；相同请求重试返回 `replayed`。`memory-prefetch` 保持只读，不会自动记录使用。

- `review-resolve` 只记录 `create-page` / `research` / `skip` 决定，后续执行仍交宿主。每条审核记录带 `created_at`、输入快照和质量问题定位；决定带 `at`、`note` 和幂等 `key`，决议事件复制这些关联字段。省略 `key` 时引擎按审核 id、决定、备注和时间确定性生成；相同决定重试只返回 `replayed`，不同决定拒绝。成功决定与 `state/events/review-<id>-<hash(key)>.json` 在同一事务中发布。`backfill` 将显式输入归档成 `raw/queries/<hash>.md` 并进入正常工单；重试不重复。若登记失败，原件保留，下一次 scan 可继续。
- `forget` 的撤销是黏性的：它不删除文件，因此用**完全相同的字节**把文件写回来不会重新登记该来源——那相当于悄悄撤销一个人的撤销决定。重新登记要求内容发生变化（`scan` 才会建新工单）。绑定该来源的记忆笔记在此期间继续报告 `invalid_sources`，直到内容变化后重新登记。

- `stats`、`fingerprints`、`read-log` 提供统计、指纹和事件。`read-log` 可带 `limit`（`0..1000`）读取按稳定事件 id 排序的最后 N 条，省略时返回全部；它不把时间戳当作排序依据。`stats.evidence.coverage` 按页面返回正文 UTF-8 字节并集、有效 claim、万分比覆盖率和重叠区间，并按 raw 来源返回有效 claim/页面覆盖；页面和来源行还给出 `provenance`（`exact`/`legacy`/`mixed`/`legacy_partial`/`invalid`/`none`/`invalidated`），以及来源的 `direct_pages`、`stale_direct_pages`、`support`（`evidenced`/`linked`/`unreferenced`/`invalidated`）和 `basis:"provenance_v1"`，用于区分锚点核验强度与结构性来源覆盖状态。它只衡量已提交区间，不判断语义蕴含。
- WASM 快照会话在同一实例内串行执行异步事务；宿主 `persist` 回调收到版本化快照格式、`base_revision`、新 `revision`、排序文件和 SHA-256，可自行执行 compare-and-swap，并可返回确认的 `revision`；恢复会拒绝 hash 不匹配的快照，旧的无 hash `{revision,files}` 记录可迁移读取。该协议不提供跨实例锁，失败仍必须保留旧快照。

## 其余只读与适配操作

- `read-page` 按 id 读取知识页正文与来源，显式报告 `stale`，并附带该页的 evidence sidecar（逐项 `valid` 与 UTF-8 区间）；页面哈希与目录不一致时拒绝。`list-pages` 返回目录中的知识页条目（id/path/kind/format/sha256/sources/stale）；`read-index` 返回文学化目录源码，`read-purpose` 返回 `purpose.md` 正文，`read-last-valid` 显式读取上次有效目录快照（仍核验所有内容版本，没有静默 fallback）。
- `plan` 列出可继续执行的非终态工单；`cancel` 取消未提交工单；`research-list`/`suggestion-list`/`overview-list` 分别列举研究主题、目标建议和综述建议工单及其状态，供宿主恢复执行。
- `check-index` 实际编译文学化目录并校验引用文件；`recover` 恢复未完成的文件事务并返回是否发生恢复。两者都不改变知识内容。
- `view-init` 创建默认文学化阅读页面（拒绝覆盖），`render-view` 编译声明并输出离线阅读快照；声明细节见 [视觉文档](visual-mbtmd.md)。`import`/`export` 的 OKF/Markdown 互操作规则见 [互操作设计](../specs/engine/interop.md)，容器格式见 [容器文档](pack-format.md)。
- `provider-list` 与 `provider-job-list` 是上面 provider 生命周期的只读列举，字段与对应记录一致。
- `help` 与 `list-tools` 返回同一份工具字典，含每个 op 的字段与 inputSchema。

## MCP

所有操作都同时存在于 CLI 与 MCP：工具名加 `corridor_` 前缀、连字符转下划线，schema 与 CLI 同源。`scripts/mcp_e2e.py` 对新增操作做真实 JSON-RPC 调用（不只是字典比对），覆盖名称翻译、布尔/数组字段往返、只读操作不返回 `execution`、`memory-prefetch` 的两种种子互斥、`memory-use` 的批量与重放、`page-history`、`purpose-cancel`/`overview-cancel` 的终态与重放、`impact-audit`/`impact-resolve` 的状态机与 dismissed 抑制、错误信封的 `error_code`。所有 93 个广告工具都有字典/schema 全量比对，其中 88 个还真实走过 `tools/call`（其余 5 个是非 vault 或会话类 op）；探针刻意在 `init` 之前跑——金库未初始化，85 个 op 必须返回领域 `error_code`，而 `lint`（诊断入口）与 `recover` 必须成功。

启动 `_build/native/debug/build/mcp/mcp.exe`。使用换行 JSON-RPC 2.0 stdio；支持 `initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`。工具前缀 `corridor_`，连字符改为下划线，例如 `corridor_read_page`。`corridor_session_open` 要求 vault，其余工具可在已打开会话中省略 vault；工具列表/schema 与 CLI 来自同一字典。当前支持协议版本 2024-11-05 / 2025-03-26 / 2025-06-18。

三个 MCP 面的传输语义逐面对照：`tools/call` 的 `arguments.receipts` 是 schema 声明的传输字段（编译回执，纯 WASI 面的 `compile_required` 协议依赖它），三个面都接受并剥除——native 面由自身子进程编译，回执不进入引擎；请求行上限逐面不同：native `mcp.exe` 与纯 WASI 面（`wasipure --mcp`）为 2 MiB，超限回复 canonical `parse_error` 信封；corridor wasm 面（`hosts/wasm-host.py --mcp`）经 `input_load` 分段装载达 16 MiB，超限由宿主直写与模块 canonical 形态逐字节一致的 `input_overflow` 信封（含 `data.error_code`/`hint`，无法回显 request_id）。

工具执行失败使用 MCP `isError:true`，结构化结果含 `error_code` 与 `hint`；JSON-RPC 格式或参数错误使用带 `error.data` 的 error 响应。通知不产生响应。`structuredContent` 为 `{result:...}`。进度通知只在调用提供 `_meta.progressToken` 时发送；事件表示同步执行的边界，不承诺运行中取消或后台调度。

## 分发

`pack` / `unpack` 的内容寻址 ZIP 格式、路径与恢复规则见 [容器文档](pack-format.md)。解包只适用于新建目标，不用于覆盖融合；OKF 互操作为独立适配。
