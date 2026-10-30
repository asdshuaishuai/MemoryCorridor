# WASM 接口：纯计算面与服务面

WASM 宿主持久化回执若包含 revision、format 或 sha256 字段，会被逐项核对本次快照封套；错误回执会拒绝发布并保留旧内存快照。

模块有两个面。**纯计算面**（`execute()`，wasm 与 wasm-gc 双目标）保持零宿主导入：目录/页面/视觉声明解析、基于宿主快照的自包含 HTML 渲染、关键词与暴力向量检索、UTF-8 预算上下文装配、页面快照图查询（`graph`/`neighbors`/`path`/`weighted-path`/`insights`）；它不具备磁盘事务，任何需要 vault 的操作不在该面。**服务面**（`service_execute()`，仅 wasm 目标）通过 8 个 `corridor-host` 宿主导入承载**全引擎**：与 native CLI 相同的 93 个 op（含 commit、memory、impact、inbox、evidence 的完整工单与事务语义）经 `@agent.dispatch_with_catalog` 在 WASM 运行时内执行，由 `hosts/wasm-host.py` 这样的薄宿主提供文件系统、flock 锁与 `moon check` 子进程。`tools` 在两个面都返回全引擎工具字典。

```sh
moon build --target wasm wasm
moon build --target wasm-gc wasm
node scripts/wasm_e2e.mjs
```

WASM-GC 测试需要 Node.js 22+（本地验证为 24.19.0）；Node.js 20 不支持当前 GC 产物。classic 产物在 Node.js 20 亦验证可加载。纯计算面没有任何宿主 imports（wasm-gc 目标保持零导入断言）；服务面恰好导入 8 个 `corridor-host` 函数，不依赖模型/网络。

## 服务面：全引擎跑在 WASM 运行时上

```sh
moon build --target wasm wasm
python3 scripts/wasm_service_e2e.py          # 首次运行自动创建 wasmtime venv
python3 hosts/wasm-host.py --module _build/wasm/debug/build/wasm/wasm.wasm --root <vault>
```

`hosts/wasm-host.py` 是 Unix 专用的薄宿主（wasmtime + wasmtime-py）：逐分量 `O_NOFOLLOW` 打开拒绝符号链接、临时文件 + fsync + rename 原子写、`<vault>/.corridor-lock` 上的非阻塞 `flock`、以 `moon check --deny-warn --target-dir .corridor/compiler` 子进程实现编译回调——逐条镜像 `platform/fs.c`。模块内 `wasm/host.mbt` 声明导入并构造与 native 同一个 `@vault.Storage`；`wasm/service.mbt` 移植 nativehost 的会话层（session-open/close、写锁持有、目录缓存）与 `cli/main.mbt` 的响应信封（`{ok,op,result,request_id}`、fault_data 增强、list-tools 特判、未知字段拒绝）。行协议与 native CLI 逐请求兼容；`:exit` 或 EOF 结束。跨进程锁竞争由操作系统 flock 裁决，第二个宿主进程被拒为 `vault_locked`。

状态协议：结果缓冲导入（read/list）返回 `>=0` 写入字节数、`-(needed+8)` 要求更大缓冲、`-3` 文件不存在（读为 None）、`-1` 拒绝（模块抛出与 native 相同的固定消息，例如缺失中间目录的预写探测读为 None 而非拒绝）。导入面是封闭契约：`scripts/wasm_e2e.mjs` 断言 wasm 目标恰好导入这 8 个函数、wasm-gc 目标保持零导入。引擎代码（base→agent）在该面零改动——agent 层本就以 `@vault.Storage` 参数化，引擎内没有时钟（所有 `at` 都是请求输入）。native 目标下该面编译为惰性 stub，仅用于通过 `moon check --deny-warn`。

边界：服务面当前仅 classic wasm 目标（指针协议依赖线性内存）；请求经 `input_load` 分段装载达 16 MiB（与单文件上限一致，宿主按 1 MiB 分块追加，纯面保持 2 MiB），超限以 `input_overflow` 信封拒绝且无法回显 request_id（与 native 对超长请求的行为一致）；宿主与 native 一样运行在类 Unix 上（flock 与 moon 子进程是 POSIX 设施）——跨平台适配交由「任意 WASM 运行时 + 各自薄宿主」承担，这是本项目的分发策略。

`sdk/wasm.mjs` 导出 `loadCorridor(bytes)`，加载后 `evaluate(request)` 返回 `{ok,result}` / `{ok:false,error}`。例如 `{op:"page",text:"..."}`；`catalog` 同样接 text，`tools` 无参数；`search` 接 `documents` 和 `query`（Document 含经验证的 title/body terms）；`vectors` 接 space/values/records。原始内核不检查磁盘或向量对应的正文版本，宿主须先提供验证后的数据。

浏览器或 Worker 可使用 `sdk/wasm-web-storage.mjs` 的 `createWebWasmStorage({key, storage, locks})` 接入 `createWasmSession`/`restoreWasmSession`。它用 Web Locks 覆盖 revision 检查和 `localStorage` 写入，并校验快照 SHA-256；运行环境没有 `navigator.locks` 时返回 `session_storage_lock_unavailable`，不会降级为无锁写入。Node 文件适配器仍负责跨进程 PID 锁和原子 rename。

