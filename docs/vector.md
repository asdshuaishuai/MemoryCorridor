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

bge-small-zh-v1.5 Apache-2.0 · tokenizers 0.21 Apache-2.0 · ort 2.0.0-rc.15
MIT/Apache-2.0 · onnxruntime MIT（与 OCR 同一份）· serde_json/ndarray
MIT/Apache-2.0。模型与运行时走钉版 fetch，不入 git。

## 下一步

向量**检索**侧的轻量 ANN 后端（usearch/hnswlib 作 search provider，接现有
`vector_candidates` 接缝，给 brute_force 之外的规模提速）见后续续条目。
