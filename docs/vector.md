# 本地向量能力：算法默认与 OS 探测

AGENTS 边界不变：MoonBit 核心不调模型、不联网、不链接 OS 框架；引擎只**存储与计算
向量**（`brute_force` 余弦、`embedding-plan`/`embedding-submit`、混合检索、
`page-redundancy` 的 vector_cosine）。向量的**生成**由宿主提供，是否可用由宿主探测。

## 默认与兜底

- **算法向量是默认与兜底（全平台）。** 不安装任何宿主件时，`retrieve`/`search` 照常
  工作：块级 256 维签名哈希特征（字符 2/3 元组 + 拉丁词元）与 BM25 按固定 `k=60`
  RRF 融合，`lanes` 如实报 `text:"on"`、`vector:"algo"`、`reason:"no_system_engine"`；
  `search` 报 `vector_status:"not_provided"`。不需要 `os-embed` 或任何模型文件。
- **仓库不再附带模型向量适配器。** 旧 bge/CLIP 参考实现与模型拉取脚本已移除；仓库不下载、不打包模型，门禁也不依赖模型。
- **外部向量接缝仍在。** 引擎仍接受宿主通过既有
  `provider-register(embedding) → embedding-plan → embedding-submit → rebuild →
  search/retrieve(query_vector)` 提交任意来源的向量；这是协议能力，不是内置模型。
  多模态空间仍按 `embed-multimodal` 能力路由，宿主负责提供图片/文本向量；没有
  内置 CLIP、bge 或中文跨模态模型。

## macOS 系统向量：NLEmbedding 宿主适配器

仓库提供一个**宿主侧**的 macOS 系统向量适配器，用来使用 OS 自带的句向量引擎。
它不是引擎依赖：MoonBit 核心不导入 `NaturalLanguage`、不链接系统框架，只接收宿主
提交的向量。

```sh
scripts/build_os_embed.sh          # swiftc -O 构建 + --selftest；缺 swiftc 返回 2
adapters/os-embed/os-embed --probe
echo '[{"page":"…","sha256":"…","text":"…"}]' | adapters/os-embed/os-embed --language zh
adapters/os-embed/os-embed --language en --selftest
```

- 实现：`adapters/os-embed/main.swift`，调用 `NLEmbedding.sentenceEmbedding(for:)`。
  简体中文句向量 **640 维**、英文 **512 维**；中文/英文是不同模型与空间，维度与
  余弦不可跨语言直接比较。适配器只接受 `zh|en`，未知参数显式失败。
- 契约：stdin 读 `embedding-plan` 的 `items`，stdout 输出
  `{page, sha256, values}`；随后仍走 `provider-register(embedding)` →
  `embedding-submit` → `rebuild`，引擎照常做维度、归一化、页面内容版本与 provider
  注册校验。二进制 `adapters/os-embed/os-embed` 不入 git。
- **有就用，没有就算了**：探针只报告系统引擎是否存在、可用语言与维度；宿主只在
  `available:true` 时注册 provider、提交向量并携带 `query_vector`。探针为正也不会
  自动切换检索 lane：system 路只在请求显式带 `query_vector` + 已注册 provider 时
  启用。不可用是成功检测（退出 0），不注册、不生成 plan、不合成向量、不写 vault，
  检索继续算法路。
- 限制：句向量质量与可用语言随 macOS 版本变化；不同 OS 版本/语言的分数不保证
  可比，生产环境应固定 space id 并把系统版本纳入基线。需要跨平台一致语义时，由
  宿主提供实现同一 `--probe`/stdin-stdout 契约的适配器并固定 space id 与版本基线。
- 许可：`NaturalLanguage`/`NLEmbedding` 是 Apple SDK 的系统框架，模型随系统分发，
  本仓库不打包、不复制模型文件；使用与分发受 Apple SDK 条款约束。适配器源码
  为本项目自研。

## 探针契约（host-only，`os-embed/v1`）

宿主先跑 `adapters/os-embed/os-embed --probe`（`scripts/vector_engine.py probe`
是同一契约的宿主助手），再决定是否注册 provider：

```json
{"probe":"os-embed/v1","available":true,"reason":null,
 "languages":[{"language":"zh","available":true,"dimensions":640,"reason":null},
              {"language":"en","available":true,"dimensions":512,"reason":null}],
 "engine":"nlembedding","platform":"darwin","os_version":"…"}
```

- 校验字段：`probe` 必为 `os-embed/v1`；`available` 为布尔；`reason` 为字符串或
  null；`languages` 每项校验 `language`/`available`/`dimensions`/`reason`。
  `engine`/`platform`/`os_version` 仅作信息，宿主不得据此判定身份或可用性。
- 不变量：`available == any(languages[].available)`；顶层 `reason` 为 null 当且仅当
  可用；不可用时等于第一个不可用语言的 reason；每个语言 `available ==
  (reason == null)`，`dimensions` 为正整数当且仅当该语言可用，否则 null。
- 封闭原因：`engine_absent`（系统模型缺失）、`dimension_mismatch`（运行时维度与
  声明不符）、`platform_unsupported`（非 Apple 适配器自报）。其他值或缺失键按
  不可用处理。
- 退出码：0 = 产出了 verdict（`available:false` 是成功检测，不是错误）；2 = 没有
  verdict（参数错误，如 `--probe` 与 `--language`/`--selftest` 同用 →
  `probe_exclusive`，或内部失败）。二进制存在而 probe 退出 2 时应视为陈旧/损坏
  构建并提示 `scripts/build_os_embed.sh`，不能静默 SKIP。
