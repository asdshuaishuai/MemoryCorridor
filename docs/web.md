# 精简本地 Web 服务

服务只使用 Python 3 标准库与已构建的 native CLI；编辑/渲染文学化页面还需要 `moon` 编译器。它固定服务一个 vault，默认监听 `127.0.0.1:8768`，不依赖桌面应用、Node 服务端或前端框架。

```sh
moon build --target native cli mcp
python3 scripts/make_demo.py /tmp/corridor-demo   # 末尾自带 rebuild
python3 scripts/serve.py /tmp/corridor-demo --port 8768
```

打开 `http://127.0.0.1:8768/`。启动时若没有默认页面声明，会通过引擎 `view-init` 创建；已有声明不会覆盖。启动和页面请求实际执行 `render-view`，由 MoonBit 编译 `views/library.mbt.md` 后生成 HTML。`--cli /absolute/cli.exe` 可指定另一份 native 可执行文件；`--port 0` 分配空闲端口，启动首行 JSON 返回地址。

| 请求 | 行为 |
| --- | --- |
| `GET /` | 编译并返回默认文学化阅读页 |
| `GET /api/status` | 引擎状态和指纹 |
| `GET /api/pages` | 知识页目录 |
| `GET /api/page?id=concepts/example` | 页面正文与来源 |
| `GET /api/search?q=关键词&limit=10&budget=4096&hops=1&query_vector=...&vector_candidates=...&dedup=similar&spread=even&provider=...` | MoonBit 排名检索及来源上下文；可选传递结果数量、UTF-8 字节预算、图扩展跳数、外部生成查询向量、宿主候选结果、去重策略、预算分配策略与 provider 绑定 |
| `GET /api/tree` | 页面树 |
| `GET /api/topics` | 主题浏览层：`synthesis` 页的标题、wikilink、raw 来源与失效状态 |
| `GET /api/lint` | 只读健康诊断；目录、来源/正文漂移、断链和缓存问题按稳定诊断字段返回 |

Web 层只暴露只读浏览路由，不实现第二套引擎逻辑：记忆、change-impact、收件箱和原文核对等能力由 CLI/MCP 使用，`/api/topics` 是其中唯一面向用户浏览的主题层视图。

JSON 接口保留 native 的 `{ok,result}` / `{ok:false,error}` 信封。除 `/api/lint` 外每次读取先 `verify`；正文/来源未登记变化、缓存损坏或编译失败返回 HTTP 409，保留上次输出文件但不把它当本次成功结果。`/api/lint` 有意跳过前置 `verify`，用于在这些状态下返回可修复诊断，但自身不写入 vault。超时返回 504，进程不可用返回 502。未知路由 404，非法/重复/缺失参数 400，写请求 405。请求不能指定其他 vault、路径、引擎操作或任意静态文件。

Markdown、HTML、图片、代码高亮与格式化沿用 [文学化阅读器](visual-mbtmd.md)。页面里的搜索框筛选当前快照；`/api/search` 使用引擎排名，两者语义分别保留。`limit` 为 1..100，`budget` 为 1..65536，`hops` 为 0..2；`dedup` 为 `exact`/`similar`，`spread` 为 `ranked`/`even`，`provider` 绑定已注册的 provider；`query_vector` 和 `vector_candidates` 都是 JSON 对象且互斥，空间、候选页面和分数校验继续由 MoonBit 引擎负责，Web 层不实现第二套检索逻辑。修改原始资料或正文后，用 CLI/MCP 显式登记，或另开已有 watcher：

```sh
python3 scripts/watch.py /tmp/corridor-demo
```

随后刷新浏览器以读取重新编译的快照。Web 服务不提供上传、编辑、模型推理或远程多人管理；编写仍走通用工单协议。Ctrl+C 停止服务。

自动验证入口 `python3 scripts/web_e2e.py`（已纳入 `scripts/verify.sh`）：真实 native/HTTP 读取与搜索对照、文学化输出、路由/参数边界、正文漂移、登记后刷新和无效页面声明不覆盖旧输出。浏览器复验沿用 `scripts/reading_browser.js`，页面来自本服务。
