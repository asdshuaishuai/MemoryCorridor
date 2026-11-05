# 本地向量能力：原生 embedding provider（续二十五）

AGENTS 边界不变：MoonBit 核心不调模型、不联网；引擎只**存储与计算向量**
（`brute_force` 余弦、`embedding-submit`/`embedding-plan`、混合检索、续二十三
的 `page-redundancy` vector_cosine），向量的**生成**由宿主提供。本续补齐宿主侧
的原生生成件，复用 OCR 已引入的 ONNX Runtime，零 Python。

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

`scripts/embed_e2e.py`（入 verify.sh，缺模型/运行时显式 SKIP 不破坏 CI）把整条
链跑通：`provider-register(embedding) → embedding-plan → embed-rs →
embedding-submit → rebuild → search(query_vector) 真语义排序 + page-redundancy
的 vector_cosine 提名改写页 + 改写页旧向量经内容版本锁掉出提名`。区别于
`redundancy_e2e.py` 的手工向量，这里全部来自真实模型。

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

## 下一步

轻量 ANN 不采用：此规模下 `brute_force` 精确余弦已足够且无精度损失，属规模
取舍而非能力归属（agent 由 LLM 驱动、只负责召回，近似能力不会由它代劳）。
redundancy 视觉线已有 `cosine_floor` 显式调档（续二十七交付）。
