# 本地向量能力：原生 embedding provider（续二十五）

AGENTS 边界不变：MoonBit 核心不调模型、不联网；引擎只**存储与计算向量**
（`brute_force` 余弦、`embedding-submit`/`embedding-plan`、混合检索、续二十三
的 `page-redundancy` vector_cosine），向量的**生成**由宿主提供。本续补齐宿主侧
的原生生成件，复用 OCR 已引入的 ONNX Runtime，零 Python。

> **现状定位（重要）**：本节描述的 `embed-rs` + bge/CLIP 是**可选旧参考实现**，
> 不是默认或必装路径；当前宿主路径是 `adapters/os-embed/os-embed --probe`（见「macOS
> 系统向量」）。没有门禁依赖 `fetch_bge.sh`/`fetch_clip.sh` 或真模型；
> `scripts/embed_e2e.py`、`scripts/multimodal_e2e.py` 也未接线 `verify.sh`。
> 跨平台时由宿主提供等价适配器，而不是把 bge 当作引擎默认。

## 形态

```
adapters/embed-rs/
  src/main.rs     原生 embedding provider（Rust：ort + tokenizers）
  Cargo.toml      ort 2.0.0-rc.15（load-dynamic 官方 libonnxruntime，同 ocr-rs）、
                  tokenizers 0.21（WordPiece）、serde_json、ndarray
  model/          bge-small-zh-v1.5 int8 ONNX（23.9MB）+ tokenizer.json
                  —— 由 scripts/fetch_bge.sh 钉版拉取，不入 git（.gitignore）
  clip/           CLIP ViT-B/32 int8 双塔 + tokenizer（续二十六，可选多模态）
                  —— 由 scripts/fetch_clip.sh 钉版拉取，不入 git（.gitignore）
```

CLI 契约（与引擎 provider 接缝对齐）：

```sh
scripts/fetch_bge.sh                       # 钉版取模型
cd adapters/embed-rs && cargo build --release
export ORT_DYLIB_PATH=.../libonnxruntime.dylib   # 复用 OCR 已引入的运行时
export EMBED_MODEL_DIR=adapters/embed-rs/model
# 读 embedding-plan 的 items，出 embedding-submit 的 items：
echo '[{"page":"…","sha256":"…","text":"…"}]' | embed-adapter
embed-adapter --selftest                   # 512 维 + 相似/无关句余弦自检
# 可选多模态（需 scripts/fetch_clip.sh + EMBED_CLIP_DIR + EMBED_VAULT_DIR）：
echo '[{"page":"…","sha256":"…","modality":"image","image":"raw/x.png","image_sha256":"…"}]' | embed-adapter
echo 'a bright red square' | embed-adapter --mm-query   # 跨模态查询向量
embed-adapter --selftest-mm                # 双塔 512 维 + 序关系 + 字节往返自检
```

## 模型选型与来源

- **bge-small-zh-v1.5**（BAAI，Apache-2.0）：33M 参数、512 维、C-MTEB 中文优化；
  int8 ONNX 仅 **23.9MB**，远低于「100MB 以内」预算，CPU 可跑。
- **走 hf-mirror.com**：ModelScope 只有 safetensors（无 ONNX），故取 Xenova 的
  预转换 ONNX 经国内 HF 镜像；`fetch_bge.sh` 按 SHA256 钉版
  （model_int8 `b9837c19…`、tokenizer `48cea5d4…`），与 OCR 的 onnxruntime、
  WasmEdge 运行时同理**不折叠进仓库/分发包**。
- 配方：WordPiece + `[CLS]/[SEP]`（tokenizer post-processor）、CLS pooling
  （`last_hidden_state[0][0]`）、L2 归一化。缺 `[CLS]/[SEP]` 会静默拉低相似度
  （社区实证坑），selftest 与 e2e 都钉住这条。

## 端到端激活

`scripts/embedding_e2e.py`（入 `verify.sh`/`quick_verify.sh`，平台无关协议面）
用宿主手工向量把 `provider-register(embedding) → embedding-plan →
embedding-submit → rebuild → search/retrieve(query_vector)` 的注册、维度、
内容版本锁与 system 路跑通；它不依赖模型。`scripts/embed_e2e.py` 与
`scripts/multimodal_e2e.py` 是可选旧路（embed-rs/bge/CLIP）的真模型验证，
缺模型/运行时显式 SKIP，**未接线门禁**，不代表必装或默认。

