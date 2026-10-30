# 未触达的校验分支

`core/records.mbt` 与 `agent/` 下每个 `@base.fail(...)` 都是一条命名分支。一个分支
没有任何测试引用时，移除它全套件照绿——这正是 `record_validation_e2e.py`
出现前 191 个分支里 177 个的状态。

本文登记**试过但无法从外部触达**的分支，以及为什么。目的不是宣称"覆盖率已满"，
而是让下一个实例不必重跑同样的死路。

判定口径：每个分支都实际构造过攻击并观察引擎的真实响应，不是"读了代码觉得不行"。
本会话里这个区别很要紧——有十几次"读了代码觉得不可达"的结论，实际一试就通。

## 当前状态

| 层 | 分支总数 | 已被测试引用 | 本文登记 |
|---|---|---|---|
| `core/records.mbt` | 191 | 191 | 0 |
| lint 谓词 | 49 | 49 | 0 |
| `agent/` 层 | 156 | 137 | 19 |

`agent/` 层那 19 个按性质分三类，下面逐个登记。

## 一、被更早的检查遮蔽（7 个）

构造路径存在，但同一函数里排在前面的校验先失败。

### `evidence_page_changed`

`agent/evidence.mbt:317`：

```moonbit
if page_entry.stale || page_entry.sha256 != page_hash { fail("evidence_page_version_mismatch") }
let page_text = @vault.required(store, page_entry.path)
if @base.hex_hash(page_text) != page_hash { fail("evidence_page_changed") }
```

要触达需要目录里的 `sha256` 与传入的 `page_hash` 一致，而文件字节哈希不同。
但改了文件字节，`@vault.verify`（每个 op 入口第一行）先报 `content_changed`，
拿不到当前哈希——和 `read-page` 的 `page_changed` 同一个死法。

### `evidence_record_conflict`

`agent/evidence.mbt:406`：记录文件已存在且内容不同。

记录 id 是 `sha256("evidence-v1\n" + canonical({page, page_hash, claims}))`。
要让同 id 的记录内容不同，必须改 `claims`——而改 `claims` 就改变了 id 本身。
所以"同 id 不同内容"这个状态构造不出来。

### `evidence_replace_target_mismatch`

`agent/evidence.mbt:387`：previous 记录的 page/page_hash 与请求不符。

隔离环境可达，但在 `record_validation_e2e.py` 的 vault 里撞
`evidence_page_version_mismatch`——该 vault 到那一时点页面已走过
archive/restore/replace，`evidence-submit` 拿不到新记录。需要把用例放到
页面还干净的位置。

### `invalid_page_hashes`

`agent/orders.mbt:25`：订单记录的 `page_hashes` 字段不是对象。

这是**记录层**检查，不是 `commit` 的 `pages` 参数（后者只收 `id`/`path`/`staged`）。
篡改记录字段后调 `context`，报的是 `order_record_page_hashes_invalid`
（`core/records.mbt` 的同名检查）——op 路径也先跑记录校验。

### `memory_record_conflict`

`agent/memory.mbt:718`：记录文件已存在。

记录 id 由 `memory_note_id(key, note_hash)` 决定，改 `key` 就改 id。

### `page_changed`

`agent/session.mbt:267` 与 `agent/pages.mbt:46,83`：文件字节与目录哈希不符。

`@vault.verify` 先跑，报 `content_changed`。和 `evidence_page_changed` 同因。

### `interop_receipt_invalid`

`agent/export.mbt:8`：import 回执事件的 op/version/bundle 不符。

`core/records.mbt` 对 import 事件有 `import_event_version_invalid` /
`import_event_bundle_invalid`，先于此触发。

## 二、竞态类（7 个）

都需要"文件在两次读取之间发生变化"。外部测试无法在单线程里构造。

### `catalog_compile_race`

`agent/session.mbt:52`：编译器运行期间目录被外部改动。

```moonbit
(store.check)("index.mbt.md")
if @vault.required(store, "index.mbt.md") != catalog { fail("catalog_compile_race") }
```

