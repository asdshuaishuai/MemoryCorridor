// The static baseline must produce byte-identical HTML for the same page
// bytes on every target, escape everything it interpolates, and resolve
// wikilinks only to pages that exist in the snapshot.

test "headings, paragraphs and thematic breaks" {
  assert_eq(render_markdown("# 标题\n\n正文段落。\n", []),
    "<h1>标题</h1><p>正文段落。</p>")
  assert_eq(render_markdown("## 二级\n\n###三级不解析\n\n***\n\ntail\n", []),
    "<h2>二级</h2><p>###三级不解析</p><hr><p>tail</p>")
}

test "fenced code stays verbatim and escapes HTML" {
  let html = render_markdown("```mbt check\nfn f() -> Int { 1 } <b>&</b>\n```\n", [])
  assert_eq(html, "<pre><code class=\"language-mbt\">fn f() -&gt; Int { 1 } &lt;b&gt;&amp;&lt;/b&gt;\n</code></pre>")
  // Unclosed fence keeps everything to EOF.
  // An unclosed fence absorbs everything to EOF, trailing blank included.
  assert_eq(render_markdown("~~~\nraw ~~ text\n", []),
    "<pre><code>raw ~~ text\n\n</code></pre>")
}

test "indented code and list blocks" {
  // Trailing blank lines belong to the indented block.
  assert_eq(render_markdown("正文：\n\n    indented\n\n之后\n", []),
    "<p>正文：</p><pre><code>indented\n\n</code></pre><p>之后</p>")
  assert_eq(render_markdown("- 甲\n- 乙\n\n1. one\n2. two\n", []),
    "<ul><li>甲</li><li>乙</li></ul><ol><li>one</li><li>two</li></ol>")
}

test "blockquote nests and inlines render inside" {
  assert_eq(render_markdown("> 引用 **强调**\n\nafter\n", []),
    "<blockquote><p>引用 <strong>强调</strong></p></blockquote><p>after</p>")
}

test "inline code spans suppress markup inside" {
  assert_eq(render_markdown("a `code **x**` b\n", []),
    "<p>a <code>code **x**</code> b</p>")
  // A backtick run without a closer stays literal.
  assert_eq(render_markdown("a `open b\n", []),
    "<p>a `open b</p>")
}

test "emphasis and strong with escaping of leftovers" {
  assert_eq(render_markdown("**bold** and *em*\n", []),
    "<p><strong>bold</strong> and <em>em</em></p>")
  assert_eq(render_markdown("<script>alert(1)</script> & \"'\"\n", []),
    "<p>&lt;script&gt;alert(1)&lt;/script&gt; &amp; &quot;&#39;&quot;</p>")
  // Unpaired markers stay literal instead of disappearing.
  assert_eq(render_markdown("a ** b\n", []), "<p>a ** b</p>")
}

test "links whitelist schemes; javascript: falls back to text" {
  assert_eq(render_markdown("[站点](https://example.com/a?b=1&c=2)\n", []),
    "<p><a href=\"https://example.com/a?b=1&amp;c=2\">站点</a></p>")
  // A refused scheme degrades to literal text (still escaped).
  assert_eq(render_markdown("[x](javascript:alert(1))\n", []),
    "<p>[x](javascript:alert(1))</p>")
  assert_eq(render_markdown("[相对](wiki/页面.md)\n", []),
    "<p><a href=\"wiki/页面.md\">相对</a></p>")
  assert_eq(render_markdown("![图](data:image/png;base64,AQID)\n", []),
    "<p><img src=\"data:image/png;base64,AQID\" alt=\"图\"></p>")
}

test "wikilinks resolve only to snapshot pages" {
  let html = render_markdown("见 [[concepts/能量|能量页]] 与 [[missing/页]]。\n", ["concepts/能量"])
  assert_eq(html, "<p>见 <a href='#p-" + @base.hex_hash("concepts/能量") + "'>能量页</a> 与 [[missing/页]]。</p>")
  // The anchor matches the reading article id the renderer emits.
  assert_true(html.contains("p-" + @base.hex_hash("concepts/能量")))
}

test "backslash escapes protect syntax characters" {
  assert_eq(render_markdown("\\*not em\\* and \\[not a link\\]\n", []),
    "<p>*not em* and [not a link]</p>")
}

test "determinism: same bytes, same html" {
  let body = "# 甲\n\n- **要点** `code`\n\n> 引 [[concepts/能量]]\n"
  assert_eq(render_markdown(body, ["concepts/能量"]), render_markdown(body, ["concepts/能量"]))
}

test "fence mask drives atomic code regions" {
  let lines = "text\n\n```\na\n\nb\n```\n\ntail".split("\n").map(x => x.to_owned()).to_array()
  let mask = @core.code_line_mask(lines)
  assert_true(mask[2] && mask[3] && mask[4] && mask[5] && mask[6])
  assert_true(!mask[0] && !mask[1] && !mask[7] && !mask[8])
}
