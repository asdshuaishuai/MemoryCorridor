# 检索上下文装配

继续现有检索任务，保持查询参数与排名规则；实现全部位于 MoonBit。

验收条件：

1. 当相关词出现在长页后段时，命中摘要与上下文应优先选取含查询词的段落；段落本身超长时定位匹配词附近。无词匹配（包括纯向量查询）采用正文前缀。
2. 当多个候选竞争预算时，按排名装配；默认 `spread` 为 `ranked`：尚有候选时每页使用剩余预算的一半，必要时增加到可容纳引用与一个 Unicode 字符；末页可用余额，短页释放余额。显式 `spread:"even"` 按剩余候选均分剩余预算（至少容纳引用与一个 Unicode 字符），紧凑预算下覆盖更多排名页。引用和正文的 UTF-8 字节总和不得超过预算，不能截断 Unicode 字符。
3. 当候选正文逐字相同时，只装配一次正文；当候选含有逐字相同的段落时，后续候选优先装配其余段落，并在 `paragraph_duplicates` 中保留重复段落的页面、哈希、来源和 UTF-8 区间。不能合并页面版本或把语义近似正文当成重复。默认 `dedup:"exact"` 保持以上逐字语义；显式 `dedup:"similar"` 额外合并**分词序列完全相同且两侧各 ≥64 UTF-8 字节**的正文/段落：大小写、空白、标点等排版差异可以命中，改变任意字母、数字、CJK 字符、词序或增删内容都不会命中；合并项记入 `similar_duplicates` / `similar_paragraph_duplicates`（含 `similarity` 与段落 `keeper_id`），被合并页版本与来源独立保留。
4. 每个上下文块返回正文中的 UTF-8 半开区间；从经校验页面的 body 截取该区间，必须能重建引用后的文本。所有原有来源/漂移/失效校验继续生效。响应同时返回启发式 `estimated_tokens`（CJK 字符 + 拉丁词，`estimate_recipe` 标识配方）和顶层 `truncated`，供宿主成本核算；估算不是模型 tokenizer 的精确值，也不改变 UTF-8 字节预算。
5. CLI、MCP、Web JSON 接口采用相同装配；WASM 纯检索采用相同摘要选择。协议文档和工具描述同步，真实 native、多字节边界与跨目标验证通过。
6. `strategy` 字段标识实际规则：默认 `ranked_halves_exact_body_paragraph_v1` 与旧行为字节一致；opt-in 组合为 `<exact|similar>_body_paragraph_<ranked|even>_v2`。同一输入重复调用必须返回字节相同的结果。
7. 图扩展按「边权 × 跳跃距离⁻¹」为每个邻居取最佳得分（互链 3.0、共同来源 4.0），按分数降序、同分按页面 id 补入上下文候选；`hits` 仍保持关键词/向量排名，图邻居不写回命中分数。种子本身不重复加入，非法边权拒绝。

设计：index 提供纯函数摘要选择与预算装配；agent 继续负责验证、排名候选和图扩展。逐字去重默认不变；近似合并只在显式 `similar` 模式下发生，且只接受分词序列完全相同的文本。阈值由 `scripts/similarity_calibration.py` 校准并把正反例固化到 `index/context_wbtest.mbt`。引用/正文预算不包含 JSON 元数据，明确记录该边界。

任务：

- [x] MoonBit 查询定位、可重建区间、排名预算与重复引用。
- [x] 纯函数反例、真实 native 工单/来源验证、WASM 跨目标摘要核对。
- [x] 协议与门禁更新，记录实际结果及剩余限制。
- [x] 显式 `dedup:"similar"` 确定性近似去冗余（token 序列相等 + 字节门槛）与 `spread:"even"` 配额策略；校准脚本、单测、native/WASM e2e 与规模对比入 `scripts/retrieval_e2e.py`、`scripts/wasm_e2e.mjs`、`scripts/scale_benchmark.py`。
- [x] 加权图扩展与启发式成本核算：邻居按「边权 × 跳跃⁻¹」取最佳得分排序（互链 3.0、共同来源 4.0）；`estimated_tokens`/`truncated` 由 `base/text.mbt` 的确定性配方计算；CJK 分词覆盖汉字/假名/谚文。

2026-10-19 复验：MoonBit 测试 96 项；`scripts/retrieval_e2e.py` 持续纳入门禁，覆盖 similar/even 场景（相似合并、来源独立、非法 choice 拒绝、漂移后不合并）、日文子串查询、`hops=1` 的加权图扩展顺序（命中页 → 共享来源邻居 → source-summary 页）、启发式 token 估算与块级一致性。真实工单创建的长页仍验证后段证据定位、重复页版本独立保留和逐字段落排除。规模基准在 16/64/128 页下对比 ranked/exact、even/exact、even/similar：紧凑 1200 字节预算时 ranked 装配约 6 页、even 装配 10 页，used 均 ≤ 预算。

边界：这是确定性词覆盖、词序等价判断与预算策略，不是模型生成质量或多领域召回的评估。`similar` 合并只接受分词序列完全相同的正文/段落，不判断改写、同义或语义等价；双侧 64 字节以下文本不合并（逐字相同仍走 exact 路径）。每个正文块仍是一个连续 UTF-8 区间。小预算可能无法包含长查询词、全部候选或全部引用；排名较后页面可用预算递减。实测配额只覆盖本机规模基线，跨平台阈值仍在后续任务。
