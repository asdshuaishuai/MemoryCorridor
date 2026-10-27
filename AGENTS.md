# MemoryCorridor 工程约束

- 目标与范围见 PROPOSAL.md；实现进度见 specs/engine/tasks.md。未实现的能力不得写成已交付。
- MoonBit 核心不得调用模型或网络。base → core → decl/visual/pack → vault/index → agent → nativehost → cli/mcp；WASM 入口仅依赖纯核心，platform 仅被 native 宿主使用。核心处理数据与提交计划，系统操作由适配层执行。
- 自有产品实现中 MoonBit 有效代码行占比 >85%；计入平台/协议适配，排除测试、生成文件、第三方及用户数据；文学化文件仅统计代码块。
- index.mbt.md 为知识目录声明，正文独立；视觉页面使用 views/*.mbt.md。生成视图不能成为另一份权威页面源。
- 本项目只交付独立引擎及精简 Web 服务；不实现或维护桌面应用、桌面控制器和专用桌面集成。模型推理由外部调用方提供。
- .corridor/ 仅可重建缓存；state/ 的工单/审核/研究/建议/overview/证据/事件/恢复日志必须保留。来源撤销必须使相关内容失效，不能仅删除 sources 标签。
- 提交前编译声明并验证来源、内容、路径及基线。失败不得部分发布；中断恢复、幂等重试和外部编辑冲突需要实际测试。
- 验证使用 ./scripts/verify.sh。更改协议时同步工具字典、文档与端到端用例。未知字段和不支持能力明确拒绝。
- 仅使用自研或已核对许可的依赖；不复制 llm_wiki 代码/提示词。不得将自动生成内容计入 MoonBit 比例以提高数字。
