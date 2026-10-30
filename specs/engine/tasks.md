# 实现进度

2026-10-17。勾选只代表这里写明的交付范围，不代表 PROPOSAL 全部阶段完成。

- [x] 工程骨架、SHA-256/严格 JSON/路径基础、条目/来源/页面校验。
- [x] 依赖边界门禁：单向 MoonBit 包层级、核心 native 边界隔离、模型/网络 SDK 拒绝和第三方许可证/来源文件核对。
- [x] index.mbt.md 规范字面量生成与受限解析、多个 MoonBit 文学化代码块组合、实际编译和内容版本校验；目录条目显式登记格式，旧六字段目录可迁移读取；首个受检块闭合围栏后的裸文本按畸形 Markdown 拒绝，合法说明与辅助块保留。
- [x] POSIX native 文件适配、OS 写锁、同步替换、事务日志、内容寻址恢复历史与所有发布中断点恢复测试。
- [x] CLI 工具字典/schema、初始化/扫描/工单/分析/暂存提交/读取，幂等与外部编辑冲突；native 长驻会话按目录文本版本复用已解析目录 IR。
- [x] 页面生命周期：`archive-page` 原子归档并传播依赖失效，`restore-page` 按正文/来源/互链校验恢复，事件保留且支持幂等重放。
- [x] raw 物理删除保留 stale 来源条目与确定性 `source-missing` 事件；重复扫描幂等，重新登记产生新版本工单。
- [x] 关键词倒排索引、verify/lint/rebuild、来源撤销/互链失效传播、显式人类编辑登记、持续文件监听；lint 提供只读、稳定排序的结构/内容/缓存/evidence 锚点诊断，verify 保持硬失败门禁。
- [x] CJK 分词统一为汉字/假名（含半角）/谚文音节的一元+二元组，拉丁/希腊/西里尔保持词元；索引缓存升级 `text-index-v3` 使旧缓存失效；日文子串查询通过 native 工单 e2e 验证。
- [x] 默认暴力向量、独立 embedding/search 回调、模型/维度/正文版本隔离及替换测试。
- [x] 图/邻居/路径（含按关系权重的确定性最短路径）/洞察，搜索结果图扩展，带引用和 UTF-8 字节预算的装配；搜索扩展按「边权 × 跳跃⁻¹」排序邻居，边权统一为互链 3.0 / 共同来源 4.0。
- [x] 冲突审核与人工决定持久化、显式回填进入工单、目标变化使旧分析失效。
- [x] `quality-audit` 将已验证图中的孤儿页/稀疏标签/legacy 或 invalid 证据锚点/证据覆盖缺口/缺少有效事实证据的页面转为内容寻址 HumanGate 审核债务，支持幂等重放、人工决定和缓存重建。
- [x] 研究主题工单：持久化主题/查询、幂等冲突、事务事件、`research-list` 宿主交接，以及只接受有效 raw 来源的 complete/cancel 终态；外部联网执行仍在引擎外。
- [x] purpose 建议工单：冻结目标上下文、外部建议交接、人类确认后的原子 `purpose.md` 更新、幂等重放和旧基线拒绝。
- [x] overview 建议工单：冻结目标/页面/图上下文，校验 synthesis 页面来源与链接，原子发布 `wiki/overview.md`，并报告 current/stale/missing/pending。
- [x] 事实证据 sidecar：`evidence-submit/evidence-list`、页面版本/raw 来源绑定、UTF-8 正文区间校验、同源多区间 claim、重复 claim 拒绝、失效标记、事务事件和 pack/unpack 纳入。
- [x] 事实证据可选精确 raw 锚点：`source_start/source_end/source_quote` 原文校验、漂移失效和旧四字段记录兼容。
- [x] 终身记忆笔记层（吸收 A5 的 lifelong context 理念）：`state/memory/` 内容寻址记录，`kind`/`scope`/`text`/`conditions`/`sources` 参与 `note_hash`，`id` 再绑定幂等 `key`；`memory-submit` 同 key 同内容重放、同 key 新内容原子 supersede 并保留双向链与旧 JSON，不同 key 的完全相同内容拒绝；`memory-supersede`/`memory-archive`/`memory-restore` 覆盖显式替换与归档（移出默认预取、可恢复）；来源只在 JSON 内登记，撤销/漂移在读取时计算为 `valid:false` + `invalid_sources`；`memory-prefetch` 用同一分词做 BM25 风格候选排序并按估算 token 预算截断，返回 `conditions` 与 `overview`，`selection:"host_required"` 明确筛选归宿主；lint 增加 `memory_source_stale` 与 supersede 链/重复/键歧义诊断；记录参与目录指纹、事务恢复与 pack 往返。- [x] 证据覆盖报告：`status/stats` 按页面计算有效 UTF-8 区间并集、重叠 claim 和万分比覆盖率，并按 raw 来源汇总有效 claim/页面；不把字节覆盖误报成语义蕴含。
- [x] 真实项目资料 + 人工参考页的 6 题检索/来源装配小样；记录分词问题与修复。
- [x] 查询定位的命中摘要与上下文、多页预算分配、精确正文去重与独立来源引用、UTF-8 定位及 native/MCP/WASM 验证；启发式 `estimated_tokens`（CJK 字符 + 拉丁词）与顶层 `truncated` 供成本核算；见 [检索上下文](retrieval-context.md)。
- [x] 检索上下文逐字重复段落去重、段落来源与 UTF-8 范围保留；语义等价判断仍不在核心内。
- [x] 显式 `dedup:"similar"` 确定性近似去冗余（正文/段落分词序列相等 + 双侧 64 字节门槛，`similar_duplicates`/`similar_paragraph_duplicates` 保留来源）与 `spread:"even"` 配额策略；校准脚本、单测、native/WASM e2e 与本机规模对比入 `scripts/retrieval_e2e.py`、`scripts/wasm_e2e.mjs`、`scripts/scale_benchmark.py`；默认 `exact`/`ranked` 行为字节不变。
- [x] 记忆按需读取与保护位（吸收 A5「详细笔记供 Agent 按需读取」「保护低频但重要的记忆」）：新增 `memory-read`(id) 单条读取与 `memory-pin`(id,pinned,at)；pinned 笔记拒绝 `memory-archive`，取消 pinned 后方可归档；记录新增 `pinned` 字段，`memory-pin` 事件路径绑定 pinned 与 at。
- [x] 扩展指南与目录白名单单一来源：新增 `docs/extending.md`，把「新增一类持久化工单」的登记位置写成 checklist（记录校验与身份可派生、事件路径绑定、事务/pack 白名单、工具字典、schema 类型与可选性、dispatch、lint、inbox 去重、单测/e2e/中断恢复/MCP 传输层/变异检验/文档，共 17 步）；`core.state_directories()` 成为事务与 pack 两个路径白名单的单一来源，`core/state_dirs_wbtest.mbt` 与 `vault/state_dirs_wbtest.mbt` 验证列表里每个目录都有 `validate_record` 分支且两个白名单都接受它（已双向验证：从列表移除目录、以及加入目录但不写校验分支，测试均失败）。
- [x] 跨层集成测试与 lint 语义修正：新增 `scripts/lifecycle_e2e.py`（13 项断言）覆盖
  「同一路径重新登记为新版本」这条真实路径——单层 e2e 各自为政，没有任何测试同时看记忆层、页失效、
  变更影响与 inbox。断言：笔记 `status=active`、`valid=false`、`drifted_sources` 指向该 raw 而非 `invalid`；
  页转 stale；`lint` 报 `memory_source_drift` 与 `stale_page`；`impact-audit` 打开 `baseline-drift`；
  inbox 把原因折进已有 research 条的 `drift` 字段而不是二次提案。
- [x] 上述测试跑出真缺陷：`lint_memory_notes` 对被 `supersede` 掉的历史笔记也报 `memory_source_drift`。
  历史笔记的源漂移不可处置（已被替代），且 `memory-list` 已为审计保留该信息，因此改为跳过 `status=="superseded"`；
  `memory_source_stale` 同样跳过。另有两个断言一开始按前缀 `page` 过滤谓词，而真实谓词叫 `stale_page`。
- [x] 来源撤销跨层路径：新增 `scripts/revocation_lifecycle_e2e.py`（11 项断言）作为 `lifecycle_e2e.py`
  的姊妹篇，覆盖「来源被撤销」而非「来源换新」。断言撤销后笔记是 `invalid` 而非 `drifted`（两类债务不同）；
  `lint` 报 `memory_source_stale`/`page_source_stale`/`stale_page`/`stale_source`；页转 stale；
  知识指纹移动使 `impact-audit` 打开 `baseline-drift`；inbox 仍按主体去重。
- [x] 该测试同时钉住 `inputs_hash` 的语义：它是**冻结基线**，撤销后不得变化；
  比对工作由 impact 层对当前指纹完成。（第一版断言写错，直接比较前后 `inputs_hash`，必失败。）
- [x] 并确认 `research-topic` 有意不接受 `sources` 字段：研究主题绑定知识指纹而非具体来源，
  因此任一路径变化都会移动指纹。这是设计选择，不是遗漏。
- [x] 文档与发布说明一致性：两轮跨层测试后复查，发现 `docs/memory.md` 仍写「22 个关键守护」
  （实际 32）与「9 条 e2e 变异」（实际 21），已改为实测值并补记「检查器自身差点静默失效」
  这段（第一版正则写错，18 条成功消息一条未匹配，守护等于不存在）。
- [x] `docs/release.md` 对文档集合的描述本来就不完整（未提 web.md/ci.md，也未提本次新增的两份），
  改为列出实际文档树，并明确说明文档引用的验证脚本（`verify.sh`、`mutation_check.py`、`*_e2e.py`）
  不在发布包内——发布包是精选运行时集合（16 文件：二进制 + serve/watch + 9 份文档），
  新增 e2e 脚本按设计不进入发布包。
- [x] `status`/`stats` 冗余校验（早前标记未做，本轮实测后处理）：`orders` 本身不校验（只读
  `state/orders/*.json`），但 `graph` 每次调用都跑一遍 `@vault.verify`。实测 24 页金库：
  `graph` 23ms、`stats` 50ms——即 `graph` 那次多余的校验占了 stats 一半成本。
- [x] 新增 `graph_unchecked`（跳过校验），应用到 4 处**可证明**调用方已校验的位置：
  `maintenance`（函数开头 45 行已校验）、`overview_suggest`（80 行已校验）、
  `assemble`（由 `search` arm 校验后调用）、`purpose_suggest`（35 行已校验）。
  `purpose_suggest` 原本在同一行把 `graph` 调了**两次**，改为绑定一次。
  `explore` 与 `quality_audit` 保留校验版本——它们由 dispatch 直达，之前没有任何校验。
- [x] 审查全部 `_unchecked` 调用点的安全性不变量（「调用方必须已校验」）：共 26 个函数用到，
  其中 9 个自身不校验。逐个追调用方后确认全部安全：`status_result`/`maintenance`/`inbox`/
  `impact_audit`/`impact_list`/`memory_prefetch`/`overview_suggest`/`evidence_for_page`/
  `evidence_list` 都先校验；`assemble` 由 `search` arm 校验后调用；
  `page_has_valid_evidence` 经 `quality_audit` → `graph` 间接校验；`lint_result` 是诊断路径，故意不校验。
- [x] 中断恢复覆盖面对照：AGENTS.md 要求中断恢复必须实际测试。`@vault.commit` 的 journal/回滚/前滚
  在 `vault/transaction_wbtest.mbt` 已逐点覆盖，但**agent 层**（每个 op 自己拼 change list）只有 4 个 op：
  `memory-pin`/`memory-supersede`/`impact-audit`/`memory-use`，而写入类 op 有 37 个。
- [x] 补上核心发布路径 `commit`：新增 `publish_fixture`（init → raw → scan → context → analysis-submit
  → draft-submit）驱动 `commit_pages` 穿过崩溃 store，逐发布点断言恢复后达到一致状态。
- [x] 测试断言两条不变量：**目录绝不能描述正文未写入的页**（对该 commit 产出的每一页，含 source-summary）；
  **不允许有孤儿事件文件**（任何 `state/events/` 下的文件都必须在目录里登记）。
- [x] 过程中三条判断被实测纠正：
  ① 第一版只检查 `concepts/ceramics` 一页，太窄——改成遍历所有页；
  ② 崩溃范围 0..8 够不到前滚恢复点，扩到 0..11 才覆盖到；
  ③ 「丢掉 source-summary 的 change」这个变异其实被 `@vault.commit` 自己的
  `verify(proposed, entries)` 抓住（事务根本没开始），我的测试抓不到——所以换了一个我的测试
  **唯一**能抓的变异：事件写盘但不登记进目录，即本会话早期靠 `file_unregistered` 抓到的那一类。
- [x] 按「change list 复杂度」给其余写入 op 排优先级后再补四个：`research-topic`、
  `purpose-suggest`、`overview-suggest`、`provider-register`——它们的 change 数组都是内联手写，
  漏一项就会留下「盘上有记录但目录没描述」或反向的孤儿。agent 层中断覆盖从 5 个 op 到 9 个。
