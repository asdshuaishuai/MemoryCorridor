fn candidate(id : String, body : String, origin? : String = "retrieval") -> ContextPage {
  let source = "raw/" + id + ".md"
  let entry : @core.Entry = { id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(id + "\n" + body), sources: [source], stale: false }
  { entry, page: { title: id, kind: "concept", sources: [source], tags: [], body, links: [] }, origin }
}

fn number(value : Json, key : String) -> Int raise @base.Fault {
  match @base.field(value, key) {
    Number(n, ..) => n.to_int()
    _ => raise @base.Fault("expected_number")
  }
}

// Reconstruct from original Unicode scalars; this independently checks that
// reported byte offsets cannot point into a multibyte scalar.
fn byte_range(body : String, start : Int, end : Int) -> String raise {
  let parts : Array[String] = []
  let mut offset = 0
  let mut start_seen = start == 0
  let mut end_seen = end == 0
  for c in body {
    let text = c.to_string()
    let next = offset + @base.utf8_size(text)
    if offset >= start && next <= end { parts.push(text) }
    offset = next
    if offset == start { start_seen = true }
    if offset == end { end_seen = true }
  }
  assert_true(start_seen && end_seen)
  parts.join("")
}

test "query evidence beyond a long introduction and within a long paragraph" {
  let body = "背景😀\n".repeat(200) + "\n\n证据：MoonBit supports exact provenance.\n\n尾注".repeat(10)
  let selected = excerpt(body, "MoonBit provenance", 100)
  assert_true(selected.text.contains("MoonBit"))
  assert_true(selected.text.contains("provenance"))
  assert_eq(byte_range(body, selected.start_byte, selected.end_byte), selected.text)
  let paragraph = "😀无关内容 ".repeat(200) + "TARGET evidence marker " + "其他内容 ".repeat(200)
  let found = excerpt(paragraph, "target", 90)
  assert_true(found.text.contains("TARGET"))
  assert_eq(byte_range(paragraph, found.start_byte, found.end_byte), found.text)
  assert_true(@base.utf8_size(found.text) <= 90)
  assert_eq(excerpt("😀文abc", "missing", 4).text, "😀")
  assert_eq(excerpt("😀文abc", "", 3).text, "")
  assert_eq(excerpt("small", "", 100).text, "small")
  assert_eq(excerpt("small", "small", 0).text, "")
}

test "paragraph coverage, deterministic ties and keyword hit excerpt share the selector" {
  let body = "alpha " + "intro ".repeat(100) + "\n\nbeta alpha confirmed.\n\nalpha beta later."
  let selected = excerpt(body, "beta alpha alpha", 30)
  assert_true(selected.text.has_prefix("beta alpha confirmed."))
  for _ in 0..<10 { assert_eq(excerpt(body, "alpha beta", 30).text, selected.text) }
  let docs : Array[Document] = [{ id: "a", title: "a", body, title_terms: tokens("a"), body_terms: tokens(body) }]
  assert_true(search(docs, "beta")[0].excerpt.contains("confirmed"))
  let emoji = "a".repeat(359) + "😀"
  assert_eq(excerpt(emoji, "", 360).text, "a".repeat(359))
}

test "long ranked pages share the budget and only exact bodies merge with full provenance" {
  let first = candidate("a", "needle alpha ".repeat(200))
  let second = candidate("b", "needle beta ".repeat(200))
  let duplicate = candidate("alias", first.page.body, origin="graph")
  let result = assemble_context([first, duplicate, second], "needle", 300)
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 2)
  assert_eq(@base.field(blocks[0], "id"), "a".to_json())
  assert_eq(@base.field(blocks[1], "id"), "b".to_json())
  assert_true(@base.utf8_size(@base.text(@base.field(blocks[0], "text"))) <= 150)
  assert_eq(@base.array(@base.field(blocks[0], "duplicates")), [reference(duplicate)])
  assert_true(@base.array(@base.field(blocks[1], "duplicates")).is_empty())
  let mut block_estimate = 0
  for block in blocks { block_estimate = block_estimate + number(block, "estimated_tokens") }
  assert_eq(number(result, "estimated_tokens"), block_estimate)
  assert_true(block_estimate > 0)
  assert_eq(@base.text(@base.field(result, "estimate_recipe")), "cjk_char_latin_word_v1")
  assert_eq(@base.field(result, "truncated"), true.to_json())
  let small = candidate("small", "needle")
  let reclaimed = @base.array(@base.field(assemble_context([small, second], "needle", 300), "blocks"))
  assert_true(@base.utf8_size(@base.text(@base.field(reclaimed[1], "text"))) > 150)
  let empty = assemble_context([], "needle", 300)
  assert_true(@base.array(@base.field(empty, "blocks")).is_empty())
  assert_eq(number(empty, "estimated_tokens"), 0)
  assert_eq(@base.field(empty, "truncated"), false.to_json())
}