- 使用路径（仅既有 op）：probe → 选语言 L 与维度 D → 宿主固定
  `space={id:<host-chosen>, dimensions:D}` → `provider-register` →
  `embedding-plan` → `os-embed --language L` → `embedding-submit` → `rebuild` →
  查询文本同样经 `os-embed --language L` → `retrieve`/`search` 的
  `query_vector={space, values}` + `provider`。探针本身不提供、不推断 space id，
  也不读 OS locale；助手仅在未给 `--space-id` 时用 `os-nl-<language>-v1` 作缺省，
  宿主仍应把选定的 id 固定进基线。没有新增 op 或字段。

## 宿主助手

`scripts/vector_engine.py` 是 probe/ensure/query-text/register 的薄封装；
`probe`/`ensure`/`query-text` 不写 vault，`register` 是唯一写入动作。

```sh
python3 -I scripts/vector_engine.py probe [--language zh|en] [--bin PATH]
python3 -I scripts/vector_engine.py ensure [--no-build] [--language zh|en]
python3 -I scripts/vector_engine.py query-text --text "…" [--space-id ID]
python3 -I scripts/vector_engine.py register --vault /abs/vault --provider os-nl \
    --at 2026-11-26T00:00:00Z [--space-id ID] [--cli PATH]
```

| 动作 | 输出（单行紧凑 JSON） | 退出码 |
| --- | --- | --- |
| `probe` / `ensure` | `{available,engine,language,dimensions,reason}` | 0（`available:false` 也是 0） |
| `query-text` 可用 | `{available:true,space:{id,dimensions},values:[…]}` | 0 |
| `query-text` 不可用 | `{available:false,reason}`（无 `space`/`values`） | 0 |
| `register` 可用 | `{available:true,registered:true,provider,space,result}` | 0 |
| `register` 不可用 | `{available:false,registered:false,reason}`（不调用 CLI） | 0 |
| `register` CLI 失败 | 无 JSON；stderr 一行诊断 | 2 |

- `probe`/`ensure` 的 `dimensions` 为 `int` 当且仅当 `available:true`，否则 `null`；
  `reason` 在可用时为 `null`，不可用时为字符串。
- 适配器 verdict 的封闭原因只有 `engine_absent`/`dimension_mismatch`/
  `platform_unsupported`。助手在适配器缺失、不可执行、输出非法或缺语言时另报
  助手本地原因 `adapter_missing`/`adapter_unavailable`/`probe_failed`/
  `probe_invalid`/`language_missing`；`ensure` 构建失败报 `build_failed`；
  `query-text` 批量失败报 `batch_failed`/`batch_invalid`，宽度不符复用
  `dimension_mismatch`。助手原因不改变适配器 verdict 的封闭词表。
- `register` 只复用既有 `provider-register`：请求为
  `{op,vault,provider,kind:"embedding",space:{id,dimensions},capabilities:["embed"],at}`，
  `result` 原样回显引擎响应，没有新增 op 或字段。
- 退出码：无动作或参数非法（argparse）退出 2、无 JSON；`register` 在 CLI
  不可用/拒绝时同样退出 2、只写 stderr。其余动作（含 `available:false`）退出 0
  并输出 JSON。
- 缺省值：`--bin` 先读环境变量 `OS_EMBED_BIN`，否则
  `adapters/os-embed/os-embed`；`--language` 默认 `zh`，仅接受 `zh|en`；
  `--space-id` 默认 `os-nl-<language>-v1`；`register` 的 `--cli` 默认
  `_build/native/debug/build/cli/cli.exe`。`ensure` 只重建标准适配器，不覆盖
  自定义 `--bin`；非 darwin、`--no-build` 或不可重建原因下原样返回 verdict。

## 验证

- `scripts/embedding_e2e.py`（入 `verify.sh`/`quick_verify.sh`）用宿主手工向量覆盖
  `provider-register(embedding) → embedding-plan → embedding-submit → rebuild →
  search/retrieve(query_vector)` 的注册、维度、内容版本锁与 system 路；不依赖模型。
- `scripts/os_embed_e2e.py` 在 macOS 验证真实 `NLEmbedding` 适配器驱动 `search` 与
  `retrieve` 的 system 路、`vector_space` 回显与页面改写后的旧向量失效；非 macOS
  或未构建时 SKIP，存在但陈旧/损坏的适配器则 FAIL 并提示重跑构建。
- `scripts/os_embed_probe_e2e.py` 与 `scripts/vector_engine_e2e.py` 覆盖 verdict
  字段/不变量、stub 不可用零写入、无网络静态守卫、macOS live probe/query-text/
  register，以及 live `ensure` 删除标准适配器二进制后由源码重建再还原。两者均入
  `verify.sh` 与 `quick_verify.sh`。
- 真实系统向量可用性只在当前 macOS 主机验证；非 macOS 由 unavailable 分支和算法
  回退覆盖；Windows/WASM 运行时不在门禁平台。`hosts/` 没有 probe 消费者。

## 下一步与边界

- 轻量 ANN 不采用：此规模下 `brute_force` 精确余弦已足够且无精度损失，属规模取舍
  而非能力归属。
- `page-redundancy` 的 `cosine_floor` 仍是宿主显式调档参数（默认 0.92，视觉空间
  建议 ≥0.995），引擎不按 space 名特判。
- 块级系统向量（`vector-submit`）未实现；当前页级系统向量按命中页映射首块
  `<page>#0`，不写成块级语义排序。
