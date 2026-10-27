# 富文本阅读

本次影响 `visual` 渲染、`agent/visual.mbt` 原件快照读取和离线浏览器资源。沿用现有纸色背景、深绿导航与三栏布局；正文采用语义化标题/列表/表格，代码区使用等宽字体、独立横向滚动、语言标签和格式化/原文操作，390px 页面本身不横向溢出。

- 视觉页面源仍为 `views/*.mbt.md`，MoonBit 负责声明校验、数据绑定、HTML 布局和快照版本检查。
- 浏览器边界使用固定版本、本地打包的 markdown-it、DOMPurify、highlight.js 与 Prettier；离线文件不请求 CDN。第三方及生成的嵌入包装不计入自有 MoonBit 比例，自有浏览器适配代码计入分母。
- Markdown 渲染标题、强调、引用、列表、表格、链接、图片和围栏代码；兼容 HTML 片段，经清洗后展示。原始 HTML 文件在隔离 frame 呈现，保留文档样式而不干扰阅读器。
- 高亮依据围栏/文件语言；额外提供 MoonBit 语法。JS/TS/JSX/TSX/Vue/JSON/HTML/CSS/Markdown/YAML 提供 Prettier 格式化；其他语言保留原缩进并高亮，不宣称已有对应 formatter。未知语言回退文本。
- 原文可查看，格式化不写回权威文档。源代码和 HTML 中的脚本不执行；不把用户 HTML 作为阅读器宿主代码。
- 验证包括真实浏览器的 Markdown 结构、HTML 页面、语言高亮/格式化、原文、内部导航、移动布局以及脚本/事件/URL 注入语料。
