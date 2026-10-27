test "catalog preserves Chinese paths, escapes, state and tombstones" {
  let entries : Array[@core.Entry] = [
    { id: "raw/资料.md", path: "raw/资料.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("原文"), sources: [], stale: false },
    { id: "concepts/引号", path: "wiki/引号\".md", kind: "concept", format: "markdown", sha256: @base.hex_hash("页面"), sources: ["raw/资料.md"], stale: false },
  ]
  let encoded = generate(entries)
  let decoded = parse(encoded)
  assert_true(decoded.contains(entries[0]))
  assert_true(decoded.contains(entries[1]))
  assert_eq(generate(decoded), encoded)
  let prose = encoded + "\n\n这段说明属于 Markdown，不改变目录语义。\n"
  let prose_decoded = parse(prose)
  assert_eq(prose_decoded.length(), entries.length())
  assert_true(prose_decoded.contains(entries[0]))
  assert_true(prose_decoded.contains(entries[1]))
}

test "catalog rejects code injection and duplicate ids" {
  let empty = generate([])
  let injected = empty.replace(old="  [\n", new="  [\n    panic(),\n")
  assert_true(try { ignore(parse(injected)); false } catch { _ => true })
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  assert_true(try { ignore(parse(generate([entry, entry]))); false } catch { _ => true })
}

test "catalog composes additional checked literate blocks" {
  let extra = generate([]) + "\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  assert_eq(parse(extra).length(), 0)
  let plain_extra = generate([]) + "\n```mbt\nfn helper() -> Int { 1 }\n```\n"
  assert_eq(parse(plain_extra).length(), 0)
  let unclosed = generate([]) + "\n```mbt check\nfn helper() -> Int { 1 }\n"
  assert_true(try { ignore(parse(unclosed)); false } catch { _ => true })
  let plain_unclosed = generate([]) + "\n```mbt\nfn helper() -> Int { 1 }\n"
  assert_true(try { ignore(parse(plain_unclosed)); false } catch { _ => true })
  let plain_before_checked = generate([]) + "\n```mbt\nfn helper() -> Int { 1 }\n\n```mbt check\nfn later() -> Int { 2 }\n"
  assert_true(try { ignore(parse(plain_before_checked)); false } catch { _ => true })
}

test "legacy six-field catalogs infer format and migrate on generation" {
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  let legacy = generate([entry]).replace(old=", \"markdown\",", new=",")
  let entries = parse(legacy)
  assert_eq(entries.length(), 1)
  assert_eq(entries[0].format, "markdown")
  assert_true(generate(entries).contains("\"markdown\""))
}

test "catalog publication preserves literate prose and auxiliary blocks" {
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  let source = "# Human catalog notes\n\n" + generate([]) +
    "\nThe declaration remains readable.\n\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  let published = generate_preserving(source, [entry])
  assert_true(published.has_prefix("# Human catalog notes\n\n"))
  assert_true(published.contains("The declaration remains readable."))
  assert_true(published.contains("fn helper() -> Int { 1 }"))
  let decoded = parse(published)
  assert_eq(decoded.length(), 1)
  assert_true(decoded[0] == entry)
}

test "catalog accepts CRLF literate sources and preserves their style" {
  let source = @base.replace_all(generate([]), "\n", "\r\n")
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  assert_eq(parse(source).length(), 0)
  let published = generate_preserving(source, [entry])
  assert_true(published.contains("\r\n"))
  assert_false(@base.replace_all(published, "\r\n", "").contains("\n"))
  assert_eq(parse(published).length(), 1)
}

test "catalog generation is sorted and parse-generate round-trips byte-for-byte" {
  let first : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  let second : @core.Entry = { id: "concepts/b", path: "wiki/concepts/b.md", kind: "concept", format: "markdown", sha256: @base.hex_hash("b"), sources: ["raw/a.md"], stale: true }
  assert_eq(generate([second, first]), generate([first, second]))
  let canonical = generate([second, first])
  assert_eq(generate(parse(canonical)), canonical)
  assert_eq(parse(generate([second, first])).length(), 2)
}

test "catalog publication replaces only the first checked block code" {
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  let source = "# Notes\n\n" + generate([]) + "\nReadable prose.\n\n```mbt check\nfn helper() -> Int { 1 }\n```\n"
  let published = generate_preserving(source, [entry])
  let old_code = @base.first_checked_block(source).code
  let new_code = code_block(generate([entry]))
  assert_eq(published, source.replace(old=old_code, new=new_code))
  assert_true(published.has_prefix("# Notes\n\n"))
  assert_true(published.contains("Readable prose."))
  assert_true(published.contains("fn helper() -> Int { 1 }"))
}

test "catalog rejects text glued to the first checked fence" {
  let glued = generate([]) + "Glued remark"
  assert_true(try { ignore(parse(glued)); false } catch { _ => true })
  let glued_preserving = generate([]) + "Glued remark"
  let entry : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("a"), sources: [], stale: false }
  assert_true(try { ignore(generate_preserving(glued_preserving, [entry])); false } catch { _ => true })
}

test "deterministic catalog mutations never panic and canonicalize when accepted" {
  let entry : @core.Entry = { id: "concepts/alpha", path: "wiki/concepts/alpha.md", kind: "concept",
    format: "markdown", sha256: @base.hex_hash("alpha"), sources: ["raw/a.md"], stale: false }
  let canonical = generate([entry])
  let block = @base.first_checked_block(canonical)
  let header = "```mbt check\n"
  let start = canonical.find(header).unwrap_or(0) + header.length()
  let replacements = ["x", "`", "~", "\n", "\"", "]", "(", " ", "0"]
  for i = 0; i < 160; i = i + 1 {
    let position = start + (i * 7919) % block.code.length()
    let replacement = replacements[i % replacements.length()]
    let mutated = canonical[:position].to_owned() + replacement + canonical[position + 1:].to_owned()
    let parsed = try { Some(parse(mutated)) } catch { _ => None }
    match parsed {
      Some(entries) => {
        let regenerated = generate(entries)
        assert_eq(generate(parse(regenerated)), regenerated)
      }
      None => ()
    }
  }
}