`check` 与随后的 `required` 之间没有注入点。

### `event_already_exists`

`agent/commit.mbt:108`：重复 commit 同一订单。

重复 commit 走重放分支（返回 `replayed: true`），不到冲突检查。

### `export_directory_changed`

`agent/export.mbt:127`：写出后目录内容与预期不符。

外来文件被更早的 `export_directory_conflict` 抓住；被删的文件会重写；
子目录不计入 `store.files`。三者都消不掉"写出后目录恰好不同"这个态。

### `export_snapshot_changed`

`agent/export.mbt:124-125`：写出后指纹或 digest 不符。

同一个原因——写出循环与随后的复核之间没有注入点。

### `pack_catalog_changed`

`agent/archive.mbt:39,56`：快照指纹与当前目录不符。

改页面字节 → `@vault.verify` 先报 `content_changed`。

### `pack_snapshot_inventory_changed`

`agent/archive.mbt:55`：`views`/`staging`/`state/transactions/history`
的列举结果前后不一致。

`extra_paths` 与 `current_extra` 来自同一次 `pack` 内的两次列举。

### `view_snapshot_conflict`

`agent/visual.mbt:43`：视图文件或目录指纹与渲染时不一致。

改 `views/*.mbt.md` 后 `render-view` 仍返回 ok——渲染重新读取视图文件，
`required(store, path) != text` 这个条件不成立。

## 三、结构上不可达（5 个）

不是"构造代价高"，是**要让冲突分支触发，需要一个"校验时合法、冲突检查时
非法"的中间态，而引擎的检查顺序把这种态消掉了**。

### `internal_context_block`

`agent/explore.mbt:163`：`@index.assemble_context` 产出的 block 不是对象。

引擎自产的 block 总是对象，外部无法注入。

### `interop_host_path_invalid`

`agent/interop.mbt:14`：`read_bundle` 拿到的路径不带目录前缀。

`paths` 全部来自 `(store.files)(directory)`，天然带前缀。

### `provider_job_payload_too_large`

`agent/provider_jobs.mbt:31`：canonical 请求超过 256 KiB。

需要 128 个 item（每个 text 上限 16384 字符）才能把请求推过上限，
而 text 必须与页面字节一致——测试 vault 没有 128 个页面。

### `impact_record_conflict`

`agent/impact.mbt:372`：`state/impacts/<id>.json` 文件已存在，
但 `by_id` 里没有对应记录。

`by_id` 由 `impact_rows_unchecked` 构建，键是记录的 `id` 字段；
audit 按 `impact_id(kind, subject, cause)` 查，而记录的文件名必须等于
`id` 字段（`core/records.mbt` 的 `impact_record_identity_invalid` 保证）。
两者必然一致，所以 `None` 分支到不了。

试过让它不一致的三条路都不通：
- 改记录 `id` → `impact_record_identity_invalid`
- 改 IR 条目 `kind` → 每种 kind 都被目录校验拒绝
  （`page`→`unsupported_entry_kind`、`concept`/`synthesis`→`invalid_page_entry`、
  `raw`→`invalid_raw_entry`、`vector`→`invalid_vector_entry`、
  `purpose`→`invalid_purpose_entry`）

目录对条目形态的校验是全域的，没有"看起来像 state 但实际不是"的中间态。

### `page_dependencies_inactive`

`agent/pages.mbt:94`：恢复后页面因依赖失效仍为 stale。

`restore_page` 的顺序：

```moonbit
for source in page.sources { ... fail("page_sources_inactive") }   // 自身来源
let mut next = entries.map(e => if e.id == id { { ..e, stale: false } } else { e })
ignore(@core.validate_page(restored, text, next))                  // 链接校验
next = @vault.invalidate_dependents(store, next)                   // 依赖传播
if @core.find(next, id).stale { fail("page_dependencies_inactive") }
```

`validate_page` 只在 `!entry.stale` 时校验链接（`core/page.mbt:203-206`），
而 restore 刚把页面标成非 stale——所以链到失效页必先报
`wikilink_unresolved`，`invalidate_dependents` 跑不到。

