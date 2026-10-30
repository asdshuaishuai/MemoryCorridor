# 文学化视觉页面

页面源是 `views/*.mbt.md`。默认模板见仓库 [views/library.mbt.md](../views/library.mbt.md)。这是能独立通过 MoonBit 编译检查的受限声明，不是把 HTML 代码改个后缀。第一个 `mbt check` 块提供安全的视图 IR，后续 `mbt` / `mbt check` 块可以提供共享辅助定义和测试，并由同一次 MoonBit 检查验证；运行期解析器会扫描整份文学化文件，拒绝未闭合的两类 MoonBit 围栏，避免把编译输入静默当成正文。

```json
{"op":"view-init","vault":"/absolute/my-vault"}
{"op":"render-view","vault":"/absolute/my-vault"}
```

`view-init` 拒绝覆盖。`render-view` 依次解析声明、调用实际 MoonBit 编译器、核验正文和来源版本，再原子写入 `.corridor/viewer.html`。使用浏览器打开这个文件即可离线阅读；它是可重建输出，不能反向成为页面源。也可用本地 HTTP 静态服务打开。

v1 声明调用为 `view(title, accent, paper, panels, features)`：

```moonbit
view("MemoryCorridor", "#315B47", "#F4F1E9", ["catalog","page","sources"], ["search","routing","rich-render","code-format","source-links"])
```

前三个参数控制标题和配色；第四个参数绑定面板及其顺序，必须包含 `catalog`、`page`、`sources`，还可加入 `graph`（从页面 wikilink 和共享来源边派生关系）和 `insights`（从当前快照派生统计）；第五个参数声明能力开关。支持的能力为 `search`（目录文本筛选）、`routing`（hash 深链与文章切换）、`rich-render`（Markdown/HTML/图片富文本 hydration）、`code-format`（代码格式化工具栏）和 `source-links`（来源证据 hash 链接）。省略第五个参数仍兼容旧四参数声明并启用全部默认能力。面板数量限制为 3..5，只接受已知面板、HEX 颜色、已知能力名和规范字面量；不支持任意 MoonBit 函数求值、任意 CSS 或用户脚本。改动后须保持规范格式，避免编译语义与运行期解析分叉。这个 API 面向第一版阅读器，不宣称为通用 UI 框架。

`graph` 面板除边列表外还渲染一张确定性快照图：节点按 `(id, title)` 排序后放在固定环形位置上（1/16 圆周查表坐标，无平台三角函数，同一快照字节一致）；实线画已验证的 wikilink，虚线画共享来源关系（无向去重，已由互链连接的页对不重复画），图例随面板显示。有入链的节点是 hash 路由链接，点击进入对应页面，孤立节点保持静态。快照图是派生视图，不参与知识数据权威，窄面板下按 `viewBox` 等比缩放。

正文布局和数据绑定由 MoonBit HTML renderer 处理；浏览器适配固定版本的 markdown-it / DOMPurify / highlight.js / Prettier。所有依赖嵌入离线 HTML，不请求 CDN。依赖、校验值和许可见 `vendor/reader/` 与 `licenses/`；生成的独立 HTML 自带 `dependency-notices`。自有浏览器代码计入源码占比分母，第三方代码和嵌入包装排除。

Markdown 实际渲染标题、强调、删除线、引用、嵌套列表、表格、标准链接、图片、行内代码和围栏代码。wikilink、快照内文件链接和中文标题锚点支持导航与刷新。HTML 片段经过清洗后呈现；独立 `.html` / `.htm` 原件在 sandbox frame 内渲染，保留文档样式和表格。源脚本、事件和危险 URL 不执行。Markdown 的样式和宿主保留类名会移除，避免影响导航。PNG/JPEG/GIF/WebP 原件可作为离线图片绑定；单图超过 4 MiB 或未在快照中的图片显示替代说明。