- [x] 抽出 `assert_consistent` 收敛两条共享不变量：**不允许孤儿事件文件**、
  **不允许孤儿记录**（目录里每个 state 条目都必须在盘上）。MoonBit 不允许在普通 fn 里同时
  调用 `assert_*` 和会 raise 的函数，因此 raise 的那半留在 test 块内，helper 只放纯断言。
- [x] 过程中又抓到自己是装饰性测试：`provider-register` 用的字段名是 `name`/`url`，
  而 schema 要求 `provider`/`kind`/`space`/`capabilities`/`at`——`@base.keys` 直接拒绝，
  op 根本没跑到，测试却一直绿。改成正确字段后才真正覆盖。这是本会话第四次「测试没测到它声称测的东西」。
- [x] 再补四个 op 的中断恢复：`quality-audit`、`research-complete`、`archive-page`、
  `forget`（来源撤销）。agent 层中断覆盖从 9 个 op 到 13 个。
- [x] 把逐 op 的崩溃循环收敛成 `each_crash_point(seed, request)`：循环到 op 真正落地为止，
  **最后一次迭代就是干净运行**——change list 漏登记事件时孤儿文件正好在那里出现。
  固定范围写死会漏掉前滚恢复点（早前 0..8 够不到），也永远跑不到干净运行。
- [x] **把「测试没测到它声称测的东西」变成结构性问题**：本轮五个装饰性测试里有三个的共同根因是
  `assert_true(failed)` 对任何失败都成立——字段名错、派发表调错、缺传输字段，
  校验失败和崩溃注入长得完全一样。
- [x] `each_crash_point` 现在先在干净 store 上跑一次该 op 并断言成功，
  证明请求合法、op 可达，之后的崩溃循环才有意义。已验证：把 `purpose-suggest` 的字段名改回错的，
  测试立刻以 `operation never ran on a clean store` 失败，而不是像以前那样绿着通过。
- [x] **按用户指正修正对 AGENTS.md 的理解**：「核心不得调用模型」的正确解读是**引擎不做判断**，
  而不是「个人代理那部分能力可以不对外」——本项目本身是给 agent 用的。
  据此审查 A5 个人代理面的对外暴露，发现真实缺口。
- [x] 缺口（已实测）：`memory-conflicts` 无需种子即可发现竞争判断，但**近重复合并候选必须带
  `query`/`page` 才能拿到**——`memory_prefetch` 开头强制种子，且 keeper/duplicate 判定写在
  hit 循环里只对命中查询的笔记生效。外部 agent 必须先猜出一个查询才能发现该整合什么，
  这正是 A5 Autodream 里由引擎主动发现、交给代理决策的那一半。
- [x] 新增只读 op `memory-candidates`（与 `memory-conflicts` 平级）：
  `merge` 给同 token 不同字节的近重复组；`prune` 给从未被宿主报告使用过的笔记。
  全部沿用既有不变量：冲突笔记两项都不提名、pinned 不提名 prune、
  superseded/archived 是历史不提名、来源失效/漂移的需要 supersede 故不提名 prune（归 `inbox`）、
  已参与 merge 的不再提名 prune（否则与它所并入的 keeper 自相矛盾）。
  引擎只记录「宿主报告过使用」，**不做 recency 阈值判断**。
- [x] 与 `memory-prefetch(dedup:"similar")` 共用 `@index.similar_eligible/similar_tokens/similar_merge`，
  两个面对同一对笔记给出一致答案，已用断言钉住。
- [x] **上述新 op 自带一个真缺陷**：只按 token 相等判定重复，不看 kind/scope。
  实测：一条 `fact` 和一条 `preference` 文本 token 完全相同，被提名为合并候选
  ——同样的词在不同 kind 下是不同类别的判断，合并会静默丢掉该区别，
  而这正是引擎不该替宿主做的那类判断。
- [x] 修法：`memory-candidates` 与 `memory-prefetch(dedup:"similar")` **同时**加
  「kind 与 scope 都相同才算重复」。两边都改是因为前者提议动作、后者为预算折叠候选，
  跨 kind 都会丢信息；而且也必须同改，否则破坏「两个面给出一致答案」这条已钉住的不变量。
- [x] 已确认 prefetch 既有测试用的是同 kind 笔记，加护栏不破坏它。
- [x] 新增单测「memory candidates never merges across kinds or scopes」：跨 kind 两边都空、
  同 kind 第三条仍能合并；并补 2 条变异分别钉住 candidates 与 prefetch 的护栏。
- [x] 顺带系统核查「算了但没对外」：`agent/` 下 68 个 `pub fn` 中只有 `mcp_tools` 未被 dispatch 引用
  （它由 `mcp/main.mbt` 使用）；93 个 op 中只有 `session-open`/`session-close` 在 dispatch 表外
  （由 `nativehost` 在派发前处理）。无死代码、无广告但不可达的 op。
- [x] 验证「一个主体只提案一次」的两个方向：折进专属项的一侧 `inbox_e2e.py` 已钉住；
  **反面**（无专属项的主体独立成 `impact` 项）此前从未被测——已用
  「apply 综述 → 外部编辑 `wiki/overview.md` → refresh → impact-audit」补上，
  并断言只有一个 impact 项、重复 audit 不再新增。
- [x] 验证「宿主决定在 pack 往返后仍然有效」：`impact_e2e.py` 原有断言只查
  `impact-audit(...)["resolved"] == 0`，没查 `opened == 0`——正是本会话
  `suppressed = false` 那类回归测不出来的形式。已补强为同时断言
  `opened == 0`、`replayed >= 1`、`committed is False`，
  且记录保持 `resolved` 并带 `dismissed`。实测该状态确实成立。
- [x] `read-source` 字节区间边界：e2e 原覆盖边界对齐、空区间、越界、非整数，
  **没覆盖切在多字节字符中间的区间**。已补：对 CJK 三字节字符取 +1/+2 偏移，
  必须报 `utf8_range_boundary_invalid`；并用**字符索引换算**出真实边界做对照，
  证明拒绝是因为"切字符"而不是"偏移不对"。
- [x] 该断言已验证载荷性：把 `base/json.mbt` 的边界校验改成"解码失败就返回空串"，
  e2e 立刻失败——而变异暴露的失败模式很严重：切字符的区间会**静默返回 `text: ""`**，
  evidence 锚点是逐字节比对的，空串会让核对悄悄失真而不是报错。已登记为变异。
- [x] evidence 锚点与 `read-source` 的字节序同源性：两个 op 各自有测试，但**从未接起来**。
  已补往返断言——用记录下的 `source_start`/`source_end` 调 `read-source`，必须取回原引文；
  并用字符偏移做对照（对 CJK 直接被拒为 `utf8_range_boundary_invalid`），
  证明断言讲的是字节序而非巧合。
- [x] **顺着这条线抓到一个真缺口**：把 `source_quote_verified` 从"按锚点切片比对"改成"全文查找"，
  变异第一次**存活**——因为 `evidence_submit` 在 `agent/evidence.mbt:350` 有独立的切片校验，
  提交路径本就安全，我的改动只影响只读字段。
- [x] 但该字段确实可观测：补「漂移后引文仍在但不在原锚点」的用例后，变异被抓住。
  失败输出很说明问题——没有这条断言，引擎会对锚点已失效的 claim 报
  `source_anchor: "exact"` 与 `source_quote_verified: True`，宿主会信以为真去读错字节。
  这是静默错误数据通道，不是普通校验分支。
- [x] 过程中修正自己两次边界计算错误：先按"前一字符 3 字节"假设回退，
  但引文前一个字符是 `\n`（1 字节）；改成按字符索引换算后边界由构造保证。
- [x] 诚实记录：尝试构造「只有这条断言能抓住」的变异失败——重新引入
  `suppressed = false` 后，同suite 里更早的两条断言（line 179/182）先失败，
  测试走不到恢复金库那一段。因此这条断言是**正确的状态钉住**与纵深防御，
- [x] 页面侧锚点往返（与来源侧对称）：`body_start/body_end` 相对**解析后正文**，
  而 `read-page` 的 `text` 仍含 frontmatter——直接套用会取到 `'---\ntype: co'` 而不是引文。
  `protocol.md` 已明确写了这条约定（「不是 frontmatter、UTF-16 或原文件字节位置」），
  但**端到端从未验证**。已补往返断言，并断言套用到全文**不**等于引文，
  使断言讲的是基准而非巧合。
- [x] `evidence-replace` 的锚点路径：它委托给同一个 `evidence_submit_with_previous`，
  校验由构造共享；但 `quality_gate_e2e.py` 里所有被替换的锚点都是 `start:0` 的平凡对齐，
  **往返从未被钉住**。已在该脚本内补一个自包含块：新建页 → 提交平凡锚点 → 
  用**非平凡中段锚点**替换 → 读回记录并验证两侧往返。
- [x] 该断言已验证载荷性（同一条变异：记录锚点按 frontmatter 长度平移）。
  它与上轮 `evidence_source_e2e.py` 那条**共用同一处代码**，因此两个 e2e 都能抓，
  **不新增重复变异条目**——已如实记录，没有为凑数复制一条。
- [x] 继续清理退化情形，系统排查 `page-history`（时间戳各不相同，非退化）、
  `memory-use`（单元素与多元素批量都有）、`read-log` limit（有"返回最后一条"的判别性断言）——均无需改。
- [x] 在 `memory-candidates` 找到一处：合并分组只用 **2 条**笔记测过，
  而「所有 duplicate 都指向同一个 keeper、且 keeper 自身不是 duplicate」这条不变量
  **只有 3 条以上才可观测**——2 条时无法区分"命中首对就停"与"链式 n1→n0、n2→n1"。
- [x] 已补 3 条同 token 笔记的用例。实测行为本来正确（一个 keeper、两个 duplicate 全指向它，
  prefetch 一致折叠成 1 条），但未被钉住。
- [x] 该用例已验证**唯一**载荷性：去掉 `continue` 让 duplicate 也充当 keeper 后，
  `keepers[0] != keepers[1]`（`"n0" != "n2"`）立刻失败——宿主按提议合并会把内容并进一个本身就是重复项的笔记。
- [x] 查 `memory-prefetch` 的 `limit`：全库只用过 `limit=0`（非法）与 `limit=10`，
  而没有任何场景产生过超过 10 个候选——**limit 逻辑从未被行使过**。
  预算截断（4096 字符大笔记那条）测得好，但那是另一条路径。
- [x] 已补：建 4 条带共同标记的笔记，分别用 `limit=1/2/3` 断言只返回对应条数且按分数降序，
  `limit=50` 返回全部且 `truncated` 为 False，并断言 `limit=2` 的结果是 `limit=50` 的前缀
  （证明 limit 取的是同一排序的顶部，而不是另一个子集）。
- [x] 顺带确认 `truncated` 在 limit 截断时为 False 是**正确且有文档依据的**：
  `protocol.md` 写明 `truncated` 指 token 预算跳过，limit 是宿主显式请求，取满 N 条即符合预期。
- [x] 已验证载荷性：把 `limit~` 改成 `limit=50`（忽略请求值），断言立刻以
  `(1, [cap-1, cap-0, cap-3, cap-2])` 失败。已登记为变异。
- [x] 继续清理退化情形，先确认三个**无需改**的：`read-source` 65536 截断（120000 字节，断言有判别性）、
  `search` 的 `budget`（0/128/150/200/400/512/2000/1200 全覆盖）、
  `embedding-plan` 的 `limit`（limit=1 时 remaining=2，确实绑定）。
- [x] 在 `hops` 找到一处：只用过 0、1、3（拒绝），**默认值 2 从未被行使**——
  而它既是默认值又是 `assemble` 的上限，是图扩展最深的一档。
- [x] 已补：建一条 6 页 wikilink 链（逆序提交以避开未解析链接拒绝），查询词只命中链头，
  断言 hops=0/1/2 分别到达 1/2/3 个链节，且默认调用与 hops=2 结果相同。
- [x] 该断言已验证载荷性（两个方向）：默认值 2→1 时「默认等于 hops=2」失败；
  上限 2→1 时 hops=2 直接被拒。已登记默认值那条为变异。
- [x] **收尾核查：文档与代码一致性**。逐项核对后发现 6 处失真，全部修正：
  ① `implementation-audit.md` 比例 89.54% → 89.61%（附实测值）；
  ② 同文 A5 行的 memory op 清单漏了本轮新增的 `memory-candidates`；
  ③ 同文「22 个关键守护」→ 61，「15 个新 op 有传输层覆盖」→ 93 个中 88 个真实 `tools/call`；
  ④ `docs/memory.md`「32 个关键守护 / 21 条 e2e 变异」→ 61 / 38，守护清单补到当前，
  并补记检查器自身三个真缺陷（备份名往返有损、启动删备份而非恢复、只重建 cli/mcp 不重建测试驱动）；
  ⑤ `docs/protocol.md`「15 个新 op 全部有传输层覆盖」→ 改为实测口径；
  ⑥ `docs/verification.md` 是 dated 记录却写「当前 96 项测试 / 87.31%」，
  改为过去时并加时点说明（它不随发布包分发，但「当前」二字会误导读者）。