test "partially repeated paragraphs are omitted from later context with byte provenance" {
  let first = candidate("first", "shared paragraph.\n\n独有甲证据")
  let second = candidate("second", "shared paragraph.\n\n独有乙证据", origin="graph")
  let result = assemble_context([first, second], "独有", 512)
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 2)
  assert_true(!@base.text(@base.field(blocks[1], "text")).contains("shared paragraph"))
  let rows = @base.array(@base.field(result, "paragraph_duplicates"))
  assert_eq(rows.length(), 1)
  assert_eq(@base.field(rows[0], "owner"), "first".to_json())
  let refs = @base.array(@base.field(rows[0], "duplicates"))
  assert_eq(@base.field(refs[0], "id"), "second".to_json())
  assert_eq(@base.field(refs[0], "paragraph_start"), Json::number(0.0))
  assert_eq(@base.field(refs[0], "paragraph_end"), Json::number(17.0))
}

test "all small budgets preserve byte accounting, citations and reconstructable ranges" {
  let pages = [candidate("甲😀", "前言😀".repeat(30) + "\n\n关键证据𠀀abc".repeat(20)),
    candidate("乙", "关键证据😀 xyz ".repeat(30), origin="graph")]
  for budget = 1; budget <= 400; budget = budget + 1 {
    let result = assemble_context(pages, "关键证据", budget)
    let blocks = @base.array(@base.field(result, "blocks"))
    let mut actual = 0
    for block in blocks {
      let id = @base.text(@base.field(block, "id"))
      let page = pages.iter().find_first(p => p.entry.id == id).unwrap()
      let start = number(block, "body_start")
      let end = number(block, "body_end")
      let text = @base.text(@base.field(block, "text"))
      assert_eq(text, "[" + id + "] " + page.page.title + "\n" + byte_range(page.page.body, start, end))
      actual = actual + @base.utf8_size(text)
    }
    assert_eq(number(result, "used"), actual)
    assert_true(actual <= budget)
  }
}

// The calibration corpus (scripts/similarity_calibration.py) pinned to the
// shipped gates: token-sequence identity plus the byte gate decide merges.
test "similar dedup merges formatting variants only above the byte gate" {
  assert_eq(SIMILAR_BYTE_GATE, 64)
  let a = "the quick brown fox jumps over the lazy dog and rests near the river tonight"
  let b = a
  assert_true(similar_merge(similar_tokens(a), similar_tokens(b)))
  let cased = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG AND RESTS NEAR THE RIVER TONIGHT"
  assert_true(similar_merge(similar_tokens(a), similar_tokens(cased)))
  let punctuated = "the quick brown fox jumps over the lazy dog and rests near the river tonight."
  assert_true(similar_merge(similar_tokens(a), similar_tokens(punctuated)))
  let reordered = "the lazy dog near the river bank tonight the quick brown fox jumps over"
  assert_true(!similar_merge(similar_tokens(a), similar_tokens(reordered)))
  let swapped = "the quick brown fox jumps over the lazy dog and rests near the river tomorrow"
  assert_true(!similar_merge(similar_tokens(a), similar_tokens(swapped)))
  assert_true(!similar_merge(similar_tokens("alpha"), similar_tokens("beta")))
  let cjk = "根据资料，实验组在第三天显示出标记物的显著上升，对照组保持基线，需要复核。"
  let cjk_changed = "根据资料，实验组在第三天显示出标记物的显著下降，对照组保持基线，需要复核。"
  assert_true(!similar_merge(similar_tokens(cjk), similar_tokens(cjk_changed)))
  let cjk_wrapped = "根据资料，实验组在第三天显示出标记物的显著上升，\n对照组保持基线，需要复核。"
  assert_true(similar_merge(similar_tokens(cjk), similar_tokens(cjk_wrapped)))
  let digits = "该药物在 3 期实验中有效率为 62%，副作用发生率为 5%，覆盖多中心样本。"
  let digits_changed = "该药物在 3 期实验中有效率为 63%，副作用发生率为 5%，覆盖多中心样本。"
  assert_true(!similar_merge(similar_tokens(digits), similar_tokens(digits_changed)))
}

