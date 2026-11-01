// Probes for the round-1 hunt fixes: link rewriting must share core's
// code-region classification, multi-segment wikilinks must not be silently
// truncated, and emitted metadata keys must survive the engine's own reader.

fn doc(path : String, body : String) -> Document {
  { path, metadata: Json::object(Map([])), body, raw: body }
}

fn import_ids() -> Map[String, String] {
  Map([("topics/b.md", "import/b"), ("b.md", "import/b")])
}

fn export_paths() -> Map[String, String] {
  Map([("import/b", "topics/b.md")])
}

test "indented code blocks keep link syntax in both directions" {
  let body = "段落\n\n    示例代码 [[b]] 保持原样\n\n之后 [[b]]\n"
  let (out, broken) = native_links(doc("topics/a.md", body), import_ids())
  assert_eq(out, "段落\n\n    示例代码 [[b]] 保持原样\n\n之后 [[import/b]]\n")
  assert_eq(broken, [])
  assert_eq(okf_links("段落\n\n    示例代码 [[import/b]] 保持原样\n\n之后 [[import/b]]\n", export_paths()),
    "段落\n\n    示例代码 [[import/b]] 保持原样\n\n之后 [import/b](/topics/b.md)\n")
}

test "fence handling matches the core scanner exactly" {
  // An indented ``` line is code, never a fence opener.
  assert_eq(okf_links("    ```\n[[import/b]]\n    ```\n之后 [[import/b]]\n", export_paths()),
    "    ```\n[import/b](/topics/b.md)\n    ```\n之后 [import/b](/topics/b.md)\n")
  // An info string containing backticks is ordinary text, not a fence.
  assert_eq(okf_links("``` ```\n[[import/b]]\n```\n", export_paths()),
    "``` ```\n[import/b](/topics/b.md)\n```\n")
  // Inline code pairs backtick runs, not single ticks.
  assert_eq(okf_links("`x`` [[import/b]]\n", export_paths()),
    "`x`` [import/b](/topics/b.md)\n")
  // A ``` line cannot close a longer ```` fence, so the tail stays code.
  assert_eq(okf_links("````\n[[import/b]]\n```\n之后 [[import/b]]\n", export_paths()),
    "````\n[[import/b]]\n```\n之后 [[import/b]]\n")
  // native_links shares the same classification (indented fence case).
  let (out, _) = native_links(doc("topics/a.md", "    ```\n[b](b.md)\n    ```\n之后 [b](b.md)\n"), import_ids())
  assert_eq(out, "    ```\n[[import/b|b]]\n    ```\n之后 [[import/b|b]]\n")
}

test "wikilinks with more than one pipe segment are never silently truncated" {
  // Import: preserve verbatim (escaped) and flag the target for review.
  let (out, broken) = native_links(doc("topics/a.md", "[[b|别名|尾段]]\n"), import_ids())
  assert_eq(out, "\\[\\[b|别名|尾段]]\n")
  assert_eq(broken, ["b"])
  // Export: no OKF equivalent exists, so the link is left intact.
  assert_eq(okf_links("[[import/b|别名|尾段]]\n", export_paths()), "[[import/b|别名|尾段]]\n")
  // Single-alias links keep converting.
  assert_eq(okf_links("[[import/b|别名]]\n", export_paths()), "[别名](/topics/b.md)\n")
  let (single, single_broken) = native_links(doc("topics/a.md", "[[b|别名]]\n"), import_ids())
  assert_eq(single, "[[import/b|别名]]\n")
  assert_eq(single_broken, [])
}

test "emitted metadata keys that the reader would split stay quoted" {
  let metadata : Json = { "type": "X", "a:b": "v1", "list,1": "v2", "arr[0]": "v3" }
  let text = emit(metadata, "b\n")
  // The keys the moonyaml reader would break on are written quoted.
  assert_true(text.contains("\"a:b\": v1"))
  assert_true(text.contains("\"arr[0]\": v3"))
  assert_true(text.contains("\"list,1\": v2"))
  // The engine imports its own export with every unknown field preserved.
  assert_eq(parse("page.md", text, "okf").metadata, metadata)
  // Nested mappings and sequence items get the same treatment, and literal
  // block content that merely looks like a key is left untouched.
  let nested : Json = { "type": "X", "outer": { "x:y": "1" }, "items": [{ "k[0]": "2" }], "note": "line\na:b: c\n" }
  let nested_text = emit(nested, "b\n")
  assert_eq(parse("page.md", nested_text, "okf").metadata, nested)
  // Sequence items that are themselves literal blocks stay verbatim too.
  let listed : Json = { "type": "X", "list": ["line\na:b: c\n", "plain"] }
  let listed_text = emit(listed, "b\n")
  assert_eq(parse("page.md", listed_text, "okf").metadata, listed)
  // Plain keys are emitted bare exactly as before.
  assert_eq(emit({ "type": "X" }, "b\n"), "---\ntype: X\n---\nb\n")
}
