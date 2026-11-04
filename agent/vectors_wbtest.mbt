// White-box tests for the multimodal plan primitives (续二十六): the
// deterministic first-image-source pick. Capability routing and the item
// shape are exercised end-to-end in scripts/embedding_e2e.py against the
// real CLI; here the pure selector is pinned in isolation.

fn img_raw(id : String, stale : Bool) -> @core.Entry {
  { id, path: id, kind: "raw", format: "image", sha256: "f".repeat(64), sources: [], stale }
}
// `page(id, sources)` (active concept entry) comes from redundancy_wbtest.mbt,
// same package.

test "first image source picks the sorted-first active image, skipping text and stale" {
  let entries = [
    page("concepts/photo", ["raw/zeta.png", "raw/alpha.md", "raw/beta.png"]),
    img_raw("raw/zeta.png", false),
    { ..img_raw("raw/beta.png", false), sha256: "a".repeat(64) },
    { ..img_raw("raw/alpha.md", false), format: "text" },
    { ..img_raw("raw/deep.png", false), stale: true },
  ]
  let picked = first_image_source(entries, entries[0])
  match picked {
    Some(e) => assert_eq(e.id, "raw/beta.png")
    None => @base.fail("expected raw/beta.png to win the sorted pick")
  }
}

test "pages without any active image source are unembeddable in a visual space" {
  let entries = [page("concepts/prose", ["raw/x.md"]), { ..img_raw("raw/x.md", false), format: "text" }]
  assert_true(first_image_source(entries, entries[0]) == None)
  let dangling = [page("concepts/orphan", ["raw/gone.png"])]
  assert_true(first_image_source(dangling, dangling[0]) == None)
  let stale_only = [page("concepts/stale", ["raw/o.png"]), img_raw("raw/o.png", true)]
  assert_true(first_image_source(stale_only, stale_only[0]) == None)
}

test "source order in frontmatter never changes the pick" {
  let a = [page("concepts/p", ["raw/a.png", "raw/b.png"]), img_raw("raw/a.png", false), img_raw("raw/b.png", false)]
  let b = [page("concepts/p", ["raw/b.png", "raw/a.png"]), img_raw("raw/a.png", false), img_raw("raw/b.png", false)]
  match (first_image_source(a, a[0]), first_image_source(b, b[0])) {
    (Some(x), Some(y)) => assert_eq(x.id, y.id)
    _ => @base.fail("both orderings must pick the same source")
  }
}
