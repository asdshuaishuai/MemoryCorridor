test "frontmatter subset and wikilink code exclusion" {
  let page = parse_page("---\ntype: concept\ntitle: 知识\nsources:\n  - raw/a.md\ntags: [\"中文\"]\n---\n[[concepts/b|别名]]\n```mbt\n[[ignored]]\n```\n`[[also-ignored]]`\n")
  assert_eq(page.sources, ["raw/a.md"])
  assert_eq(page.links, ["concepts/b"])
  assert_eq(page.tags, ["中文"])
}

test "mask rejects backtick fences whose info string has a backtick" {
  // CommonMark: the info string after a backtick fence may not contain
  // backticks, so the line stays text and cannot swallow later prose.
  assert_eq(code_line_mask(["``` a`b", "prose after", "more prose"]), [false, false, false])
  // Tilde fences may keep backticks in their info string.
  assert_eq(code_line_mask(["~~~ a`b", "prose", "~~~"]), [true, true, true])
  // Wikilink scanning shares the mask and sees past such a line.
  assert_eq(wikilinks("``` a`b\n[[concepts/real]]\nmore prose"), ["concepts/real"])
}

test "mask never opens indented code on a whitespace-only line" {
  assert_eq(code_line_mask(["    ", ""]), [false, false])
  assert_eq(code_line_mask(["\t", "text"]), [false, false])
  // Interior blanks of a real block still belong to it.
  assert_eq(code_line_mask(["    code", "", "    more", "", "text"]),
    [true, true, true, true, false])
}

test "mask clears the indented-code latch when a fence opens" {
  assert_eq(code_line_mask(["    a", "```", "x", "```", "", "    b"]),
    [true, true, true, true, false, true])
}

test "wikilink anchors validate and keep page-only dependencies" {
  let page = parse_page("---\ntype: concept\ntitle: 锚点\nsources: [\"raw/a.md\"]\n---\n[[concepts/b#核心概念|跳转]] [[concepts/b#中文 标题]]\n```mbt\n[[concepts/ignored#标题]]\n```")
  assert_eq(page.links, ["concepts/b"])
  for bad in [
    "[[concepts/b#]]",
    "[[concepts/b#   ]]",
    "[[concepts/b#one#two]]",
    "[[#标题]]",
  ] {
    assert_true(try { ignore(parse_page("---\ntype: concept\ntitle: 非法\nsources: [\"raw/a.md\"]\n---\n" + bad)); false } catch { _ => true })
  }
}

