# .mcpack v1

这是确定性的知识快照分发格式，日常仍编辑目录和独立文件。不是加密容器，也不等同于 OKF。

```json
{"op":"pack","vault":"/absolute/source","output":"exports/snapshot.mcpack"}
{"op":"unpack","vault":"/absolute/empty-target","file":"imports/snapshot.mcpack"}
```

目标根目录需预先存在。先把包复制至目标 `imports/`。`pack` 只写 `exports/*.mcpack` 且拒绝覆盖；`unpack` 只读 `imports/*.mcpack`，拒绝覆盖已有 vault 或目标知识目录中的无关文件。两者均通过 CLI/MCP 同一字典公开。

## 编码

包使用标准 ZIP STORE，不压缩、不加密、无 ZIP64。全部条目为普通文件，UTF-8 名称，固定 1980-01-01 00:00:00 时间戳和 0644 元数据，按名称的 UTF-16 字典顺序保存。没有目录条目、注释、额外字段或数据描述符。

ZIP 内包含 `manifest.json` 和去重的 `objects/<sha256>`。清单为 canonical JSON，结构为：

```json
{"files":[{"path":"index.mbt.md","sha256":"...","size":123}],"format":"memorycorridor-pack","vault_fingerprint":"...","version":1}
```

files 按原路径排序。每个 object 的名称、清单哈希、大小及 ZIP CRC32 均核对；未引用/缺失对象、重复路径、前向版本和非规范 ZIP 拒绝。读取时重新构造 central directory，检查权限、偏移、签名、顺序和尾随隐藏字节，禁止符号链接条目。普通 ZIP 工具可以检查内容；通用 ZIP 重新打包后可能因元数据不规范而被拒绝。

vault_fingerprint 是根目录声明的 SHA-256，它包含登记内容/状态的版本；pack_fingerprint 是整个 ZIP 的 SHA-256，另涵盖实际打包的草稿、视觉源码与辅助文件。

v1 包字节数与逻辑展开内容分别最多 16 MiB，最多 4096 逻辑文件。未做流式读取或大文件分卷；超限明确报错。内容寻址去重也不能绕过展开上限。

## 纳入与排除

纳入登记的原件/正文/向量/持久状态、根目录、purpose/schema、知识目录/日志、`views/*.mbt.md`、staging 草稿，以及 `state/transactions/history/*.json` 恢复历史。撤销且已物理删除的原件可缺席，其撤销标记仍保留。未登记原件先 scan 再打包。视觉文件必须能通过当前受限声明解析，不将任意代码带入编译流程。

不纳入 `.corridor/`、锁、导入/导出文件、编译缓存、正在进行的事务和未登记的任意文件。工单暂存属于快照内容，避免只恢复分析状态而丢失草稿。内置编译器适配已把产物定向到 `.corridor/compiler`，旧版 views/_build 也不当作视觉源码。

编码后再次读取每份纳入文件及根目录的哈希；外部编辑变化会中止输出。

## 发布与恢复

解包先验证全部 ZIP、清单、文件字节、目录引用、页面/来源、工单/审核/向量记录与视觉声明，再实际编译候选目录和视觉源。通过后在 `state/transactions/unpack.mcpack` 保留完整恢复包，写 `unpack.json` 记录包哈希。其后写入独立文件，`index.mbt.md` 最后发布。

`recover`（以及其他引擎操作前的自动恢复）可在任意发布中断点前滚；恢复前检查所有目标文件及额外文件。任何非预期人工编辑均保留，恢复记录也保留，不进行猜测覆盖。普通文件事务成功恢复时，先按 `sha256(canonical({version,direction,journal}))` 写入 `state/transactions/history/<sha256>.json`，再移除 pending 日志；相同历史可重试，不同内容占用同一路径会拒绝恢复。准备前或清理后的孤立内部恢复包可安全清除。恢复成功后移除进行中日志/恢复包，再通过 rebuild 生成搜索缓存。

原件和工单在 index 发布前可能被外部文件管理器看见；引擎本身通过根目录区分有效 vault，这不是对任意外部读者的多文件瞬时原子性。

## 证据

`scripts/pack_e2e.py` 使用 Python 标准 ZIP 读取器和独立编码器核对字节，再通过真实 native 进程恢复二进制、中文路径、草稿、工单与视觉页；核对恢复前后指纹和检索。覆盖 CRC、前向版本、截断、尾随数据、路径穿越、事务注入、链接权限和语义无效工单，并验证磁盘恢复两侧及人工编辑冲突。纯 MoonBit 测试覆盖每个解包发布中断点。
