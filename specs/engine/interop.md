# OKF / Markdown 适配

上游规范核对：GoogleCloudPlatform/knowledge-catalog 的 okf/SPEC.md，v0.2（2026-10-16 读取）。规范要求容忍未知 type/key、缺失可选字段、缺失 index 和断链；sources 使用带 resource 的对象，不能套用 native 的路径数组。

- YAML 使用固定版本 moonbitstack/moonyaml 0.1.1，Apache-2.0，单独登记许可。解析 JSON 兼容的 YAML 1.2，保留未知字段/嵌套元数据及原始字节；拒绝重复键、超深/过量别名及不支持的 YAML 构造，不静默猜测。
- 导入目录来自 imports/；原始文档和附件作为不可变 raw 输入保留。知识页转为引擎支持的类型，未知类型按 generic concept 消费，原 type 和扩展元数据随来源/导入记录保留。
- OKF 标准 Markdown 链接转为内部关系；路径后的标题 fragment 会保留为 `[[page#标题]]`，导出时再编码回标准 `path#fragment`。断链保留为外部原文并记待核对项，不穿过 native 硬校验。导入不执行 executor/attester/脚本，不伪造 verified 证明。
- 正文/元数据未修改时可按原始文档字节往返；生成文档按 OKF 的对象式 sources 和标准 Markdown 链接导出，附可核验的原始资料引用。
- 导出至 exports/，不覆盖已有内容；导入事务只在校验/编译完成后发布目录。原件上传区和导出准备区的失败残留需可重试，不能把部分知识版本当作成功。
