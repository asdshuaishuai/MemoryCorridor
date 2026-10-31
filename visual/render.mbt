pub(all) struct Reading {
  entry : @core.Entry
  page : @core.Page
} derive(ToJson)
pub extend Reading with ToJson::{to_json}

pub(all) struct Source {
  id : String
  path : String
  sha256 : String
  text : String
  format : String
  image : String
} derive(ToJson)
pub extend Source with ToJson::{to_json}

pub fn escape(text : String) -> String {
  let amp = @base.replace_all(text, "&", "&amp;")
  let lt = @base.replace_all(amp, "<", "&lt;")
  let gt = @base.replace_all(lt, ">", "&gt;")
  let quote = @base.replace_all(gt, "\"", "&quot;")
  @base.replace_all(quote, "'", "&#39;")
}

fn anchor(kind : String, id : String) -> String {
  kind + "-" + @base.hex_hash(id)
}

fn link(kind : String, id : String, title : String) -> String {
  "<a href='#" + anchor(kind, id) + "'>" + escape(title) + "</a>"
}

fn enabled(view : View, feature : String) -> Bool {
  view.features.contains(feature)
}

fn body_html(body : String, format : String, path : String, page_ids : Array[String]) -> String {
  // Static CommonMark-subset baseline renders without scripts; the browser
  // hydrate replaces .rendered content wholesale and moves the (previously
  // hidden) original into the 查看原文 details toggle.
  let original = "<pre class='original-code' hidden>" + escape(body) + "</pre>"
  let static_html = if format == "markdown" { render_markdown(body, page_ids) } else { "" }
  "<section class='rich-document' data-format='" + escape(format) + "' data-path='" + escape(path) +
    "'><div class='rendered'>" + static_html + original + "</div></section>"
}

// Deterministic snapshot map: node order is (id, title) and positions are a
// fixed circle, so the same verified snapshot always renders the same SVG.
// Nodes link through the existing hash router; the edge list below the map
// remains the accessible fallback.
pub(all) struct GraphNode {
  id : String
  title : String
  x : Double
  y : Double
  links : Array[String]
  shared : Array[String]
} derive(ToJson)
pub extend GraphNode with ToJson::{to_json}

// Fixed 1/16-turn offsets keep the ring byte-identical on every target: no
// trigonometry, no platform math library in the rendered output.
let ring_cosine : Array[Double] = [
  0.0, 0.3826834323650898, 0.7071067811865476, 0.9238795325112867,
  1.0, 0.9238795325112867, 0.7071067811865476, 0.3826834323650898,
  0.0, -0.3826834323650898, -0.7071067811865476, -0.9238795325112867,
  -1.0, -0.9238795325112867, -0.7071067811865476, -0.3826834323650898,
]
let ring_sine : Array[Double] = [
  1.0, 0.9238795325112867, 0.7071067811865476, 0.3826834323650898,
  0.0, -0.3826834323650898, -0.7071067811865476, -0.9238795325112867,
  -1.0, -0.9238795325112867, -0.7071067811865476, -0.3826834323650898,
  0.0, 0.3826834323650898, 0.7071067811865476, 0.9238795325112867,
]

fn shares_source(a : Array[String], b : Array[String]) -> Bool {
  a.any(source => b.contains(source))
}

fn graph_nodes(pages : Array[Reading]) -> Array[GraphNode] {
  let ordered = pages.copy()
  ordered.sort_by((a, b) => {
    let by_id = @base.compare(a.entry.id, b.entry.id)
    if by_id != 0 { by_id } else { @base.compare(a.page.title, b.page.title) }
  })
  let total = ordered.length()
  let nodes : Array[GraphNode] = []
  for i, reading in ordered.iter2() {
    let step = i * 16 / total
    let x = 180.0 + 130.0 * ring_cosine[step]
    let y = 180.0 + 130.0 * ring_sine[step]
    let links = reading.page.links.copy()
    links.sort_by(@base.compare)
    let shared : Array[String] = []
    for j, other in ordered.iter2() {
      if i == j { continue }
      if shares_source(reading.entry.sources, other.entry.sources) { shared.push(other.entry.id) }
    }
    shared.sort_by(@base.compare)
    nodes.push({ id: reading.entry.id, title: reading.page.title, x, y, links, shared })
  }
  nodes
}