代码按目录登记的 `format`（旧目录读取时才按路径迁移推导）高亮，支持 highlight.js 内置语言及自研 MoonBit 规则（`moonbit` / `mbt`，包括 `mbt check`）。除常见 JS/TS/JSX/TSX/Vue/JSON/HTML/CSS/SCSS/Less/Markdown/YAML 外，也识别 Python、Rust、Go、C/C++、Java/Kotlin、Swift、Dart、Ruby、PHP、Lua、Scala、Haskell、Elixir、Clojure、F#/Perl/R/Julia、Shell/PowerShell、SQL、TOML/INI、GraphQL、Protobuf、LaTeX、Dockerfile 和 Makefile，并按对应 highlight.js 语言高亮。JS/TS/JSX/TSX/Vue/JSON/HTML/CSS/SCSS/Less/Markdown/YAML 具有“格式化 / 原始排版”切换；格式化使用对应 Prettier parser，不写回正文。其他语言保留原始缩进并高亮，当前没有为它们提供格式化器。未知语言保留文本；无效或超过 100,000 字符的代码不进行格式化。所有文档均可展开“查看原文”。数学、Mermaid 以及运行用户脚本不在本次范围。

这个版本的浏览器搜索是在阅读快照内筛选文本，和 CLI 的分词/向量排名是两个不同使用场景。页面注明快照性质；需要最新排名或向量搜索时调用引擎工具后重新生成。PDF 等其他二进制原件只显示路径和哈希，由原格式工具打开。失效页面可显式阅读但不参与非空搜索。

页面编译或校验失败不覆盖上次 HTML，也不阻止正常引擎读取。watcher 默认重新构建 `views/library.mbt.md`；自定义文件可使用 `python3 scripts/watch.py <vault> --view views/custom.mbt.md`，或直接使用 `render-view` 的 `view` 参数。

已评估 MoonViz：它的 `.mbt.md` 与 SVG 输出适合画布原型，但长文本阅读、文本选择和原件证据导航更适合 HTML。当前阅读器独立实现并保留相同的单一页面源原则，没有修改或复制 MoonViz 源码；后续可加 MoonViz renderer 适配。

可重现的真实项目示例：

```sh
python3 scripts/make_demo.py /tmp/corridor-demo
open /tmp/corridor-demo/.corridor/viewer.html
```

示例从本仓库 PROPOSAL.md 和 LICENSE 摄入，参考页由人工整理，不冒充 Agent 自动知识生成。

2026-10-16 已通过实际浏览器检查：1440px 宽屏目录 → 详情 → 原始资料，搜索“暴力余弦”得到向量页，零结果状态，hash 深链刷新；390px 无横向溢出，运行时错误为 0。截图为 [宽屏](reading-wide.png) 和 [手机](reading-mobile.png)。使用环境可用的 Playwright 浏览器工具完成，未依赖未安装的 agent-browser 命令。

同日富文本复验使用 `scripts/reading_fixture.py` 创建真实 vault，执行 `scripts/reading_browser.js`：Markdown 标题/列表/表格、HTML 片段和独立 HTML 样式/表格、本地图片、MoonBit/Python 高亮、JS/JSON 格式化与原始排版切换、中文标题深链刷新、宿主隔离及 390px 布局均通过。运行时错误为 0，无 CDN 请求；截图为 [富文本宽屏](reading-rich-wide.png) 和 [富文本手机](reading-rich-mobile.png)。

2026-10-18 快照图复验：`python3 scripts/reading_fixture.py <dir> --with-map` 渲染启用 `graph` 的视图并运行 `scripts/reading_map_browser_cdp.py`（本机 Chrome headless + DevTools 协议的纯 Python 标准库实现，无 Playwright / Node 依赖）。断言快照图节点/边存在、共同来源虚线边存在、有入链节点是路由链接、点击后 hash 更新且只显示一篇正文、无横向溢出、运行时错误为 0；该检查已纳入 `verify.sh`，缺少 Chrome 时显式跳过（`CHROME_BINARY` 可指定）。

精简 Web 服务使用相同页面源和 renderer，启动方式见 [Web 服务](web.md)。本轮已在该服务上重跑以上浏览器检查，宽屏/手机均通过，记录见 [检查结果](web-browser-check.json)及[宽屏](web-wide.png)/[手机](web-mobile.png)截图。Web 页面直接使用本次 native 编译输出，没有另写前端页面。