图操作接收 `pages:[{entry,text}]`，其中 `text` 是页面完整 Markdown，WASM 会重新解析 frontmatter 和 wikilink，并核对 `entry` 的页面路径、Markdown 格式、来源路径、唯一性和 `sha256` 后再建图；宿主不能只提交一份 links 数组或旧正文绕过页面解析。`neighbors` 另接 `id`，`path` 与 `weighted-path` 接 `from/to`；后者使用互链/共同来源边权做确定性最短路。结果与 native 图遍历使用同一确定性排序规则。

`context` 接收 `candidates:[{entry,text,origin}]`、`query` 和 `budget`（1..65536），可选 `dedup`（`exact`/`similar`）与 `spread`（`ranked`/`even`），重新解析候选页面并核对页面路径、来源和 SHA-256 后复用 native 的查询定位、UTF-8 字节范围、完整正文/段落去重、`similar` 近似合并、预算分配与 `estimated_tokens` 启发式算法；返回 `offset_unit:"body_utf8_bytes"`、`used`、`estimated_tokens`、`truncated`、`blocks`、`strategy` 与重复引用，不读取磁盘或来源状态。

WASM 页面解析与 native 一致接受 `[[page#标题]]` 标题锚点；锚点只用于渲染路由，图依赖仍按页面 id 建立。

`view` 接收 `{text}` 并解析 `views/*.mbt.md` 的受限声明。`render-view` 接收 `{text,pages,sources,fingerprint}`：`pages` 为 `{entry,text}`，`sources` 为 `{entry,text,image}`，WASM 会重新解析声明、页面 frontmatter/wikilink、来源绑定和文本 SHA-256，再调用与 native 相同的 MoonBit HTML renderer。图片的 `image` 必须是与目录格式匹配的 data URL；WASM 解码后重新计算图片字节 SHA-256，binary/image 的展示正文由引擎生成，不信任宿主传入文本。返回 `html`、页面/来源数量和声明指纹。WASM 不读取文件、不联网、不执行脚本。渲染操作不写入快照，宿主如需发布仍须使用自己的原子持久化边界。

纯检索的 `excerpt` 与 native 关键词/混合检索共用查询段落定位，最多 360 UTF-8 字节且不拆 Unicode 字符；已在两个目标核对长页后段命中与 emoji 字节边界。带来源、重复引用和预算的完整上下文装配仍是 native 协议能力，未新增 WASM 会话操作。

ABI 只用整数和 UTF-8 字节，避免依赖 MoonBit 字符串内存布局：`input_reset()`，每字节 `input_push(0..255)`，`execute()` 返回输出字节数，逐个 `output_byte(offset)` 读取。每次 reset 清除输入及溢出状态，输入上限 2 MiB。单实例同步非重入。服务面另有 `scratch(cap)`（分配宿主可写缓冲）、`input_load(ptr,len)`（分段追加，总上限 16 MiB）、`output_ptr()`（批量读响应）与 `service_execute()`；宿主按 1 MiB 分块装载请求。

`sdk/wasm-session.mjs` 提供一个受宿主控制的 UTF-8 文件快照会话。创建和恢复入口先拒绝绝对路径、路径穿越、反斜杠、NUL 和非字符串文件，再由 MoonBit `session-verify` 校验已有目录、正文哈希和页面依赖；未登记的辅助文件仍可随快照保存。MoonBit 的 `session-plan` 校验变更前置条件并返回确定性计划；宿主调用 `compile(path,text)` 回调检查候选文学化文件，全部通过后才按正文先、`index.mbt.md` 后的顺序更新内存快照。同一会话的异步事务按提交队列串行执行，避免两个调用同时通过旧 revision；持久化回调收到版本化 `format:"memorycorridor-wasm-snapshot-v1"`、`base_revision`、`revision`、排序后的 `files` 和快照 `sha256`，持久化成功才发布内存状态，适配器可用 `base_revision` 实现外部 compare-and-swap，并返回可选的确认 `revision`。`restoreWasmSession({kernel,storage})` 会再次校验恢复快照和 SHA-256 封套，再绑定宿主的 `load/save`；没有 hash 的旧 `{revision,files}` 快照仍可迁移读取。编译失败、持久化失败、外部冲突和重放都保留旧快照。持久化适配器必须自行提供原子写入；WASM 不声称具备跨进程锁或完整 native 文件事务。

Node 宿主可直接使用 `sdk/wasm-node-storage.mjs` 的 `createNodeWasmStorage(path)`：它在读取当前版本、CAS 检查、临时文件写入和原子 rename 的整个窗口持有同目录 PID 锁；活跃进程持有锁时返回 `session_storage_locked`，死亡 PID 的锁可回收。快照写入同目录临时文件并在 flush 后原子 rename，按 `base_revision` 拒绝顺序上的过期写入，并串行化同一适配器实例的保存调用。纯 WASM 核心和自定义 `load/save` 适配器不内置文件锁，必须由宿主提供等价互斥或 CAS。快照封套会保留完整 `files`，包括事务候选 `Map` 中的正文。

```js
const memorySession = createWasmSession({ kernel, files, compile });
await memorySession.execute({ op: "transaction", changes });

const session = await restoreWasmSession({
  kernel,
  storage: { load: loadSnapshot, save: saveSnapshot },
  compile,
});
```

仍待实现的是 WASM 内核自身的持久化文件系统；Node 文件适配器已经覆盖跨进程保存互斥，Web 适配器覆盖具备 Web Locks 的浏览器/Worker。没有 Web Locks 的运行环境仍需宿主提供等价锁或 CAS，适配器不会无锁降级。视觉渲染已提供纯快照等价层，但浏览器中的 Markdown/HTML hydration、格式化和高亮仍由生成 HTML 中的阅读器运行时执行。