fn graph_svg(nodes : Array[GraphNode]) -> String {
  let position_index : Map[String, Int] = Map([])
  for i, node in nodes.iter2() { position_index[node.id] = i }
  let edge_rows : Array[(Int, Int)] = []
  let targets : Map[String, Bool] = Map([])
  for node in nodes {
    let source = position_index.get(node.id).unwrap_or(-1)
    if source < 0 { continue }
    for target in node.links {
      targets[target] = true
      match position_index.get(target) {
        Some(index) => edge_rows.push((source, index))
        None => ()
      }
    }
  }
  edge_rows.sort_by((a, b) => if a.0 != b.0 { a.0.compare(b.0) } else { a.1.compare(b.1) })
  let edges = edge_rows.map(pair => {
    let from = nodes[pair.0]
    let to = nodes[pair.1]
    if pair.0 == pair.1 {
      "<circle class='graph-self' cx='" + from.x.to_string() + "' cy='" + (from.y - 9.0).to_string() + "' r='3'/>"
    } else {
      "<line class='graph-edge' x1='" + from.x.to_string() + "' y1='" + from.y.to_string() +
        "' x2='" + to.x.to_string() + "' y2='" + to.y.to_string() + "'/>"
    }
  }).join("")
  // Shared-source relations are undirected: draw each pair once (lower index
  // first) and only when no wikilink already connects the two pages.
  let shared_rows : Array[(Int, Int)] = []
  for i = 0; i < nodes.length(); i = i + 1 {
    for j = i + 1; j < nodes.length(); j = j + 1 {
      if nodes[i].shared.contains(nodes[j].id) &&
        !nodes[i].links.contains(nodes[j].id) && !nodes[j].links.contains(nodes[i].id) {
        shared_rows.push((i, j))
      }
    }
  }
  let shared_edges = shared_rows.map(pair => {
    let from = nodes[pair.0]
    let to = nodes[pair.1]
    "<line class='graph-edge graph-shared' x1='" + from.x.to_string() + "' y1='" + from.y.to_string() +
      "' x2='" + to.x.to_string() + "' y2='" + to.y.to_string() + "'/>"
  }).join("")
  let shapes = nodes.map(node => {
    let circle = "<circle class='graph-node' cx='" + node.x.to_string() + "' cy='" + node.y.to_string() + "' r='5'/>"
    let label = "<text class='graph-label' x='" + node.x.to_string() + "' y='" + (node.y + 18.0).to_string() +
      "' text-anchor='middle'>" + escape(node.title) + "</text>"
    let body = circle + label
    let anchor_id = anchor("p", node.id)
    if targets.contains(node.id) {
      "<a href='#" + anchor_id + "'>" + body + "</a>"
    } else { "<g>" + body + "</g>" }
  }).join("")
  if nodes.is_empty() { return "" }
  "<svg class='graph-map' viewBox='0 0 360 360' role='img' aria-label='知识关系快照图：互链与共同来源'>" +
    shared_edges + edges + shapes + "</svg>"
}