## 许可登记（宿主工具链，均已核对）

bge-small-zh-v1.5 Apache-2.0 · CLIP ViT-B/32（Xenova 导出）MIT · tokenizers 0.21
Apache-2.0 · ort 2.0.0-rc.15 MIT/Apache-2.0 · onnxruntime MIT（与 OCR 同一份）·
image 0.25（embed-rs 解码，同 ocr-rs）MIT · sha2 0.10 MIT/Apache-2.0 ·
serde_json/ndarray MIT/Apache-2.0。模型与运行时走钉版 fetch，不入 git。

## 可选多模态空间（续二十六）

默认仍是文本为核心：`model-content-v1` + bge 通路与否完全不受本节影响。多模态是
宿主注册的**另一个可插拔向量空间**，引擎按能力词表路由，核心不感知任何模型。

- **协议**：provider 注册时能力为封闭词表 `embed / search / embed-multimodal`，
  未知能力按 `provider_capability_unknown` 拒绝。声明 `embed-multimodal` 的
  provider+空间组合下，`embedding-plan` 改发图片任务
  `{page, sha256, modality:"image", image, image_sha256}`；`image` 是该页来源集合
  中按 id 排序的第一个活跃图片 raw（配方 `first-image-source-v1`），
  `image_sha256` 把任务钉到字节版本；无图片来源的页在视觉空间结构性跳过、
  不计缺口。响应中 `text_recipe`/`image_recipe` 恰有一个非空。发布仍走
  `embedding-submit`（维度、归一化、页面内容版本锁、编译门禁全复用）；
  provider-job 信封目前只收文本配方。
- **模型**：CLIP ViT-B/32 int8（OpenAI 权重 MIT；Xenova 预转换 ONNX，投影烤进
  图，IO 即 `pixel_values→image_embeds`、`input_ids→text_embeds`，掩码由图内
  从 pad=0 推导）。`scripts/fetch_clip.sh` 从 hf-mirror.com 钉 SHA256（vision
  89,117,001B `583fd111…`、text 64,504,507B `73baab85…`、tokenizer
  `f7f3b7af…`），与 bge/onnxruntime/wasmedge 同理不入 git。
- **宿主实现**：`adapters/embed-rs` 增双塔（`Mm`）：官方 CLIP 预处理（短边
  224 CatmullRom 缩放 + 中心裁剪 + mean/std 归一 CHW），图片项先校验
  `image_sha256` 再推理（字节漂移即拒绝），路径只接受 vault 内 `raw/…`
  （逃逸拒绝）；`--mm-query` 出跨模态查询向量；`--selftest-mm` 钉 512 维、
  字节往返 cos≈1.0、同色序关系与配文匹配序关系。纯图片批次不需要 bge 模型
  在场，反之亦然（按 item 惰性装配）。
- **校准发现 → 已接口化（续二十七）**：0.92 余弦线按 bge 文本调参；纯色/扁平图在
  CLIP 外观空间互相很近（红↔蓝 ~0.925 会压线被提名），同图才 ≈1.0。现在
  `page-redundancy` 接受可选 `cosine_floor`（0.0..1.0，默认 0.92）由宿主显式声明调档，
  响应回显生效值；视觉空间建议 ≥0.995（「~0.999=同内容」从解读约定变成协议参数）。
  引擎不按 space 名特判，模型无关边界不变；`multimodal_e2e.py` 与 `redundancy_e2e.py`
  分别以真模型和手工向量把调档语义钉成可重放断言。
- **中文跨模态**：CLIP 文本塔为英文 BPE，中文「以文搜图」不走这条线（中文
  图文召回仍由 OCR+bge 文本空间承担视觉内容的文字面）。真中文跨模态需要
  Chinese-CLIP ViT-B/16（MIT 系），现成 ONNX 仅 fp16 约 380MB，超出轻量档
  4 倍，**不入分发包**；若日后需要可按 `fetch_clip.sh` 同法钉版换 heavier
  pair，引擎与 embed-rs 双塔接缝不变。

## macOS 系统向量：NLEmbedding 宿主适配器

除 Rust/bge 通路外，仓库提供一个**宿主侧**的 macOS 系统向量适配器，用来验证
「OS 自带 embedding 引擎」这条路线。它不是引擎依赖：MoonBit 核心仍不导入
`NaturalLanguage`、不链接系统框架，只接收宿主提交的向量。

