// White-box tests for the semantic page-redundancy decision logic. The op's
// end-to-end flow (provider-register -> embedding-submit -> page-redundancy)
// is exercised by scripts/redundancy_e2e.py; here we pin the pairing rules
// directly so every signal, priority and guard is covered deterministically.

fn page(id : String, sources : Array[String]) -> @core.Entry {
  { id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown",
    sha256: "0".repeat(64), sources, stale: false }
}

// 28 CJK chars = 84 bytes, clears the 64-byte gate.
fn long() -> String { "龙泉窑青瓷以粉青与梅子青著称" + "釉料以石灰碱釉为基钾长石约占三成" }
fn other() -> String { "铁还原呈色含量约百分之一点五" + "哥窑以开片釉闻名紫口铁足辨识" }

fn space2() -> @index.VectorSpace { { id: "s1", dimensions: 2 } }

fn rec(pid : String, v : Array[Double]) -> @index.VectorRecord {
  { page: pid, sha256: "0".repeat(64), space: space2(), values: v }
}

fn str_map(pairs : Array[(String, String)]) -> Map[String, String] {
  let m : Map[String, String] = Map([])
  for pair in pairs { m[pair.0] = pair.1 }
  m
}

fn tok_map(pairs : Array[(String, String)]) -> Map[String, Array[String]] {
  let m : Map[String, Array[String]] = Map([])
  for pair in pairs { m[pair.0] = @index.similar_tokens(pair.1) }
  m
}

fn rec_map(pairs : Array[(String, @index.VectorRecord)]) -> Map[String, @index.VectorRecord] {
  let m : Map[String, @index.VectorRecord] = Map([])
  for pair in pairs { m[pair.0] = pair.1 }
  m
}

fn has(arr : Array[String], x : String) -> Bool { arr.iter().any(v => v == x) }

test "identical token sequences nominate similar_text" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let bodies = str_map([("concepts/a", long()), ("concepts/b", long() + "\n")])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", long() + "\n")])
  let vectors : Map[String, @index.VectorRecord] = Map([])
  match redundancy_pair(b, a, texts, bodies, vectors) {
    Some((reason, score, signals)) => {
      assert_eq(reason, "similar_text")
      assert_eq(score, 1.0)
      assert_true(has(signals, "similar_text"))
    }
    None => @base.fail("expected similar_text nomination")
  }
}

test "short bodies never merge on a coincidental token sequence" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let bodies = str_map([("concepts/a", "釉色"), ("concepts/b", "釉色")])
  let texts = tok_map([("concepts/a", "釉色"), ("concepts/b", "釉色")])
  let vectors : Map[String, @index.VectorRecord] = Map([])
  assert_true(redundancy_pair(b, a, texts, bodies, vectors) is None)
}

test "high vector cosine nominates vector_cosine with the real score" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let bodies = str_map([("concepts/a", long()), ("concepts/b", other())])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", other())])
  let vectors = rec_map([
    ("concepts/a", rec("concepts/a", [1.0, 0.0])),
    ("concepts/b", rec("concepts/b", [0.9, 0.1])),
  ])
  match redundancy_pair(b, a, texts, bodies, vectors) {
    Some((reason, score, signals)) => {
      assert_eq(reason, "vector_cosine")
      assert_true(score >= 0.92 && score <= 1.0)
      assert_true(has(signals, "vector_cosine"))
    }
    None => @base.fail("expected vector_cosine nomination")
  }
}

test "orthogonal vectors nominate nothing without a structural signal" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let bodies = str_map([("concepts/a", long()), ("concepts/b", other())])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", other())])
  let vectors = rec_map([
    ("concepts/a", rec("concepts/a", [1.0, 0.0])),
    ("concepts/b", rec("concepts/b", [0.0, 1.0])),
  ])
  assert_true(redundancy_pair(b, a, texts, bodies, vectors) is None)
}

test "shared source plus high term overlap nominates shared_source (weak)" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/x.md"]) // same source
  let bodies = str_map([("concepts/a", long()), ("concepts/b", long() + "梅子青")])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", long() + "梅子青")])
  let vectors : Map[String, @index.VectorRecord] = Map([])
  match redundancy_pair(b, a, texts, bodies, vectors) {
    Some((reason, _, _)) => assert_eq(reason, "shared_source")
    None => @base.fail("expected shared_source nomination")
  }
}

test "shared source with low term overlap does not nominate" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/x.md"])
  let unrelated = "完全不同的主题内容讲的是别的东西" + "与青瓷釉料工艺毫无关系啊"
  let bodies = str_map([("concepts/a", long()), ("concepts/b", unrelated)])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", unrelated)])
  let vectors : Map[String, @index.VectorRecord] = Map([])
  assert_true(redundancy_pair(b, a, texts, bodies, vectors) is None)
}

test "similar_text takes priority over vector_cosine" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let bodies = str_map([("concepts/a", long()), ("concepts/b", long())])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", long())])
  let vectors = rec_map([
    ("concepts/a", rec("concepts/a", [1.0, 0.0])),
    ("concepts/b", rec("concepts/b", [0.9, 0.1])),
  ])
  match redundancy_pair(b, a, texts, bodies, vectors) {
    Some((reason, _, signals)) => {
      assert_eq(reason, "similar_text")
      assert_true(has(signals, "similar_text") && has(signals, "vector_cosine"))
    }
    None => @base.fail("expected nomination")
  }
}

test "find_keeper files a page under the first matching keeper by id order" {
  let a = page("concepts/a", ["raw/x.md"])
  let b = page("concepts/b", ["raw/y.md"])
  let c = page("concepts/c", ["raw/z.md"])
  let unrelated = "无关主题完全不同的内容绝不该合并进" + "来这是另一回事了"
  let bodies = str_map([("concepts/a", long()), ("concepts/b", long()), ("concepts/c", unrelated)])
  let texts = tok_map([("concepts/a", long()), ("concepts/b", long()), ("concepts/c", unrelated)])
  let vectors : Map[String, @index.VectorRecord] = Map([])
  match find_keeper(b, [a], texts, bodies, vectors) {
    Some((keeper, reason, _, _)) => { assert_eq(keeper, "concepts/a"); assert_eq(reason, "similar_text") }
    None => @base.fail("b should file under a")
  }
  assert_true(find_keeper(c, [a, b], texts, bodies, vectors) is None)
}

test "term_overlap is the shorter page's distinct-token coverage" {
  assert_true(term_overlap(long(), "龙泉窑青瓷以粉青") >= 0.99)
  let unrelated = "完全不同毫不相关的主题内容讲的是" + "别的东西与青瓷釉料工艺无关"
  assert_true(term_overlap(long(), unrelated) < 0.5)
}
