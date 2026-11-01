// The literal reader must accept exactly the formatting moon accepts for the
// closed subset, decode MoonBit string escapes faithfully, and refuse what is
// not a literal with a message the catalog/view parsers can surface.

fn described(code : String) -> Array[String] raise {
  literal_tokens(code).map(t => t.describe())
}

test "tokens skip whitespace and line comments and split punctuation" {
  assert_eq(described("pub(all) struct X { // 说明\n  id : String\n}\n"),
    ["`pub`", "`(`", "`all`", "`)`", "`struct`", "`X`", "`{`", "`id`", "`:`", "`String`", "`}`"])
  assert_eq(described("  a\t,\r\n b "), ["`a`", "`,`", "`b`"])
}

test "strings decode MoonBit escapes including braces and surrogate pairs" {
  fn only(code : String) -> String raise {
    match literal_tokens(code) {
      [Str(value)] => value
      _ => { fail("expected one string token"); "" }
    }
  }
  assert_eq(only("\"a\\nb\""), "a\nb")
  assert_eq(only("\"\\u{1F600}\""), "😀")
  assert_eq(only("\"\\u00e9\\u{e9}\""), "éé")
  assert_eq(only("\"it\\'s \\\"quoted\\\" \\\\\""), "it's \"quoted\" \\")
  assert_eq(only("\"中文/路径.md\""), "中文/路径.md")
}

test "lexer refuses unterminated strings, bad escapes and control characters" {
  for bad in ["\"open", "\"line\nbreak\"", "\"\\q\"", "\"\\u{110000}\"", "\"\\u{d800}\"", "\"\\u12\"", "\"\u0001\""] {
    assert_true(try { ignore(literal_tokens(bad)); false } catch { _ => true })
  }
}

test "literal values and calls accept trailing commas and refuse code" {
  let tokens = literal_tokens("entry(\"a\", [\"x\", \"y\",], true,)")
  let (args, next) = literal_call(tokens, 0, "entry")
  assert_eq(args.length(), 3)
  assert_eq(args[1], ["x", "y"].to_json())
  assert_eq(args[2], true.to_json())
  assert_eq(next, tokens.length())
  for code in ["entry(panic())", "entry(1)", "entry(x)", "entry([1])", "entry(\"a\"", "other(\"a\")"] {
    let t = literal_tokens(code)
    assert_true(try { ignore(literal_call(t, 0, "entry")); false } catch { _ => true })
  }
}

test "prefix and tail matching compare tokens, not bytes" {
  let scaffold = literal_tokens("fn f() -> Int {\n  1\n}\n")
  let spaced = literal_tokens("fn   f ( ) ->Int{1}")
  assert_true(literal_prefix_matches(spaced, scaffold))
  assert_true(literal_tail_matches(spaced, 0, scaffold))
  assert_true(!literal_tail_matches(literal_tokens("fn f() -> Int { 2 }"), 0, scaffold))
  assert_true(!literal_prefix_matches(literal_tokens("fn g"), scaffold))
}
