test "SHA-256 NIST empty and abc and multiblock" {
  assert_eq(hex_hash(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  assert_eq(hex_hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  assert_eq(hex_hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
}

test "canonical JSON sorts recursive objects" {
  assert_eq(canonical(parse("{\"z\":1,\"a\":{\"b\":2,\"a\":3}}")), "{\"a\":{\"a\":3,\"b\":2},\"z\":1}")
  assert_eq(canonical(parse("{\"b\":1,\"aa\":2}")), "{\"aa\":2,\"b\":1}")
}

test "path rejects traversal and NUL" {
  for bad in ["../x", "wiki/../x", "/x", "a//b", "a\\b", "a:\\b", "x\u0000y"] {
    let rejected = try { path(bad); false } catch { _ => true }
    assert_true(rejected)
  }
  path("wiki/概念.md")
}

test "literate lexer finds checked blocks and rejects unclosed fences" {
  let document = "intro\n\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  let block = first_checked_block(document)
  assert_true(block.checked)
  assert_eq(block.code, "fn helper() -> Int { 1 }")
  assert_true(try { ignore(first_checked_block("```mbt\nfn helper() -> Int { 1 }\n```\n")); false } catch { _ => true })
  assert_true(try { ignore(first_checked_block("no fenced code")); false } catch { _ => true })
  assert_true(try { ignore(first_checked_block("```mbt\nfn helper() -> Int { 1 }\n")); false } catch { _ => true })
  assert_true(try { ignore(first_checked_block("```mbt check\nfn helper() -> Int { 1 }\n")); false } catch { _ => true })
}

test "literate checked block requires a blank line before trailing content" {
  let document = "```mbt check\nfn helper() -> Int { 1 }\n```"
  assert_eq(first_checked_block(document).code, "fn helper() -> Int { 1 }")
  assert_eq(first_checked_block(document + "\n").code, "fn helper() -> Int { 1 }")
  assert_eq(first_checked_block(document + "\n\nProse stays readable.\n").code, "fn helper() -> Int { 1 }")
  assert_eq(first_checked_block(document + "\n\n```mbt\nfn later() -> Int { 2 }\n```\n").code, "fn helper() -> Int { 1 }")
  assert_true(try { ignore(first_checked_block(document + "extra code")); false } catch { _ => true })
  assert_true(try { ignore(first_checked_block(document + "\nextra code")); false } catch { _ => true })
}

test "literate fence grammar accepts Markdown indentation, tildes and longer runs" {
  let indented = "   ```mbt check\n   fn helper() -> Int { 1 }\n   ```\n"
  assert_eq(first_checked_block(indented).code, "   fn helper() -> Int { 1 }")
  let tilde = "~~~mbt check\nfn helper() -> Int { 1 }\n~~~\n"
  assert_eq(first_checked_block(tilde).code, "fn helper() -> Int { 1 }")
  let longer = "````mbt check\n```\nfn helper() -> Int { 1 }\n````\n"
  assert_eq(first_checked_block(longer).code, "```\nfn helper() -> Int { 1 }")
  let longer_close = "```mbt check\nfn helper() -> Int { 1 }\n````\n"
  assert_eq(first_checked_block(longer_close).code, "fn helper() -> Int { 1 }")
  let empty = "```mbt check\n```\n"
  assert_eq(first_checked_block(empty).code, "")
  let crlf = "intro\r\n\r\n```mbt check\r\nfn helper() -> Int { 1 }\r\n```\r\n"
  assert_eq(first_checked_block(crlf).code, "fn helper() -> Int { 1 }")
  let info_variant = "```mbt check extra\nnot checked\n```\n\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  assert_eq(first_checked_block(info_variant).code, "fn helper() -> Int { 1 }")
  let four_spaces = "    ```mbt check\n    fn helper() -> Int { 1 }\n    ```\n"
  assert_true(try { ignore(first_checked_block(four_spaces)); false } catch { _ => true })
  let tab_indented = "\t```mbt check\n\tfn helper() -> Int { 1 }\n\t```\n"
  assert_true(try { ignore(first_checked_block(tab_indented)); false } catch { _ => true })
  let short_close = "````mbt check\nfn helper() -> Int { 1 }\n```\n"
  assert_true(try { ignore(first_checked_block(short_close)); false } catch { _ => true })
  let dirty_close = "```mbt check\nfn helper() -> Int { 1 }\n``` trailing\n"
  assert_true(try { ignore(first_checked_block(dirty_close)); false } catch { _ => true })
  let wrong_marker = "```mbt check\nfn helper() -> Int { 1 }\n~~~\n"
  assert_true(try { ignore(first_checked_block(wrong_marker)); false } catch { _ => true })
}

test "replace_first_checked keeps every byte outside the canonical block" {
  let source = "intro\n\n```mbt check\nold\n```\n\ntail prose\n"
  assert_eq(replace_first_checked(source, "new"), "intro\n\n```mbt check\nnew\n```\n\ntail prose\n")
  let no_trailing = "```mbt check\nold\n```"
  assert_eq(replace_first_checked(no_trailing, "new"), "```mbt check\nnew\n```")
  let crlf = "intro\r\n\r\n```mbt check\r\nold\r\n```\r\n\r\ntail\r\n"
  let replaced = replace_first_checked(crlf, "new")
  assert_eq(replaced, "intro\r\n\r\n```mbt check\r\nnew\r\n```\r\n\r\ntail\r\n")
  assert_true(try { ignore(replace_first_checked("```mbt check\nold\n```glued", "new")); false } catch { _ => true })
}

test "deterministic literate corpus never panics and replacement is byte-idempotent" {
  let alphabet = ["```", "~~~", "mbt check", "mbt", "prose", "\n", " ", "\t", "`", "~", "check"]
  let mut state : Int = 12345
  for i = 0; i < 400; i = i + 1 {
    let mut document = ""
    for j = 0; j < 24; j = j + 1 {
      state = (state * 25173 + 13849) % 65536
      document = document + alphabet[state % alphabet.length()]
    }
    if state % 3 == 0 {
      document = "```mbt check\nfn f() -> Int { 1 }\n```\n\n" + document
    }
    if state % 5 == 0 {
      document = "intro\n\n" + document + "\n\n```mbt check\nfn g() -> Int { 2 }\n```"
    }
    let block = try { Some(first_checked_block(document)) } catch { _ => None }
    match block {
      Some(found) => assert_eq(replace_first_checked(document, found.code), document)
      None => ()
    }
  }
}

test "token estimate counts CJK scalars and Latin words" {
  assert_eq(estimate_tokens(""), 0)
  assert_eq(estimate_tokens("hello world"), 2)
  assert_eq(estimate_tokens("hello,world!"), 2)
  assert_eq(estimate_tokens("a1b2"), 1)
  assert_eq(estimate_tokens("你好世界"), 4)
  assert_eq(estimate_tokens("hello 你好 world"), 4)
  assert_eq(estimate_tokens("😀 !!!"), 0)
  assert_eq(estimate_tokens("café"), 1)
  assert_eq(estimate_tokens("hello\n\nworld"), 2)
}

test "literate tail faults carry structural repair records" {
  let raw = try { ignore(first_checked_block("```mbt check\nfn f() -> Int { 1 }\n```\nextra code")); "" } catch {
    Fault(message) => message
  }
  assert_eq(fault_code(raw), "literate_tail_content")
  for code in ["catalog_literate_tail", "view_literate_tail"] {
    let data = fault_data(code + ": separate trailing content from the closing fence with a blank line")
    assert_eq(field(data, "error_code"), code.to_json())
    let violations = array(field(data, "violations"))
    assert_eq(field(violations[0], "predicate"), code.to_json())
    assert_true(text(field(data, "hint")).contains("空行"))
  }
}