- [x] 已核对**无需改**的：93 个 op 全部在 `protocol.md` 有契约；README 的门禁描述是定性的、无过期数字；
  `release.py` 的 12 个发布文件全部存在；两份未进发布包的 docs 中，
  `2026-10-15-literate-feasibility.md` 自称"不是交付记录"，`verification.md` 已加时点说明。
- [x] 用同一把尺子量 WASM 面：桥暴露 15 个纯函数 op，**15 个全部被真实行使**
  （`wasm_e2e.mjs` 直接跑 tools/page/vectors/graph/neighbors/path/weighted-path/insights/context/catalog/search/view/render-view；`session-plan`/`session-verify` 经 
  `sdk/wasm-session.mjs` 适配器的 plan/transaction/restore 间接覆盖）。无需改。
- [x] **过程中差点报出假缺口**：第一版提取正则没匹配 `{op:'...'}`（无空格），
  得出「15 个 op 从未被行使」的错误结论。改用 `op\s*:\s*['"]([a-z-]+)['"]` 后为 15/15。
  这与本会话其他退化情形同族——**测量工具本身没测到它要测的东西**。
- [x] **schema 边界的双侧覆盖**：先核对 8 组整数边界的「schema 广告值 vs 代码校验值」，
  全部一致（read-log limit 0..1000、search limit 1..100、budget 1..65536、hops 0..2、
  graph hops 0..8、embedding-plan limit 1..128、memory-prefetch limit 1..50、
  read-source start/end 0..16777216）——没有"客户端被告知一个范围而引擎执行另一个"的错位。
- [x] 但**超上界从未被测**：所有拒绝用例都取 0（低于下界）或中间值，
  只有 `search` limit 101、`graph` hops 9、`embedding-plan` limit 129 三处例外。
  已补 `search` budget 65537 与 `read-source` start/end 16777217 两条。
- [x] `read-source` 那条有个细节：边界拒绝与范围拒绝的错误形态不同
  （`source_range_invalid: end` vs `source_range_invalid: 0 <= start < end <= N`），
  因此断言写成前者才真正测到边界；用子串 `source_range_invalid` 会两者都匹配、测不到边界。
- [x] 两条新断言均已验证载荷性：去掉 budget 上界后 65537 直接成功；
  去掉字节上界后 end=16777217 落回范围检查（错误形态改变），断言立刻失败。已登记为 2 条变异。
- [x] 修正 `docs/wasm.md` 一处不精确：原文只说「支持工具字典」，
  未点明 `tools` 枚举的是**全引擎 93 个 op** 而 WASM 只执行列出的纯函数子集——
  宿主若据此以为 memory/impact/inbox 在 WASM 可用会落空。已改为显式声明边界并指向 CLI/MCP。
- [x] 算术一致性脚本核对：字典 op 数 93=93、门禁 e2e 套件 28=28。
- [x] 过程中修正自己五处：① 变量名 `vault` 应为 `root`；② frontmatter 的 title 未加引号，
  导致 `validate_range` 的 `json.loads` 失败；③ 查询词「链头独特关键词」被分词成
  「链/节」等所有页都有的 token，六页全命中，改为只出现在链头的「独特关键」；
  ④ 五处调试 print 忘删；⑤ 一度把失败误判为 CLI 崩溃，实为测试自身的 frontmatter 解析。
- [x] 过程中修正自己三处：① 查询词匹配不到足够笔记（改为专门建带标记的笔记）；
  ② 零分笔记也进了结果，改为只对 `cap-` 系列断言；③ 辅助函数名 `capped` 遮蔽了后续要用的同名变量。
- [x] 过程中修正自己三处 MoonBit 语法：`0..2` 应为 `0..<3`；`String::replace` 需要 `old=`/`new=` 标签；
  以及一条未使用变量。
- [x] 过程中修正自己四次：① 引用仓库根而非临时金库；② `mid_source` 取到空串；
  ③ 减少 claim 数破坏了后续 coverage 计数（改为不影响既有断言的自包含块）；
  ④ 块缩进为 0 落在 `with tempfile` 之外（临时目录已删），并留了一行死代码。
- [x] 该断言已验证**唯一**载荷性：把记录的锚点按 frontmatter 长度平移后，
  提交、逐项校验、`source_anchor:"exact"`、`valid:True` 全部照旧通过，只有往返失败；
  失败输出显示宿主按记录去读会得到空串。与上轮 dismissed 那条（非唯一捕获者）性质不同，已分别记录。
  但不是任何单一变异的唯一捕获者。没有把它写成「已验证载荷性」。
- [x] 查清该规则的边界：`impact_id(kind, subject, cause)` 含 cause，而 cause 由当前状态导出，
  所以同一主体同一时刻只会有一条 open 记录；cause 翻转时旧记录自动 resolve、新记录才开。
  `standalone` 里的 `reason + "+" + cause` 分支因此是防御性的。
- [x] 并确认新 op 的四面划分正确：Web（`serve.py`）与 WASM 只暴露人类浏览面
  （页/检索/主题/lint/status），agent 工作面不走那里，与所有同类 op 一致。
- [x] 覆盖：3 个单测 + `memory_e2e.py` 全流程（含 pack 往返与两面一致性）+ MCP 传输层 + 5 条变异。
- [x] 过程中修正自己 6 处测试错误，其中两处是同一类：构造的测试数据自身构成冲突组
  （同 kind/scope/conditions 不同 text），导致候选被正确排除而断言失败。
- [x] MCP 传输层可达性探针：字典/schema 全量比对只证明 92 个工具**被广告**，
  而 `mcp_e2e.py` 实际只 `tools/call` 了 29 个。新增循环对每个广告工具发一次真实 `tools/call`，
  断言：不出现顶层 JSON-RPC error；`isError` 时必须带 `error_code`；成功时必须带 `structuredContent`。
  探针刻意在 `init` 之前跑——金库是未初始化状态，85 个 op 必须返回领域 `error_code`，
  而 `lint`（诊断入口）和 `recover`（干净金库上是 no-op）必须成功。
- [x] 已验证该探针是载荷性的：让 `lint` 拒绝缺失目录，立刻以
  `must succeed on a damaged vault, got lint_refuses_missing_catalog` 失败。
  同时确认它不是装饰性的——曾试过让 `topics` 抛裸 Fault，那种情况仍有 `error_code`，
  由既有的只读视图断言抓住，说明探针覆盖的是另一类失败。
- [x] **修掉变异检查器的两个真缺陷**：
  ① 备份文件名用 `path.replace("/", "_")`，往返有损——`agent/page_history.mbt`
  会还原成 `agent/page/history.mbt`；改用 `urllib.parse.quote/unquote`。
  ② 启动时发现已有备份会**直接删掉**而不是恢复，所以被信号或 timeout 杀掉的运行
  （`finally` 不执行）会把生产代码留在变异状态，且下一次运行销毁唯一能还原的副本。
  现改为：启动时若发现备份就先恢复、重建二进制与测试驱动、清理备份，并以退出码 3 报告。
  已实测：手工留下变异 + 原始备份，检查器正确恢复 1 个文件并报 `Restored 1 file(s)`。
- [x] 附带收益：这个探针同时成了 schema 校验测试。从 `tools.mbt` 的 `purpose-suggest` 里删掉 `key` 字段，
  同一条断言立刻失败——中断恢复测试现在能抓住工具字典与请求不同步的漂移。
- [x] 门禁里出现过一次**未能复现的间歇失败**：`memory_e2e.py:155` 的
  `assert note["valid"] is False`。已排查：`memory-list` 按 note id 稳定排序（`memory_entries` 用
  `sort_by`），该 key 只有一个笔记，`[0]` 无歧义；且按设计每条分支都该是 False——
  来源被撤销则 `invalid_sources` 非空，来源换了字节则 `drifted_sources` 非空，两者都令 `valid` 为 False。
  复现尝试：单独跑 13/13 通过，按 verify.sh 前 5 个套件顺序跑 5/5 通过，完整门禁 3 次里 2 次通过。
  结论记为「环境性、未定位」，不作为已修复项；后续若再现，先看是否为门禁长时运行的资源压力。
- [x] 期间修掉五个自己的错误，其中三个是装饰性测试：
  ① `run_crashed` 原先调 `maintenance`，但 `archive-page`/`forget` 由 session 表派发，
  改成 `dispatch` 后这两个 op 才真的跑到；
  ② `dispatch` 要求 `vault` 传输字段，请求里没带 → `purpose-suggest`/`overview-suggest`
  从头到尾都是 `unknown_field`，测试却一直绿；
  ③ 这两个 op 的 schema 是 `at`/`key`，不是 `purpose`/`body`（建议文本由外部宿主生成）；
  ④ `seed_page` 里 scan 了两次，第二次拿不到 order；
  ⑤ `archive-page` 用了不存在的页 id（scan 之后还没有页，要先 commit）。
- [x] **修掉变异检查器留下的幽灵失败**：`finally` 里只重建 `cli`/`mcp`，
  而测试驱动是另一个二进制，MoonBit 不会因为源码还原就重建它。于是紧接着跑 `moon test`
  用的还是最后一次变异构建出的驱动，报出假的失败。已补 `moon test --build-only`。
  （当时表现为 `inbox by_kind counts` 偶发失败，一度被误判成 flaky；
  实跑证明该测试确实能抓住对应的变异，是载荷性的。）
- [x] 变异面 38 → 42：为四个 op 各加一条「事件必须登记进目录，不能只写盘」，全部由新测试捕获。
- [x] 变异面 37 → 38：新增「commit 事件必须登记进目录，不能只写盘」，由新测试捕获。
- [x] 上述审查引出真缺口：**篡改探针只覆盖 4 个 op**（stats/memory-list/impact-list/inbox），
  而 `@vault.verify` 是全量的——篡改任一 state 文件本该让每个派生读 op 都拒绝。
- [x] 新增 `scripts/tamper_e2e.py`：对 21 个读 op 逐个在篡改后调用，断言除原始字节读取器外全部拒绝。
  结果 19/19 派生读拒绝，`read-index`/`read-purpose` 仍可用（受损金库要能查看）。
- [x] **该探针当场抓到 `list-pages` 不校验**：它是派生读（和 `status`/`topics`/`tree` 同类），
  却直接返回目录条目，导致同一金库上 `list-pages` 报成功而 `status` 报 `content_changed`。已补校验。
  原始字节读取器 `read-index`/`read-purpose` 与 `lint` 同理豁免——它们的存在意义就是查看损坏的金库。
- [x] 变异面 36 → 37：新增「list-pages 是派生读，必须拒绝受损金库」。
- [x] **变异检查器抓到一个真回归**：`agent/impact.mbt` 的「宿主持决定必须压制重复上报」被写成了
  `let suppressed = false`，而注释还写着「A host decision made against these exact inputs stays closed」。
  后果：`impact-resolve` 记录了人工决定（`dismissed` 存了当时的输入指纹），但下一次 `impact-audit`
  **无视它直接 reopen，并把 `dismissed` 清成 None**——人工决定被静默丢弃，同一个漂移会反复回来烦人。
- [x] 该回归此前被 137 个单测和 14 个 e2e 全部漏掉：`impact_e2e.py` 只断言
  `impact-audit(...)["resolved"] == 0`（决定不会被自动关掉），从未断言它**不会被重新打开**。
  是变异检查器报「pattern did not match」才暴露的——源码变了而变异没跟上。
- [x] 修复：恢复 `match existing.dismissed { None => false; Some(value) => value == f.current }`。
  语义：输入没变 → `replayed`，记录保持 resolved 且 `dismissed` 不丢；输入真的变了 → reopen 并清除 dismissed。
  已在 `impact_e2e.py` 补两组断言分别钉住这两个方向。
- [x] `session-close` 必须在自身释放金库锁，而不是留给进程退出：原测试先 close 再退出，
  无法区分两者。新增「进程保持存活、另一进程立即 scan」的断言，并验证过移除
  `nativehost/host.mbt` 里的 `@platform.unlock()` 会让它以 `vault_locked` 失败。
- [x] 并发写入正确性：新增 `scripts/concurrent_e2e.py`。AGENTS.md 要求「中断恢复、幂等重试和
  外部编辑冲突需要实际测试」，前两者有崩溃 store 单测覆盖，但 N 个真实进程竞争同一金库从未测过。
- [x] 查明确认的并发机制：CLI 每次调用取 `flock(.corridor-lock, LOCK_EX|LOCK_NB)`
  （`platform/fs.c` 的 `mc_lock`），因此竞争由**操作系统排他锁**裁决，失败的写入者报
  `vault_locked: another writer is active`；库内还有乐观基线检查 `catalog_conflict` / `write_conflict`。
  6 进程竞争同一提交的实测结果稳定：3-5 个成功（幂等重放）、1-3 个被 `vault_locked` 拒绝，
  金库最终始终只剩一页一版本。
