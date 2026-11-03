// Deterministic HTML visible-text extraction. Contract mirrors the OOXML
// channel: raw bytes stay auditable through read-source, context serves this
// extraction, and anything ambiguous is refused instead of guessed.

fn enc(s : String) -> Bytes { @utf8.encode(s) }

fn extract_ok(s : String) -> String {
  try { text(enc(s)) } catch { @base.Fault(m) => "extraction-failed: " + m }
}

fn extract_err(s : String) -> String {
  try { ignore(text(enc(s))); "" } catch { @base.Fault(m) => m }
}

test "tags lowercased, void and quoted-with-angle attributes tolerated" {
  assert_eq(
    extract_ok("<HTML><BODY><P>Hello <SPAN TITLE=\"a>b\">world</SPAN></p></body></html>"),
    "Hello world",
  )
  assert_eq(extract_ok("<p>a<img src=\"x.png\" alt=\"gone\">b</p>"), "ab")
}

test "script and style are dropped, their ends reopen the body" {
  assert_eq(
    extract_ok("<p>before</p><script>if (a<b) { hide(); }</script><p>after</p>"),
    "before\nafter",
  )
  assert_eq(
    extract_ok("<style>body{color:red}</style><h1>T</h1>"),
    "T",
  )
}

test "unclosed script refuses instead of swallowing the tail" {
  assert_eq(extract_err("<p>ok</p><script>var x = 1;"), "html_unterminated_script")
  assert_eq(extract_err("<style>p{"), "html_unterminated_style")
}

test "title leads, head-only metadata contributes nothing" {
  assert_eq(
    extract_ok("<head><meta charset=\"utf-8\"><title>窑口笔记</title></head><body><p>正文</p></body>"),
    "窑口笔记\n正文",
  )
}

test "self-closing title/pre must not latch their capture regions" {
  assert_eq(extract_ok("<title/>正文此后是内容"), "正文此后是内容")
  assert_eq(extract_ok("<p>a</p><pre/>b"), "a\nb")
}

test "block boundaries and br make lines; inline text joins" {
  assert_eq(extract_ok("<ul><li>one</li><li>two</li></ul>"), "one\ntwo")
  assert_eq(extract_ok("a<br/>b<br>c"), "a\nb\nc")
  assert_eq(extract_ok("<div>x</div><div>y</div>"), "x\ny")
}

test "pre keeps interior whitespace verbatim" {
  let out = extract_ok("<pre>line one\n  indented\nline three</pre>")
  assert_eq(out, "line one\n  indented\nline three")
}

test "entities: numeric must decode, unknown names stay literal" {
  assert_eq(extract_ok("<p>&amp;tis &#65;&#x42;</p>"), "&tis AB")
  assert_eq(extract_ok("<p>a &nbsp; b</p>"), "a   b")
  assert_eq(extract_ok("<p>AT&T 5 &lt; 6</p>"), "AT&T 5 < 6")
  assert_eq(extract_err("<p>&#x1;</p>"), "html_entity_codepoint_invalid: &#x1;")
  assert_eq(extract_err("<p>&#xD800;</p>"), "html_entity_codepoint_invalid: &#xD800;")
}

test "comments vanish; bare less-than is text; declarations skipped" {
  assert_eq(extract_ok("<p>a<!-- hidden -->b</p>"), "ab")
  assert_eq(extract_ok("<p>5 < 6</p>"), "5 < 6")
  assert_eq(extract_ok("<!DOCTYPE html><p>x</p>"), "x")
  assert_eq(extract_ok("<p>tail<!-- never closed"), "tail")
}

test "structural faults refuse the document" {
  assert_eq(extract_err("<p>x</p><div a=\"unclosed"), "html_unterminated_attribute")
  assert_eq(extract_err("<p>x</p><span"), "html_unterminated_tag")
}

test "non-utf-8 bytes refuse with a transcode instruction" {
  let bad = Bytes::from_array([(255).to_byte(), (254).to_byte(), b'A'])
  let err = try { ignore(text(bad)); "" } catch { @base.Fault(m) => m }
  assert_eq(err, "html_utf8_invalid: transcode host-side before registering")
}

test "html format contract is a single name" {
  assert_true(is_html_format("html"))
  assert_false(is_html_format("markdown"))
  assert_false(is_html_format("binary"))
}
