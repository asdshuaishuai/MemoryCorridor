test "literate view grammar rejects unsupported code, styles and bindings" {
  let view = default_view()
  assert_eq(parse(generate(view)).to_json(), view.to_json())
  assert_eq(parse(generate(view) + "\n\n这里是页面说明。\n").to_json(), view.to_json())
  assert_true(try { ignore(parse(generate({ ..view, accent: "red;display:none" }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, panels: ["page", "page", "sources"] }))); false } catch { _ => true })
  let dynamic = { ..view, panels: ["catalog", "page", "graph", "insights", "sources"] }
  assert_eq(parse(generate(dynamic)).panels, dynamic.panels)
  assert_true(try { ignore(parse(generate({ ..view, panels: ["catalog", "page", "sources", "unknown"] }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, features: ["unknown"] }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, features: ["search", "search"] }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate(view) + "extra code")); false } catch { _ => true })
}

test "literate view composes additional checked blocks" {
  let view = default_view()
  let extra = generate(view) + "\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  assert_eq(parse(extra).to_json(), view.to_json())
  let plain_extra = generate(view) + "\n```mbt\nfn helper() -> Int { 1 }\n```\n"
  assert_eq(parse(plain_extra).to_json(), view.to_json())
  let unclosed = generate(view) + "\n```mbt check\nfn helper() -> Int { 1 }\n"
  assert_true(try { ignore(parse(unclosed)); false } catch { _ => true })
  let plain_unclosed = generate(view) + "\n```mbt\nfn helper() -> Int { 1 }\n"
  assert_true(try { ignore(parse(plain_unclosed)); false } catch { _ => true })
  let plain_before_checked = generate(view) + "\n```mbt\nfn helper() -> Int { 1 }\n\n```mbt check\nfn later() -> Int { 2 }\n"
  assert_true(try { ignore(parse(plain_before_checked)); false } catch { _ => true })
}

test "literate view accepts CRLF sources" {
  let source = @base.replace_all(generate(default_view()), "\n", "\r\n")
  assert_eq(parse(source).to_json(), default_view().to_json())
}

test "literate view round-trips canonical output and validates field bounds" {
  let view = default_view()
  assert_eq(generate(parse(generate(view))), generate(view))
  assert_eq(parse("# Preface\n\n" + generate(view)).to_json(), view.to_json())
  let legacy = generate(view).replace(
    old=", [\"search\",\"routing\",\"rich-render\",\"code-format\",\"source-links\"])", new=")")
  assert_eq(parse(legacy).features, default_features())
  let padded = generate(view).replace(old="view(\"MemoryCorridor\"", new="view( \"MemoryCorridor\"")
  assert_true(try { ignore(parse(padded)); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, title: "" }))); false } catch { _ => true })
  assert_eq(parse(generate({ ..view, title: "a".repeat(100) })).title.length(), 100)
  assert_true(try { ignore(parse(generate({ ..view, title: "a".repeat(101) }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, panels: ["catalog", "page"] }))); false } catch { _ => true })
  assert_true(try { ignore(parse(generate({ ..view, panels: ["catalog", "page", "sources", "graph", "insights", "catalog"] }))); false } catch { _ => true })
  let eof_helper = generate(view) + "\n\n```mbt check\nfn later() -> Int { 2 }\n```"
  assert_eq(parse(eof_helper).to_json(), view.to_json())
}

test "deterministic view mutations never panic and canonicalize when accepted" {
  let canonical = generate(default_view())
  let block = @base.first_checked_block(canonical)
  let header = "```mbt check\n"
  let start = canonical.find(header).unwrap_or(0) + header.length()
  let replacements = ["x", "`", "~", "\n", "\"", "]", "(", " ", "0"]
  for i = 0; i < 160; i = i + 1 {
    let position = start + (i * 7919) % block.code.length()
    let replacement = replacements[i % replacements.length()]
    let mutated = canonical[:position].to_owned() + replacement + canonical[position + 1:].to_owned()
    let parsed = try { Some(parse(mutated)) } catch { _ => None }
    match parsed {
      Some(view) => assert_eq(generate(parse(generate(view))), generate(view))
      None => ()
    }
  }
}

