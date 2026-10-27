# 扩展引擎：新增一种持久化工单

MemoryCorridor 的「持久化工单」指跨会话存活、由外部宿主执行、最终由人工确认的状态记录：研究主题、目标/综述建议、审核债务、事实证据、记忆笔记、change-impact。新增一类需要在**同一组位置**登记，漏一处不会编译失败，只会在运行时静默破坏。

本文件是 checklist；`specs/engine/tasks.md` 记录已交付的范围。

## 一、记录与校验（`core/records.mbt`）

1. `state_directories()` 加入新目录。**事务白名单和 pack 白名单都读这一个列表**，所以加在这里就等于两处同时生效。
2. `validate_record` 增加对应分支：`@base.keys` 声明全部字段（未知字段必须拒绝），逐字段校验类型、长度、换行、哈希形状，并把「身份能否从字段重新派生」作为断言——例如 `memory` 用 `note_hash` + `key` 派生 id，`impact` 用 `kind/subject/cause` 派生 id。身份可派生意味着重复提交会自然重放，而不是产生第二条记录。
3. 若有状态机（`proposed` → `applied`/`cancelled`），把每个状态的不变量写进校验：终态必须带 `closed_at`，未应用的不能带 `result_hash`。
4. 事件字典：`supported` 加入新 op，并写一个分支把事件路径绑定到记录身份（通常是 `state/events/<op>-<id>-<hash(...)>`）。路径绑定让同一事件不能被改写到别处。

## 二、状态转移（`agent/<kind>.mbt`）

5. 新模块实现 op。每条状态转移都必须：
   - **`@vault.verify` 每个 op 只调用一次。** 需要多个记录来源时用 `*_rows_unchecked` 变体，不要让每个助手各自校验——那会让 `inbox` 这类多来源读取把 vault 内每个文件重复哈希多遍（本次优化前 `inbox` 一次触发约 8 次全量校验，500 笔记下 759ms）。
   - **但 dispatch 到达的入口必须自己校验。** `dispatch` 在 `match` 之前不 verify，所以直接从 dispatch 进入的 op（如 `impact-list`）若只用 `_unchecked` 变体就完全失去校验——外部篡改记录后会静默返回篡改数据。`status`/`stats` 这类在入口已 verify 的聚合 op 才该用 `_unchecked`。
   - 以 `@vault.verify(store, entries)` 开头——外部改写 `state/` 记录由此拒绝；
   - 通过 `@vault.commit` 落库，**并且把事件条目 upsert 进目录**。漏掉 upsert 会让事件文件成为孤儿：`read-log` 和 `verify` 都看不到它。`lint` 的 `file_unregistered` 专抓这个；
   - 幂等：相同请求重放返回 `replayed`，不同请求拒绝。
6. 只读 op **不要**返回 `execution:"host_required"`——该字段只属于「记录了计划、等宿主执行」的写操作。

## 三、表面注册

7. `agent/tools.mbt`：字典条目（name/description/fields）。
8. `agent/schema.mbt`：字段类型、整数上下界、是否必填。**可选字段必须加进 optional 列表**，否则 MCP 会把它宣传成必填；整数字段要加进 integer 分支，否则会被宣传成 string。这类错误只有单测能发现。
9. `agent/session.mbt`：dispatch 匹配臂。
10. `agent/lint.mbt`：跨记录不变量（重复、断链、孤儿）。单条记录能表达的校验放 `validate_record`，跨记录的放 lint。
11. `agent/inbox.mbt`：若这是宿主必须处理的工作，加一种 `kind`，带 `next` 建议操作。**一个 subject 只提议一次**——若它已有专门条目，把原因并入该条目的 `drift` 字段。

## 四、测试与文档

12. `agent/<kind>_wbtest.mbt`：身份派生、JSON 往返、校验与事件字典的拒绝路径、schema 边界。
13. `scripts/<kind>_e2e.py`：真实磁盘上的完整流程 + `verify` + pack 往返，并接进 `scripts/verify.sh`。
14. 若 op 写状态：在 `agent/transaction_safety_wbtest.mbt` 加一个发布点的中断恢复用例（用会在第 N 次 `write` 时崩溃的 store）。
15. 文档：`docs/protocol.md`（op 语义）、`specs/engine/tasks.md`（交付范围）、`README.md`（一句话特性）。
16. MCP：`scripts/mcp_e2e.py` 至少对一个代表性新 op 做真实 `tools/call`——字典比对不能证明传输层可用。
17. `scripts/mutation_check.py` 加入一条针对性变异，确认第 12-14 步写的测试真的会失败。**把 e2e 脚本名作为第六条字段写上（哪怕该行为也有 MoonBit 测试）**——漏写时 `moon test` 可能全绿，变异被误判为「测试没覆盖」，实际上是检查器没去看。这个失误连续发生过两次，因此 `mutation_check.py` 现在会扫描所有 `scripts/*_e2e.py` 的成功输出：若某条变异的 `expected_test` 是某个 e2e 成功消息的前缀却没有带 e2e 名，检查器直接报错退出（exit 2），不再依赖人记得加。

## 自检

第 17 步不是可选项。变异抓不到时先分辨两种情况：测试是装饰性的，还是这段代码本来就是冗余的（上游已保证）。后者该改的是测试——直接调用目标函数并构造能暴露问题的输入，而不是靠调用链兜底。本次开发中两个测试「看起来在测但其实没测」：一个只断言工具名存在于字典，一个被更早的 path 检查挡住、想测的身份派生从未执行。两者都是读代码看不出来、只有注入缺陷才暴露的。

写测试时最常见的失误就是「更早的检查先失败，导致想测的分支根本没跑到」——例如用篡改的 id 测身份派生，结果被 path 检查拒掉。构造用例时要确认想测的那一行真的会被执行。

```sh
moon check --target native --deny-warn   # 零警告
moon test --target native                # 含 core/state_dirs_wbtest.mbt 的目录一致性
python3 scripts/<kind>_e2e.py
python3 scripts/mutation_check.py        # 所有变异必须被测试捕获
PATH="$HOME/.nvm/versions/node/v22.23.2/bin:$PATH" ./scripts/verify.sh
```

`core/state_dirs_wbtest.mbt` 会验证：共享列表里每个目录都有 `validate_record` 分支，且两个路径白名单都接受它。新增目录忘记写校验分支时它立刻失败。