pub fn render(view : View, pages : Array[Reading], sources : Array[Source], fingerprint : String) -> String {
  let routing = enabled(view, "routing")
  let source_links = enabled(view, "source-links")
  let hidden = if routing { " hidden" } else { "" }
  let directory = pages.map(r => {
    "<li data-item='" + escape(r.entry.id) + "'>" + link("p", r.entry.id, r.page.title) +
      "<small>" + escape(r.entry.kind) + (if r.entry.stale { " · 待重编译" } else { "" }) + "</small></li>"
  }).join("")
  let page_ids : Array[String] = pages.map(r => r.entry.id)
  let articles = pages.map(r => {
    let evidence = r.entry.sources.map(s => if source_links { link("r", s, s) } else { escape(s) }).join(" · ")
    let stale = if r.entry.stale { "<p class='warning' role='status'>来源已失效，此页等待重编译，不参与搜索。</p>" } else { "" }
    "<article class='reading' id='" + anchor("p", r.entry.id) + "'" + hidden + " data-id='" + escape(r.entry.id) + "'>" +
    "<p class='eyebrow'>" + escape(r.entry.kind) + " / " + escape(r.entry.id) + "</p><h1>" + escape(r.page.title) + "</h1>" +
    stale + "<div class='prose'>" + body_html(r.page.body, "markdown", r.entry.path, page_ids) + "</div><footer>来源证据<br>" + evidence + "</footer></article>"
  }).join("")
  let originals = sources.map(s => {
    "<article class='reading' id='" + anchor("r", s.id) + "'" + hidden + "><p class='eyebrow'>原始资料</p><h1>" +
    escape(s.id) + "</h1><div class='prose'>" + body_html(s.text, s.format, s.path, []) + "</div><small>SHA-256 " + escape(s.sha256) + "</small></article>"
  }).join("")
  let search_controls = if enabled(view, "search") {
    "<label for='query'>在知识库中搜索</label><input id='query' type='search' placeholder='输入关键词…' autocomplete='off'><p id='count' aria-live='polite'></p><p id='no-results' hidden>没有匹配页面，试试其他关键词。</p>"
  } else { "" }
  let source_items = sources.map(s => "<li>" + (if source_links { link("r", s.id, s.id) } else { escape(s.id) }) + "</li>").join("")
  let mut edge_count = 0
  let mut stale_count = 0
  for reading in pages {
    edge_count = edge_count + reading.page.links.length()
    if reading.entry.stale { stale_count = stale_count + 1 }
  }
  let graph_nodes_value = graph_nodes(pages)
  let graph_items = pages.map(r => {
    let linked_targets = r.page.links.copy()
    linked_targets.sort_by(@base.compare)
    let linked = linked_targets.map(target => "<span class='edge-kind'>互链</span> " + link("p", target, target)).join(" · ")
    let shared_targets = pages.filter(other => other.entry.id != r.entry.id &&
      r.entry.sources.any(source => other.entry.sources.contains(source))).map(other => other.entry.id)
    shared_targets.sort_by(@base.compare)
    let shared = shared_targets.filter(target => !linked_targets.contains(target)).map(target =>
      "<span class='edge-kind'>共同来源</span> " + link("p", target, target)).join(" · ")
    let targets = [linked, shared].filter(part => !part.is_empty()).join(" · ")
    "<li><strong>" + escape(r.page.title) + "</strong><span class='graph-arrow'> → </span>" +
      (if targets.is_empty() { "<span class='muted'>无出边</span>" } else { targets }) + "</li>"
  }).join("")
  let panels : Map[String, String] = Map([])
  panels["catalog"] = "<nav aria-label='知识目录'><p class='eyebrow'>LIBRARY / 知识目录</p>" + search_controls + "<ul id='catalog'>" + directory + "</ul></nav>"
  panels["page"] = "<main id='reading'><div id='welcome'><p class='eyebrow'>MEMORY / CORRIDOR</p><h1>让资料成为<br>可追溯的知识。</h1><p>选择左侧页面，开始阅读。每一篇知识都保留通往原始资料的路径。</p><p>" + pages.length().to_string() + " 篇知识 · " + sources.length().to_string() + " 份资料</p></div>" + articles + originals + "<p id='missing' hidden>该页面不存在于此快照。</p></main>"
  panels["sources"] = "<aside aria-label='来源'><p class='eyebrow'>EVIDENCE / 来源</p><h2>回到事实发生处</h2><p>知识正文与原始资料分别保存。点击来源，核对上下文。</p><ul>" + source_items + "</ul><hr><p class='eyebrow'>阅读快照</p><small class='fingerprint'>" + escape(fingerprint) + "</small><p><small>搜索覆盖当前快照中的有效页面；资料变化后重新生成以更新。</small></p></aside>"
  panels["graph"] = "<aside class='data-panel graph-panel' aria-label='知识关系'><p class='eyebrow'>GRAPH / 知识关系</p><h2>页面之间的连接</h2>" + graph_svg(graph_nodes_value) + "<ul>" + graph_items + "</ul><p><small>实线：互链 · 虚线：共同来源。图为当前快照的确定性环形布局；点击节点进入对应页面。</small></p></aside>"
  panels["insights"] = "<aside class='data-panel insights-panel' aria-label='快照洞察'><p class='eyebrow'>INSIGHTS / 快照洞察</p><h2>当前结构</h2><dl><div><dt>知识页</dt><dd>" + pages.length().to_string() + "</dd></div><div><dt>来源</dt><dd>" + sources.length().to_string() + "</dd></div><div><dt>关系</dt><dd>" + edge_count.to_string() + "</dd></div><div><dt>待重编译</dt><dd>" + stale_count.to_string() + "</dd></div></dl></aside>"
  let readings = pages.map(r => {
    let value : Json = { "id": r.entry.id, "title": r.page.title, "body": r.page.body, "stale": r.entry.stale }
    value
  })
  let data : Json = { "pages": readings.to_json(), "sources": sources.to_json(), "features": view.features.to_json(),
    "graph_nodes": graph_nodes_value.to_json(),
    "links": pages.map(r => {
      let value : Json = { "id": r.entry.id, "path": r.entry.path, "anchor": anchor("p", r.entry.id) }
      value
    }).to_json(), "source_links": sources.map(s => {
      let value : Json = { "id": s.id, "path": s.path, "anchor": anchor("r", s.id) }
      value
    }).to_json() }
  let encoded = @base.replace_all(@base.canonical(data), "<", "\\u003c")
  let safe_data = @base.replace_all(encoded, ">", "\\u003e")
  "<!doctype html><html lang='zh-CN'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>" +
  "<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; frame-src about:; base-uri 'none'; form-action 'none'\">" +
  "<title>" + escape(view.title) + "</title><script type='application/json' id='dependency-notices'>" + @reader.notices() + "</script><style>:root{--accent:" + view.accent + ";--paper:" + view.paper + "}" + styles() + "</style>" +
  "<body><header><a href='#' class='brand'>MC<span> / " + escape(view.title) + "</span></a><span>有来源的记忆</span></header><div class='workspace'>" +
  view.panels.map(p => panels[p]).join("") + "</div><script id='page-data' type='application/json'>" + safe_data + "</script><script>" + @reader.javascript() + "</script><script>" + runtime() + rich_runtime() + "</script></body></html>"
}