test "hostile text stays escaped in markup and embedded data" {
  let entry : @core.Entry = { id: "concepts/test", path: "wiki/concepts/test.md", kind: "concept", format: "markdown", sha256: "a".repeat(64), sources: ["raw/a.md"], stale: false }
  let page : @core.Page = { title: "<script>bad</script>", kind: "concept", sources: entry.sources, tags: [], body: "</script><img src=x onerror=alert(1)>\n[[concepts/test|自己]]", links: [entry.id] }
  let html = render(default_view(), [{ entry, page }], [], "hash")
  assert_false(html.contains("<img src=x"))
  assert_false(html.contains("<script>bad"))
  assert_true(html.contains("&lt;img"))
  assert_true(html.contains("\\u003c/script\\u003e"))
  assert_true(html.contains("data-format='markdown'"))
  assert_true(html.contains("CorridorLibraries"))
}

test "original sources carry explicit render format without embedding executable HTML" {
  let source : Source = { id: "raw/page.html", path: "raw/page.html", sha256: "a".repeat(64), text: "<h2>HTML</h2><script>alert(1)</script>", format: "html", image: "" }
  let html = render(default_view(), [], [source], "hash")
  assert_true(html.contains("data-format='html'"))
  assert_true(html.contains("&lt;h2&gt;HTML&lt;/h2&gt;"))
  assert_false(html.contains("<script>alert(1)</script>"))
  assert_eq(source_format("raw/main.mbt"), "moonbit")
  assert_eq(source_format("raw/main.py"), "python")
  assert_eq(source_format("raw/component.tsx"), "tsx")
  assert_eq(source_format("raw/component.vue"), "vue")
  assert_eq(source_format("raw/page.html"), "html")
  assert_eq(source_format("raw/paper.pdf"), "binary")
  assert_eq(image_mime("raw/PHOTO.PNG"), "image/png")
  assert_eq(image_mime("raw/PHOTO.GIF"), "image/gif")
  let runtime = render(default_view(), [], [], "hash")
  assert_true(runtime.contains("tsx:'typescript'"))
  assert_true(runtime.contains("vue:'xml'"))
}

test "declared view features change generated controls and runtime guards" {
  let view = default_view()
  let html = render({ ..view, features: ["routing"] }, [], [], "hash")
  assert_false(html.contains("id='query'"))
  assert_true(html.contains("\"features\":[\"routing\"]"))
  assert_true(html.contains("const searchable = features.has('search')"))
  assert_true(html.contains("if (!richRendering) return"))
}

test "rendered wikilinks preserve heading fragments across routes" {
  let target : @core.Entry = { id: "concepts/target", path: "wiki/target.md", kind: "concept", format: "markdown", sha256: "a".repeat(64), sources: ["raw/a.md"], stale: false }
  let source : @core.Entry = { id: "concepts/source", path: "wiki/source.md", kind: "concept", format: "markdown", sha256: "b".repeat(64), sources: ["raw/a.md"], stale: false }
  let source_page : @core.Page = { title: "Source", kind: "concept", sources: ["raw/a.md"], tags: [], body: "[[concepts/target#核心概念|跳转]]", links: [target.id] }
  let target_page : @core.Page = { title: "Target", kind: "concept", sources: ["raw/a.md"], tags: [], body: "# 核心概念\n正文", links: [] }
  let html = render(default_view(), [{ entry: source, page: source_page }, { entry: target, page: target_page }], [], "hash")
  assert_true(html.contains("function headingSlug"))
  assert_true(html.contains("wikilinkHref"))
  assert_true(html.contains("function localFragment"))
  assert_true(html.contains("target.anchor+(fragment ? '--'+encodeURIComponent(headingSlug(fragment)) : '')"))
  assert_true(html.contains("function routeParts"))
  assert_true(html.contains("id+'--'+route.fragment"))
  assert_true(html.contains("startsWith('#'+x.anchor+'--')"))
  assert_true(html.contains("核心概念"))
}

