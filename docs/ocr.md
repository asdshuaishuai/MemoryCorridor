# 原生 OCR/PDF 直接集成（唯一模型例外）

## 边界

MoonBit 的 `base → agent` 仍不调用模型、不联网；知识页仍只经
`scan/plan → context → analysis-submit → 宿主 staged 页 → commit` 产生。
**唯一例外**是 native 宿主在 `scan`/`refresh` 的导入调度和 `context` 兜底阶段调用本地 OCR 适配器：
`nativehost` 是 host 层，适配器由 `platform` 以固定 argv 执行；WASM 面、
纯计算面和 `agent` 分发都没有这条路径。除 OCR/PDF 抽取外，模型推理仍由外部
调用方提供。

自动抽取成功后只写 digest-bound 的
`state/extractions/<source sha256>.json` sidecar；后续 `context` 用它返回
`source_text` 并把工单推进 `context-ready`。它**不会**自动写 `wiki/` 或
`index.mbt.md`；页面正文仍由既有 LLM 两步工单产生。

## 直接集成流程

OCR 按**导入的文件**调度：`scan`/`refresh` 为新增或变化的 raw 来源建工单后，
native 宿主只对 PDF/图片工单执行适配器；其他文本、OOXML、HTML 来源不进入该
分支。sidecar 在 context 之前就已经准备好。

```text
scan / refresh（导入）
  └─ 新建 PDF/图片工单
       ├─ native 宿主发现 OCR 适配器
       ├─ 执行 ocr-adapter <source> --json（cwd=vault 根）
       ├─ 校验适配器 sha256 == 工单 source_hash
       └─ extraction-submit（既有 sidecar 通道）

plan → context
  ├─ 已有 sidecar → source_text + extraction_required:false
  └─ 未配置/导入时失败 → extraction_required:true
       （context 仍会做一次兜底重试，成功后返回 source_text）
```

CLI/MCP/Web 共用 `nativehost.execute`，因此导入后的 PDF/图片在同一摄取链路里
就完成抽取，不再需要手工运行适配器和 `extraction-submit`。手工路径仍保留：
`read-source` 继续走原始字节通道；宿主也可以关闭自动抽取后自行入账。

### 适配器发现与配置

1. `MEMORYCORRIDOR_OCR_BIN`：适配器绝对路径；必须是绝对路径，不从 `PATH`、
   cwd 或 vault 内容推断。
2. native 可执行文件同目录的 `ocr-adapter`：release 包使用的布局。
   `bin/memorycorridor-cli`、`bin/memorycorridor-mcp`、`bin/memorycorridor-web`
   与 `bin/ocr-adapter` 同级。
3. 都没有时自动抽取关闭，`context` 保持 `extraction_required:true`。

- `MEMORYCORRIDOR_OCR=off`（或 `0`）同时关闭 scan/refresh 的导入调度和
  context 的兜底重试。
- ONNX Runtime **默认嵌入 `ocr-adapter` 二进制**：构建时 `build.rs` 把
  `runtime/libonnxruntime.dylib` 作为字节嵌入，启动时写入权限 0600 的临时文件
  并 dlopen，随后解除链接。`ORT_DYLIB_PATH` 只在未嵌入构建或内嵌加载失败时
  作为回退；再回退到适配器同目录的 runtime。
- `MEMORYCORRIDOR_OCR_AT` 可覆盖 sidecar 的 `submitted_at`，用于测试和确定性
  复现；正常宿主使用 UTC 时钟。
- 适配器缺失、启动失败、超时（120 s）、输出超过 2 MiB、JSON 非法、digest
  不匹配、文本为空/含 `\r`/超过 1 MiB、`extraction-submit` 冲突：导入阶段
  静默跳过，`context` 保留 `extraction_required:true` 并可再重试；绝不写
  半成品。

## 输入与抽取语义

- **文本层 PDF**：`lopdf` 读取每页文本；非空白字符达到阈值（当前实现为 ≥20）时直接采用，
  `source:"text-layer"`、extractor `lopdf`。不运行 OCR 模型。
- **扫描版 PDF**：文本层近空时提取页内最大内嵌图（DCTDecode JPEG 或
  FlateDecode 位图，含 PNG/TIFF predictor 重建），`source:"ocr"`、
  extractor `ppocrv4-mobile-ocr-rs`。
- **图片**：PNG/JPEG/WebP/BMP/TIFF，PP-OCRv4 mobile det+cls+rec；颠倒页由
  方向分类器先旋转再识别。GIF 不被适配器解码，自动抽取会回退为手工路径。
- PDF 检测按 `.pdf` 后缀或 `%PDF` 魔数；无文本层且无可解码页内图时显式失败。
- 已知限制：扫描版 PDF 只 OCR **页内最大内嵌图**，多页扫描不会逐页完整抽取；
  当前不做 PDF 页面栅格化。任何输入超 25 MP、单边超 20000 px、尺寸非正或
  声明尺寸与解压字节不符，在分配前拒绝。
- 文本上限是 1 MiB UTF-8 字节（与 `extraction-submit` 同一约束），sidecar
  绑定登记字节哈希；来源撤销或字节漂移后自动抽取不会复活旧文本。
