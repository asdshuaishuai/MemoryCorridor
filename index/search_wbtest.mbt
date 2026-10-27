test "Chinese bigrams and title weighted ranking with deterministic ties" {
  assert_true(tokens("接口，VectorSearchBackend 负责检索。").contains("vectorsearchbackend"))
  assert_eq(tokens("Hello😀world，Test"), ["hello", "world", "test"])
  assert_true(tokens("光合作用").contains("光合"))
  let a : Document = { id: "a", title: "光合作用", body: "知识", title_terms: tokens("光合作用"), body_terms: tokens("知识") }
  let b : Document = { id: "b", title: "知识", body: "光合作用", title_terms: tokens("知识"), body_terms: tokens("光合作用") }
  let hits = search([b,a], "光合作用")
  assert_eq(hits[0].id, "a")
  assert_true(hits[0].score > hits[1].score)
  assert_eq(search([a,b], "无匹配").length(), 0)
  assert_eq(search([], "光合作用").length(), 0)
}

test "kana and Hangul index as unigrams and bigrams for substring recall" {
  let japanese = tokens("こんにちは世界")
  assert_true(japanese.contains("こ"))
  assert_true(japanese.contains("こん"))
  assert_true(japanese.contains("んに"))
  assert_true(japanese.contains("世界"))
  let korean = tokens("안녕하세요")
  assert_true(korean.contains("안"))
  assert_true(korean.contains("안녕"))
  assert_true(korean.contains("하세"))
  let mixed = tokens("食べる")
  assert_true(mixed.contains("食"))
  assert_true(mixed.contains("食べ"))
  assert_true(mixed.contains("べる"))
  let halfwidth = tokens("ｶﾀｶﾅ")
  assert_true(halfwidth.contains("ｶﾀ"))
  let doc : Document = { id: "jp", title: "日本語", body: "こんにちは世界",
    title_terms: tokens("日本語"), body_terms: tokens("こんにちは世界") }
  assert_eq(search([doc], "こんにち").length(), 1)
  let korean_doc : Document = { id: "kr", title: "한국어", body: "안녕하세요",
    title_terms: tokens("한국어"), body_terms: tokens("안녕하세요") }
  assert_eq(search([korean_doc], "안녕").length(), 1)
  assert_eq(search([doc], "さようなら").length(), 0)
}
