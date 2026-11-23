// Verification memo differential tests (knowledge/memory redesign phase 0).
//
// Re-reading and re-hashing a whole catalog per request is what makes a large
// global knowledge base unusable, but skipping it must not weaken verification.
// These tests drive the reuse rules directly: reads are counted, change signals
// are scripted, and the catalog set is changed without touching file bytes.

fn memo_store() -> (Storage, Map[String, String], Map[String, Int], Map[String, String]) {
  let files : Map[String, String] = Map([])
  let reads : Map[String, Int] = Map([])
  let signatures : Map[String, String] = Map([])
  let count = path => { reads[path] = reads.get(path).unwrap_or(0) + 1 }
  let store : Storage = {
    read: path => { count(path); files.get(path) },
    read_bytes: path => files.get(path).map(text => @utf8.encode(text)),
    digest: path => { count(path); files.get(path).map(@base.hex_hash) },
    write: (path, text) => { files[path] = text },
    write_bytes: (path, bytes) => { files[path] = try @utf8.decode(bytes) catch {
      _ => raise @base.Fault("invalid_utf8_fixture")
    } },
    mkdirs: _ => (),
    remove: path => { files.remove(path) },
    files: prefix => files.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: _ => (),
    stat: path => signatures.get(path),
    memo: VerifyMemo::new(),
  }
  (store, files, reads, signatures)
}

fn memo_fixture() -> (Storage, Map[String, String], Map[String, Int], Map[String, String]) {
  let (store, files, reads, signatures) = memo_store()
  files["raw/a.md"] = "raw 正文\n"
  files["purpose.md"] = "目标\n"
  files["wiki/a.md"] = "---\ntype: source-summary\ntitle: \"甲\"\nsources: [\"raw/a.md\"]\n---\n正文 [[concept/b]]\n"
  files["wiki/b.md"] = "---\ntype: concept\ntitle: \"乙\"\nsources: [\"raw/a.md\"]\n---\n概念\n"
  for path in ["raw/a.md", "purpose.md", "wiki/a.md", "wiki/b.md"] { signatures[path] = "sig-1" }
  (store, files, reads, signatures)
}

fn memo_entries(files : Map[String, String], b_stale : Bool) -> Array[@core.Entry] {
  let hash = path => @base.hex_hash(files[path])
  [
    { id: "purpose.md", path: "purpose.md", kind: "purpose", format: "markdown", sha256: hash("purpose.md"), sources: [], stale: false },
    { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: hash("raw/a.md"), sources: [], stale: false },
    { id: "source/a", path: "wiki/a.md", kind: "source-summary", format: "markdown", sha256: hash("wiki/a.md"), sources: ["raw/a.md"], stale: false },
    { id: "concept/b", path: "wiki/b.md", kind: "concept", format: "markdown", sha256: hash("wiki/b.md"), sources: ["raw/a.md"], stale: b_stale },
  ]
}

test "verify reuses unchanged files and re-reads on a changed signal" {
  let (store, files, reads, signatures) = memo_fixture()
  let entries = memo_entries(files, false)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)   // signal + hash + epoch all match
  // An edit the catalog has not seen must fail, not be memoized away.
  signatures["wiki/a.md"] = "sig-2"
  files["wiki/a.md"] = files["wiki/a.md"] + "改动\n"
  let failed = try { verify(store, entries); false } catch {
    @base.Fault(message) => message.has_prefix("content_changed")
  }
  assert_true(failed)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "a new signal re-verifies matching content without failing" {
  let (store, files, reads, signatures) = memo_fixture()
  let entries = memo_entries(files, false)
  verify(store, entries)
  signatures["wiki/a.md"] = "sig-2"        // same bytes, new identity (e.g. rewritten)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "page validation is invalidated when the active page set changes" {
  let (store, files, reads, _) = memo_fixture()
  verify(store, memo_entries(files, false))
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  // Only the set changed: the linked concept became stale, so the link dangles.
  let failed = try { verify(store, memo_entries(files, true)); false } catch {
    @base.Fault(message) => message.has_prefix("wikilink_unresolved")
  }
  assert_true(failed)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "non-page files are reused across catalog changes" {
  let (store, files, reads, _) = memo_fixture()
  verify(store, memo_entries(files, false))
  assert_eq(reads.get("purpose.md").unwrap_or(0), 1)
  ignore(try { verify(store, memo_entries(files, true)) } catch { _ => () })
  verify(store, memo_entries(files, false))
  assert_eq(reads.get("purpose.md").unwrap_or(0), 1)
}

test "a file edited while being verified is not memoized" {
  let (base, files, reads, signatures) = memo_fixture()
  let calls : Array[Int] = [0]
  let store : Storage = {
    ..base,
    stat: path => {
      if path == "wiki/a.md" {
        calls[0] = calls[0] + 1
        // reusable() sees a stable signal, the read is bracketed by two others.
        if calls[0] == 2 { Some("sig-1") } else { Some("sig-2") }
      } else {
        signatures.get(path)
      }
    },
  }
  let entries = memo_entries(files, false)
  verify(store, entries)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "a catalog hash that no longer matches the memo forces a re-read" {
  let (store, files, reads, _) = memo_fixture()
  verify(store, memo_entries(files, false))
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  // The catalog records different bytes although the file identity stands.
  let entries = memo_entries(files, false)
  let forged : Array[@core.Entry] = entries.map(entry => if entry.path == "wiki/a.md" {
    { ..entry, sha256: @base.hex_hash("另一种内容\n") }
  } else {
    entry
  })
  let failed = try { verify(store, forged); false } catch {
    @base.Fault(message) => message.has_prefix("content_changed")
  }
  assert_true(failed)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "without a change signal every verify re-reads" {
  let (base, files, reads, _) = memo_fixture()
  let store : Storage = { ..base, stat: _ => None }
  let entries = memo_entries(files, false)
  verify(store, entries)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "an unrelated page addition does not invalidate validated pages" {
  let (store, files, reads, _) = memo_fixture()
  verify(store, memo_entries(files, false))
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  // Another page joins the catalog; wiki/a.md's own links still resolve.
  files["wiki/c.md"] = "---\ntype: concept\ntitle: \"丙\"\nsources: [\"raw/a.md\"]\n---\n另一个概念\n"
  let next = memo_entries(files, false)
  next.push({
    id: "concept/c", path: "wiki/c.md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(files["wiki/c.md"]), sources: ["raw/a.md"], stale: false,
  })
  verify(store, next)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  assert_eq(reads.get("wiki/c.md").unwrap_or(0), 1)
}

test "the explicit audit re-reads files the memo already trusts" {
  let (store, files, reads, _) = memo_fixture()
  let entries = memo_entries(files, false)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  verify(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 1)
  verify_full(store, entries)
  assert_eq(reads.get("wiki/a.md").unwrap_or(0), 2)
}

test "catalog memo answers for the exact text it was given" {
  let (store, files, _, _) = memo_fixture()
  let active = @decl.generate(memo_entries(files, false))
  let stale = @decl.generate(memo_entries(files, true))
  let (first, first_fingerprint) = catalog_memo(store, active)
  assert_eq(first.length(), 4)
  let (second, second_fingerprint) = catalog_memo(store, stale)
  assert_true(first_fingerprint != second_fingerprint)
  assert_true(second.iter().any(entry => entry.stale))
  let (again, again_fingerprint) = catalog_memo(store, stale)
  assert_eq(again_fingerprint, second_fingerprint)
  assert_eq(again.length(), 4)
}