```sh
scripts/build_os_embed.sh          # swiftc -O 构建并跑 --selftest；缺 swiftc 返回 2
echo '[{"page":"…","sha256":"…","text":"…"}]' | adapters/os-embed/os-embed --language zh
adapters/os-embed/os-embed --language en --selftest
```

- 实现：`adapters/os-embed/main.swift`，调用 `NLEmbedding.sentenceEmbedding(for:)`。
  简体中文句向量 **640 维**、英文 **512 维**；中文/英文是不同模型与空间，维度与
  余弦不可跨语言直接比较。适配器只接受 `zh|en`，未知参数显式失败。
- 契约与 `embed-rs` 一致：stdin 读 `embedding-plan` 的 `items`，stdout 输出
  `{page, sha256, values}`；随后仍走 `provider-register(embedding)` →
  `embedding-submit` → `rebuild`，引擎照常做维度、归一化、页面内容版本与
  provider 注册校验。二进制 `adapters/os-embed/os-embed` 不入 git。
- 已验证：`scripts/os_embed_e2e.py` 用中文改写页与无关页验证 `search` 的语义
  排序、`retrieve` 的 `vector:"system"`/`provider_vectors` 路、`vector_space`
  回显与页面改写后的旧向量失效；非 macOS 或未构建适配器时显式 SKIP；二进制
  存在但 `--probe` 没有 verdict 时失败并提示重跑 `scripts/build_os_embed.sh`
  （旧二进制会答 `unknown argument: --probe`）。
- 限制：句向量质量与可用语言随 macOS 版本变化；不同 OS 版本/语言的分数不保证
  可比，生产环境应固定 space id 并把系统版本纳入基线。需要跨平台一致语义时，
  由宿主提供实现同一 `--probe`/stdin-stdout 契约的适配器并固定 space id 与版本
  基线；`embed-rs` + bge 仅是可选的旧参考实现，不是默认或必装路径。
- 许可：`NaturalLanguage`/`NLEmbedding` 是 Apple SDK 的系统框架，模型随系统分发，
  本仓库不打包、不复制模型文件；使用与分发受 Apple SDK 条款约束。适配器源码
  为本项目自研。

### 默认与兜底（续八十五）

- **算法向量是默认与兜底（全平台）。** 不安装任何宿主件时，`retrieve`/`search` 照常工作：
  块级 256 维签名哈希特征与 BM25 按固定 `k=60` RRF 融合，`lanes` 如实报
  `text:"on"`、`vector:"algo"`、`reason:"no_system_engine"`；`search` 报
  `vector_status:"not_provided"`。不需要 `os-embed`、`embed-rs` 或任何模型文件。
- **探针只检测 OS 提供的向量引擎，可用才使用。** `adapters/os-embed/os-embed --probe`（或宿主助手
  `scripts/vector_engine.py probe`）输出版本化 verdict；只有 `available:true`
  时宿主才注册 provider、提交向量并携带 `query_vector`。探针为正不会自动切换
  lane：system 路只在请求显式带 `query_vector` + 已注册 provider 时启用。
- **不可用是干净回退，不是错误。** verdict 退出 0 并给出 `available:false`：
  不注册 provider、不生成 plan/`embedding-submit`、不 rebuild、不合成
  `query_vector`、不写 vault；检索继续算法路并如实报告原因。
- **不引入新向量模型、不下载模型、不联网。** 探针不读 stdin、不读 vault、不访问
  网络；`ensure` 只在 darwin 且标准适配器缺失/损坏时调用既有
  `scripts/build_os_embed.sh`（`swiftc` 编译仓库内 `main.swift`），不拉取模型。
  `adapters/embed-rs` + bge/CLIP 与 `fetch_bge.sh`/`fetch_clip.sh` 是**可选旧参考
  实现**，不是必装或默认，也没有门禁依赖。
- **不自动索引。** 探针与助手不生成 `embedding-plan`、不自动注册 provider、
  不自动提交向量；向量供给仍由宿主显式调用既有 op。块级 `vector-submit`
  未实现，页面级向量到首块 `<page>#0` 的映射是当前边界。

### 探针契约（host-only，`os-embed/v1`）

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
  `probe_exclusive`，或内部失败）。宿主按 `available` 分支，不按退出码分支；但
  二进制存在而 probe 退出 2 时应视为陈旧/损坏构建并提示
  `scripts/build_os_embed.sh`，不能静默 SKIP。
