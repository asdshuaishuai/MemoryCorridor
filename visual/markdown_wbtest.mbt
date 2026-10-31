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

test "astral characters survive the inline path" {
  // 😀 (U+1F600) and 𠮷 (U+20BB7) are two UTF-16 units; slicing one unit at
  // a time used to orphan the surrogates and drop them from every inline.
  assert_eq(render_markdown("😀\n", []), "<p>😀</p>")
  assert_eq(render_markdown("*a😀b*\n", []), "<p><em>a😀b</em></p>")
  assert_eq(render_markdown("😀**加粗**😀\n", []), "<p>😀<strong>加粗</strong>😀</p>")
  assert_eq(render_markdown("- 😀\n", []), "<ul><li>😀</li></ul>")
  assert_eq(render_markdown("# 😀\n", []), "<h1>😀</h1>")
  assert_eq(render_markdown("𠮷野家\n", []), "<p>𠮷野家</p>")
}

test "emphasis honors CommonMark flanking rules" {
  // Word-internal underscores never pair; "_ a_" cannot open or close.
  assert_eq(render_markdown("foo_bar_baz\n", []), "<p>foo_bar_baz</p>")
  assert_eq(render_markdown("_ a_\n", []), "<p>_ a_</p>")
  assert_eq(render_markdown("*x*\n", []), "<p><em>x</em></p>")
}

test "delimiter runs nest strong and emphasis" {
  assert_eq(render_markdown("***a***\n", []), "<p><em><strong>a</strong></em></p>")
  assert_eq(render_markdown("*a **b** c*\n", []), "<p><em>a <strong>b</strong> c</em></p>")
  assert_eq(render_markdown("**a *b* c**\n", []), "<p><strong>a <em>b</em> c</strong></p>")
}

test "whitespace-only lines never open indented code" {
  assert_eq(render_markdown("    \n", []), "")
  assert_eq(render_markdown("\t\n", []), "")
  assert_eq(render_markdown("   \n", []), "")
  assert_eq(render_markdown("text\n    \nmore\n", []), "<p>text</p><p>more</p>")
  assert_eq(@core.code_line_mask(["    ", ""]), [false, false])
}

test "a pending indented-code latch does not survive a fence" {
  let lines = ["    a", "```", "x", "```", "", "    b"]
  assert_eq(@core.code_line_mask(lines), [true, true, true, true, false, true])
  // The masked region interleaves indented code and the fence in order.
  assert_eq(render_markdown("    a\n```\nx\n```\n\n    b\n", []),
    "<pre><code>a\n</code></pre><pre><code>x\n</code></pre><pre><code>b\n\n</code></pre>")
}

test "backtick fence info string containing a backtick is not a fence" {
  // Shared core/visual classification: the line stays paragraph text.
  assert_eq(@core.code_line_mask(["``` a`b", "prose after", "more prose"]), [false, false, false])
  assert_eq(render_markdown("```a`b\ncode\n```\n", []),
    "<p>```a`b\ncode</p><pre><code>\n</code></pre>")
  // Tilde fences may keep backticks in their info string.
  assert_eq(@core.code_line_mask(["~~~ a`b", "prose", "~~~"]), [true, true, true])
}

test "nested lists stay inside their item" {
  assert_eq(render_markdown("- a\n  - b\n- c\n", []),
    "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>")
  assert_eq(render_markdown("- a\n      code\n", []),
    "<ul><li>a<pre><code>code\n\n</code></pre></li></ul>")
}

test "ordered lists keep their start number" {
  assert_eq(render_markdown("3. one\n4. two\n", []),
    "<ol start=\"3\"><li>one</li><li>two</li></ol>")
  assert_eq(render_markdown("1. one\n2. two\n", []),
    "<ol><li>one</li><li>two</li></ol>")
}

test "setext underlines turn paragraphs into headings" {
  assert_eq(render_markdown("标题\n===\n", []), "<h1>标题</h1>")
  assert_eq(render_markdown("标题\n---\n", []), "<h2>标题</h2>")
  // A standalone --- stays a thematic break.
  assert_eq(render_markdown("---\n", []), "<hr>")
}

test "ATX closing sequences are stripped" {
  assert_eq(render_markdown("# 标题 #\n", []), "<h1>标题</h1>")
  assert_eq(render_markdown("## 标题 ###\n", []), "<h2>标题</h2>")
  // A # glued to the text is not a closing sequence.
  assert_eq(render_markdown("# 标题#\n", []), "<h1>标题#</h1>")
}

test "fence language keeps the first info word, non-ASCII included" {
  assert_eq(render_markdown("``` rust\nx\n```\n", []),
    "<pre><code class=\"language-rust\">x\n</code></pre>")
  assert_eq(render_markdown("```😀\nx\n```\n", []),
    "<pre><code class=\"language-😀\">x\n</code></pre>")
}

test "link titles split off the destination" {
  assert_eq(render_markdown("[t](https://e.example \"标题\")\n", []),
    "<p><a href=\"https://e.example\" title=\"标题\">t</a></p>")
  assert_eq(render_markdown("[t](https://e.example '标题')\n", []),
    "<p><a href=\"https://e.example\" title=\"标题\">t</a></p>")
  assert_eq(render_markdown("[t](https://e.example (标题))\n", []),
    "<p><a href=\"https://e.example\" title=\"标题\">t</a></p>")
  // No title: unchanged behavior.
  assert_eq(render_markdown("[t](https://e.example)\n", []),
    "<p><a href=\"https://e.example\">t</a></p>")
}

test "link labels never nest another anchor" {
  // The inner link wins; the outer construct degrades to literal text.
  assert_eq(render_markdown("[x [y](u2)](https://e.example)\n", []),
    "<p>[x <a href=\"u2\">y</a>](https://e.example)</p>")
}

test "reference links resolve via definitions and stay literal without" {
  assert_eq(render_markdown("[a][b]\n", []), "<p>[a][b]</p>")
  assert_eq(render_markdown("[a][b]\n\n[b]: https://x.example\n", []),
    "<p><a href=\"https://x.example\">a</a></p>")
}
