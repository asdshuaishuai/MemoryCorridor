# 精简本地 Web 服务

Web 服务是 MoonBit 原生实现（`web/` 包，与 CLI/MCP 同层的宿主适配），socket 走 `platform/socket.c` 的 native FFI，engine 调用经 `nativehost` 进程内派发。编辑/渲染文学化页面仍需要 `moon` 编译器。它固定服务一个 vault，默认监听 `127.0.0.1:8768`，不依赖桌面应用、Node 服务端、Python 或前端框架；发布包不再包含 Python HTTP 适配器。

```sh
moon build --target native cli mcp web
python3 scripts/make_demo.py /tmp/corridor-demo   # 末尾自带 rebuild
_build/native/debug/build/web/web.exe /tmp/corridor-demo --port 8768
```

打开 `http://127.0.0.1:8768/`。启动时先执行 `verify`，若没有默认页面声明会通过引擎 `view-init` 创建；已有声明不会覆盖，随后执行一次 `render-view`。启动任一步失败会把 `{ok:false}` 诊断打到 stderr 并以非零码退出。绑定成功后向 stdout 输出一行 JSON（`url`/`vault`/`mode`）；`--port 0` 分配空闲端口，`url` 携带实际端口。页面请求实际执行 `render-view`，由 MoonBit 编译 `views/library.mbt.md` 后生成 HTML。

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

JSON 接口保留 native 的 `{ok,result}` / `{ok:false,error}` 信封。除 `/api/lint` 外每次读取先 `verify`；正文/来源未登记变化、缓存损坏或编译失败返回 HTTP 409，保留上次输出文件但不把它当本次成功结果。`/api/lint` 有意跳过前置 `verify`，用于在这些状态下返回可修复诊断，但自身不写入 vault。未知路由 404，非法/重复/缺失参数 400，写请求（POST）405，其余方法 501，Host 头不是 `127.0.0.1:<port>`/`localhost:<port>` 的请求 403（含绝对形式 request-target，客户端会带来别的 Host）。请求不能指定其他 vault、路径、引擎操作或任意静态文件。

锁语义与引擎一致：每个请求单独「打开 vault → 取写锁 → verify → 派发 → 释放锁」，服务进程从不在请求之间持有 vault 锁，并发的 CLI/MCP 写者只需等待单个请求的派发时长。

参数约束与 Python 版一致：`/api/page` 只接受一个非空 `id`；`/api/search` 的 `q` 必填（可与空 `q` 的 `query_vector`/`vector_candidates` 同用），每个参数最多出现一次，查询字段最多 12 个；`limit`/`budget`/`hops` 按十进制整数解析；`query_vector`/`vector_candidates` 必须是 JSON 对象。空间、维度、候选页面、模型隔离及 `limit`(1..100)/`budget`(1..65536)/`hops`(0..2)/`dedup`/`spread`/provider 的合法性仍由 MoonBit 引擎校验，Web 层不做第二套检索逻辑；非法取值以 409 返回。

当前边界：无 TLS、无访问控制（loopback 专用）；串行逐请求处理（一次一个连接，每个连接单请求，响应固定 `Connection: close`），无每请求超时——浏览器或本机工具并发打开多条连接时会排队，恶意慢客户端可占住服务；HTTP 解析是面向本服务的最小实现（请求行/Host/头与 Content-Length 上限、绝对形式 target 与 16KiB 长度拒绝），不是通用 HTTP 服务器；`platform/socket.c` 的 Winsock 分支按 POSIX 镜像编写并标注，尚未在 Windows 环境验证。

Markdown、HTML、图片、代码高亮与格式化沿用 [文学化阅读器](visual-mbtmd.md)。页面里的搜索框筛选当前快照；`/api/search` 使用引擎排名，两者语义分别保留。修改原始资料或正文后，用 CLI/MCP 显式登记，或另开已有 watcher：

```sh
python3 scripts/watch.py /tmp/corridor-demo
```

随后刷新浏览器以读取重新编译的快照。Web 服务不提供上传、编辑、模型推理或远程多人管理；编写仍走通用工单协议。Ctrl+C 停止服务。

自动验证入口 `python3 scripts/web_e2e.py`（已纳入 `scripts/verify.sh`）：启动 MoonBit `web` 二进制，对照真实 native/HTTP 读取与搜索、文学化输出、路由/参数边界、Host 隔离、正文漂移、登记后刷新和无效页面声明不覆盖旧输出。
