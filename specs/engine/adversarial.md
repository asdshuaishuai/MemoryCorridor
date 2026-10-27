# 敌意输入边界

scripts/adversarial_e2e.py 使用真实 native CLI 和临时 vault，集中验证错误输入不会改变指纹或留下部分缓存：

- 未知字段、空/越界/非整数 limit、budget、hops；路径穿越、绝对路径、`views/../escape.mbt.md` 等非法视图路径。
- 检索策略字段：未知/空/尾随空格/非字符串 `dedup`、未知/非字符串 `spread`、`dedup`×`spread` 非法组合、以及显式注入未声明的 `dedup_ratio`（按未知字段拒绝）。
- 同一批边界值（budget 1/65536 × exact/ranked × similar/even）必须成功且 `used<=budget`、指纹与权威文件快照不变，证明拒绝路径与合法路径都不会误写状态。
- 非法向量空间维度、空批次；重复 frontmatter；无效 mbt.md 声明；原件 symlink。
- 超过 native 单行限制的请求，在 JSON 解析前被拒绝。
- 每次拒绝后比较除可重建 `.corridor/` 外的权威 vault 文件快照，最后执行 verify 和检索；缓存变化单独允许重建。

它不替代 CommonMark/YAML 全语法、文件系统权限矩阵或模糊测试；这些仍是后续工作。运行：

    python3 scripts/adversarial_e2e.py