- [x] 测试同时钉住恢复语义，其中两条与我的初始假设相反：
  `dispatch` 在派发任何 op 之前先调用 `@vault.recover`，所以**匹配现行目录的 journal 会被自动向前重放并清除**，
  不会永久阻塞后续写入者；而 `old_index` 与现行目录不符的 journal 报 `recovery_conflict` 且**保留**，
  供人工检查——不是静默应用也不是丢弃。未知 version 报 `journal_version_unsupported`。
- [x] 另发现 `commit` 不产生独立的 `page-*.json` 事件文件，页面生命周期记在目录的提交历史里；
  因此「竞争不得重复记录」用 `page-history` 的 `counts.versions == 1` 断言，而不是数事件文件。
- [x] 变异面 33 → 35：新增「恢复必须拒绝目录被外部编辑过的 journal」与
  「恢复必须保留 journal 而不是丢弃」，均被 concurrent_e2e.py 捕获。
- [x] 顺着这条线发现 `memory_summary` 仍用校验版 `memory_rows`，而孪生的 `impact_summary`
  早已用 `impact_rows_unchecked`。改后 `stats` 50ms → 29.5ms（快 41%）。
- [x] 为「`graph_unchecked` 信任调用方」这条不变量加变异：移除 `maintenance` 的校验。
  **第一版变异是装饰性的**——它 SURVIVED，因为 `memory_summary` 自己还在校验，stats 照样拒绝篡改。
  这已是本轮第二次「变异没测到它声称测的东西」。先在 `memory_e2e.py` 补上篡改探针
  （外部编辑后 `stats`/`memory-list`/`impact-list`/`inbox` 都必须报 `content_changed`，
  `lint` 作为诊断路径只报不拒），修掉 `memory_summary` 后该变异才被真正捕获。
- [x] `specs/engine/implementation-audit.md` 的比例同步为 89.54%（实测 0.8954403955319539）。
- [x] 变异面 30 → 32：新增「撤销的来源必须让笔记 invalid 而非 drifted」与
  「笔记 valid 要求来源既在又未变」（去掉 drifted 半边即失败），均被 e2e 捕获。
