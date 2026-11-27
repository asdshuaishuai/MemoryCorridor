# 检索子系统（派生层）

本文只描述检索。知识库的权威设计仍以 [PROPOSAL](../PROPOSAL.md) §4–14、[实现设计](../specs/engine/design.md) 与 [OKF 互操作](../specs/engine/interop.md) 为准；检索不改变知识页的编译方式，也不成为第二份页面源。

## 0. 与两条知识基线的关系

- **文学化目录是唯一目录入口。** `index.mbt.md` 是可编辑、可编译、可增量重建的 `.mbt.md` 声明；正文独立为 Markdown/OKF 页面。检索缓存只读这些正文与目录，不能反向生成或改写它们。
- **知识页只经两步工单产生。** `scan/plan → context → analysis-submit → 宿主 staged 页 → commit` 仍是唯一写入路径；模型在宿主侧，引擎零模型。检索命中、块或记忆笔记都不是“已编译知识”。
- **OKF 只做互操作。** 页面 frontmatter 保持 OKF 风格 + `sources[]`；`import`/`export` 的 OKF/Markdown 适配与 `pack` 语义不变。检索不解析出新的页面格式。
- **回归门。** `scripts/e2e.py`（两步摄入）与 `scripts/interop_e2e.py`（OKF 往返）任一失败，检索改动不得合并。
- **工作区投影不进入检索。** `workspaces/` 是派生分层，不是目录输入；`search`/`retrieve`/`context`/`graph`/`pack` 只读 `index.mbt.md` 列出的条目，删除或改写 `workspaces/` 不影响任何检索结果。`scripts/workspace_layer_e2e.py` 用派生页中的哨兵串验证这一点。

## 1. 实现

- 内核：MoonRetrieve 0.6.0 分块 BM25（Apache-2.0，纯 MoonBit）。页面按 800 字符切块、80 字符重叠，块 id 为 `<页面ID>#<序号>`；块表只存哈希，不内嵌正文。
- 缓存：`.corridor/fts.json`（制品 v5，含算法、输入指纹、页面绑定、块表与序列化 BM25）与旁车 `.corridor/fts.vectors.bin`（逐块 256 维 f32 小端，主文件用 `vectors_sha256` 钉住）。两者都是派生缓存，可整目录删除重建。
- 向量兜底：字符 2/3 元组 + 拉丁词元的签名哈希特征，256 维、L2 归一化、精确扫描；与文本路按固定 `k=60` 的 RRF 融合，同分按块 id 定序。响应的 `lanes` 如实报告 `text:"on"`、`vector:"algo"`、`reason:"no_system_engine"`。
- 系统向量路：`retrieve` 可选 `query_vector` + `provider`。宿主自行生成查询向量，引擎按 provider 注册校验后，把向量路切到页面级系统向量（每个命中页映射到首块 `<page>#0`，保留宿主返回的排序），`lanes` 报 `vector:"system"`、`reason:"provider_vectors"` 并回显 `vector_space`；无可用页面向量时仍报 `vector:"system"`、`reason:"no_matching_vectors"`。缺省（不传 `query_vector`）继续算法兜底，绝不静默切换。核心不调用 OS/模型，只校验与计算；OS/模型引擎是否存在由宿主探测（`adapters/os-embed/os-embed --probe`，见 [vector.md](vector.md)），探针为正也不会自动切换 lane——只有请求显式携带 `query_vector` + 已注册 provider 时 system 路才启用。`lanes.reason:"no_system_engine"` 表示本次请求未携带宿主查询向量，不表示机器没有引擎。
- 宿主探针与助手（续八十五）：`adapters/os-embed/os-embed --probe` 或 `python3 -I scripts/vector_engine.py probe` 只检测 OS 句向量引擎，输出 `os-embed/v1` verdict；`available:false` 是成功检测而非错误，退出 0，不注册 provider、不生成 plan/`embedding-submit`、不合成 `query_vector`、不写 vault，检索继续算法兜底并报 `no_system_engine`。只有 `available:true` 时宿主才可 `register`（调用既有 `provider-register`）并用 `query-text` 取得 `{space,values}` 驱动 system 路；探针为正也不会自动切换 lane。该路径不引入新向量模型、不下载模型、不联网；`adapters/embed-rs` + bge 是可选旧参考实现，不是默认或必装。探针不自动注册、不生成 `embedding-plan`、不自动索引。
- 接口：`retrieve` 返回块级命中与 `text_rank`/`vector_rank`；`search` 是同一内核上的页面视图（每页取最高分块）；`context` 默认 `scope=related`（引用页 + 同来源命名空间，`CONTEXT_PAGE_LIMIT=64`），显式 `scope=all` 才做整库装配，并报告 `pages_total`/`pages_omitted`。
- 校验：分块缓存绑定页面哈希与输入指纹；制品自洽但页绑定/块号/BM25 计数/旁车长度/旁车哈希任一不符都拒绝。超过 16 MiB 单文件上限的库降级为进程内集合继续应答（`cache_rebuilt:true`），`lint` 报 `cache_invalid: file_too_large`。
- 增量：`@platform.signature` 提供变化信号，`@vault.VerifyMemo` 在同一请求内前后采样一致时复用；WASM 面 `stat→None` 永远全量。
- 记忆排序复用同一分词/BM25 内核，但候选集只来自 `state/memory` 的可见笔记。默认 `rank=bm25`；`rank=weighted` 必须显式 `now`，按 `0.35×bm25/(1+bm25) + 0.30×decay×usage + 0.35×importance` 重排，半衰期 `30×(1+3×importance+2×intensity)` 天，响应返回 `score_components` 与 `tier`。这是记忆层排序，不改变页面检索的 RRF 路径。

