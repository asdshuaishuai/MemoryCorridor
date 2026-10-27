// Real-browser check without external tooling: launches local Chrome headless
// with a CDP endpoint, loads the mapped reader snapshot and asserts the graph
// map renders, routes on click, and produces no console errors.
// Usage: node scripts/reading_map_browser_cdp.mjs [file-url] [chrome-path]
import { spawn } from "node:child_process";
import { once } from "node:events";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";

const URL = process.argv[2] || "file:///tmp/corridor-rich-reading/.corridor/map-viewer.html";
const CHROME = process.argv[3] || process.env.CHROME_BINARY ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PROFILE = join(tmpdir(), "corridor-cdp-profile-" + process.pid);
const chrome = spawn(CHROME, [
  "--headless=new", "--disable-gpu", "--no-first-run",
  "--remote-debugging-port=0", `--user-data-dir=${PROFILE}`,
  "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

let PORT = "";
const reader = createInterface({ input: chrome.stderr });
reader.on("line", line => {
  const match = line.match(/DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//);
  if (match) PORT = match[1];
});

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
for (let attempt = 0; attempt < 100 && !PORT; attempt++) await sleep(100);
if (!PORT) {
  chrome.kill();
  throw new Error("chrome did not expose a debugging port");
}
let socket;
for (let attempt = 0; attempt < 50; attempt++) {
  await sleep(100);
  try {
    const version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
    socket = new WebSocket(version.webSocketDebuggerUrl);
    await once(socket, "open");
    break;
  } catch { socket = undefined; }
}
if (!socket) {
  chrome.kill();
  await rm(PROFILE, { recursive: true, force: true }).catch(() => {});
  throw new Error("chrome debugging endpoint unavailable");
}

let messageId = 0;
const pending = new Map();
const events = [];
socket.addEventListener("message", event => {
  const message = JSON.parse(event.data);
  if (message.id && pending.has(message.id)) {
    pending.get(message.id)(message);
    pending.delete(message.id);
  } else if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
    events.push(message.params.args.map(a => a.value).join(" "));
  } else if (message.method === "Runtime.exceptionThrown") {
    events.push(message.params.exceptionDetails.text);
  }
});
const send = (method, params = {}, sessionId) => new Promise(resolve => {
  const id = ++messageId;
  pending.set(id, resolve);
  socket.send(JSON.stringify({ id, method, params, sessionId }));
});

const { result: { targetId } } = await send("Target.createTarget", { url: "about:blank" });
const { result: { sessionId } } = await send("Target.attachToTarget", { targetId, flatten: true });
await send("Runtime.enable", {}, sessionId);
await send("Page.enable", {}, sessionId);
await send("Page.navigate", { url: URL }, sessionId);
await sleep(2500);

const evaluate = async expression => {
  const response = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true }, sessionId);
  if (response.result?.exceptionDetails) throw new Error(response.result.exceptionDetails.text);
  return response.result.result.value;
};

const checks = [];
const check = (value, label) => { checks.push({ label, ok: !!value }); };

check(await evaluate(`!!document.querySelector('.graph-panel svg.graph-map')`), "graph map renders");
check(await evaluate(`document.querySelectorAll('.graph-map line.graph-edge').length >= 1`), "graph edges present");
check(await evaluate(`document.querySelectorAll('.graph-map line.graph-shared').length >= 1`), "shared-source dashed edges present");
check(await evaluate(`document.querySelectorAll('.graph-map circle.graph-node').length >= 2`), "graph nodes present");
check(await evaluate(`document.querySelectorAll(".graph-map a[href^='#p-']").length >= 1`), "graph nodes are routable links");
const routed = await evaluate(`(async () => {
  const link = document.querySelector(".graph-map a[href^='#p-']");
  const href = link.getAttribute('href');
  link.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
  await new Promise(resolve => setTimeout(resolve, 300));
  const visible = [...document.querySelectorAll('.reading')].filter(a => !a.hidden);
  return { href, hash: location.hash, visible: visible.length, id: visible[0]?.dataset?.id || '' };
})()`);
check(routed.hash === routed.href, `graph click updates the hash (${routed.href} -> ${routed.hash})`);
check(routed.visible === 1, `graph routing shows one article (${routed.visible})`);
check(await evaluate(`document.documentElement.scrollWidth <= innerWidth`), "no horizontal overflow at current viewport");
check(events.length === 0, `no console errors (${events.join("; ")})`);

const failed = checks.filter(c => !c.ok);
for (const c of checks) console.log(`${c.ok ? "ok  " : "FAIL"} ${c.label}`);
socket.close();
chrome.kill();
await rm(PROFILE, { recursive: true, force: true }).catch(() => {});
if (failed.length) process.exit(1);
console.log("map reader browser check passed");
