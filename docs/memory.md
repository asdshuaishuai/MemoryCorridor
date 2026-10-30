# 记忆层说明

MemoryCorridor 的核心不调用模型，也不推断「什么值得记住」。本文件说明引擎如何承接 [A5](https://huggingface.co/blog/KYLN24/introducing-a5) 提出的终身上下文（lifelong context）与主动性（proactivity）理念，以及哪些判断明确留给外部宿主。

## A5 理念到引擎机制的映射

| A5 | MemoryCorridor |
| --- | --- |
| `MEMORY.md` 概览层，会话开始时进入上下文 | `purpose.md`（目标）与 `wiki/overview.md`（综述），由 `memory-prefetch` 的 `overview` 字段始终返回 |
| 详细笔记保存具体事实与适用条件 | `state/memory/<sha256>.json` 记忆笔记，`conditions` 是身份的一部分 |
| Workspace Memory / User Memory | 仅接受 `scope:"workspace"`；跨 vault 的用户级记忆需要独立机制，未实现即拒绝 |
| Memory Prefetch：BM25 找候选，预取 Agent 再筛选 | `memory-prefetch` 只做候选排序与有界装配，`selection:"host_required"`；种子可以是 `query` 或某个知识页（用其 title+body 确定性派生），对应「结合当前对话筛选」 |
| 交互结束后由提取 Agent 决定保留什么 | `memory-submit` 由外部 Agent 调用；引擎校验、去重、落库 |
| Autodream 保护低频但重要的记忆 | `pinned` 位；`memory-pin` 设置/清除，`memory-archive` 拒绝归档 pinned 笔记 |
| Autodream 合并重复、修正过时内容、保留冲突背景 | `memory-supersede` 原子替换并保留双向链与旧 JSON；`memory-prefetch` 的 `dedup:"similar"` 在候选阶段合并改写变体 |
| Autodream 主动发现待整合项（合并候选 / 精简候选） | `memory-candidates` 无需种子给出两类候选；判定规则全部沿用既有不变量，输出按 id 稳定排序，只读不写 |
| Autodream 保留判断的适用条件，无法确认的冲突保留背景并标为待确认 | `conditions` 参与分组键；`memory-conflicts` 与 `memory-prefetch.conflicts` surfaced 冲突候选，lint 以 warning 报告 |
| 长期未用的记忆归档，仍可查找和恢复 | `memory-archive` / `memory-restore`；`memory-use` 提供 `last_used_at` 使用信号，`pinned` 保护低频但重要的记忆 |
| 记忆保留可核对的依据 | `sources` 绑定 raw 并记录当时 SHA-256；撤销进 `invalid_sources`，字节改写进 `drifted_sources`，两者都置 `valid:false` |
| Diff Engine：判断变化是否与进行中的工作相关，必要时回查原文 | `impact-audit`/`impact-list`/`impact-resolve`，按工单冻结的输入确定性比较，见下文 |
| 回原文核对细节 | `read-source`，可取的 UTF-8 字节区间与 evidence 锚点同约定 |
| Proposal Engine：筛查已完成/执行中/重复事项后进 Inbox | `inbox` 只读汇总，一个主题只提议一次，漂移原因并入 `drift` |
| Context 索引：材料节点 + 按主题组织的语义节点 | `synthesis` 页为语义层，`topics` 只列语义层供逐层浏览 |
| Workspace Wiki：页面带来源引用和版本历史 | `page-history` 汇总提交/归档/恢复/来源撤销及各版本 SHA-256 |

## 变化影响：Diff Engine 的承接

A5 的 Diff Engine 判断「已接入上下文的变化是否与正在推进的工作相关」，并把相关更新送回到下一步之前。引擎里的持久化工单——研究主题、purpose/overview 建议、已发布综述——在创建时都冻结了自己依赖的输入，因此相关性可以确定性计算，见 [协议](../docs/protocol.md) 中的 `impact-audit` / `impact-list` / `impact-resolve`。

三条设计约束：

- **只比较知识输入。** 研究主题按 `inputs_hash`（purpose、raw、页面、向量的指纹）比较，排除全部 state 记录。新增工单、建议或再次审计都不会被误判成新材料。
- **不累积记录。** impact 按 `kind/subject/cause` 内容寻址，一个工单一条；已发布综述只在没有任何 applied 记录匹配当前页面时报告，因此发布更新的综述会关闭旧记录而不是叠加新记录。
- **处理过的不再重报。** 漂移消失时自动 `resolved` 且不带决定摘要；`impact-resolve` 写入 `dismissed`（当时的输入）后，只有输入再次变化才重新打开。这对应 A5「重新提出用户拒绝过的建议时，需要说明出现了哪些实质变化」。

### 冲突：保留而不是二选一

A5 的 Autodream 明确「不同条件下成立的记录可以并存，无法确认的冲突则保留背景、标为待确认，在再次用到时向用户求证」。引擎因此不替宿主判断谁对：

- 分组键是 `kind` + 规范化后的 `conditions` 集合（顺序不影响）。同一条件下两条 `preference` 说了不同的话就是候选冲突；换 `kind` 或换条件都不是。
- `superseded` 与 `archived` 笔记不参与分组，所以替换或归档某一侧即解除冲突；收窄某一侧的条件同样解除冲突。完全相同的正文不算冲突——那是重复，提交时已经拒绝。
- 冲突两侧都保留可读。解除的两种方式——`memory-supersede`（换条件或换正文）和 `memory-archive`——都会留下记录，审计时能看到当时的判断和它的适用条件。
- `memory-conflicts` 给出全量视图，`memory-prefetch` 只在候选相关时把冲突一起送回，对应 A5「在再次用到时向用户求证」。

### 主题浏览：语义层与材料层分开

A5 的 Context 索引把「具体文件/网页」与「按主题组织的语义节点」分成两层，可以先浏览主题再定位材料、回原文核对。引擎里 `synthesis` 页（`wiki/overview.md` 和宿主提交的综述页）就是语义层，entity/concept/source-summary/query 是材料层。`topics` 只列语义层，带 `title`、`links`、`sources`、`stale_sources` 和 `body_bytes`，因此浏览不需要逐页读取；来源撤销时进入 `stale_sources` 而不被静默丢弃。

### 页面版本历史

A5 的 Workspace Wiki 要求「页面保留来源引用和版本历史，供用户查阅、核查和修正」。引擎此前只在归档/恢复事件里记了页面哈希，提交事件只记工单和来源，因此某页发布过哪些版本无法恢复——`state/orders` 的 `page_hashes` 是 `context` 时点的快照，不是发布记录。

现在 `commit` 在 `ingest` 事件里追加 `pages`（本次发布的每页 SHA-256），`page-history` 于是能把提交、归档、恢复和来源撤销连成一条时间线，并给出当前哈希以便核对旧引用。`pages` 对本变更前的事件可缺省：旧事件仍可读，只是没有逐页历史。

### 回原文核对

引擎一直登记、哈希并引用 raw 来源，evidence 也把 claim 绑到 raw 字节区间，但从没有一个 op 下发来源字节——宿主只能自己读盘，也就无法判断读到的内容是否就是目录登记的那份。`read-source` 补上这一环：返回登记元数据、digest 是否仍匹配、失效状态和内容，并可用 `start`/`end` 取 UTF-8 字节半开区间，与 evidence 锚点用同一约定，因此「核对一条 claim」变成一次精确读取而不是全文比对。

### 收件箱：把理解变成可执行的下一步

A5 的 Proposal Engine 汇集上下文变化、已完成交互和知识更新的证据，筛查掉已完成、执行中或重复的事项，再把值得提出的送进 Inbox 由用户决定。引擎不做「是否值得做」的判断，因此只实现其中确定性的部分：`inbox` 汇总全部待处理工作（打开的 impact、pending 审核、`proposed` 工单、失效页面、未登记来源），每条带建议操作，并按 kind+subject+reason 稳定排序。

三条约束：

- **一个主题只提议一次。** 若某条工单已有专门条目，它的漂移原因并入该条目的 `drift` 字段，不再单列 `impact`。这对应 A5「排除已完成、执行中或重复的事项」。
- **待确认项也进 inbox。** 记忆冲突（`memory-conflict`）和来源已失效或被改写的记忆笔记（`memory-source-stale`，`source-revoked-or-drifted` 与 `source-bytes-changed` 两种 reason）都需要人或宿主确认，条目带建议操作，与审核债务同级，而不是只作为 lint warning 存在。
- **空 inbox 就是「不提出建议」。** A5 明确「缺乏足以推动当前工作的新信息时，Agent 也可以不提出建议」；`items` 为空即此意，宿主无需轮询各个 list 再拼装。
- **stranded 的工单必须能关闭。** 基线漂移后的建议永远无法应用，`purpose-cancel`/`overview-cancel` 把它移出待处理集合，记录和冻结上下文仍保留用于审计。

仍未承接：A5 的主动候选生成——由 Proposal Agent 判断「是否值得建议」，是模型判断，按项目约束归外部宿主。除此之外，A5 中能由无模型引擎确定性完成的机制都已落地：终身上下文与预取、Diff Engine、Autodream 的冲突保留与去冗余、Proposal Engine 的筛查与 Inbox、Context 索引的主题分层、Workspace Wiki 的引用与版本历史。`quality-audit` 与 `review-resolve` 提供 HumanGate 审核债务与人工决定机制，是主动候选生成的现成承接点。
## 设计约束

- **适用条件是一等身份。** `note_hash` 绑定 `kind/scope/text/conditions/sources`。同一句话在不同条件下成立就是两条笔记，修正条件会生成新记录而不是静默改写旧记录。
- **修正不丢历史。** supersede 在同一事务中写新记录、把旧记录标为 `superseded` 并建立 `superseded_by`/`supersedes` 双向链。旧 JSON 永久保留，参与 pack 与审计。
- **合并是判断，不是默认行为。** 不同 `key` 但判断相同（`kind`/`scope`/`text`/`conditions`，不含来源绑定）返回 `memory_duplicate_text` 并指出已有记录 id，由宿主决定 supersede 还是归档。冲突分组同样只看判断：两条笔记说同一件事就不是冲突，哪怕它们引用不同来源。重复判定只针对 `active` 笔记——归档后的笔记仍然可恢复，不该挡住同一判断的重新提交。
- **失效是读取时计算，且区分两种原因。** state 条目不能携带目录 `sources`，因此来源绑定记在 JSON 内。`forget` 后来源缺失或撤销 → `invalid_sources`；来源被整体改写并重新登记 → `drifted_sources`（与记录时的 SHA-256 不同）。后者曾经查不出来：笔记会继续自称「可核对」，而它引用的证据已经变成完全不同的内容。evidence 靠 `source_quote` 校验能抓到这种漂移，记忆层现在靠 `source_hashes` 也能。没有 `source_hashes` 的旧记录按路径判定，仍然可读。
- **去冗余绝不掩盖冲突。** 处于未解决冲突中的笔记不参与 `similar` 合并——合并会丢掉一侧，宿主就看不到需要确认的竞争判断。相同条件 + 不同正文本身就是冲突候选，因此 `dedup:"similar"` 只合并不构成冲突的改写变体（不同 `kind` 或不同 `conditions`）。
- **去冗余不删记录。** `dedup:"similar"` 只影响默认候选集合：合并发生在排名与预算阶段，`similar_duplicates` 指明保留者与被合并者，两条笔记都仍可列出、归档和恢复。门槛与页面检索共用（分词序列相等 + 双侧 64 字节），因此短笔记不会因偶然相同的词元被合并。
- **中断恢复按发布点逐一测试。** `agent/transaction_safety_wbtest.mbt` 用会在第 N 次 `write` 时崩溃的 store 驱动 `memory-pin`（7 次写入）、`memory-supersede`（8 次写入）和 `impact-audit`（两个 impact 一次提交，9 次写入），覆盖每个发布点：恢复后要么整笔落地要么整笔回滚，supersede 双向链不会半应用，pinned 笔记仍拒绝归档。批量事务额外断言「要么 0 条要么 2 条」以及每条落地的记录都有已登记进目录的事件——后者专门抓漏掉 event change 的情况（该断言已验证：把 event change 删掉后测试立即失败）。外部改写 `state/` 记录一律以 `content_changed` 拒绝并被 lint 报出。
- **登记位置集中在一份清单。** 新增一类持久化工单要在记录校验、事件字典、两个路径白名单、工具字典、schema、dispatch、lint、inbox 和测试里分别登记，漏一处不报编译错只会在运行时静默破坏。`docs/extending.md` 是这份 checklist；`state_directories()` 把两个路径白名单收成单一来源，`core/state_dirs_wbtest.mbt` 验证列表里每个目录都有校验分支。
- **事件必须登记进目录。** 每次记忆状态转移都写事件，且事件条目必须 upsert 进目录；漏掉 upsert 会让文件成为孤儿——`read-log` 和 `verify` 都看不到它。`lint` 的 `file_unregistered` 专门抓这类问题，开发过程中它当场抓到过三处漏登记。
- **守护测试要用变异检验，不能只看名字。** `scripts/mutation_check.py` 对 80 个关键守护逐一注入缺陷（身份派生、记录校验、事件路径绑定、冲突分组、来源漂移、重复判定、archived 不阻塞、memory-use 时间戳与批量原子性、topics 语义层过滤与撤销来源、page-history 事件装配与来源撤销、read-source 区间校验、lint 的孤儿文件/源漂移/冲突判定、inbox 的两类记忆条目与 drift 归并、inbox 条目的幂等去重、dispatch 入口必须先校验、supersede 掉的笔记不报漂移、撤销来源让笔记 invalid 而非 drifted、lint 不得对 superseded 笔记报漂移、commit/research/purpose/overview/provider 的事件必须登记进目录、impact 与 inbox 的一主体一提案、`memory-candidates` 的冲突/pinned/merge 参与者不提名、跨 kind 不合并、所有 duplicate 指向同一 keeper、prefetch 的 limit 默认值与检索图扩展的两跳默认、evidence 锚点必须按偏移切片而非全文查找、记录的 body 锚点不得按 frontmatter 平移、字节区间切字符必须拒绝而非静默返回空串、lint 必须在金库损坏时仍可运行、schema 整数与字符计数边界（search 预算上限、read-source 偏移上限、memory 文本/条件/来源数量）、记录与 provider job 终态的字段拒绝、外部编辑目录时恢复日志必须保留、session-close 自行释放 vault 锁、lint 的 frontmatter 字段命名与 evidence 引用不可解析（`evidence_reference_unresolvable`）、wasm 服务边界的 -3 缺失/-1 拒绝映射、读重试缓冲增长与 wasm 会话锁释放），断言对应测试真的失败；跑完恢复原码并校验，被信号打断也不会留下变异。`topics`/`page_history` 没有 MoonBit 行为测试（只有 schema 断言），因此这两条变异附带 e2e 脚本——`moon test` 或该 e2e 失败都算捕获。它当场抓到两处「看起来在测但其实没测」：impact 身份派生被更早的 path 检查挡住、以及 execution 测试只查字典。现已纳入 `verify.sh`（约 15 分钟，其中 56 条 e2e 变异每次先 `moon build`——含 wasm 服务变异的 wasm 模块重建——再跑脚本）。**每条变异都必须带 e2e 脚本名，如果该行为只有 e2e 覆盖**——漏写会让 `moon test` 全绿通过，缺陷被藏住；本次补 6 条新变异时有 5 条一开始漏写，全部假阴性。这个失误发生了两次，因此检查器现在自己扫描 `scripts/*_e2e.py` 的成功输出：若某条变异的 `expected_test` 是某个 e2e 成功消息的前缀却没带 e2e 名，直接 exit 2。注意它本身差点静默失效——第一版正则写错，18 条成功消息一条都没匹配到，守护等于不存在。此后又修掉它三个真缺陷：备份文件名用 `replace("/", "_")` 往返有损（`agent/page_history.mbt` 会还原成 `agent/page/history.mbt`）；启动时发现已有备份会直接删掉而不是恢复，被 timeout 杀掉的运行于是把生产代码留在变异状态；`finally` 里重建 `cli`/`mcp` 成功但不重建测试驱动，紧接着的 `moon test` 会报假失败。三者共同点：**守护自身的故障模式和它要防的故障一样不可见**。

这个检查工具本身也出过两次错，都值得记下：一是 `"failed:" in output` 会匹配 `failed: 0`，导致五条 e2e 变异全是假阳性——上轮报告「全部捕获」时其实一条都没捕获；二是 e2e 用的是已编译的二进制，不重新 build 就等于测上一个版本；修正后还发现跑完变异会在二进制里留下最后一个缺陷，因此结尾统一重新 build。修正后 15/15 真正被捕获，且跑完不会给后续命令留下脏状态。还有一类坑：某个变异「抓不到」可能说明代码本来就对——`inbox_counts` 的排序在调用链里是冗余的（上游已排序），直接删掉它行为不变。这时该改的是测试：改成直接调用这个函数并故意传入未排序输入，让它真的守护自己的契约，而不是靠调用链兜底。**验证工具和被测代码一样需要被怀疑。**

- **只读不挂 execution。** `execution:"host_required"` 表示「引擎记下了计划，等宿主执行」，只属于写操作。`memory-read`、`read-source` 等读操作曾误返该字段，会让通用客户端以为还欠引擎一个动作；现已移除，`read-source` 的 binary 分支用更精确的 `extraction_required` 表达「需要外部抽取」。`agent/sources_wbtest.mbt` 直接驱动这些 op 断言字段缺席（而不是只查字典），并已验证：把字段加回 `memory-read` 后测试立即失败。
- **预取不写入，使用由宿主显式回报。** `memory-prefetch` 是只读操作，不更新任何状态。A5 的 Autodream 要归档「长期未用于前台交互」的记忆，这需要一个引擎无法从读取行为推断的信号，因此由 `memory-use` 批量登记 `last_used_at`；`memory-list` 返回该字段，宿主据此决定归档对象，`pinned` 则保护低频但重要的记忆。

## 典型流程

```json
{"op":"memory-submit","kind":"preference","scope":"workspace",
 "text":"优先安排陶瓷窑口对比的参观时间","conditions":["规划博物馆行程时"],
 "sources":[],"at":"2026-10-20T09:00:00Z","key":"ceramics-preference"}
{"op":"memory-prefetch","query":"陶瓷 参观 时间","limit":5}
{"op":"memory-submit","kind":"preference","scope":"workspace",
 "text":"优先安排陶瓷窑口对比的参观时间，并保留半天自由活动",
 "conditions":["规划博物馆行程时"],"sources":[],
 "at":"2026-10-20T10:00:00Z","key":"ceramics-preference"}
{"op":"memory-archive","id":"<note id>","at":"2026-10-20T13:00:00Z"}
```

`memory-prefetch` 返回的每条候选都带 `conditions`、`valid`、`invalid_sources` 与 `conflicted`：宿主应先判断条件是否适用于当前请求，再决定是否采信。来源已失效或存在竞争判断的候选都不应作为依据。

## 验证

`scripts/memory_e2e.py` 覆盖提交与重放、重复拒绝、supersede 链、归档与恢复、pinned 保护、来源漂移失效、冲突分组与解除、similar 合并不掩盖冲突、page 种子预取、非法 kind/scope/条件/来源、孤儿事件文件、状态指纹不变，以及 pack/unpack 往返。`agent/memory_wbtest.mbt` 覆盖身份派生、JSON 往返、记录与事件字典的拒绝路径和工具 schema 边界；`agent/transaction_safety_wbtest.mbt` 覆盖每个发布点的中断恢复与外部编辑冲突。

其余承接层各有自己的 e2e：`impact_e2e.py`（漂移检测、幂等重放、resolve/reopen、批量事务与 pack 往返）、`inbox_e2e.py`（汇总、去重、drift 归并、排空）、`topics_e2e.py`（语义层与材料层分离）、`page_history_e2e.py`（版本时间线与 pack 往返）、`read_source_e2e.py`（元数据、字节区间、binary 抽取、截断与 evidence 锚点核对）、`unregistered_e2e.py`（未登记文件检测）。全部由 `./scripts/verify.sh` 执行。