test "similar mode keeps exact-mode defaults byte-identical until opted in" {
  let first = candidate("a", "needle alpha ".repeat(200))
  let second = candidate("b", "needle beta ".repeat(200))
  let twin = candidate("twin", first.page.body, origin="graph")
  let exact = assemble_context([first, twin, second], "needle", 300)
  let similar = assemble_context([first, twin, second], "needle", 300, dedup="similar")
  assert_eq(@base.field(exact, "strategy"), "ranked_halves_exact_body_paragraph_v1".to_json())
  assert_eq(@base.field(similar, "strategy"), "similar_body_paragraph_ranked_v2".to_json())
  let exact_blocks = @base.array(@base.field(exact, "blocks"))
  let similar_blocks = @base.array(@base.field(similar, "blocks"))
  for i = 0; i < exact_blocks.length(); i = i + 1 {
    assert_eq(@base.field(exact_blocks[i], "id"), @base.field(similar_blocks[i], "id"))
    assert_eq(@base.field(exact_blocks[i], "text"), @base.field(similar_blocks[i], "text"))
    assert_eq(@base.field(exact_blocks[i], "duplicates"), @base.field(similar_blocks[i], "duplicates"))
  }
  assert_true(@base.array(@base.field(exact, "similar_duplicates")).is_empty())
  let rows = @base.array(@base.field(similar, "similar_duplicates"))
  assert_eq(rows.length(), 1)
  assert_eq(@base.field(rows[0], "owner"), "a".to_json())
  let refs = @base.array(@base.field(rows[0], "duplicates"))
  assert_eq(@base.field(refs[0], "id"), "twin".to_json())
  assert_eq(@base.field(refs[0], "similarity"), Json::number(1.0))
}

test "similar mode merges a wrapped whole body and keeps distinct evidence separate" {
  let original = "实验组在第三天显示出标记物的显著上升，对照组保持基线，结论需要复核。"
  let wrapped = "实验组在第三天显示出标记物的显著上升，\n对照组保持基线，结论需要复核。"
  let distinct = "实验组在第三天显示出标记物的显著下降，对照组保持基线，结论需要复核。"
  let first = candidate("first", original)
  let copy = candidate("copy", wrapped, origin="graph")
  let other = candidate("other", distinct, origin="graph")
  let result = assemble_context([first, copy, other], "标记物", 2048, dedup="similar")
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 2)
  assert_eq(@base.field(blocks[0], "id"), "first".to_json())
  assert_eq(@base.field(blocks[1], "id"), "other".to_json())
  assert_true(!@base.text(@base.field(blocks[0], "text")).contains("显著下降"))
  let body_rows = @base.array(@base.field(result, "similar_duplicates"))
  assert_eq(body_rows.length(), 1)
  assert_eq(@base.field(body_rows[0], "owner"), "first".to_json())
  let body_refs = @base.array(@base.field(body_rows[0], "duplicates"))
  assert_eq(body_refs.length(), 1)
  assert_eq(@base.field(body_refs[0], "id"), "copy".to_json())
  assert_eq(@base.field(body_refs[0], "similarity"), Json::number(1.0))
  assert_true(@base.array(@base.field(result, "similar_paragraph_duplicates")).is_empty())
  let exact = assemble_context([first, copy, other], "标记物", 2048)
  let exact_blocks = @base.array(@base.field(exact, "blocks"))
  assert_eq(exact_blocks.length(), 3)
  assert_true(@base.array(@base.field(exact, "similar_duplicates")).is_empty())
}