- 使用路径（仅既有 op）：probe → 选语言 L 与维度 D → 宿主固定
  `space={id:<host-chosen>, dimensions:D}` → `provider-register` →
  `embedding-plan` → `os-embed --language L`（既有 items 契约）→
  `embedding-submit` → `rebuild` → 查询文本同样经 `os-embed --language L` →
  `retrieve`/`search` 的 `query_vector={space, values}` + `provider`。探针本身不提供、
  不推断 space id，也不读 OS locale；助手仅在未给 `--space-id` 时用
  `os-nl-<language>-v1` 作缺省，宿主仍应把选定的 id 固定进基线。没有新增 op 或字段。
- 不可用路径：逐字转发 verdict 后停止——不注册 provider、不生成
  plan/embedding-submit、不 rebuild、不合成 `query_vector`；`retrieve` 仍报
  `lanes.vector:"algo"`/`reason:"no_system_engine"`（表示本次请求未带宿主查询
  向量，不是机器没有引擎），`search` 仍报 `vector_status:"not_provided"`。
- 构建：二进制 `adapters/os-embed/os-embed` 被 `.gitignore` 忽略。本次改动后必须
  重跑 `scripts/build_os_embed.sh`；旧二进制对 `--probe` 返回
  `unknown argument: --probe`（退出 2），即上面的陈旧构建分支。
- 验证：`scripts/os_embed_probe_e2e.py`（入 `verify.sh`/`quick_verify.sh`）覆盖
  verdict 字段/不变量、stub 不可用与 exit-2 的零写入、以及 macOS 上逐语言生产
  batch oracle 与 probe 一致，并带 Swift 导入/门禁令牌静态守卫；
  `scripts/vector_engine_e2e.py` 覆盖 `scripts/vector_engine.py` 的
  probe/ensure/query-text/register 四动作、不可用/畸形/错版本适配器、query-text
  不合成、register 零写与不可用 vault 字节不变，另有无网络静态守卫、macOS live
  `ensure` 删除标准适配器二进制后由源码重建再还原、陈旧/损坏适配器 FAIL 并提示重跑
  构建、以及 en 512 query-text 断言。两者都是契约与参考流测试，不是已交付宿主；
  `hosts/` 目前没有 probe 消费者。

### 实际命令与字段（续八十五）

构建并直接探测适配器（`--probe` 不读 stdin、不需要 vault；助手的 probe 步骤与两个 e2e 以 30 秒超时约束）：

```sh
scripts/build_os_embed.sh                 # swiftc -O 构建 + --selftest；缺 swiftc 退出 2
adapters/os-embed/os-embed --probe
adapters/os-embed/os-embed --probe --language zh    # 退出 2，stderr: probe_exclusive
adapters/os-embed/os-embed --probe --selftest       # 退出 2，stderr: probe_exclusive
```

`--probe` 的标准输出是单个紧凑 JSON 对象，字段为
`probe`/`available`/`reason`/`languages`/`engine`/`platform`/`os_version`；
`languages` 恒含 `zh` 与 `en` 两行，每行 `language`/`available`/`dimensions`/`reason`。
退出 0 表示产出了 verdict；退出 2 表示没有 verdict（只写 stderr，无 stdout）。

宿主助手（`probe`/`ensure`/`query-text` 不写 vault；`register` 是唯一写入动作）：

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
- 运行方式：`python3 -I scripts/os_embed_probe_e2e.py` 与
  `python3 -I scripts/vector_engine_e2e.py` 分别覆盖 verdict 契约/零写入/静态守卫
  与助手四动作/不可用零写入/静态守卫；后者在 macOS live 段会临时删除标准适配器
  二进制、由 `scripts/build_os_embed.sh` 重建后再还原原二进制（自定义 `OS_EMBED_BIN` 时
  跳过该子段）。两者都接入 `verify.sh` 与 `quick_verify.sh`。

## 下一步

轻量 ANN 不采用：此规模下 `brute_force` 精确余弦已足够且无精度损失，属规模
取舍而非能力归属（agent 由 LLM 驱动、只负责召回，近似能力不会由它代劳）。
redundancy 视觉线已有 `cosine_floor` 显式调档（续二十七交付）。
macOS 系统向量适配器、`adapters/os-embed/os-embed --probe` 与 `retrieve` 的 system 路已交付；块级
`vector-submit` 仍未实现，页面级向量到首块 `<page>#0` 的映射是当前边界，不写成
块级语义排序。
