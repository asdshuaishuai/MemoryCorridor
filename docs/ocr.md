# 宿主侧原生 OCR / PDF 适配器（引擎外模型能力的交付实现）

AGENTS.md 与 PROPOSAL 的边界：MoonBit 核心不调模型、不联网；PDF/OCR/网页抓取
由外部适配器提供，引擎只**记账**。引擎侧的入账通道是续十二的
`extraction-submit` sidecar（`state/extractions/<source sha256>.json`，绑定登记
字节哈希，来源撤销/漂移即失效）。`adapters/ocr-rs` 是那条边界的宿主交付：
**原生 Rust，零 Python**（用户约束：分发不得携带 Python 组件库）。

## 形态

```
adapters/ocr-rs/
  src/main.rs          单二进制管线（det DB 后处理 + rec CTC + PDF，全自研实现）
  models/              PP-OCRv4 mobile：det 4.7 MB + rec 10.9 MB（cls 0.6 MB 方向校正已接入），
                       字典 6623 行（自 rec 模型 metadata 导出）——共 15 MB，入库
  target/release/ocr-adapter   模型经 include_bytes! 内嵌，构建产物约 17 MB
  runtime/libonnxruntime.dylib 官方 ONNX Runtime（MIT，43 MB），**不入库**，
                       由 scripts/fetch_ort.sh 按校验和拉取
```

推理运行时是纯 C 动态库（Microsoft 官方构建，MIT，可再分发）。二进制启动时
按 `ORT_DYLIB_PATH` → 自身同目录 `libonnxruntime.dylib` 顺序 dlopen。

CLI 契约（与引擎 sidecar 对齐）：

```sh
ocr-adapter <文件>          # 纯文本
ocr-adapter <文件> --json   # {sha256, kind, source, confidence, text}
```

路径：图片（PNG/JPEG/WebP/BMP/TIFF）→ PP-OCRv4 det+cls+rec；PDF → 优先文本层
（lopdf，精确、免模型）；文本层近空即判扫描版，提取页内最大内嵌图
（DCTDecode JPEG 或 FlateDecode 位图，支持 PNG/TIFF predictor、RGB/Gray/CMYK）
走 OCR；两者皆无则显式拒绝说明原因。**cls 方向分类器**（0.6MB，`use_cls` 参考
默认开）逐框判 0°/180°（softmax 输出，阈值 0.9），命中先把 crop 转 180°
再识别——颠倒扫描件（真实传真/双面扫描常见）全行恢复，关闭则整页乱码。

## 选型（对照「50 MB 以内最合适，不要最大不要最小」）

PP-OCRv4 **mobile** 档：模型 16.2 MB（server 档 80 MB+ 超预算；tiny 档检测
80.6 Hmean 偏低且不含日文）。推理用 ONNX Runtime CPU。实测中文整页置信度
0.97–0.99；噪声+微旋转仿真扫描页同样全行召回；真实公开扫描件（IRS F1040
Schedule 1 文本层）精确直读。macOS 设备原生 Vision 作为第二后端的评估仍挂起
（用户标记待定）。

## 关键工程事实（为什么是 load-dynamic）

初版用 `ort` 的 `download-binaries`（pyke 预构建静态链）。同一输入张量逐字节
dump 对照：det 输出与 Python 参考完全一致，**rec 却塌缩成单 token**；同一张量
在 Python `onnxruntime==1.31.1`（官方动态库）下输出完美。版本相同、输入相同
→ 根因是 pyke 静态构建在 macOS/arm64 上对 rec 计算图执行异常（ORT 1.x 的
crate 全系列已 yanked，无法换版绕开）。故切换到 `load-dynamic`：运行时只链
官方 dylib。**这是分发形态的硬约束依据，不是偏好。**

det 后处理的 unclip 与 PaddleOCR 语义精确对齐（`area*1.6/perim` 原图坐标系、
**无钳位**）：此前 12 px 钳位会截掉汉字部首导致单字误识，对齐后与参考实现
逐框一致（±2 px）。

## 验证

`scripts/ocr_e2e.py`（verify.sh 第 48 行）：以 `OCR_BIN` 指向原生二进制，
自造中文版面图 / 扫描版 PDF / 文本层 PDF 三类运行时样本，走
scan → context(extraction_required) → ocr-adapter → extraction-submit
（绑定 sha256）→ context 供 sidecar → commit 发布 → rebuild/verify → search
全链。二进制或 runtime dylib 缺失时**显式 SKIP（退出 0）**；fixture 生成用的
字体渲染是纯 dev 工具（`FIXTURE_PYTHON`，pillow+fpdf2），**不属于任何运行期
依赖**。引擎 sidecar 记账本身由 `extraction_e2e.py` 全量门禁（合成文本，零
外部依赖）。

## 许可登记（均已核对）

- onnxruntime（推理运行时，官方 dylib）MIT
- PP-OCRv4 mobile det/rec/cls 模型 + 字典 Apache-2.0
- Rust 依赖：ort 2.0.0-rc.15（MIT/Apache-2.0 双许可）、ndarray、image、lopdf、
  serde_json（均 MIT/Apache-2.0/BSD/Unicode，逐个核对见 cargo 元数据）
- fpdf2 LGPL-2.1：**仅** dev fixture 生成，非运行时依赖，不分发

## 构建

```sh
cd adapters/ocr-rs && cargo build --release
scripts/fetch_ort.sh                       # 校验和固定 1.31.1
cp target/release/ocr-adapter runtime/libonnxruntime.dylib <部署目录>/  # 同目录发现
```
