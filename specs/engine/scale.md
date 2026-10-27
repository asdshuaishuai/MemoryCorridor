# 规模与并发基线

`scripts/scale_benchmark.py` 在临时真实 vault 中执行初始化、扫描、文学化工单提交、向量提交、缓存重建和检索。它测量关键词、纯暴力向量、混合检索的端到端 native CLI 延迟，并用多个 native 进程同时读取同一个 vault，检查 OS 锁拒绝是否明确、目录是否仍能通过 `verify`。

`--notes N`（默认 64）额外提交 N 条记忆笔记并测量 A5 衍生表面：`memory-prefetch`、`memory-list`、`inbox`、`impact-audit`。其中 `memory-prefetch` 每次调用都要对全部笔记重建索引，是记忆层唯一随笔记数线性增长的热点，因此单独计量；结果写入 `memory` 数组，同样只作本机诊断基线，不是跨平台 SLA。

2026-11-13 本机 32 页 / 48 笔记：`memory-prefetch` 中位 37ms、`memory-list` 37ms、`inbox` 39ms、`impact-audit` 34ms。2026-11-14 本机 200 笔记：`memory-prefetch` 中位 180ms、`memory-list` 183ms、`inbox` 193ms、`impact-audit` 170ms。48 → 200 笔记（约 4 倍）下四个面同比例增长，说明余下成本是固有的（一次 `@vault.verify` 全量哈希 + 读取全部记录），不是可再消除的重复校验——`inbox` 作为聚合面要读 memory/research/suggestion/overview/review/impacts 六类记录，这部分无法减少。并发基线：8 进程竞争同一 vault 时 1 成功 7 被 `vault_locked` 拒绝，最大 318ms。此前 `inbox` 为 154ms、`impact-audit` 97ms、`memory-prefetch` 86ms——原因是每个 `*_rows` 助手都各自调用一次 `@vault.verify`（读取并哈希 vault 内每个文件），`inbox` 一次要触发约 8 次全量校验。现已按仓库既有的 `evidence_rows_unchecked` 模式拆出 `_unchecked` 变体，由 op 顶部统一校验一次。

运行：

```sh
python3 scripts/scale_benchmark.py --pages 32 128 256 --queries 8 --workers 8
```

输出默认写入 `docs/scale-benchmark.json`。样本包含进程启动、JSON 传输、磁盘读取和索引装配，不是内核函数的微基准；p95 使用向上取整的最近秩。并发读取未设计为排队服务：native 宿主对每个请求持有 vault 独占锁，因此竞争请求可能得到 `vault_locked`，这属于当前一致性边界，不是吞吐承诺。

2026-10-16 在 macOS ARM64、native CLI、16/64 页、每种查询 2 次和 4 个并发进程上实测：关键词中位延迟约 12.0/34.6ms，纯向量约 12.1/40.6ms，混合检索约 12.4/39.2ms；并发竞争出现 2/4、1/4 个成功请求，其余明确返回锁错误，最终 `verify` 通过。完整本机报告保留在 [scale-benchmark.json](../../docs/scale-benchmark.json)。这些数字仅用于发现增长趋势；尚未形成跨机器阈值、Linux/Windows 结果、长驻服务吞吐或大规模内存模型。

2026-10-19 复验并把配额策略与并发矩阵纳入基准：长页样本（每页约 1.4KB 正文）× 16/64/128 页 × 8 次查询。紧凑 1200 字节预算下，`spread:"ranked"` 中位装配 6 页 / 1190 字节，`spread:"even"` 与 `dedup:"similar"` 装配 10 页 / 1200 字节；三种策略的 used 均不超过预算，`similar` 的额外 token 比较使中位延迟增加约 6ms（三档规模均 <3%）。并发矩阵从 1 到 8 个进程：每个规模都恰好 1 个请求成功、其余明确返回 `vault_locked`，等待上界随规模从约 42ms 增至约 310ms；这是"覆盖更多页 vs 每页更多正文"和独占锁一致性的确定性取舍，不宣称某种策略普遍更优或高并发吞吐。报告见 [scale-benchmark.json](../../docs/scale-benchmark.json)。

当前策略仍是 O(N×D) 暴力向量扫描、每请求重建/读取 native 进程上下文，以及单 vault 非排队锁。若要提高并发吞吐，需要新增明确的宿主队列或只读快照协议，不能把现有独占锁结果解释为高并发服务能力。