试过"归档 B 后再撤销 A 的源，恢复 B 时链到失效的 A"，报的就是
`wikilink_unresolved: concepts/b -> concepts/a`。

## 已落地的触达手法

这些配方在本会话里反复复用，按构造代价从低到高：

### 纯记录层字段篡改（最便宜）

改一个不参与 id 计算的字段，同步改 IR 里对应的 `sha256`。
例：`suggestion_key_conflict`（改 purpose 哈希）、`impact_dismissed_invalid`。

先读代码确认分支前置条件——`evidence_already_replaced` 只要篡改
`superseded_by` 一个字段，而同族的 `evidence_event_conflict` 要整套拆除。

### 选择性拆除（中等）

让 op 看到"文件在但条目不在"或反之。要点：

- **匹配 IR 条目行只能取 `entry()` 的前两个引号字段**——行的其余部分
  （路径参数、`sources` 数组）也会出现 `raw/imports/...`，用 `in line`
  匹配会误删别的条目
- **拆除只能用差集**——用"op 执行前的条目集合"算出它到底新增了什么，
  只撤那些。按类型通配会把别的章节的数据一起毁掉
- **删注册文件要同时删 IR 条目并把文学块计数断言减一**，否则报
  `catalog_noncanonical`

### 改序列化（当所有字段都被钉死时）

`page_archive_event_conflict` / `page_restore_event_conflict` 的每个字段都喂
文件名哈希、`version` 又钉死为 1，字段层面无路可走。但引擎比对的是**原始字节**：

```python
reserialized = json.dumps(json.loads(original), ensure_ascii=False, indent=1)
```

同字段、不同字节（实测 183 → 202），路径不变、内容不同，冲突分支立刻触达。

**一条通用手法找到后要横向复制**——archive 通之后原样搬到 restore，一次通过。

## 操作层面的坑

这些和分支本身无关，但本会话里反复踩到：

1. **变异检查被中断后，注入 `agent/lint.mbt` 的载荷性变异会留在工作区，
   而二进制还是用变异码编译的。** 恢复源码后测试仍失败，因为 `moon build`
   认为无需重建——必须显式重新编译。症状是 `mcp_e2e` 报
   `must succeed on a damaged vault, got lint_refuses_missing_catalog`。
   另需清掉残留的 `.git/index.lock`
2. **每次用到前重读 catalog。** 任何 op 只要写了事件就会改 IR，之前存的副本
   立刻过期。**恢复时也要用动手前一刻的快照**——用更早章节的副本会把别人
   刚写进的改动一起撤掉
3. **用例位置很重要。** `scan` 只在测试早期能正常登记订单；`overview`/`evidence`
   类用例必须放在页面还干净的位置（`suggest` 会记录 suggest 时刻的
   `page_hashes`，拆除不能精确复现就被拒为 stale）
4. **定位事件必须用业务字段，不能用目录顺序。** 事件文件名是内容哈希，
   `sorted(glob)` 的顺序随新事件写入而变；同一个 op 可能有多个实例
5. **`another_order_active` 是订单簿的隐形约束。** `analysis-submit` 在任何
   其它订单处于 `context-ready`/`analysis-done` 时拒绝，而 `context` 会把订单
   从 `pending` 推到 `context-ready`。订单族可以用同一个订单走两步来避开
6. **诊断要打印真实返回值再下结论。** 直接调 CLI 拿原始回复，比靠推理猜准
7. **`git checkout <file>` 是可靠的即时回退手段**，比手工删块安全

## 复现方式

```bash
# 哪些分支还没有测试引用
python3 scripts/branch_coverage.py

# 记录/事件校验分支的触达与还原
python3 scripts/record_validation_e2e.py

# lint 谓词的触达与还原
python3 scripts/lint_predicates_e2e.py

# 全量门禁
./scripts/verify.sh
```

`scripts/record_validation_e2e.py` 里每个用例都带注释说明它为什么必须那么构造，
改动前先读对应段落。