## 2. 实测（2026-11-24，Apple M4）

- 120 页 × 32 KiB 库：`search` 21/20 ms（冷/热），`retrieve` 3/4 ms；唯一标识 `tok-p77-9` 在文本路与双路 RRF 中都排第 1。
- 600 页库：`retrieve` 12 ms；`fingerprints` 332→16 ms、`list-pages` 335→11 ms、`plan` 448→131 ms、`search` 523→44 ms、`lint` 3.7→0.42 s。
- 这些是本机规模基线，不外推为跨平台或模型质量结论。

## 3. 明确不做

- 不在核心里生成答案、摘要或查询改写；不默认用 LLM 改写查询；不引入交叉编码器重排。需要模型的部分留给外部调用方。
- 不把检索命中当成知识页；不自动写入 `wiki/`、`index.mbt.md` 或 OKF 导出。
- 核心不生成查询向量、不链接 OS/模型框架。系统向量只经宿主适配器（见 [vector.md](vector.md)）以 `query_vector` 提供；不可用时明确回退算法路并报告原因。宿主探针（`os-embed --probe`）及其可用性判断同样在宿主侧，引擎不读取、不信任、不链接。

## 4. 待办

- 块级系统向量（`vector-submit`）尚未加入：当前系统向量按页面映射到首块 `<page>#0`，保留宿主页级排序；块级排序留给后续，不写成已交付。
- macOS `NLEmbedding` 适配器与宿主探针已作为宿主工具交付（`adapters/os-embed/`、`scripts/build_os_embed.sh`、`scripts/vector_engine.py`、`os-embed/v1`），由 `scripts/os_embed_e2e.py`、`scripts/os_embed_probe_e2e.py`、`scripts/vector_engine_e2e.py` 验证；其他平台继续算法兜底。
- 分词：MoonBit jieba 因固定工具链与体积暂缓（见 `specs/engine/tasks.md` 历史账），当前 CJK n-gram 已覆盖召回；不写成已启用。

## 5. 验证

`retrieval_wbtest.mbt` 覆盖唯一标识、制品自洽拒绝、旁车哈希、向量路召回文本路漏掉的截断标识符、宿主页排序替换算法路与命名空间过滤；`retrieval_e2e.py` 覆盖块级 retrieve/命名空间/非法前缀；`embedding_e2e.py` 用手工 2 维 provider 向量在平台无关路径覆盖 `retrieve` 的 system 路、首块映射与旧向量排除（Linux CI 也执行）；`os_embed_e2e.py` 在 macOS 上验证真实 `NLEmbedding` 适配器驱动同一路径，非 macOS 显式 SKIP，存在但陈旧/损坏的适配器则 FAIL 并提示重跑构建；`os_embed_probe_e2e.py` 与 `vector_engine_e2e.py` 覆盖探针契约、不可用零写入、无网络静态守卫与 macOS live `ensure` 重建（后者临时删除标准适配器二进制并由源码重建再还原）；`e2e.py`、`interop_e2e.py` 守住知识基线与 OKF；全部由 `./scripts/verify.sh` 执行。
