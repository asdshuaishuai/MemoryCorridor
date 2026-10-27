# 外部向量供给与检索

模型推理由外部调用方提供，核心仅处理验证后的向量。`EmbeddingProvider` 和 `VectorSearchBackend` 是独立 MoonBit 回调；CLI/MCP 还提供 provider 生命周期和 `provider-job-open` / `provider-job-claim` / `provider-job-heartbeat` / `provider-job-complete` / `provider-job-cancel` 持久交接协议，不接收可执行回调。

- `embedding-plan(space, limit?, provider?)` 验证 vault，按页面 id 返回当前空间下缺失/旧版本的活跃页。提供 `provider` 时必须是已注册且 active 的 embedding provider，并且空间完全匹配；空间与完整页面 SHA-256 均匹配才复用向量；批次 1–128，默认 8。空计划不写状态。
- 文本配方 `title-body-prefix16KiB-v1` 是标题、两个换行与正文的完整字符 UTF-8 前缀，最多 16 KiB。返回截断标志；原文和关键词索引保留全文。外部调用方须把配方和模型身份计入空间 id。
- 外部模型对文档和查询使用同一空间，随后调用 `embedding-submit(..., provider?)`。推理期间不持有 vault 写锁；提交时重新核验 provider、页面/来源版本、空间、维度和向量有效性。
- 使用 `provider-job-open(kind="embedding")` 时，任务输入中的每个页面必须仍是活跃页面、SHA-256 一致，并逐字匹配 `embedding-plan` 的 `title-body-prefix16KiB-v1` 文本与截断标记；宿主通过 `provider-job-claim` / `provider-job-heartbeat` 获取和续租任务，租约过期后允许领取者用 `provider-job-fail` 明确记录超时；`provider-job-complete` 接收同批 `items` 后，在任务状态和 `vectors/` 更新的同一事务中完成版本、维度、有限值和零范数校验。失败或取消不会产生向量记录。
- `embedding-submit` 的 item 是 `{page,sha256,values}` 或 `{page,sha256,values_b64}`，两种编码必须二选一。`values_b64` 是 RFC 4648 Base64 编码的 IEEE-754 binary32 little-endian 连续字节，解码后必须正好为 `dimensions * 4` 字节；解码结果仍按有限数值、维度和非零范数校验，落盘记录保持可读的 JSON 数组。
- `search.query_vector` 同样接受 `values` 或 `values_b64` 二选一；查询载荷不写入 vault。
- 默认暴力余弦扫描已有匹配向量并与关键词融合。未提供查询向量时走关键词；嵌入式宿主可通过 `VectorSearchBackend` 回调覆盖扫描，CLI/MCP 则通过 `vector_candidates:{space,hits}` 提交一次已排序候选，并可用 `provider` 绑定 active search provider。候选只能指向当前活跃页面，最多 100 项且不得重复；无效候选拒绝请求。外部候选不要求本地保存同空间向量，适合宿主维护独立索引。

`scripts/embedding_e2e.py` 和 MoonBit 测试验证确定性有界 Unicode 文本、增量跳过、模型/维度/正文版本隔离、来源失效、编译拒绝、来源竞态、JSON/f32 Base64 双载荷及外部后端覆盖。实际模型质量、模型分发与推理生命周期属于外部调用方，本仓不维护桌面模型单例。
