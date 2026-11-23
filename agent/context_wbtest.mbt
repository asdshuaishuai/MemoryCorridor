// Context scoping: a global knowledge base cannot ship every page's full text
// with every order, and an unscoped default would silently grow the response
// with the catalog. These tests pin the selection rules directly so the
// truncation stays deterministic and the namespace claim stays honest.

fn context_page(id : String, sources : Array[String]) -> @core.Entry {
  {
    id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown",
    sha256: @base.hex_hash(id), sources, stale: false,
  }
}

test "context selection is bounded and namespace-scoped" {
  let pages : Array[@core.Entry] = []
  // Another namespace sorts first by id: namespace scoping must still skip it.
  pages.push(context_page("aaaa-other", ["raw/other/x.md"]))
  for i = 0; i < 70; i = i + 1 {
    pages.push(context_page("page-" + i.to_string(), ["raw/repo/f.md"]))
  }
  let (selected, total) = context_selection(pages, "raw/repo/f.md", "related", CONTEXT_PAGE_LIMIT)
  assert_eq(total, 71)
  assert_eq(selected.length(), CONTEXT_PAGE_LIMIT)
  assert_true(!selected.iter().any(page => page.id == "aaaa-other"))
  // Above the cap the namespace filter must still hold on its own: with room
  // for everything, the other namespace stays out and every sibling stays in.
  let (roomy, _) = context_selection(pages, "raw/repo/f.md", "related", 200)
  assert_eq(roomy.length(), 70)
  assert_true(!roomy.iter().any(page => page.id == "aaaa-other"))
  // The citing page is always chosen first, even when the cap is under pressure.
  let (narrow, _) = context_selection(pages, "raw/repo/f.md", "related", 3)
  assert_eq(narrow.length(), 3)
  assert_true(narrow.iter().any(page => page.id == "page-0"))
  let (all, all_total) = context_selection(pages, "raw/repo/f.md", "all", CONTEXT_PAGE_LIMIT)
  assert_eq(all_total, 71)
  assert_eq(all.length(), 71)
  assert_true(try { ignore(context_selection(pages, "raw/repo/f.md", "everything", 3)); false } catch {
    @base.Fault(message) => message.has_prefix("context_scope_invalid")
  })
}

test "citing pages come before namespace siblings" {
  let pages : Array[@core.Entry] = [
    context_page("z-cites", ["raw/repo/f.md"]),
    context_page("a-sibling", ["raw/repo/g.md"]),
    context_page("m-other", ["raw/other/x.md"]),
  ]
  let (selected, total) = context_selection(pages, "raw/repo/f.md", "related", 1)
  assert_eq(total, 3)
  assert_eq(selected.length(), 1)
  assert_eq(selected[0].id, "z-cites")
}

test "source namespace is the first two segments" {
  assert_eq(source_namespace("raw/repo/docs/a.md"), "raw/repo")
  assert_eq(source_namespace("raw/a.md"), "raw")
  assert_eq(source_namespace("raw"), "raw")
  assert_eq(source_namespace(""), "")
}
