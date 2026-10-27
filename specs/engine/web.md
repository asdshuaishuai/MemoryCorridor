# 精简 Web 服务

用户确认边界：独立引擎，删除桌面实现及专用桌面集成；可提供精简 Web 服务。

- 页面源仍为 `views/library.mbt.md`。HTTP 层不维护另一份页面模板；`/` 调用 native `render-view` 后提供编译结果，正文独立存放。
- 服务固定绑定一个启动时指定的 vault，默认仅监听 `127.0.0.1:8768`。只公开阅读页及 status/pages/page/search/tree/lint 读取接口，不公开文件目录和写入操作。
- 每次读取先经引擎验证；来源/正文漂移或编译失败返回显式错误，保留旧派生文件但不把它当最新成功响应。登记变化继续使用 CLI/MCP 或已有 watcher。
- Markdown/HTML 呈现和语言高亮/格式化由现有文学化阅读器承担。Web JSON 搜索直接返回 MoonBit 排名与来源装配；页面搜索保持快照内筛选语义。
- HTTP 是 Python 标准库薄传输层，知识规则、目录编译、检索及提交仍在 MoonBit。服务代码计入 >85% 门槛，不含模型或桌面依赖。
- `/api/search` 的 `q` 必填（可与空字符串的 `query_vector` 或 `vector_candidates` 同用），并可传 `limit`（1..100）、`budget`（1..65536）、`hops`（0..2）、`dedup`（`exact`/`similar`）、`spread`（`ranked`/`even`）、`provider` 和 JSON `query_vector`/`vector_candidates`；两种向量输入互斥，参数只转换为 native 请求字段，空间、维度、候选页面、模型隔离及错误仍由引擎校验。

任务：

- [x] 固定 vault 的 loopback HTTP 传输、显式错误和文学化页面绑定。
- [x] 真实 native/HTTP 对照、正文和编译错误验证、实际浏览器复验。
- [x] 更新使用说明、完整门禁和源码比例。
- [x] `/api/search` 与引擎检索字段对齐：`dedup`/`spread`/`provider` 透传，invalid choice 返回 409，native/HTTP 输出逐字节对照。

2026-10-19：`scripts/verify.sh` 完整通过（96 项 MoonBit 测试）；`/api/search` 与 native 的 limit/budget/hops/dedup/spread/provider 及向量输入逐字节对照，非法 `dedup`/`spread` 返回 409；注册 provider 后显式 rebuild，Web 的 verify 前置检查与缓存指纹保持一致。实际浏览器运行 `scripts/reading_browser.js`，覆盖宽屏/手机、Markdown/HTML、高亮、格式化切换、导航及隔离；[记录](../../docs/web-browser-check.json)保留检查范围与截图。