- [x] 变异面 28 → 30：新增「supersede 掉的笔记不报漂移」与「inbox 必须把 drift 折进已覆盖主体」，均被 e2e 捕获。
- [x] 为 lint 诊断器与 inbox 条目补变异覆盖：变异面从 23 扩到 28。新增 `lint` 的 `file_unregistered`（孤儿文件检测，正是它抓到「事件漏登记进目录」这一类缺陷）、`memory_source_drift`、`memory_conflict`，以及 inbox 的 `memory-source-stale` 与 `memory-conflict` 两类条目。过程中三条变异一开始写错：一条只删掉未被测路径覆盖的分支（假阴性）、两条因括号不闭合或空数组类型不确定而无法编译——已全部修正，28/28 被测试捕获。
- [x] 变异检查器强制 e2e 脚本名：「漏写 e2e 名导致 `moon test` 全绿、缺陷被藏住」这个失误连续发生两次。现由 `mutation_check.py` 扫描所有 `scripts/*_e2e.py` 的成功输出并建立「成功消息 → 脚本」映射，若某条变异的 `expected_test` 是某 e2e 成功消息的前缀却没带 e2e 名，直接报错退出（exit 2）。已用「故意删掉一条 e2e 名」验证守卫会触发。修复过程中还发现并修正了守卫自身的正则缺陷（`[^"]*?` 非贪婪匹配永远追不上闭括号，导致 18 条消息一条都没扫到）。
- [x] 修复性能重构引入的校验缺失并覆盖 status/stats：`impact-list` 改用 `impact_rows_unchecked` 后，因 dispatch 在 match 前不 verify 而完全失去校验——外部篡改 `state/impacts` 记录后静默返回篡改数据（`memory-list` 正确拒绝）。已恢复入口校验，并把 `status`/`stats` 也改为入口 verify 一次、聚合用 `_unchecked`（原各自触发约 7 次全量校验）。`impact_e2e.py` 新增外部编辑冲突用例（4 个 op 必须拒绝、lint 报 `content_hash_drift`、恢复登记字节后可用），并加变异守卫。新增变异时又一次漏写 e2e 脚本名导致假阴性，补上后 23/23 全部捕获。
- [x] 消除 A5 衍生表面的重复全量 verify：规模基准暴露 `inbox` 759ms、`memory-prefetch` 431ms、`impact-audit` 465ms（500 笔记）。根因是每个 `*_rows` 助手都各自调用 `@vault.verify`（读取并哈希 vault 内每个文件），`inbox` 一次触发约 8 次全量校验。按仓库既有的 `evidence_rows_unchecked` 模式拆出 `_unchecked` 变体（`memory_rows`/`impact_rows`/`review_rows`/`research_rows`/`suggestion_rows`/`overview_rows`/`overview_status`），由 op 顶部统一校验一次。优化后（500 笔记）：prefetch 197ms、inbox 216ms、impact-audit 160ms；规模基准（32 页 / 48 笔记）inbox 154→39ms、impact-audit 97→34ms、prefetch 86→37ms。137 项测试与 12 个 e2e 全通过。
- [x] 规模基准覆盖 A5 衍生表面：`scale_benchmark.py` 建于记忆层之前，只测 search 三模式与锁竞争。新增 `--notes N`（默认 64）提交 N 条记忆笔记并测量 `memory-prefetch`/`memory-list`/`inbox`/`impact-audit`——其中 `memory-prefetch` 每次调用对全部笔记重建索引，是记忆层唯一随笔记数线性增长的热点，此前无任何规模可见性。本机 32 页 / 48 笔记基线：prefetch 中位 86ms、list 38ms、inbox 154ms、impact-audit 97ms（含进程启动与磁盘 IO）。
- [x] 补齐发布物文档清单：`release.py` 的 DOCS 漏了本次新增的 `docs/memory.md`（A5 理念承接记录）与 `docs/extending.md`（新增持久化工单的 17 步 checklist）——发布物宣称随附协议文档，但最重要的两份新文档不在归档里。已补入并重新打包验证（14 → 16 个文件），`release_e2e` 通过。同时实跑验证了两条此前未执行的文档流程：`watch.py --once` 与持续监听（改动 raw 后正确建单并重编译视图）、`release.py` 打包与解包。
- [x] 修复 README 快速入门实际跑不通：文档流程是 `make_demo.py` 后直接 `serve.py`，但 `make_demo.py` 不调用 `rebuild`，vault 没有有效索引缓存，而 `serve.py` 每次读取先 `verify`，因此所有路由 409 拒绝。`web_e2e.py` 自己调 `rebuild` 所以没暴露。已在 `make_demo.py` 末尾补 `rebuild`，并实跑服务逐条 curl 验证：`/`、`/api/status`、`/api/pages`、`/api/tree`、`/api/topics`、`/api/lint`、`/api/page?id=overview`、`/api/search` 均 200，未知路由 404、缺参 400、写请求 405、路径穿越 404，`/api/topics` 返回 1 个主题。
- [x] 补齐 5 个新 op 的 MCP 传输层覆盖：`memory-use`、`impact-audit`、`impact-resolve`、`page-history`、`overview-cancel` 此前只被 CLI 覆盖，从未经 JSON-RPC 调用——传输层是独立表面（名称翻译、schema 类型、错误信封）。已全部补上，15 个新 op 现均有传输层覆盖；其中 `overview-apply` 对被取消建议的拒绝码取决于建议冻结后 vault 变动多少，因此断言「isError 且带 error_code」而非具体码。
- [x] MCP 传输层覆盖：此前 14 个新 op 只被字典/schema 比对覆盖，从未经 JSON-RPC 真实调用。`mcp_e2e.py` 现对代表性新 op 做真实调用，覆盖名称翻译、布尔/数组字段往返、只读 op 不返回 `execution`、`memory-prefetch` 两种种子互斥、`purpose-cancel` 终态与重放、错误信封 `error_code`；另确认 `progress` 传输提示对每个 op 成立（成功 started/completed，失败 failed 后返错）。
- [x] page 种子记忆预取（吸收 A5 预取代理「结合当前对话筛选相关内容」）：`memory-prefetch` 新增可选 `page`，以该页 `title`+`body`（截断 4096 字符）作确定性种子查询，`query` 与 `page` 二选一（同给或皆缺拒绝，`page` 必须指向已登记知识页）；响应以 `query_seed` 标明种子来源；schema 中两者均为可选，由 op 强制二选一。
- [x] 系统变异检验并纳入门禁：新增 `scripts/mutation_check.py`，对 8 个关键守护逐一注入缺陷（memory note hash 绑定、impact 身份派生、memory-pin 事件路径、冲突分组需两个判断、来源漂移检测、重复判定忽略来源绑定、ingest 事件路径、archived 不阻塞），断言对应测试失败后恢复原码并校验（防信号打断留下变异）；已纳入 `verify.sh`（约 70 秒）。它抓到两处装饰性测试：impact 身份派生被更早的 path 检查挡住从未被执行；以及上一轮的 execution 测试只查字典。均已修正，现 8/8 被测试捕获。
- [x] 加固「只读不挂 execution」测试：原测试只断言工具名存在于字典，完全不检查行为——把 `execution` 加回任何读 op 它都会通过。改为在真实 vault 上驱动 15 个读 op 断言字段缺席、并断言 `research-topic` 等写 op 仍保留该字段；已用变异验证（加回字段后测试失败）。
- [x] 响应形状一致性：`execution:"host_required"` 语义收敛为「引擎记录计划、等待宿主执行」的写操作专属标记；`memory-read` 与 `read-source` 两个纯读 op 曾误返该字段（会让通用客户端以为有待办动作），已移除，`read-source` 的 binary 分支保留更精确的 `extraction_required`；协议文档明确该字段只属于写操作，并用单测固化读操作清单。
- [x] demo 展示 inbox 与来源绑定：README 称 demo 可直接试 `inbox`，但 demo 没有任何待处理工作、inbox 恒为空，指令 misleading；且三条记忆笔记都没绑定来源，`source_hashes` 恒为 `[]`，来源固定与漂移检测整层能力在 demo 里不可见。补一个开放研究工单和一条绑定 `raw/项目方案.md` 的记忆笔记；README 示例扩为五条并逐条实跑通过（`read-source` 的字节区间必须落在字符边界上，示例取 0..19）。
- [x] Web 服务暴露主题浏览层：新增只读 `/api/topics` 路由（engine `topics`），web e2e 增加 parity 断言并确认带参请求 400、子路径与未实现 op 404；文档明确 Web 层只暴露只读浏览路由，不实现第二套引擎逻辑。
- [x] 原文核对入口（吸收 A5「回原文核对」与 Diff Engine「必要时回查原文」）：新增只读 `read-source`(id,start?,end?)，返回登记 format/SHA-256/stale/verified/present/bytes 与文本内容；`binary`/`image` 只报告体积并要求外部抽取；`start`/`end` 为 UTF-8 字节半开区间，与 evidence 锚点同约定；整篇按 65536 字节截断并置 `truncated`（按字节封顶并回退到字符边界），显式区间不截断；撤销来源报告 `stale` 而非假装有效。同时修正 `input_schema`：`start`/`end` 被误标为必填 string，实际是可选 integer，并用单测固化。
- [x] 页面版本历史（吸收 A5 Workspace Wiki「页面保留来源引用和版本历史」）：`commit` 的 `ingest` 事件追加 `pages`（本次发布的每页 SHA-256，旧事件可缺省仍可读）；新增只读 `page-history`，按时间列出提交/归档/恢复/来源撤销及各自哈希，附 `current` 供核对旧引用；经 e2e 覆盖两版发布、归档恢复、来源牵连失效、source-summary 页、只读确定性与 pack 往返。
- [x] 补齐 `impact-audit` 中断恢复覆盖：AGENTS.md 要求中断恢复需实际测试，但此前只覆盖 `memory-pin`/`memory-supersede`。`impact-audit` 是新增代码里最大的多记录事务（每条 impact 2 个 change），现以两个 research topic 制造一次提交两条 drift 的场景，对 9 个发布点逐一注入崩溃并断言：恢复后记录数为 0 或 2（批量原子性）、每条落地记录的事件都已登记进目录、再次审计为纯重放且指纹不变。事件登记断言已验证有效——删掉 new-record 分支的 event change 后测试立即失败。
- [x] 新 op 事务安全：`agent/transaction_safety_wbtest.mbt` 以崩溃 store 覆盖 `memory-pin`（7 次写入）与 `memory-supersede`（8 次写入）的每个发布点，断言恢复后整笔落地或整笔回滚、supersede 链不半应用、pinned 仍拒绝归档；`memory-pin` 幂等重放；外部改写 `state/` 记录以 `content_changed` 拒绝且 lint 报 `content_hash_drift`；`overview-cancel` 幂等与终态拒绝纳入 inbox e2e。
- [x] 未登记文件检测：`lint` 新增 `file_unregistered`，覆盖 `state/`、`wiki/`、`vectors/` 下未被目录登记的文件（例外：`state/transactions/pending.json`、`wiki/index.md`、`wiki/log.md`）；`views/`/`staging/` 按目录列举本就不是目录驱动，`raw/` 交由 `inbox` 的 `unscanned-source`。它当场发现并修复了 memory-submit/supersede/archive/restore/pin 与 impact-resolve 的事件漏 upsert 进目录的问题，以及 supersede 事件字段与校验不一致的问题。
- [x] 主题浏览层（吸收 A5 Context 索引「语义节点可逐层浏览」理念）：只读 `topics` 只列 `synthesis` 语义层页，带 `title`/`links`/`sources`/`stale_sources`/`stale`/`sha256`/`body_bytes`；材料层页不列入；来源撤销进入 `stale_sources` 而非静默丢弃；按页 id 稳定排序且重复调用不改变指纹。`impact-audit` 计数语义拆为 opened/updated/resolved/replayed（updated 保留 `created_at`、前进 `updated_at`），显式 `key` 只在首次创建时生效。
- [x] 固化 `forget` 撤销黏性语义并加 e2e：曾据「identical 恢复不复活来源」的现象修改 `scan` 去重条件，但那会让 `forget` 失去黏性——它不删除文件，相同的字节写回来就等于悄悄撤销人的撤销决定，`topics_e2e` 当即失败。已回滚，并在 `source_deletion_e2e.py` 固化：identical 恢复不产生新工单、绑定笔记仍报 `invalid_sources`、内容变化才重新登记且笔记恢复 `valid`。
- [x] 修复 archived 笔记阻塞同判断提交：判断摘要改造后，`archived` 笔记会阻塞同一判断的新提交并被 lint 报为重复，但它已退出默认集合且可恢复，本不构成竞争（原代码只跳过 `superseded`，当时因 `note_hash` 含 sources 不易碰撞）。`memory_write` 与 lint 的重复判定都改为只针对 `active` 笔记；e2e 与单测覆盖归档后可重新提交、competing active 仍被拒。
- [x] 修复来源版本固定引入的误报：把 `source_hashes` 并入 `note_hash` 后，「正文与条件完全相同、仅绑定来源不同」的两条笔记不再被判为重复，反而被 `memory-conflicts` 报成冲突——它们说的是一件事。改为按「判断摘要」（`kind`/`scope`/`text`/`conditions`，从已存字段派生、不入记录）做重复判定与冲突分组；`note_hash` 仍含 `source_hashes` 用于 id 派生与重放。e2e 与单测覆盖：同判断不同来源判重、真冲突仍报、相同提交仍重放。
- [x] 记忆来源版本固定：`memory-submit`/`memory-supersede` 要求来源已登记且有效，并把当时 SHA-256 记入 `source_hashes`（与 `sources` 一一对应，参与 `note_hash`）。此前来源被整体改写并重新登记后笔记仍报 `valid:true`——它引用的证据已完全变成别的内容，而 evidence 的 `source_quote` 校验能抓到、记忆层不能。现在区分 `invalid_sources`（缺失/撤销）与 `drifted_sources`（字节已变），`valid` 覆盖两者；`inbox` 用两种 reason 报告，lint 报 `memory_source_stale`/`memory_source_drift`，`stats.memory` 分别计数；无 `source_hashes` 的旧记录按路径判定仍可读；重新绑定到当前字节即解除。
- [x] 记忆使用信号（吸收 A5 Autodream「长期未用于前台交互的普通记忆应归档」）：新增 `memory-use`(ids 1..64, at) 批量登记 `last_used_at`，一次报告只写一个事件且整批原子落地（中断恢复测试覆盖 8 个发布点，断言 0 或 2 条被登记、事件已登记进目录、重复报告为重放）；`memory-prefetch` 保持只读不自动记录使用；`memory-list` 返回 `last_used_at`；变异检验新增 2 条（时间戳必须写入、批量必须原子）。
- [x] 记忆预取去冗余不掩盖冲突：处于未解决冲突中的笔记不参与 `similar` 合并（相同条件 + 不同正文本身就是冲突候选，合并会丢掉一侧）；`dedup:"similar"` 只合并不构成冲突的改写变体；`memory-source-stale` 记忆笔记纳入 inbox 待确认项。
- [x] 记忆预取去冗余与类型过滤（吸收 A5 Autodream「合并重复信息」理念）：`memory-prefetch` 新增 `dedup`（默认 `none`，显式 `similar` 按页面检索同一套规则合并改写变体——分词序列相等且双侧 UTF-8 ≥64——保留排名靠前者并在 `similar_duplicates` 报告 `{duplicate,keeper}`；相同正文提交时已拒绝，故不提供 `exact`）与 `kinds` 类型过滤；合并只影响候选集合，记录仍可列出/归档/恢复；默认行为字节不变。
- [x] 记忆冲突保留（吸收 A5 Autodream 理念）：按 `kind` + 规范化 `conditions` 分组检测 active 笔记之间的冲突候选，新增 `memory-conflicts`；`memory-prefetch` 返回 `conflicts`/`conflict_counts` 与逐条 `conflicted`，`memory-list` 与 `stats.memory.conflicted` 同步计数；`superseded`/`archived` 不参与分组，收窄条件或归档某一侧即解除冲突，相同正文不算冲突；lint 以 warning 报告 `memory_conflict`，两侧记录保留可读，由 `memory-supersede`/`memory-archive` 解决。
- [x] 主动工作收件箱（吸收 A5 Proposal Engine/Inbox 理念）：新增只读 `inbox`，汇总打开的 change-impact、pending HumanGate 审核、`proposed` 研究/目标/综述工单、失效页面和未登记 raw 来源，每条带 `kind`/`subject`（目录路径）/`reason`/`detail`/`next`，按 kind+subject+reason 稳定排序且重复调用不改变指纹；一个 subject 只提议一次，漂移原因并入专门条目的 `drift` 字段；空 `items` 表示无需主动介入。为此补充 `purpose-cancel`/`overview-cancel`（基线漂移后永远无法应用的建议只能取消，记录与冻结上下文保留），`cancelled` 终态的 `result_hash` 必须为 null。
- [x] 变化影响层（吸收 A5 Diff Engine 理念）：`state/impacts/` 内容寻址记录与 `impact-audit`/`impact-list`/`impact-resolve`；研究主题按创建时记录的 `inputs_hash`（purpose/raw/页面/向量知识指纹，排除 state 记录）比较，综述建议按冻结的 `purpose_hash` 与 `page_hashes` 比较，已发布综述只在没有 applied 记录匹配时报告；漂移消失自动 resolve，宿主决定后按 `dismissed` 抑制重报，输入再次变化才重新打开；lint 增加 `impact_subject_missing`/`impact_no_drift`，`status/stats` 报告 `impacts` 计数；记录参与目录指纹、事务恢复与 pack。
- [ ] 多领域真实资料与外部模型生成知识的质量/成本对照；改写/同义级语义去冗余仍不在核心内。
- [x] 四领域 native 检索/来源/预算基线（物理、医学、软件、食品；中英文问题集）；不宣称模型质量，见 [多领域基线](quality.md)。
- [x] MCP stdio 生命周期、JSON-RPC/工具错误、通知与 CLI 字典/schema 对账。
- [x] CLI/MCP 可区分结构化进度事件；CLI 显式 opt-in，MCP 按 `progressToken` 映射标准通知，并保留唯一终态响应。
- [x] OKF/Markdown 导入导出适配与兼容矩阵；保留未知字段/原件，支持断链审核、sources 对象、编译边界与真实磁盘重试。
- [x] 确定性内容寻址 ZIP 容器、清单/CRC/哈希校验、拒绝式 unpack 与每个发布点中断恢复；独立编码器/标准 ZIP 工具和真实磁盘核对。
- [x] 当前主机 native CLI/MCP 的确定性分发包：包含精简 Web/监听适配器、协议/视觉/容器/WASM 文档、许可、逐文件 manifest 与归档 SHA-256；跨目标构建仍需目标工具链。
- [x] views/*.mbt.md 声明、真实编译、MoonBit HTML 渲染，离线目录/筛选/详情/来源跳转；声明式 features 可关闭对应运行时能力；`graph` 面板提供确定性环形快照图（实线互链、虚线共享来源、查表坐标、字节一致、节点 hash 路由、孤立节点静态），headless Chrome CDP 检查纳入 `verify.sh`。
- [x] 无效视觉声明隔离、宽屏和手机 Web 浏览器验证与截图；视觉库不成为知识数据权威。
- [x] Markdown/HTML 富文本呈现、离线图片、MoonBit/多语言高亮、主流前端语言格式化和原文切换；真实浏览器验证隔离、导航与手机布局。
- [x] classic WASM / WASM-GC 纯计算产物与稳定整数/UTF-8 ABI，Node 实例化与跨目标核对。
- [x] WASM `view`/`render-view` 视觉快照入口：重新解析 `.mbt.md` 声明、页面/来源元数据、SHA-256、来源与 wikilink 后生成与 native 相同的自包含 HTML；不含文件系统、网络或浏览器执行权限。
- [x] WASM UTF-8 快照会话、创建/恢复入口路径与正文校验、宿主编译回调、带版本和 SHA-256 封套的 `load/save` 持久化边界、索引最后发布、重试与冲突保护；Node 文件适配器另有 PID 跨进程保存锁和死亡锁回收，浏览器/Worker 适配器使用 Web Locks + localStorage；纯 WASM 内核的内置持久文件系统仍未宣称完成。
- [x] WASM 同会话异步事务串行化与 `base_revision` 持久化基线；并发调用只允许队列中的首个符合旧快照提交，宿主可据此实现外部 compare-and-swap。
- [x] 引擎增量向量计划、空间/页面版本校验和外部搜索抽象；见 [向量供给](embedding.md)。
- [x] 外部向量交换载荷：JSON 数组与 little-endian f32 Base64 双编码、长度/有限值/二选一校验；provider 注册、心跳、撤销、空间绑定、当前页面版本与 embedding 输入文本校验、持久 provider-job open/claim/heartbeat/complete/cancel/fail、租约抢占与超时失败、embedding 原子向量发布、search 候选校验和审计已通过 native e2e，provider 进程的实际推理仍在引擎外。
- [x] 外部 Agent 编写协议：上下文版本令牌、结构化草稿整批校验、编译提交和真实磁盘竞态验证；见 [编写协议](authoring.md)。
- [x] 精简 Web 服务及真实 HTTP/浏览器验收；见 [Web 规格](web.md)。
- [ ] Linux/Windows CI 与多平台引擎分发：三个 job 已配置（Ubuntu 完整门禁并产出 Linux native 分发包/校验和、`windows-native`（官方 PowerShell 安装器 + native check/test/build + 分发包脚本）、`clang-cl` 对 `platform/fs.c` 的语法检查）；历史 26 次运行全部因依赖解析失败（工作流缺 `moon install` 步骤），随后补的 `moon install` 又被新版工具链移除无参数形式打破（运行 41046091111），本会话改为两个 moon job 仅 `moon update`、依赖按需拉取并以本机验证，并新增 `.moonbit-version` 把 CI 工具链固定在本机验证过的 `0.10.14+7d59c7ec9`（moon 0.1.20260920）以止住 latest 漂移；Linux 绿运行与 `memorycorridor-native-linux` 分发包 artifact 已由运行 41050582660 取得（2026-10-30），Windows 运行时/分发证据仍缺——`windows-native` 现稳定执行到 native 链接，败于 `platform/socket.c` 的 Winsock 符号未解析（缺 ws2_32 链接）。
- [x] 受限文学化 IR 一致性矩阵：缩进/Tab/波浪线/超长围栏、短闭合与脏闭合拒绝、信息串变体、空块、CRLF、EOF 辅助块、`replace_first_checked` 逐字节保留、目录/视图规范化往返与字段边界、native/WASM 同一尾随规则拒绝，以及 400 个随机文档 + 320 个确定性变异的无 panic/幂等检查；见 [验证记录](../../docs/verification.md)。
- [x] 当前实现的 check 零警告、纯函数/磁盘/MCP/WASM 门禁与 >85% 有效源码占比核对。
- [ ] 完整分期验收与跨平台压力：Windows/Linux 运行时证据和跨机器阈值仍未取得（见上一条），本机矩阵已覆盖但完整分期验收未完成。
- [x] 检索语义/策略字段的敌意矩阵与边界成功用例；见 [敌意输入](adversarial.md)。
- [x] 初始本机规模/并发诊断基线：真实 16/64/128 页、关键词/暴力向量/混合检索、ranked/even/similar 配额对比与 1/2/4/8 进程锁竞争；不宣称跨平台 SLA，见 [规模基线](scale.md)。

## 已知边界

- 本版的图统计是基础启发式；已提供确定性加权路径和加权标签传播社区结果，但不等于语义聚类或完整 Louvain 优化，仍未做实测规模优化。
- 检索上下文按词覆盖选择单一连续正文区间，预算优先排名较前页面；精确正文去重不判断语义等价。预算包含块内引用与正文，不包含 JSON 元数据；没有特定模型 tokenizer 的精确承诺。
- [x] **字符串/数组边界（参数扫描的最后一块）**：`text ≤4096`、`key ≤256`、
  `conditions ≤16`、各 condition `≤256`、`sources ≤32` 五个边界此前只有一条 newline 用例，
  **两侧都没钉住**。已全部补双边：恰好等于上限必须通过、上限+1 必须拒绝。
- [x] 实测确定语义：这些边界按**字符**计而非字节——4096 个 CJK 字符（12288 字节）被接受。
  已把该用例写进测试，任何人把它改成字节计数都会立刻失败。
- [x] **第一版 `sources` 计数测试是单边的，变异存活**：只断言 33 条被拒，
  而把上界从 32 改成 16 后 33 条仍然被拒——测试照绿。
  利用检查顺序修掉：计数检查先于注册检查，所以发恰好 32 条时，
  上界正确则报 `memory_source_not_registered`，上界被压低则报 `memory_sources_count_invalid`，
  两者可区分。**不需要真注册 32 个文件就能钉住下界。**
- [x] **枚举字段扫描**：逐个核对 7 组枚举的合法值是否都被发送、非法值是否都被拒。
  6 组完整（format、provider kind/status、memory kind、dedup、spread）；
  `review-resolve` 的 `action` 三个合法值中 `create-page` 从未被发送。
- [x] 但更要紧的是：**`review-resolve` 的非法 action 拒绝分支从未被测**。
  已用**真实 review id** 补断言（用不存在的 id 会被记录查找先拦住，测不到枚举）。
- [x] **顺着这条线抓到一个完全无守护的 AGENTS.md 要求**：
  `core/records.mbt` 里事件层还独立校验一次 decision action（`review_action_invalid`），
  防外部编辑的 `state/reviews/*.json` 夹带不支持的操作——而**移除它全套件照绿**。
  原因：没有任何测试断言过 `record_invalid`。
- [x] 已补：篡改一条已解决 review 的 `decision.action`，断言 `lint` 报出
  `record_invalid` 且 `detail == "review_action_invalid"` 且路径正确，
  并断言 `verify`/`review-list`/`status`/`stats` 都以 `content_changed` 拒绝。
  已验证是**唯一**捕获者：移除该校验后 `lint` 不再报 `record_invalid`，断言立刻失败。
  注意必须走 `lint`——`verify` 先被内容哈希拦住，根本到不了记录校验。
- [x] 四条边界均已验证载荷性并登记为变异（text 字符/字节、conditions 计数、sources 计数）。
- 浏览器是只读快照，文本筛选不是 CLI 的排名搜索；视觉声明支持包含目录、正文、来源的必选面板，以及受限的 wikilink 图关系和快照统计面板，不支持任意动态组件。
- staging 暂存草稿有意保留，无自动清理。目标声明修改必须显式 refresh 后重新读取上下文。
- [x] **按"每个 fail 分支是否可达"系统扫 `core/records.mbt`**：191 个 `*_invalid` 分支中
  **177 个从未被任何测试引用**。先验证可达性假设：这些分支无法经 op 触达
  （篡改记录先被内容哈希拦住，所有校验读都停在 `content_changed`），
  唯一能触达的面是 `lint`——它报 `record_invalid` 且 `detail` 正是分支名。5 个样本全部验证通过。
- [x] 新增 `scripts/record_validation_e2e.py`：表驱动覆盖 **17 个分支**，
  横跨 memory / research / suggestion / overview / order / provider / provider-job 七类记录。
  每条用例：篡改一个字段 → 断言 `lint` 恰好报一条 `record_invalid` 且 detail 命中 → 还原 → 断言干净。
- [x] 该测试对校验链上**每一个**分支都敏感：移除 memory kind 分支后，
  同一篡改的 detail 从 `memory_kind_invalid` 变成 `memory_note_hash_mismatch`，断言立刻失败。
  已登记为变异。
- [x] **把记录校验覆盖从 17 扩到 53**。上轮我说这是"没有新判断的机械工作"——
  这个判断又是错的：扩展过程本身就需要一个发现工具，而工具揭示了新信息。
- [x] 新增 `scripts/branch_probe.py`：对每类记录的**每个字段**系统性投毒，
  记录 `lint` 报什么。它区分了三种情况：
  ① 单字段篡改就能触达的分支（大多数）；
  ② 需要**两个字段配合**的分支（status 先变，closed 状态的形状才被检查）——6 条；
  ③ 参与记录身份的字段（evidence 的 page/claims），篡改后报 identity mismatch 而非目标分支。
- [x] 扩展中修正自己对数据形状的误判：`source_hashes` 是与 `sources` **并列的数组**，不是 map。
- [x] 并确认一个顺序细节：memory 的 shape 检查在 `note_hash` 之前，
  所以篡改 kind/scope/text 会先触达 shape 分支——这让同一条断言对两类分支都敏感。
- [x] 已验证载荷性：移除 `research_inputs_hash` 分支后，
  对 `inputs_hash` 的篡改不再报该分支，断言立刻失败。
- [x] **记录校验覆盖 53 → 86**。用 `branch_probe.py` 把探针扩到全部记录类别，
  新发现 impact / review / order / provider-job 四类此前**完全没覆盖**，
  以及 evidence 的 `page_hash` → `evidence_page_invalid`。
- [x] 探针还揭示两类新模式：
  ① `impact` 的 `dismissed`/`resolved_at` 在 open 状态下有专属分支
  （`impact_dismissed_open_invalid` / `impact_open_resolved_at_invalid`）；
  ② `provider-job` 的 `closed_at`/`error`/`result`/`result_hash` 在 pending 状态下
  统一走 `provider_job_pending_invalid`——一个分支覆盖四个字段。
- [x] 过程中修掉探针脚本两处：`publish` 与外部共用一个变量名被误替换；
  `plan` 在金库无待办工单时返回空列表，改为先写新 raw 再 scan 取工单。
- [x] 已验证载荷性：移除 `impact_kind` 分支后，篡改 kind 的 detail
  从 `impact_kind_invalid` 变成 `impact_record_identity_mismatch`，断言立刻失败。
- [x] **event 层从零覆盖到 122 个分支**。新增 `scripts/event_branch_probe.py`：
  事件文件是内容寻址的，所以容易假设"篡改只会得到 identity mismatch"——
  **实测不成立**：shape 检查独立于文件名哈希，48 个 (op, field) 组合触达 46 个分支。
- [x] 已把探针发现写入 `record_validation_e2e.py` 的事件用例表（36 条），
  覆盖 ingest / memory-submit / research-topic / purpose-suggest /
  overview-suggest / quality-audit / review-resolve / provider-register 八类事件，
  总覆盖 **122 个分支**（191 个中的 64%）。
- [x] 过程中修正自己三处：① `ingest` 事件在本场景没有 `page_hash` 字段，该用例不可达，已删；
  ② 补了 `review-resolve` 后，原来那条"pending 不得带 decision"的用例失效，
  改为单独捕获一条仍 pending 的 review；③ `predicate`/`subject` 需含换行才触发，空串合法。
- [x] 已验证载荷性：移除 `memory_event_key_invalid` 分支后断言立刻失败。已登记为变异。
- [x] **本会话第四次被「shell 传代码」咬到**：用 `python3 -c` 写含 `\n` 的字符串，`\n` 被解释成真实换行，把 `mutation_check.py` 的单引号字面量写跨行、语法错误，verify.sh 直接 EXIT=1 且无输出。前三次是反引号命令替换。
  **定论：凡是要把含引号/反斜杠/换行的代码写进项目文件，一律走 `write_file` 写脚本再执行，不用 `python3 -c` 也不用 heredoc。**

- [x] **抓到一个真回归：`memory-candidates` 的 pinned 护栏消失了**。
  `moon test` 报 `memory candidates never proposes a pinned or already-settled note`
  失败（`2 != 1`），加打印后确认 `pinned` 笔记出现在 prune 候选里——
  即引擎会提名删除一条被人工标记保护的笔记，直接违反保护位。
- [x] 已恢复 `if note.pinned { continue }` 并补注释说明它优先于任何使用信号。151 测试恢复全绿。
- [x] 这条回归大概率来自本轮前面某次「备份 → 变异 → 还原」序列中用了过期备份
  （本会话对 `agent/memory.mbt` 做过 7 次变异，每次都是 `cp` 备份再还原）。
  **教训：变异还原不能只信 `cp` 备份，还原后必须跑一次全量 `moon test` 确认；
  本次如果只看变异检查器的输出（它自己会恢复并重建），这个回归会被带过去。**
- [x] **覆盖 122 → 131，并验证两个此前的假设是错的**：
  ① 我以为 `*_event_identity_invalid` 可靠"重命名事件文件"触达——实测**不能**，
  重命名只会让文件变成孤儿，由 `file_unregistered` 报告，两个谓词不能混为一谈；
  ② 我以为 vector 记录在 `state/vectors/`——实际在 `vectors/`。
- [x] 新覆盖分支：`event_operation_required` / `event_operation_unsupported: <op>`
  （后者正是 AGENTS.md「未知 op 必须拒绝」的落地，含尾随空格变体）、
  `vector_record_dimensions_mismatch` / `vector_record_zero_norm` /
  `vector_record_hash_invalid` / `vector_record_nonfinite`，以及"重命名成孤儿"这条对照断言。
- [x] 过程中修正自己四处：① 孤儿断言用 basename 比全路径；
  ② provider 注册的是 8 维空间而请求写了 2 维；
  ③ `["a"]*n` 触达的是 `vector_record_nonfinite`（有限性检查在维度之前），不是维度不符；
  ④ 变异字符串没匹配到（实际在 588 行、形态不同），改用 write_file 脚本。
- [x] **查清剩余分支为什么不该强盖**：`*_event_identity_invalid` 一类（约 30 个）没有任何外部触达方式，三条路全部实测走通后确认：
  ① 重命名事件文件 → 只变成孤儿，报 `file_unregistered`（已作为对照断言写入测试）；
  ② 篡改字段 → shape 分支先触发；
  ③ `pack` 导入 → **包里只有内容寻址的 `objects/<hash>`，根本没有路径，也不含 `state/events/`**（对真实归档核对过）。
- [x] 结论：这些分支断言的是**引擎自身维护的不变量**，是纵深防御而非可达状态，
  任何测试都无法诚实宣称覆盖它们。已把这段推理写进 `record_validation_e2e.py` 的注释，
  连同"重命名→孤儿"的对照断言，避免后来者重复这三条死路。
- [x] **复核上一轮"不可达/低价值"的判断，部分成立部分不成立**：
  逐个数出 191 个分支中 84 个未被任何测试引用，其中约 15 个确是证明不可达的
  `*_event_identity`，但**其余 69 个里混着可达的**——上轮"低价值"的笼统判断又偏了。
- [x] 新覆盖 3 个分支（131 → **134**）：`evidence_event_page_hash_invalid`、
  `ingest_event_order_invalid`、`evidence_superseded_by_invalid`。
- [x] 同时确认一个**结构性遮蔽**：evidence 记录的 claim 级分支
  （`evidence_quote_invalid` / `evidence_range_invalid` / `evidence_source_quote_invalid` 等）
  在记录校验层不可达——记录 id 由含 claims 的全文派生，篡改任一 claim 字段都先触发
  `evidence_record_identity_mismatch`。这些分支只在 `evidence-submit` 提交时可达，
  而那已由 `evidence_source_e2e.py` 覆盖。已把结论写进注释，不算缺口。
- [x] 另确认 `page-archive` / `page-restore` 事件**没有任何字段可达 shape 分支**
  （所有字段都进文件名哈希），因此那 8 个 `page_*_event_*` 分支确实不可达。
- [x] **尝试覆盖 provider-job 生命周期分支，未完成，已回滚**。过程中连续踩到
  shell 转义问题（本会话第五、六次），把 `record_validation_e2e.py` 写坏，
  最终**回滚到本轮开始前的 134 分支状态**并验证：语法通过、134 分支全绿、
  `moon check`/`moon test` 通过。
- [x] 回滚前已确认的技术结论（下次可直接用）：
  ① `provider-job-complete` 的 `result` 形如 `{"items": [{page, sha256, values}]}`，
  且 page/sha256 必须与 job 的 request 完全一致，否则报 `provider_job_result_page_mismatch`；
  ② `provider-job-open` 的 request item 必须保留 `embedding-plan` 给出的**全部**字段（含 `text`），
  而 `embedding-submit` 只收 `page/sha256/values`——两者的 item 形状不同；
  ③ 测试辅助函数的 `error=` 参数会吞掉同名的 op 字段，需要单独的传参路径。
- [x] **provider-job 生命周期分支覆盖完成（134 → 142），这次按规则做的**：
  全程用 `write_file` 写脚本，没有被 shell 咬到。上一轮回滚的三个技术结论直接可用。
- [x] 覆盖内容：构建三个终态 job（completed / failed / cancelled），
  分别篡改各自状态才检查的字段——`provider_job_result_invalid`、
  `provider_job_closed_at_invalid`（三个终态各一条）、`provider_job_error_invalid`、
  `provider_job_cancelled_result`，以及请求信封的 `provider_job_items_invalid`、
  `provider_job_text_recipe_invalid`。共 8 个新分支。
- [x] 关键前提（上一轮已确认）：request item 必须保留 `embedding-plan` 的全部字段（含 `text`），
  而 `embedding-submit` 只收 `page/sha256/values`；completion 的 `result.items[].page/sha256`
  必须与 request 完全一致，否则报 `provider_job_result_page_mismatch`。
- [x] 新增 `call_fields` 辅助函数：某些 op 有名为 `error` 的字段，
  会被主辅助函数的 `error=` 期望参数吞掉。
- [x] 两条新变异均已验证载荷性（移除 `provider_job_result_invalid` / `provider_job_cancelled_result` 后断言立刻失败）。
- [x] **尝试补 provider-job 事件层分支，未完成，已还原到 142 分支的已验证状态**。
  失败原因不是技术问题而是操作问题：本轮上下文接近耗尽，连续的截断/移动脚本
  把测试文件复制出多份生命周期块与事件块，越修越坏。最终按行号截断到本轮编辑前的位置
  并手工补回尾部，验证 **142 分支全绿**、`moon check`/`moon test` 通过。
- [x] 已确认的技术结论（下次可直接用，不白费）：
  ① job 事件的 op 名是**过去式**（`provider-job-completed`/`failed`/`cancelled`），
  与操作名（`complete`/`fail`/`cancel`）不同，容易写错；
  ② 事件形状比记录窄：completed/cancelled 只有 `op,id,provider,at`，
  failed 只有 `op,id,error,at`——result 的形状是**记录级**检查而非事件级，
  因此 `provider_job_result_invalid` 在事件层不可达（已在 142 分支中由记录层覆盖）；
  ③ 可达的事件层分支是 `provider_job_event_id_invalid`、`provider_job_event_provider_invalid`、
  `provider_job_event_error_invalid`、`provider_job_event_field_invalid: <field>`。
- [x] **provider-job 事件层分支覆盖完成（142 → 147），这次按规则做的**：
  单个 `write_file` 脚本、插入后立刻核对块计数（lifecycle=1 / events=1 / open_job=1），
  没有被复制问题咬到。上一轮记下的三个技术结论直接可用。
- [x] 覆盖 5 个新分支：`provider_job_event_error_invalid`、`provider_job_event_id_invalid`、
  `provider_job_event_provider_invalid`（completed 与 cancelled 各一条）、
  `provider_job_event_field_invalid: worker`。
- [x] 关键形状（上轮已确认）：completed/cancelled 事件只有 `op,id,provider,at`，
  failed 只有 `op,id,error,at`；op 名是过去式。因此 `provider_job_result_invalid` 在事件层不可达——它是记录级检查，已由上一轮覆盖。
- [x] 新增 `scripts/branch_coverage.py`（**报告器，非门禁**）：
  数出 `core/records.mbt` 的 191 个 `*_invalid` 分支中哪些没有被任何测试引用。
  它存在的理由是：这些分支曾经长期停在 1/191，因为没有任何东西数过它们，
  而删掉一个没人引用的分支会让所有套件照绿。
- [x] **实测纠正了我上一轮的错误估计**：我说「实际可达而未覆盖的已降至个位数」，
  实际是 **74 个分支未被任何测试引用**（191 中 117 个被引用）。
  我之前的估计把「`record_validation_e2e.py` 报的 147 个分支」当成了分母，
  而那个数字包含 `agent/`、`vault/` 等其它文件的分支，分母完全不同。
- [x] **用两个探针对 74 个未引用分支做可达性实测，补齐后 147 → 157**。
  结论：74 个中 **12 个探针可达而测试未引用**（真实缺口），62 个探针也未触达。
  已补 10 条（另 2 条需要 `impact-resolve` 事件，本场景未构造，留待后续）。
- [x] **实测推翻我之前的一个结论**：`*_event_identity_invalid` 我记为不可达，
  理由是"重命名事件文件只会变成孤儿」。这没错但不完整——**篡改一个进入文件名哈希的字段**（如 idempotency key、provider 名）就能触达身份校验。已按此补 case。
- [x] **扩展探针取值形状，又触达 4 个分支（157 → 161）**。第一版探针的取值集合太窄
  （只有空串/超长/换行/bogus/坏哈希），漏掉了几类形状：**形状正确但值错的对象**
  （`{"id":"vec","dimensions":0}`）、64 位十六进制但非真实哈希、负数、布尔、
  路径逃逸。补上后新增 `order_record_page_hash_invalid`、`overview_page_hash_invalid`、
  `provider_dimensions_invalid`、`provider_job_dimensions_invalid`。
- [x] **探针递归进嵌套字段，又触达 3 个分支（161 → 164）**。前两轮只篡改顶层字段，
  而 provider 的 `space`、job 的 `request.items[]` 的校验在对象内部，顶层篡改永远到不了。
- [x] 修掉探针自身一个崩溃：`dig()` 把 `claims[0]` 当字典键用，
  改为先用正则拆出数组下标。修前探针 exit=1（跑到一半就死），修后 exit=0——
  **探针自己崩掉时也会给出一个看起来正常的数字**，和早前正则写错同类。
- [x] 分支覆盖 **131 → 133 被引用**（191 中 58 未被引用）。
- [x] **尝试给探针加状态组合，不可行，已回退**。受 `status` 保护的分支需要先改 status，
  这会把工作量乘以状态数（12 个候选状态），探针直接超时（exit=124）。
  已回退到 exit=0 的可用形态，并把原因写进 `branch_probe.py` 注释：
  这类分支由 `record_validation_e2e.py` **手工覆盖**（research/suggestion/provider-job 已如此），
  这是实际可行的取舍，不是遗漏。
- [x] 回退后核对：探针 exit=0、142 行输出、分支覆盖 133 不变、164 分支全绿、
  `moon check`/`moon test` 通过。
- [x] 过程中修正自己一处：拆出 `probe_state` 时忘了把 `target` 传进去（NameError）。
- [x] 另有一条 `provider_job_embedding_item_invalid` 探针能触达但我的取值触达不到，
  已注释说明而非硬写一个假 case。
- [x] 分支覆盖 **127 → 131 被引用**（191 中 60 未被引用）。
- [x] 另一个细节：名称/键的形状校验先于身份校验，所以要用**合法但不同**的值（`renamed-backend` 而非 `""`）才能触达身份分支。
- [x] 该工具**故意不做成门禁**：我第一版带了「不可达豁免清单」，一整轮之内清单就与实测脱节
（0/33 匹配），而这正是它要防的那类失效——一份声称覆盖率的清单自己失真。
  因此改为打印事实、把判断留给运行者；要豁免某个分支，去 `tasks.md` 写明理由。
- [x] 已验证载荷性：移除 `provider_job_event_error_invalid` 后断言立刻失败。已登记为变异。
- [x] **操作教训（第七次）**：长文件的批量插入/移动必须在改完后立刻核对块计数，
  不能假设"移走"就是移走——本轮三次编辑有两次实际是复制。
- [x] 过程中修正自己一次：第一条变异写错了，复用已有的 evidence 分支却改了名，已替换为真正的 job 分支。
- [x] **操作教训（第六次）**：本轮每次写代码都用 `python3 -c` 内联长字符串，
  连续三次被 shell 吃掉引号/反斜杠。正确做法从第一行就该是 `write_file` 写脚本。
  已在前面记录过该定论，本轮是**没有遵守自己刚写下的规则**。
- [x] 已验证载荷性：移除 `evidence_superseded_by_invalid` 分支后断言立刻失败。
- [x] 因此记录/事件层覆盖的实际上限就是 **131/191**，剩下约 60 个中约 30 个是上述不可达分支，其余是 provider-job 事件层明细（可达但需要构造完整的  job 生命周期，边际价值低于已覆盖部分）。
- [x] 已验证载荷性：接受未知 event op 后，`bogus-op` 不再报分支，断言立刻失败。
- [x] 剩余约 69 个分支集中在 vector 记录明细、provider-job 事件层与
  `*_event_identity_invalid` 一类（后者需要构造文件名与内容不一致，触达方式不同）。
- [x] 剩余未覆盖约 91 个分支，集中在 **event 层**（`*_event_*`，约 60 个）与
  vector 记录明细；event 层需要真实事件文件而非记录文件，触达路径与记录层不同。
- [x] 剩余约 124 个分支未覆盖，集中在 event 层（`*_event_*`）与 vector/provider-job 明细；
  它们共用同一机制，扩表就是加行，但每条都需要先确认触达路径，不是纯复制。
- [x] 过程中修正自己四处：① `provider-job-open` 的 request 字段名错（应为 items/text_recipe，
  数据要从 `embedding-plan` 取）；② provider 记录路径不是名字而是 register 返回的 `path`；
  ③ evidence 的 `page`/`claims` 参与记录身份，篡改后报 identity mismatch 而非目标分支
  （这是正确拒绝，只是另一分支，已改为注释说明）；④ shell 反引号再次吞代码。
- 无效知识目录通过显式 read-last-valid 读取经过版本复核的缓存快照；没有静默 fallback 或未验证正文读取。
- [x] **演示金库补上 change-impact（Diff Engine）的展示**：`make_demo.py` 本来就有记忆笔记和
  一个开放研究主题，但从不调用 `impact-audit`——A5 的头目特性在演示里完全看不见。
  现在在主题冻结**之后**加入新材料（`raw/断代依据.md` + 概念页）再调用 `impact-audit`，
  演示金库里真有一条 open 的 research baseline-drift 记录，`inbox` 的 research 条目带
  drift 字段——正是「一个主体只提案一次、原因折进 drift」的实况。
  顺序关键：材料必须在主题冻结之后到达，否则输入未变、不会开记录。
- [x] **演示补齐其余 A5 面**：上一条之后复查发现还有两处同型缺口——
  `memory-conflicts` 恒为空（冲突保留不可见）、`memory-candidates` 的 `merge` 恒为 0（去重不可见），
  两者都是 A5 Autodream 的头目概念。已补：一对**同条件不同判断**
  （`memory-conflicts` 报 groups=1/notes=2，`inbox` 出现 `memory-conflict` 条目）；
  一对**异条件同 token 的改写变体**（`memory-candidates` 报 merge=1）。
- [x] 关键区分：同条件+不同文本 = 冲突（两侧都保留）；异条件+同 token = 可合并。
  演示现在四个面都有实数据：conflicts / candidates(merge+prune) / impacts / inbox。
- [x] **protocol.md 的字段契约无法机器可靠核对，已记录结论并停止该方向**。
  两次尝试：未锚定正则匹配 `- \`op\`` 得 14 个疑似缺失，其中 13 个是假阳性
  （把「`memory-pin` 之外的状态记录…」这类行内提及当成定义段）；改为行首锚定后
  仍有 13 个存疑，且 93 个 op 中只有 32 个有行首契约段——其余写在共享的散文段里。
- [x] 结论：文档用带共享段落和行内提及的散文描述 op，**脚本化比对字段名的假阳性率约 90%**，
  这类检查比不检查更糟（会导向修改 13 个不存在的问题）。唯一确证的缺口
  （`evidence-submit` 未提包裹字段名 `items`）已人工找出并补上。
- [x] 因此不再为该方向写工具；后续若要核对，应逐个人工读，或先把 protocol.md 改成
  每个 op 一个结构化小节——那是文档重构，不属于「在现有基础上完善」。
- [x] **补 lint 谓词覆盖：新增 `scripts/lint_predicates_e2e.py`**。系统核对发现 lint 的
  48 个谓词中 **25 个未被任何测试引用**（人工 grep 确认，非假阳性）。
  已补 4 个可达的：`page_metadata_drift`（kind 非法 / sources 为空）、
  `page_syntax`（frontmatter 缺必填字段）、`source_hash_drift`（raw 来源消失）。
- [x] 方法与 `record_validation_e2e.py` 同源：**篡改引擎没写的文件**
  （人类编辑或外部工具真实会产生的形状），断言点名的谓词，再还原并断言全部谓词清空。
- [x] 剩余 21 个未覆盖谓词集中在：目录层（`catalog_syntax`/`catalog_compile`/
  `duplicate_entry_*`/`entry_*`/`*_entry_invalid`）、向量与 evidence 锚点、
  以及 memory/impact 的跨记录不变量（`memory_supersede_*`/`impact_duplicate`/`memory_key_ambiguous`）。
  这些多数需要构造结构损坏的目录或特定跨记录组合，触达成本高于已补部分。
- [x] **实测确认剩余 lint 谓词为何不可经记录篡改触达**（而非断言）：
  对向量记录逐个字段投毒（page/space/dimensions/values），只产生通用的 `record_invalid`，
  没有任何专属谓词。原因：`vector_entry_invalid` 校验的是**条目形状**
（`vectors/` 前缀、`json` 格式、无 sources），不是记录内容——见 `agent/lint.mbt:112`。
  要触达必须改目录 IR（围栏内的条目行），那和 `duplicate_entry_id` 属同一类，已确认成本高。
- [x] 因此上一轮"剩余部分是在为覆盖率而构造」的判断**这次有实测支撑**，
  不是又一次凭感觉下结论：剩余谓词全部需要目录层构造，而非真实的记录损坏路径。
- [x] **实测确认目录结构类谓词为何难触达**（而非断言）：在 `index.mbt.md` 的 IR 围栏内
  复制一行 `entry(...)` 构造重复 id，得到的不是 `duplicate_entry_id` 而是
  `catalog_syntax`，detail 为 `catalog_noncanonical: offset 11640; expected "2)\n}" got "1)\n}"`
  ——引擎按规范形式重新生成目录时会编号，重复行使编号不符，先被规范化检查拦下。
- [x] 因此剩余 lint 谓词确实需要**生成规范形式的多条目 IR**（而非简单复制行），
  触达成本显著高于已补的 12 个。这是实测结论，不是又一次「我觉得够了」。
- [x] **`agent/` 层 156 个 `@base.fail` 分支的系统扫描**：会话开始时 79 个无任何测试引用。
  已补 66 个，剩余 19 个的触达路径与失败原因逐条登记在
  [未触达的校验分支](../../docs/unreachable-branches.md)——按性质分三类：
  被更早检查遮蔽（7）、竞态类（7）、结构上不可达（5）。
  **判定口径是实际构造攻击并观察引擎真实响应，不是"读了代码觉得不行"。**
  本会话里这个区别很要紧：有十几次"读了代码觉得不可达"的结论，实际一试就通。
- [x] 该文档同时沉淀了三条可复用的触达手法，按构造代价从低到高：
  纯记录层字段篡改（先读代码确认分支前置条件，`evidence_already_replaced`
  只要篡改一个字段而同族 `evidence_event_conflict` 要整套拆除）、
  选择性拆除（匹配 IR 条目行只能取 `entry()` 前两个引号字段；只能用差集；
  删注册文件要同步删 IR 条目并把计数断言减一）、
  改序列化（当所有字段都被路径/校验钉死时，引擎比对的是原始字节，
  `json.dumps(parsed, indent=1)` 同字段不同字节即可触达）。
- [x] 一条通用手法找到后要横向复制：`page_archive_event_conflict` 的"改序列化"
  配方原样搬到 `page_restore_event_conflict`，一次通过。前面几轮逐个分支单啃，
  浪费了不少轮次。
- [x] 操作层面的坑也写进该文档，本会话反复踩到：变异检查被中断后**二进制还是用
  变异码编译的**（恢复源码后必须显式重编译，否则 `mcp_e2e` 报
  `lint_refuses_missing_catalog`）；catalog 副本会过期（恢复时也要用动手前一刻的
  快照）；用例位置有约束（`scan` 只在早期能登记订单；`overview`/`evidence` 类
  必须放在页面还干净处）；定位事件必须用业务字段不能用目录顺序；
  `another_order_active` 是订单簿的隐形约束。
- [x] **2026-10-29 修复 CI 依赖解析——GitHub Actions 26 次运行全部失败的根因是工作流缺依赖安装步骤**。
  26 次运行全部 `failure`：`verify.sh` 首条命令是 `moon check`，而工作流从未执行过
  `moon update` + `moon install`，依赖解析必败。修复：Ubuntu job 在工具链安装之后、
  verify 步骤之前新增「Sync the MoonBit registry and install dependencies」（bash）；
  `windows-native` job 在 PowerShell 安装器之后新增同名步骤（pwsh）；
  `clang-cl` job 只做 `platform/fs.c` 纯 C 语法检查、不涉 moon 依赖，确认无需改动。
- [x] **以全新目录模拟验证依赖修复通过**：在干净目录按工作流同序执行
  `moon update` + `moon install` + `moon check`，确认克隆后缺索引/缺依赖的状态能自愈。
  绿运行与 Linux/Windows 分发 artifact 仍待推送后由 CI 取得——此前 26 次运行
  **从未产出过任何 artifact**，旧文档「Ubuntu job 产出 Linux 分发包」的写法与事实相反。
- [x] **2026-10-30 修复运行 41046091111：最新 moon 工具链移除无参数 `moon install`（改版后
  `install <SOURCE>` 为必选参数，用于全局安装二进制包），两个 moon job 的
  「Sync the MoonBit registry and install dependencies」步骤直接 exit 2**。修复：两个 job
  改为仅 `moon update`（注册表索引同步仍是必需的），`moon.mod` 声明的依赖由
  `moon check/test/build` 按需拉取到 `.mooncakes/`——本机把 `.mooncakes/` 移走后
  `moon update` + `moon check --target native --deny-warn core` 实测自动解析并重新下载
  `moonbitstack/moonyaml@0.1.1`；README 首次构建代码块、README/implementation-audit/tasks
  的 CI 现状表述同步。Windows 侧同一根因同一修法，但无 Windows 环境实测。
- [x] **2026-10-30 后续运行 41047212599：依赖同步步骤已绿，但 latest 工具链的新版 core 把
  `ToJson::to_json` 方法调用标记为 deprecated（建议改用 `Json(value)`），verify.sh 首条
  `moon check --target native --deny-warn` 在 base 包即失败 4 处；全仓 `.to_json()` 调用
  394 处，修完 base 后会连锁暴露，非本次最小修复范围**。修复改为根治漂移：新增
  `.moonbit-version`（`0.10.14+7d59c7ec9`），unix 安装器以位置参数、PowerShell 安装器以
  `MOONBIT_INSTALL_VERSION` 读取同一文件，CI 不再随 latest 漂移。已实测：临时 `MOON_HOME`
  安装该版本得到 moon 0.1.20260920/914d7da（与本机一致），冷启动 `moon update` +
  `moon check --target native --deny-warn` 通过（exit 0）。遗留：全仓迁移到 `Json(value)`
  需在新工具链下本地验证后另行推进，届时再升 `.moonbit-version`。
- [x] **2026-10-30 运行 41048766040：固定工具链后 linux job 深入到 verify.sh 尾段
  （check/test/build、30 个 e2e、record/lint 分支探针全过），仅快照图浏览器检查的
  「no horizontal overflow」在 CI 首次执行即失败（8/9 断言过）**。根因：CDP 检查启动
  Chrome 未指定窗口尺寸，溢出断言随环境默认视口与字体度量漂移——本机默认视口
  innerWidth=756 时 scrollWidth=741，仅以一个滚动条宽度（15px）余量通过，Linux 字体
  更宽即翻转。修复：检查固定 `--window-size=1280,800` 桌面视口，溢出失败时在断言标签
  内报告 scrollWidth/innerWidth 与最宽越界元素（本机注入 2000px div 实测诊断输出正确）；
  本机重跑 `reading_fixture.py --with-map` 9/9 通过。同一运行 `windows-native` 败于
  `web.exe` 链接：`platform/socket.c` 的 Winsock 符号（`__imp_send`/`__imp_WSAGetLastError`
  等 14 个）未解析，疑似 Windows 链接缺 ws2_32；无 Windows 环境实测，按约束不赌改，
  保留为待 Windows 证据的遗留项（非本次硬门槛）。
- [x] **2026-10-30 运行 41050582660：linux job 首次全绿**——固定工具链 + `moon update`
  按需依赖 + verify.sh 全门禁（含快照图浏览器检查）+ release 分发包构建校验 +
  `memorycorridor-native-linux` artifact 上传（约 10.6 MB）全部通过，硬门槛达成；
  `windows-filesystem` 亦绿。整条 run 的 failure 仅剩 `windows-native` 的 Winsock
  链接错误（`web.exe`/`web.blackbox_test.exe` 各 14 个未解析符号），与 41048766040
  的失败点一致、可复现，是纯 Windows 链接配置问题。
- [x] **浏览器检查去 Node 化**：工具链约束改为尽量不引入外部运行时后，原 Node 版
  CDP 检查脚本重写为纯 Python 标准库的
  `scripts/reading_map_browser_cdp.py`（socket/json/sys/subprocess/time 等）：
  Chrome 以 `--remote-debugging-port=0` + 临时 profile 启动、从 stderr 解析 DevTools
  端口；`/json/version` 按响应头 + Content-Length 读响应体——Chrome 忽略
  `Connection: close` 并保持连接，按 EOF 读响应体会一直超时，首轮误报
  `chrome debugging endpoint unavailable` 即此因；WebSocket 握手与 Sec-WebSocket-Key
  校验、客户端帧掩码、文本帧读写、CDP 消息往返、console 错误收集、map 渲染/路由断言、
  超时与临时 profile 清理全部自实现，语义与原 .mjs 一致，本机 Chrome 154 实测
  通过（9 项断言全 ok + console.error 反例 FAIL，exit 码正确，profile 无残留），
  随后删除原脚本；`reading_fixture.py` 直接以 `sys.executable` 调用新脚本，
  原 `resolve_node()` 探测与 Node 22+ 前置要求一并移除。
- [x] README.md 首次构建代码块补上 `moon update` + `moon install`（并注明克隆后需先同步索引
  安装依赖），验证入口一句收窄为仅 WASM 实例化 e2e 需要 Node 22+（JS 引擎宿主），
  浏览器检查不再要求 Node，30/49/58 行未动；`docs/verification.md` 第 3 行同步注明
  `NODE_BINARY` 仅用于 WASM e2e（`verify.sh` 在 48-50 行消费它）。
- [x] **lint 谓词补到 49 个且全部被测试引用**：新增 `evidence_reference_unresolvable`
  （schema 合法但引用页面不可解析的 evidence 记录），`lint_predicates_e2e.py` 触达
  **25 个**并全部还原（复跑输出 `lint predicates: 25 reached by editing files and restored`），
  变异总数 75 → 76。此前审计文档写「48 个谓词中 10 个触达」，两个数字都已过时。
- [x] **文档对账修正 `specs/engine/implementation-audit.md` 的三处失真**：
  ① 分支可达性一段是旧结论残留——「191 个分支中 164 触达、约 33 外部不可达」与
  `docs/unreachable-branches.md`（191/191 全部被引用、登记 0 个；19 个不可达分支在
  `agent/` 层：被更早检查遮蔽 7、竞态类 7、结构上不可达 5）、`docs/verification.md`、
  乃至本清单上方「实测推翻 `*_event_identity` 不可达」的记录直接矛盾，
  且 164+33=197 > 191，算术不成立——旧段把早已被推翻的死路推理又搬了回来；
  ② CI 表述与事实相反（写成已产出 Linux 分发 artifact），已改为三 job 已配置、
  依赖安装修复并经全新目录模拟验证、绿运行与分发 artifact 待推送后取得；
  ③ 更新时间写成未来日期 2026-11-14（改 2026-10-29），且 `../docs/*` 相对链接从
  `specs/engine/` 出发解析到不存在的 `specs/docs/`，改为 `../../docs/`；
  本清单 `unreachable-branches.md` 的同类断链一并修正。
- [x] **精简 Web 服务去 Python 化：`serve.py` 改为 MoonBit 原生 `web` 包**：新增
  `platform/socket.c` + `platform/socket.mbt`（POSIX socket/bind/listen/accept/recv/send/close
  完整实现，`SIGPIPE` 忽略 + `EINTR` 重试；Winsock 分支按 POSIX 镜像并在注释标注未验证，
  Windows 语法检查随 `platform_smoke.sh` 纳入）；`web/main.mbt` 实现最小 HTTP/1.x
  （请求行/Host/头/查询解析，urlsplit 方案与 `parse_qs(strict, keep_blank, max 12)` 语义镜像，
  16KiB target、100 头、131KiB 头块上限），八条只读路由经 `nativehost` 进程内派发，
  每请求独立会话「打开-校验-派发-释放」vault 锁，不长期持有；启动序 verify →（缺声明时）
  view-init → render-view，失败打印诊断退出；响应固定 `Connection: close` 逐请求处理。
  `scripts/serve.py` 删除；`web_e2e.py` 改为驱动 `_build/.../web/web.exe`，
  **全部既有断言原样保留并实跑通过**（native parity、编译页、路由/参数边界、
  未知路由 404、缺参 400、POST 405、Host 隔离 403、绝对形式 target 403、路径穿越 404、
  正文漂移 lint/status/page//、无效页面声明不覆盖旧输出）；
  `release.py` 载荷以 `bin/memorycorridor-web` 取代 serve.py，`release_e2e.py` 通过；
  `source_audit.py` 计入 `web` 包并移除 serve.py 适配项，`dep_audit.py` 增补
  `web: 层6 → base/nativehost/platform`；verify.sh 构建行加 `web`。
  文档对账：README 快速入门、docs/web.md 重写（无 TLS、loopback、串行逐请求、无每请求超时、
  Winsock 未验证）、docs/release.md、specs/engine/design.md 与 web.md、本审计「精简 Web」行
  与第 7 行占比（重跑 source_audit 实测 0.9028770854613551）。
- 本项目不包含桌面应用与专用桌面适配；此前原型及验收脚本已删除。
- 完整 YAML/CommonMark、二进制原件抽取、模型生成的广泛质量/成本与全平台分发均未借局部测试标为完成；模型调用由外部调用方提供，MoonBit 核心不访问模型或网络。