test "wikilink parser respects multi-backtick code spans" {
  let page = parse_page("---\ntype: concept\ntitle: 代码\nsources: [\"raw/a.md\"]\n---\n``[[ignored-double]]``\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser does not close a span on a shorter backtick run" {
  let page = parse_page("---\ntype: concept\ntitle: 代码\nsources: [\"raw/a.md\"]\n---\nprefix ```before `` [[ignored]] ``` after\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser respects fenced marker length and indentation" {
  let page = parse_page("---\ntype: concept\ntitle: 围栏\nsources: [\"raw/a.md\"]\n---\n````mbt\n[[ignored-short-close]]\n```\n[[ignored-inside]]\n````\n    ~~~\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser ignores indented code blocks across blank lines" {
  let page = parse_page("---\ntype: concept\ntitle: 缩进代码\nsources: [\"raw/a.md\"]\n---\n    [[ignored-indented]]\n\n    [[also-ignored]]\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser keeps inline code spans across lines" {
  let page = parse_page("---\ntype: concept\ntitle: 跨行代码\nsources: [\"raw/a.md\"]\n---\n``\n[[ignored-across-lines]]\n``\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser keeps inline code spans across blank lines" {
  let page = parse_page("---\ntype: concept\ntitle: 空行代码\nsources: [\"raw/a.md\"]\n---\n`\n\n[[ignored-across-blank]]\n`\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser honors backslash escaping" {
  let page = parse_page("---\ntype: concept\ntitle: 转义\nsources: [\"raw/a.md\"]\n---\n\\[[ignored-escaped]]\n\\\\[[concepts/even-slashes]]\n")
  assert_eq(page.links, ["concepts/even-slashes"])
}

test "wikilink parser does not leak an unmatched code span across paragraphs" {
  let page = parse_page("---\ntype: concept\ntitle: 未闭合代码\nsources: [\"raw/a.md\"]\n---\n` unmatched\n[[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "wikilink parser ignores escaped code delimiters" {
  let page = parse_page("---\ntype: concept\ntitle: 转义反引号\nsources: [\"raw/a.md\"]\n---\n\\` [[concepts/first]] ` [[concepts/second]]\n")
  assert_eq(page.links, ["concepts/first", "concepts/second"])
}

test "wikilink parser does not use escaped backticks as closers" {
  let page = parse_page("---\ntype: concept\ntitle: 转义闭合\nsources: [\"raw/a.md\"]\n---\n` \\` [[concepts/real]]\n")
  assert_eq(page.links, ["concepts/real"])
}

test "page rejects unsupported frontmatter and alias does not resolve target" {
  let text = "---\ntype: concept\ntitle: A\nsources: [\"raw/a.md\"]\n---\n[[missing|待建]]"
  let raw : Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  let page : Entry = { id: "concepts/a", path: "wiki/a.md", kind: "concept", format: "markdown", sha256: @base.hex_hash(text), sources: [raw.id], stale: false }
  assert_true(try { ignore(validate_page(page, text, [raw, page])); false } catch { _ => true })
  assert_true(try { ignore(parse_page(text.replace(old="title: A", new="title: A\ntitle: B"))); false } catch { _ => true })
}

test "frontmatter accepts standard YAML single quoted scalars and arrays" {
  let page = parse_page("---\ntype: 'concept'\ntitle: 'O''Reilly #1'\nsources: ['raw/a.md']\ntags: ['中文', 'two']\n---\n正文\n")
  assert_eq(page.kind, "concept")
  assert_eq(page.title, "O'Reilly #1")
  assert_eq(page.sources, ["raw/a.md"])
  assert_eq(page.tags, ["中文", "two"])
}

test "frontmatter accepts YAML comments and multiline title" {
  let page = parse_page("---\ntype: concept # stable kind\ntitle: |\n  多行\n  标题\nsources:\n  - raw/a.md # source\ntags: []\n---\n正文\n")
  assert_true(page.title.has_prefix("多行\n标题"))
  assert_eq(page.sources, ["raw/a.md"])
}

test "entry format is deterministic and validated by kind" {
  assert_eq(format_for_path("raw/readme.md"), "markdown")
  assert_eq(format_for_path("raw/README.MD"), "markdown")
  assert_eq(format_for_path("raw/page.html"), "html")
  assert_eq(format_for_path("raw/PAGE.HTML"), "html")
  assert_eq(format_for_path("raw/main.mbt"), "moonbit")
  assert_eq(format_for_path("raw/main.js"), "javascript")
  assert_eq(format_for_path("raw/component.tsx"), "tsx")
  assert_eq(format_for_path("raw/component.vue"), "vue")
  assert_eq(format_for_path("raw/main.py"), "python")
  assert_eq(format_for_path("raw/Dockerfile"), "dockerfile")
  assert_eq(format_for_path("raw/Makefile"), "makefile")
  assert_eq(format_for_path("raw/query.sql"), "sql")
  assert_eq(format_for_path("raw/service.ex"), "elixir")
  assert_eq(format_for_path("raw/module.hs"), "haskell")
  assert_eq(format_for_path("raw/config.toml"), "ini")
  assert_eq(format_for_path("raw/schema.proto"), "protobuf")
  assert_eq(format_for_path("raw/page.mdx"), "markdown")
  assert_eq(format_for_path("raw/photo.png"), "image")
  assert_eq(format_for_path("raw/PHOTO.PNG"), "image")
  assert_eq(format_for_path("raw/archive.pdf"), "binary")
  let hash = @base.hex_hash("body")
  let raw = { id: "raw/page.html", path: "raw/page.html", kind: "raw", format: "html", sha256: hash, sources: [], stale: false }
  validate_entries([raw])
  let wrong = { ..raw, format: "markdown" }
  assert_true(try { validate_entries([wrong]); false } catch { _ => true })
  let page = { id: "concepts/a", path: "wiki/a.md", kind: "concept", format: "markdown", sha256: hash, sources: [raw.id], stale: false }
  validate_entries([raw, page])
  let wrong_page = { ..page, format: "html" }
  assert_true(try { validate_entries([raw, wrong_page]); false } catch { _ => true })
  let legacy = entry_from_json({
    "id": "raw/old.md", "path": "raw/old.md", "kind": "raw",
    "sha256": hash, "sources": [], "stale": false,
  })
  assert_eq(legacy.format, "markdown")
}

test "source deletion event is content addressed and rejects forged identity" {
  let source = "raw/a.md"
  let source_hash = @base.hex_hash("source")
  let path = "state/events/source-missing-" + @base.hex_hash(source + "\n" + source_hash) + ".json"
  let text = @base.canonical({ "op": "source-missing", "source": source, "source_hash": source_hash })
  let entry : Entry = { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(text), sources: [], stale: false }
  validate_record(entry, text)
  let forged = @base.canonical({ "op": "source-missing", "source": source, "source_hash": "0".repeat(64) })
  assert_true(try { validate_record({ ..entry, sha256: @base.hex_hash(forged) }, forged); false } catch { _ => true })
}
