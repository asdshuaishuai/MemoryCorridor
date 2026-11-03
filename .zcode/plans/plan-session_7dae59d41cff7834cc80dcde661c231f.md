## 语义级去冗余（续二十三）

### Context
PROPOSAL §373 把「改写/同义级语义去冗余」列为「不在核心内」的历史限定；用户 2026-11-03 指示开做。现状探查确认：引擎判「两段文本相近」只有 `similar_merge`（词元序列恒等，**只认格式化差异、不认改写**）、向量余弦（`brute_force`，但**只走 query→页，无页-页成对 API**）、shared-source/wikilink 图边。真正的「改写/同义级」空档 = 页向量两两比较没有入口。memory 层已有验证过的三层模式（`memory_candidates` 提议不决定 + lint 谓词）可作模板。目标：给页面层补上语义冗余的**检测+提议**面，宿主经现有 commit/编辑流程去合并——**不新增写事务面**（与「similarity 绝不能抹掉不同证据」一致）。

### 设计（两个落点，各司其职）
1. **新只读 op `page-redundancy`**（fields `["space","limit"]`，镜像 `memory_candidates`）：先 `@vault.verify` fail-closed，再对 active 非 stale 页面成对提名冗余，三路信号：
   - **向量余弦**（抓改写/同义）：同 `space` 且两页向量 `sha256==当前页哈希`（复用 hybrid_search 的内容版本闸），`@index.brute_force` 取余弦、滤自匹配、≥ `REDUNDANCY_COSINE_FLOOR=0.92` → `reason:"vector_cosine"` + 实际 `score`。缺/漂移向量的页不参与余弦提名（`embedding-plan` 已报缺口）。
   - **词元近似**（格式化近重）：复用 `@index.similar_eligible/similar_tokens/similar_merge` → `reason:"similar_text"`。
   - **共享来源**：`@index.build_graph` 的 shared-source 边 + 高词元重叠 → `reason:"shared_source"`（弱提名）。
   输出提议组 `{keeper, duplicate, reason, score}`（keeper 按 id 稳定、首个 keeper 吸收传递组，同 memory），带 `counts`/`fingerprint`。**全程只读、绝不写库**，记录仍可恢复。
2. **新确定性 lint 谓词 `redundant_page`**（warning，进 inbox）：**只用**词元近似 + 共享来源（无向量，保 lint 快且幂等），镜像 `memory_duplicate_note` 写法。

### 复用的现成件
`@index.brute_force`/`normalize`（index/vector.mbt:76/50）、`@index.similar_*`（index/context.mbt:165-186）、`@index.build_graph`（index/graph.mbt:23）、`memory_candidates` 结构（agent/memory.mbt:350-420）、`hybrid_search` 的向量内容版本闸（agent/vectors.mbt:142）、`lint_add` 谓词模式（agent/lint.mbt）。不新造底层原语。

### 改动文件
- 新增 `agent/redundancy.mbt`（op 实现）
- `agent/lint.mbt`（+`redundant_page` 确定性谓词）
- `agent/tools.mbt`（注册 `page-redundancy`）、`agent/session.mbt`（dispatch 分支）
- `agent/schema.mbt`（space/limit 字段边界，若 search 既有派生已覆盖则免改）
- 测试：新增 `agent/redundancy_wbtest.mbt`（余弦成对命中/词元命中/共享来源/无向量不提名余弦/字节闸/只读），`agent/lint_wbtest.mbt`（+1 谓词）
- 三面计数 94→95：`scripts/wasm_service_e2e.py`、`scripts/wasipure_e2e.py`（并各加一次 `page-redundancy` 调用证三面可达）
- 新 `scripts/redundancy_e2e.py`（provider-register→embedding-submit 造近义页向量→`page-redundancy` 余弦命中→只读不写；接进 verify.sh）
- `docs/protocol.md`（op 契约 + lint 谓词清单 + 计数散文）、`docs/acceptance.md`（语义去冗余从「推进中」转交付）、`specs/engine/tasks.md`（续二十三条目）
- `scripts/mutation_check.py`：为每个新决策配可抓它的测试/e2e（余弦阈值、内容版本闸、字节闸、共享来源提名、lint 谓词）

### 验证
1. `moon test -p agent -p index --target native` 全绿；`moon check --deny-warn` 零警告。
2. `scripts/similarity_calibration.py` 不受影响（词元规则未改）。
3. `scripts/redundancy_e2e.py` 端到端：造两页同义改写 + 注册 embedding provider + 提交向量 → op 报 `vector_cosine` 冗余对且 `score` 合理；未提交向量的页只有 `similar_text`/`shared_source`；op 前后 vault 字节指纹不变（证只读）。
4. 三面 e2e 计数断言 95 通过（wasm/wasipure/native 同 op 可达）。
5. `./scripts/verify.sh` 全量 EXIT=0、全部变异 CAUGHT；推送后按 `gh run view` conclusion 核实 CI。
6. 落账续二十三 + 更新 acceptance。