fn styles() -> String {
  let css =
  #|*{box-sizing:border-box}
  #|body{margin:0;background:var(--paper);color:#252923;font-family:Georgia,'Songti SC',serif}
  #|a{color:var(--accent);text-underline-offset:4px}
  #|header{height:76px;padding:0 32px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid #d6d6cb}
  #|.brand{text-decoration:none;font-size:25px;font-weight:bold}
  #|.brand span{font-size:16px;font-weight:normal}
  #|header>span{font-size:13px;color:#687364}
  #|.workspace{display:flex;min-height:calc(100vh - 76px)}
  #|nav{flex:0 0 270px;padding:36px 24px;border-right:1px solid #d6d6cb}
  #|main{flex:1;min-width:0;padding:58px clamp(24px,5vw,76px)}
  #|aside{flex:0 0 250px;border-left:1px solid #d6d6cb;padding:36px 24px;background:#eeeee4}
  #|.data-panel h2{font-size:20px;margin:0 0 18px}
  #|.data-panel ul{margin-top:0}
  #|.data-panel li{line-height:1.6}
  #|.graph-arrow,.muted,.edge-kind{color:#687364}
  #|.edge-kind{font-size:11px}
  #|.graph-map{width:100%;max-width:320px;height:auto;display:block;margin:0 0 10px}
  #|.graph-edge{stroke:#a8afa2;stroke-width:1}
  #|.graph-shared{stroke:#b3a98e;stroke-dasharray:3 3}
  #|.graph-node{fill:var(--accent)}
  #|.graph-self{fill:none;stroke:var(--accent);stroke-width:1}
  #|.graph-label{font:10px 'Courier New',monospace;fill:#3c463b}
  #|.graph-map a:hover .graph-node{fill:#A45C32}
  #|.insights-panel dl{margin:0}
  #|.insights-panel dl div{display:flex;justify-content:space-between;border-bottom:1px solid #d6d6cb;padding:10px 0}
  #|.insights-panel dt{color:#687364}
  #|.insights-panel dd{margin:0;font-family:'Courier New',monospace;color:var(--accent)}
  #|.eyebrow{font-family:'Courier New',monospace;font-size:11px;letter-spacing:1.5px;color:#687364;margin:0 0 24px}
  #|label{display:block;font-size:13px;margin-bottom:10px}
  #|input{font:inherit;width:100%;padding:12px 10px;border:1px solid #a8afa2;background:transparent;border-radius:0}
  #|input:focus{outline:2px solid var(--accent);outline-offset:2px}
  #|ul{list-style:none;padding:0;margin:20px 0}
  #|li{margin:0;padding:14px 0;border-bottom:1px solid #d6d6cb;overflow-wrap:anywhere}
  #|li a{text-decoration:none}
  #|li a:hover{text-decoration:underline}
  #|small{display:block;font-size:11px;color:#687364;margin-top:7px}
  #|h1{font-weight:normal;font-size:clamp(32px,3.5vw,54px);line-height:1.3;margin:0 0 32px;overflow-wrap:anywhere}
  #|h2{font-weight:normal;font-size:24px;line-height:1.4}
  #|p{line-height:1.8}
  #|#welcome{padding-top:40px;max-width:620px}
  #|#welcome h1{font-size:clamp(40px,4.5vw,70px)}
  #|.prose{font-size:17px;line-height:1.9;overflow-wrap:anywhere}
  #|.prose p{min-height:8px}
  #|.prose h1{font-size:32px;margin-top:32px}
  #|.prose h2{font-size:27px;margin-top:30px}
  #|.prose h3{font-size:23px;margin-top:26px}
  #|.prose h4,.prose h5,.prose h6{font-size:19px}
  #|.prose ul{list-style:disc;padding-left:26px}
  #|.prose ol{padding-left:26px}
  #|.prose li{padding:3px 0;border:0}
  #|.prose li p{margin:4px 0}
  #|.prose blockquote{margin:22px 0;padding:4px 22px;border-left:3px solid var(--accent);background:#eeeee4}
  #|.table-scroll{overflow-x:auto;margin:24px 0}
  #|.prose table{border-collapse:collapse;min-width:100%;font-size:15px}
  #|.prose th,.prose td{border:1px solid #c5cabb;padding:10px 15px;text-align:left}
  #|.prose th{background:#e7e9de}
  #|.prose img{max-width:100%;height:auto}
  #|.prose :not(pre)>code{font:14px/1.6 'Courier New',monospace;background:#e7e9de;padding:2px 5px}
  #|.prose pre{white-space:pre;overflow-x:auto;overflow-wrap:normal;margin:0 0 24px}
  #|.original-code{white-space:pre-wrap!important;overflow-wrap:anywhere!important}
  #|.code-toolbar{display:flex;gap:14px;align-items:center;padding:8px 14px;background:#dfe3d5;font:12px/1.7 'Courier New',monospace}
  #|button{font:inherit;cursor:pointer;border:1px solid #a8afa2;background:transparent;color:var(--accent);padding:3px 10px}
  #|button:focus-visible,summary:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
  #|button:disabled{cursor:wait;opacity:.65}
  #|.original{margin:28px 0;font-size:13px;border-top:1px solid #d6d6cb;padding-top:14px}
  #|summary{cursor:pointer;color:var(--accent);margin-bottom:14px}
  #|.html-preview{display:block;width:100%;height:65vh;min-height:420px;border:1px solid #c5cabb;background:white}
  #|.hljs-keyword,.hljs-selector-tag,.hljs-literal{color:#7852a1}
  #|.hljs-string,.hljs-regexp,.hljs-attribute,.hljs-meta .hljs-string{color:#27604b}
  #|.hljs-number,.hljs-symbol,.hljs-bullet{color:#914923}
  #|.hljs-title,.hljs-section,.hljs-built_in,.hljs-type{color:#235a85}
  #|.hljs-comment,.hljs-quote{color:#63715c;font-style:italic}
  #|.hljs-name,.hljs-tag,.hljs-meta,.hljs-attr{color:#875525}
  #|footer{margin-top:50px;padding-top:24px;border-top:1px solid #d6d6cb;font-size:13px;line-height:2;overflow-wrap:anywhere}
  #|pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.8 'Courier New',monospace;background:#e7e9de;padding:20px}
  #|.warning{padding:14px;border-left:3px solid #A45C32;color:#844321}
  #|.fingerprint{overflow-wrap:anywhere;font-family:'Courier New',monospace}
  #|hr{border:0;border-top:1px solid #d6d6cb;margin:32px 0}
  #|#count{font-size:12px;color:#687364}
  #|a:focus-visible{outline:2px solid var(--accent);outline-offset:4px}
  #|[hidden]{display:none!important}
  #|@media(max-width:1000px){aside{flex-basis:200px}
  #|nav{flex-basis:220px}
  #|main{padding:38px 26px}
  #|}
  #|@media(max-width:760px){header{padding:0 20px}
  #|header>span{display:none}
  #|.workspace{display:block}
  #|nav,aside{border:0;padding:24px}
  #|nav{border-bottom:1px solid #d6d6cb}
  #|#catalog{max-height:220px;overflow:auto}
  #|main{min-height:60vh;padding:36px 24px}
  #|aside{border-top:1px solid #d6d6cb}
  #|#welcome{padding-top:0}
  #|}
  #|@media(prefers-reduced-motion:no-preference){a,input{transition:color .15s,border-color .15s}
  #|}
  css
}