test "similar paragraph dedup excludes merged paragraphs and keeps distinct bodies separate" {
  let original = "实验组在第三天显示出标记物的显著上升，对照组保持基线，结论需要复核。"
  let wrapped = "实验组在第三天显示出标记物的显著上升，\n对照组保持基线，结论需要复核。"
  let extra = "补充说明段落记录额外的实验批次与样本规模，确保正文整体不同。"
  let first = candidate("first", original + "\n\n独有甲证据段落")
  let copy = candidate("copy", wrapped + "\n\n" + extra + "\n\n独有乙证据段落", origin="graph")
  let result = assemble_context([first, copy], "标记物", 2048, dedup="similar")
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 2)
  assert_eq(@base.field(blocks[0], "id"), "first".to_json())
  assert_eq(@base.field(blocks[1], "id"), "copy".to_json())
  assert_true(!@base.text(@base.field(blocks[1], "text")).contains("显著上升"))
  assert_true(@base.text(@base.field(blocks[1], "text")).contains("独有乙证据段落") ||
    @base.text(@base.field(blocks[1], "text")).contains("补充说明"))
  assert_true(@base.array(@base.field(result, "similar_duplicates")).is_empty())
  let rows = @base.array(@base.field(result, "similar_paragraph_duplicates"))
  assert_eq(rows.length(), 1)
  assert_eq(@base.field(rows[0], "owner"), "first".to_json())
  let refs = @base.array(@base.field(rows[0], "duplicates"))
  assert_eq(@base.field(refs[0], "id"), "copy".to_json())
  assert_eq(@base.field(refs[0], "keeper_id"), "first".to_json())
  assert_eq(@base.field(refs[0], "paragraph_start"), Json::number(0.0))
  assert_eq(@base.field(refs[0], "paragraph_end"), Json::number(@base.utf8_size(wrapped).to_double()))
  let exact = assemble_context([first, copy], "标记物", 2048)
  let exact_blocks = @base.array(@base.field(exact, "blocks"))
  assert_true(@base.text(@base.field(exact_blocks[1], "text")).contains("显著上升"))
}

test "even spread divides the remaining budget across candidates" {
  let bodies = ["alpha " + "长内容😀 ".repeat(200), "alpha " + "另一内容😀 ".repeat(220),
    "alpha " + "更多内容😀 ".repeat(240)]
  let pages = [candidate("甲", bodies[0]), candidate("乙", bodies[1], origin="graph"),
    candidate("丙", bodies[2], origin="graph")]
  let ranked = assemble_context(pages, "alpha", 600)
  let even = assemble_context(pages, "alpha", 600, spread="even")
  assert_eq(@base.field(even, "strategy"), "exact_body_paragraph_even_v2".to_json())
  let ranked_blocks = @base.array(@base.field(ranked, "blocks"))
  let even_blocks = @base.array(@base.field(even, "blocks"))
  assert_eq(even_blocks.length(), 3)
  for i = 1; i < 3; i = i + 1 {
    let ranked_size = @base.utf8_size(@base.text(@base.field(ranked_blocks[i], "text")))
    let even_size = @base.utf8_size(@base.text(@base.field(even_blocks[i], "text")))
    assert_true(even_size > ranked_size)
  }
  assert_true(number(even, "used") <= 600)
  for budget = 1; budget <= 300; budget = budget + 1 {
    let result = assemble_context(pages, "alpha", budget, spread="even")
    let blocks = @base.array(@base.field(result, "blocks"))
    let mut actual = 0
    for block in blocks {
      let id = @base.text(@base.field(block, "id"))
      let page = pages.iter().find_first(p => p.entry.id == id).unwrap()
      let text = @base.text(@base.field(block, "text"))
      assert_eq(text, "[" + id + "] " + page.page.title + "\n" +
        byte_range(page.page.body, number(block, "body_start"), number(block, "body_end")))
      actual = actual + @base.utf8_size(text)
    }
    assert_eq(number(result, "used"), actual)
    assert_true(actual <= budget)
  }
}

// A blank line inside a fenced (or indented) code block must not split the
// block: dedup hashes, byte offsets and the excerpt window treat the whole
// block as one atomic paragraph slice.
test "code block with blank line stays one paragraph slice" {
  let body = "before\n\n```\nfirst\n\nthird\n```\n\nafter"
  let page = candidate("甲", body)
  let result = assemble_context([page], "before", 100000)
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 1)
  let text = @base.text(@base.field(blocks[0], "text"))
  assert_true(text.contains("```"))
  assert_true(text.contains("after"))
  // Byte offsets independently reconstruct the exact slice text.
  let start = number(blocks[0], "body_start")
  let end = number(blocks[0], "body_end")
  assert_eq(text, "[甲] 甲\n" + byte_range(page.page.body, start, end))
}

// Indented code behaves the same way, and the mask classifies every line.
test "indented code block and fence mask atomicity" {
  let body = "intro\n\n    line one\n\n    line two\n\noutro"
  let page = candidate("乙", body)
  let result = assemble_context([page], "intro", 100000)
  let blocks = @base.array(@base.field(result, "blocks"))
  assert_eq(blocks.length(), 1)
  let lines = body.split("\n").map(x => x.to_owned()).to_array()
  let mask = @core.code_line_mask(lines)
  assert_eq(mask.length(), lines.length())
  assert_true(mask[2] && mask[3] && mask[4])
  assert_true(!mask[0] && !mask[1] && !mask[6])
}