- 历史实测：IRS F1040 Schedule 1 文本层 PDF 精确直读；带噪声/微旋转的仿真扫描页
  全行召回，整页置信度约 0.97–0.99。具体样本与限制以本机 `ocr_e2e.py` 重跑为准。


## 适配器形态

```text
adapters/ocr-rs/
  build.rs             构建时把 runtime 字节嵌入 embedded_ort.rs
  src/main.rs          单二进制管线（det DB 后处理 + rec CTC + PDF，自研实现）
  models/              PP-OCRv4 mobile：det 4.7 MB + rec 10.9 MB（cls 0.6 MB 方向校正），
                       字典 6623 行；共约 15 MB，入库
  target/release/ocr-adapter   模型 + ONNX Runtime 均内嵌，构建产物约 61 MB
  runtime/libonnxruntime.dylib 官方 ONNX Runtime（MIT，约 43 MB），构建输入，
                       不入库；由 scripts/fetch_ort.sh 按校验和拉取
```

CLI 契约：

```sh
ocr-adapter <文件>          # 纯文本
ocr-adapter <文件> --json   # {sha256, kind, source, confidence?, text, pages?}
```

运行时是纯 C 动态库（Microsoft 官方构建，MIT，可再分发）。**嵌入构建**在
启动时把内嵌字节写到私有临时文件（0600）后 dlopen，并立即 unlink；没有
外部 runtime 也能工作。没有 `runtime/` 的构建保持外部回退：先
`ORT_DYLIB_PATH`，再适配器同目录 `libonnxruntime.dylib`/`.so`。

**平台**：macOS arm64 为当前验证目标；Linux/Windows 可按同一 load-dynamic
契约对接官方 `.so`/`.dll`。release 包在适配器为嵌入构建时只携带
`bin/ocr-adapter`，不再重复携带 runtime；非嵌入构建才把 runtime 放在同目录。

## 安全约束

- 适配器路径必须来自主机环境或 native 可执行文件同目录，绝不从 vault 内容或
  cwd 推断；不以 shell、`PATH` 或 `execlp` 启动。
- 子进程在 vault 根目录执行，只收到已登记的相对 source 路径和固定 `--json`
  参数；stdin 接 `/dev/null`，stdout 有界捕获，stderr 留给宿主日志。
- 适配器返回的 `sha256` 必须等于工单 `source_hash`；不匹配即拒绝，绝不把
  别的文件读成已登记来源。
- 自动抽取受 vault 写锁保护，与 `context` 的排他工单语义一致；超时后杀死
  子进程，避免挂死适配器阻塞所有写者。

## 验证

- `scripts/ocr_native_e2e.py`（快速门禁 + 全量门禁）：用 Python stub 适配器
  覆盖 **scan 导入时调度**、context 兜底、文本层 PDF 的 `lopdf` 映射、digest
  不匹配、适配器失败、`MEMORYCORRIDOR_OCR=off`、文本源不触发 OCR，以及
  `read-source` 不变；不需要 ONNX Runtime、模型或网络。
- `scripts/ocr_e2e.py`（全量门禁）：`OCR_BIN` 指向真实适配器，自造中文版面图 /
  扫描版 PDF / 文本层 PDF / 颠倒图，验证导入即调度、context 直接返回正文、
  sidecar 绑定、发布、verify 与检索。嵌入构建不需要外部 runtime；非嵌入构建
  缺 runtime 时显式 SKIP（退出 0）；fixture 渲染是纯 dev 工具
  （`FIXTURE_PYTHON`，pillow+fpdf2），不属于运行期依赖。
- `scripts/extraction_e2e.py`：合成 PNG 的 sidecar 入账、重放、冲突、撤销/漂移、
  1 MiB 上限与 pack/unpack 往返，完全平台无关。
- 门禁不下载模型、不访问网络；真实 OCR 只在有本机构建物的主机执行。

## 许可登记

- onnxruntime（推理运行时，官方动态库）MIT
- PP-OCRv4 mobile det/rec/cls 模型 + 字典 Apache-2.0
- Rust 依赖：ort 2.0.0-rc.15（MIT/Apache-2.0 双许可）、ndarray、image、lopdf、
  flate2（miniz_oxide，均 MIT/Apache-2.0/BSD/Unicode，逐个核对见 cargo 元数据）
- fpdf2 LGPL-2.1：**仅** dev fixture 生成，非运行时依赖，不分发

## 构建

```sh
scripts/fetch_ort.sh                       # 校验和固定 1.31.1，构建输入
cd adapters/ocr-rs && cargo build --release # build.rs 把 runtime 嵌入二进制
cp target/release/ocr-adapter <部署目录>/   # 只需适配器；runtime 已在其中
```

部署目录也可以是 release 的 `bin/`；CLI/MCP/Web 与 `ocr-adapter` 同级即可自动
使用，无需设置 `MEMORYCORRIDOR_OCR_BIN`。没有 `runtime/` 时构建仍可产出一个
非嵌入适配器，但必须同时部署 runtime（`ORT_DYLIB_PATH` 或同目录）。需要手工
接管时设置 `MEMORYCORRIDOR_OCR=off` 并调用 `extraction-submit`，sidecar 的
绑定与重放规则不变。
