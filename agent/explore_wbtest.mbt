test "tree builds deterministic nested directories and index-first pages" {
  let mut root = tree_dir("wiki")
  root = tree_insert(root, [], { name: "z", id: "concepts/z", title: "Z", path: "wiki/z.md", kind: "concept", stale: false })
  root = tree_insert(root, ["topic"], { name: "z", id: "concepts/topic/z", title: "Z2", path: "wiki/topic/z.md", kind: "concept", stale: false })
  root = tree_insert(root, ["topic"], { name: "index", id: "concepts/topic/index", title: "Index", path: "wiki/topic/index.md", kind: "concept", stale: true })
  let value = tree_json(root)
  let dirs = @base.array(@base.field(value, "dirs"))
  assert_eq(dirs.length(), 1)
  assert_eq(@base.text(@base.field(dirs[0], "name")), "topic")
  let pages = @base.array(@base.field(dirs[0], "pages"))
  assert_eq(@base.text(@base.field(pages[0], "name")), "index")
  assert_true(@base.boolean(@base.field(pages[0], "stale")))
  assert_eq(@base.text(@base.field(@base.array(@base.field(value, "pages"))[0], "name")), "z")
}