fn runtime() -> String {
  let js =
  #|const snapshot = JSON.parse(document.getElementById('page-data').textContent);
  #|const pages = snapshot.pages;
  #|const features = new Set(snapshot.features || []);
  #|const searchable = features.has('search');
  #|const routing = features.has('routing');
  #|const query=document.getElementById('query');
  #|function filter() {
  #|  if (!searchable || !query) return;
  #|  const words = query.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
  #|  let count = 0;
  #|  for (const item of document.querySelectorAll('[data-item]')) {
  #|    const page = pages.find(p => p.id === item.dataset.item);
  #|    const haystack = (page.title + ' ' + page.body).toLocaleLowerCase();
  #|    const show = words.length === 0 || (!page.stale && words.every(w => haystack.includes(w)));
  #|    item.hidden = !show;
  #|    if (show) count++;
  #|  }
  #|  document.getElementById('count').textContent = count + ' 篇知识';
  #|  document.getElementById('no-results').hidden = count !== 0;
  #|}
  #|function routeParts() {
  #|  const raw=location.hash.slice(1), marker=raw.indexOf('--');
  #|  let id=marker<0 ? raw : raw.slice(0,marker), fragment=marker<0 ? '' : raw.slice(marker+2);
  #|  try { id=decodeURIComponent(id); fragment=decodeURIComponent(fragment); }
  #|  catch { return {id:'',fragment:''}; }
  #|  return {id,fragment};
  #|}
  #|function route() {
  #|  if (!routing) return;
  #|  const route=routeParts(), id=route.id;
  #|  let selected = null;
  #|  for (const article of document.querySelectorAll('.reading')) {
  #|    article.hidden = article.id !== id;
  #|    if (!article.hidden) selected = article;
  #|  }
  #|  document.getElementById('welcome').hidden = !!id;
  #|  document.getElementById('missing').hidden = !id || !!selected;
  #|  for (const a of document.querySelectorAll('#catalog a')) {
  #|    if (a.hash === location.hash) a.setAttribute('aria-current', 'page');
  #|    else a.removeAttribute('aria-current');
  #|  }
  #|  if (selected && route.fragment) requestAnimationFrame(()=>document.getElementById(id+'--'+route.fragment)?.scrollIntoView());
  #|}
  #|if (searchable && query) { query.addEventListener('input', filter); filter(); }
  #|if (routing) { window.addEventListener('hashchange', route); route(); }
  js
}