test "dynamic data panels are derived from the snapshot" {
  let source : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: "a".repeat(64), sources: [], stale: false }
  let entry : @core.Entry = { id: "concepts/a", path: "wiki/a.md", kind: "concept", format: "markdown", sha256: "b".repeat(64), sources: [source.id], stale: false }
  let second_entry : @core.Entry = { id: "concepts/b", path: "wiki/b.md", kind: "concept", format: "markdown", sha256: "c".repeat(64), sources: [source.id], stale: false }
  let page : @core.Page = { title: "A", kind: "concept", sources: [source.id], tags: [], body: "body", links: ["concepts/b"] }
  let second_page : @core.Page = { title: "B", kind: "concept", sources: [source.id], tags: [], body: "body", links: [] }
  let view = { ..default_view(), panels: ["catalog", "page", "graph", "insights", "sources"] }
  let html = render(view, [{ entry, page }, { entry: second_entry, page: second_page }], [{ id: source.id, path: source.path, sha256: source.sha256, text: "source", format: "markdown", image: "" }], "hash")
  assert_true(html.contains("GRAPH / 知识关系"))
  assert_true(html.contains("INSIGHTS / 快照洞察"))
  assert_true(html.contains("关系</dt>"))
  assert_true(html.contains("互链"))
  assert_true(html.contains("共同来源"))
}

test "snapshot graph map is deterministic, escaped and routable" {
  let entry : @core.Entry = { id: "concepts/a", path: "wiki/a.md", kind: "concept", format: "markdown", sha256: "a".repeat(64), sources: ["raw/a.md"], stale: false }
  let second_entry : @core.Entry = { id: "concepts/b", path: "wiki/b.md", kind: "concept", format: "markdown", sha256: "b".repeat(64), sources: ["raw/a.md"], stale: false }
  let third_entry : @core.Entry = { id: "concepts/c", path: "wiki/c.md", kind: "concept", format: "markdown", sha256: "c".repeat(64), sources: ["raw/a.md"], stale: false }
  let page : @core.Page = { title: "<img src=x onerror=alert(1)>", kind: "concept", sources: ["raw/a.md"], tags: [], body: "body", links: ["concepts/b"] }
  let second_page : @core.Page = { title: "B", kind: "concept", sources: ["raw/a.md"], tags: [], body: "body", links: [] }
  let third_page : @core.Page = { title: "C", kind: "concept", sources: ["raw/a.md"], tags: [], body: "body", links: [] }
  let view = { ..default_view(), panels: ["catalog", "page", "graph", "sources"] }
  let readings = [{ entry, page }, { entry: second_entry, page: second_page }, { entry: third_entry, page: third_page }]
  let html = render(view, readings, [], "hash")
  assert_true(html.contains("<svg class='graph-map'"))
  assert_true(html.contains("知识关系快照图"))
  assert_true(html.contains("class='graph-edge'"))
  assert_true(html.contains("<a href='#p-" + @base.hex_hash("concepts/b") + "'>"))
  assert_true(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
  assert_false(html.contains("<img src=x"))
  // a<->b have a wikilink, so only the a-c and b-c shared-source pairs are drawn.
  assert_true(html.contains("graph-shared"))
  assert_eq(html.split("graph-edge graph-shared").length() - 1, 2)
  assert_true(html.contains("实线：互链 · 虚线：共同来源"))
  let reversed = render(view, [readings[2], readings[1], readings[0]], [], "hash")
  assert_eq(graph_panel_slice(html), graph_panel_slice(reversed))
  let without_graph = render(default_view(), readings, [], "hash")
  assert_false(without_graph.contains("<svg class='graph-map'"))
}

fn graph_panel_slice(html : String) -> String {
  let open = html.find("<svg class='graph-map'").unwrap_or(0)
  let close = html[open:].find("</svg>").unwrap_or(6) + "</svg>".length()
  html[open:open + close].to_owned()
}
