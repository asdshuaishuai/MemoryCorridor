test "YAML unknown types and nested fields survive without inventing trust" {
  let raw = "---\r\ntype: CustomType\r\ntitle: Example\r\nextra:\r\n  nested: [1, true, null]\r\nverified:\r\n  by: person@example.org\r\nsources:\r\n  - resource: /assets/data.csv\r\n---\r\nbody\r\n"
  let doc = parse("nested/page.md", raw, "okf")
  assert_eq(doc.raw, raw)
  assert_eq(doc.body, "body\n")
  assert_eq(parse("nested/page.md", emit(doc.metadata, doc.body), "okf").metadata, doc.metadata)
  assert_eq(display_title(doc), "Example")
  assert_eq(tags(doc), [])
  assert_eq(parse("nested/index.md", "reserved", "okf").body, "reserved")
  assert_eq(parse("note.md", "ordinary markdown", "markdown").body, "ordinary markdown")
}

test "YAML input rejects ambiguous structure before native adaptation" {
  for text in ["body", "---\n- item\n---\nbody", "---\ntype: A\ntype: B\n---\n", "---\ntitle: no type\n---\n", "---\ntype: 42\n---\n", "---\ntype: X\n"] {
    let rejected = try { ignore(parse("page.md", text, "okf")); false } catch { _ => true }
    assert_true(rejected)
  }
}

test "bundle identity includes format, paths and binary content" {
  let a : File = { path: "a.md", data: @utf8.encode("---\ntype: New\n---\nA") }
  let b : File = { path: "asset.bin", data: Bytes::from_array([0,255,128]) }
  assert_eq(bundle("okf", [a,b]).id, bundle("okf", [b,a]).id)
  assert_true(bundle("markdown", [a,b]).id != bundle("okf", [a,b]).id)
  for files in [[a,a], [{ path: "../bad.md", data: a.data }], [{ path: "index.md", data: a.data }]] {
    let rejected = try { ignore(bundle("okf", files)); false } catch { _ => true }
    assert_true(rejected)
  }
}

test "standard links resolve relative, root and UTF8 paths and retain broken references" {
  let ids = Map([("tables/用户 表.md", "import/user"), ("topics/b.md", "import/b")])
  let doc = parse("topics/a.md", "[user](/tables/%E7%94%A8%E6%88%B7%20%E8%A1%A8.md) [b](./b.md) [missing](../missing.md)\n`[b](b.md)`\n```md\n[b](b.md)\n```\n[[unknown]]", "markdown")
  let (body, broken) = native_links(doc, ids)
  assert_true(body.contains("[[import/user|user]] [[import/b|b]] [missing](../missing.md)"))
  assert_true(body.contains("`[b](b.md)`"))
  assert_true(body.contains("```md\n[b](b.md)\n```"))
  assert_eq(broken, ["missing.md", "unknown"])
  let paths = Map([("import/user", "tables/用户 表.md"), ("import/b", "topics/b.md")])
  assert_true(okf_links(body, paths).contains("[user](/tables/%E7%94%A8%E6%88%B7%20%E8%A1%A8.md) [b](/topics/b.md)"))
}

test "interop preserves wikilink and standard-link heading fragments" {
  let ids = Map([("topics/b.md", "import/b"), ("tables/用户 表.md", "import/user")])
  let doc = parse("topics/a.md", "[user](/tables/%E7%94%A8%E6%88%B7%20%E8%A1%A8.md#事实) [[./b.md#核心|章节]]", "markdown")
  let (body, broken) = native_links(doc, ids)
  assert_eq(broken, [])
  assert_true(body.contains("[[import/user#事实|user]]"))
  assert_true(body.contains("[[import/b#核心|章节]]"))
  let paths = Map([("import/user", "tables/用户 表.md"), ("import/b", "topics/b.md")])
  let exported = okf_links(body, paths)
  assert_true(exported.contains("[user](/tables/%E7%94%A8%E6%88%B7%20%E8%A1%A8.md#%E4%BA%8B%E5%AE%9E)"))
  assert_true(exported.contains("[章节](/topics/b.md#%E6%A0%B8%E5%BF%83)"))
}
