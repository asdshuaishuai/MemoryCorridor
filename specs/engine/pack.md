# mcpack v1

此实现细化 PROPOSAL 的确定性 ZIP 目标，不更改日常 vault 布局。

- ZIP STORE（不压缩、不加密、无 ZIP64），UTF-8 文件名，固定时间戳/权限/顺序；常规 ZIP 工具可以检查内容。
- manifest.json 为 canonical JSON：format/version/vault_fingerprint/files。每项含 path/sha256/size，文件字节去重保存于 objects/<sha256>。vault 指纹等于目录声明的 SHA-256，pack 指纹是完整 ZIP 字节的 SHA-256。
- 包含登记文件及实际存在的原件、purpose、schema、目录/日志、视觉源、工单暂存与 `state/transactions/history/*.json`；排除缓存、锁、导入导出文件和正在进行的事务。已撤销且缺失的原件可缺席，仍保留目录撤销标记。
- v1 单包、逻辑展开内容各限制 16 MiB，最多 4096 文件；严格检查 CRC、SHA、清单/对象全集、路径和目录/正文语义，拒绝压缩、未知前向版本、链接条目、非规范 ZIP 与目录穿越。
- unpack 面向新建空 vault，明确拒绝覆盖既有目录或无关文件。所有校验及候选目录编译先完成，再在 state/transactions 持久保存包和恢复记录，最后发布 index.mbt.md；仅允许结构合法的 `history/*.json`，仍拒绝其他事务文件。
- 中断通过 recover 前滚完成。恢复前先检查所有已有目标字节，外部修改冲突时保留日志并拒绝覆盖；索引发布前引擎不将部分解包视为有效 vault。外部文件管理器仍可能看见准备阶段文件。
- import/export 的 OKF 适配另行定义，不能将 mcpack 改名当作 OKF。
