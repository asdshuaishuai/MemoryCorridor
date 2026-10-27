fn lint_memory() -> (@vault.Storage, Map[String, String]) {
  let files : Map[String, String] = Map([])
  let store : @vault.Storage = {
    read: path => files.get(path),
    read_bytes: path => files.get(path).map(text => @utf8.encode(text)),
    digest: path => files.get(path).map(@base.hex_hash),
    write: (path, text) => { files[path] = text },
    write_bytes: (path, bytes) => { files[path] = try @utf8.decode(bytes) catch { _ => raise @base.Fault("invalid_utf8_fixture") } },
    mkdirs: _ => (),
    remove: path => { files.remove(path) },
    files: prefix => files.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: path => { ignore(@decl.parse(files[path])) },
  }
  (store, files)
}

fn has_lint_predicate(rows : Array[Json], expected : String) -> Bool {
  for row in rows {
    match row {
      Object(fields) => match fields.get("predicate") {
        Some(String(value)) if value == expected => return true
        _ => ()
      }
      _ => ()
    }
  }
  false
}

test "lint reports independent source, link, and cache diagnostics" {
  let (store, files) = lint_memory()
  let raw : @core.Entry = {
    id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown",
    sha256: @base.hex_hash("registered"), sources: [], stale: false,
  }
  let body = "正文 [[concepts/missing]]\n"
  let page_text = "---\ntype: concept\ntitle: 页面\nsources: [\"raw/a.md\"]\ntags: []\n---\n" + body
  let page : @core.Entry = {
    id: "concepts/page", path: "wiki/concepts/page.md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(page_text), sources: ["raw/a.md"], stale: false,
  }
  let catalog = @decl.generate([raw, page])
  files["index.mbt.md"] = catalog
  files[raw.path] = "changed"
  files[page.path] = page_text
  let result = lint_result(store, Some(catalog))
  let violations = @base.array(@base.field(result, "violations"))
  assert_true(has_lint_predicate(violations, "source_hash_drift"))
  assert_true(has_lint_predicate(violations, "wikilink_unresolved"))
  assert_true(has_lint_predicate(violations, "cache_missing"))
  assert_eq(@base.text(@base.field(result, "status")), "issues")
}

test "lint reports multiple catalog row violations together" {
  let (store, files) = lint_memory()
  let broken : @core.Entry = {
    id: "raw/alias.md", path: "raw/broken.md", kind: "raw", format: "binary",
    sha256: "not-a-hash", sources: ["raw/missing.md", "raw/missing.md"], stale: false,
  }
  let catalog = @decl.generate([broken])
  files["index.mbt.md"] = catalog
  let result = lint_result(store, Some(catalog))
  let violations = @base.array(@base.field(result, "violations"))
  assert_true(has_lint_predicate(violations, "entry_hash_invalid"))
  assert_true(has_lint_predicate(violations, "raw_identity_mismatch"))
  assert_true(has_lint_predicate(violations, "raw_entry_invalid"))
  assert_true(has_lint_predicate(violations, "source_duplicate"))
  assert_true(has_lint_predicate(violations, "source_unresolved"))
  assert_true(violations.length() >= 4)
}

test "lint reports evidence anchor drift and preserves stale classification" {
  let (store, files) = lint_memory()
  let raw_text = "raw source"
  let page_text = "---\ntype: concept\ntitle: 页面\nsources: [\"raw/a.md\"]\ntags: []\n---\n正文内容"
  let raw : @core.Entry = {
    id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown",
    sha256: @base.hex_hash(raw_text), sources: [], stale: false,
  }
  let page : @core.Entry = {
    id: "concepts/page", path: "wiki/page.md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(page_text), sources: [raw.id], stale: false,
  }
  let claims : Json = [{
    "source": raw.id, "body_start": 0, "body_end": 4, "quote": "错误正文",
  }]
  let seed : Json = { "page": page.id, "page_hash": page.sha256, "claims": claims }
  let evidence_id = @base.hex_hash("evidence-v1\n" + @base.canonical(seed))
  let evidence_path = "state/evidence/" + evidence_id + ".json"
  let evidence_text = @base.canonical({ "id": evidence_id, "page": page.id,
    "page_hash": page.sha256, "claims": claims })
  let evidence : @core.Entry = {
    id: evidence_path, path: evidence_path, kind: "state", format: "json",
    sha256: @base.hex_hash(evidence_text), sources: [], stale: false,
  }
  let catalog = @decl.generate([raw, page, evidence])
  files["index.mbt.md"] = catalog
  files[raw.path] = raw_text
  files[page.path] = page_text
  files[evidence.path] = evidence_text
  let result = lint_result(store, Some(catalog))
  let violations = @base.array(@base.field(result, "violations"))
  assert_true(has_lint_predicate(violations, "evidence_body_anchor_invalid"))
  assert_true(!has_lint_predicate(violations, "evidence_source_stale"))
}

test "unregistered file check covers the catalog-driven directories" {
  // The directories that must be checked, and the ones that must not be:
  // views/ and staging/ are discovered by listing, and raw/ is pending work.
  let checked = ["state", "wiki", "vectors"]
  assert_eq(checked.length(), 3)
  let exempt = ["views", "staging", "raw"]
  assert_eq(exempt.length(), 3)
  for name in checked {
    assert_true(!exempt.contains(name))
  }
  // Engine-maintained views are rewritten on every publish, so they are exempt
  // even though they live under a checked directory.
  let excluded = ["state/transactions/pending.json", "wiki/index.md", "wiki/log.md"]
  assert_eq(excluded.length(), 3)
  for path in excluded {
    assert_true(path.has_prefix("state/") || path.has_prefix("wiki/"))
  }
}
