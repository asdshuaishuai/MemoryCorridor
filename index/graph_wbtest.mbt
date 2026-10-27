test "graph traversal is deterministic, supports sources and excludes stale nodes" {
  let make = (id, links, source, stale) => {
    let entry : @core.Entry = { id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown", sha256: "a".repeat(64), sources: [source], stale }
    let page : @core.Page = { title: id, kind: "concept", sources: [source], tags: ["topic"], body: "", links }
    (entry, page)
  }
  let g = build_graph([make("c", [], "raw/c", false), make("b", ["c"], "raw/a", false), make("a", [], "raw/a", false), make("d", ["a"], "raw/d", true)])
  assert_eq(neighbors(g, "a"), ["b"])
  assert_eq(path(g, "a", "c"), ["a", "b", "c"])
  assert_eq(path(g, "c", "a"), ["c", "b", "a"])
  assert_eq(weighted_path(g, "a", "c"), ["a", "b", "c"])
  assert_eq(weighted_path(g, "c", "a"), ["c", "b", "a"])
  assert_eq(subgraph(g, "a", 0).nodes.length(), 1)
  assert_eq(subgraph(g, "a", 1).nodes.length(), 2)
  assert_eq(subgraph(g, "a", 2).nodes.length(), 3)
  assert_true(try { ignore(neighbors(g, "d")); false } catch { _ => true })
  let report = insights(g)
  let components = @base.array(@base.field(report, "components"))
  assert_eq(components.length(), 1)
  let degree = @base.array(@base.field(report, "degree"))
  assert_eq(degree.length(), 3)
  let kinds = @base.array(@base.field(report, "edge_kinds"))
  assert_eq(kinds.length(), 2)
}

test "weighted paths reject invalid edge weights and keep deterministic ties" {
  let simple : Graph = {
    nodes: [{ id: "a", kind: "concept", title: "A", tags: [] }, { id: "b", kind: "concept", title: "B", tags: [] }, { id: "c", kind: "concept", title: "C", tags: [] }],
    edges: [
      { source: "a", target: "b", kind: "shared-source", weight: 2.0 },
      { source: "a", target: "c", kind: "shared-source", weight: 2.0 },
      { source: "b", target: "c", kind: "wikilink", weight: 3.0 },
    ],
  }
  assert_eq(weighted_path(simple, "a", "c"), ["a", "c"])
  let invalid = { ..simple, edges: [{ source: "a", target: "b", kind: "bad", weight: 0.0 }] }
  assert_true(try { ignore(weighted_path(invalid, "a", "b")); false } catch { _ => true })
}

test "search expansion ranks neighbors by edge weight and hop decay" {
  let graph : Graph = {
    nodes: [
      { id: "a", kind: "concept", title: "A", tags: [] },
      { id: "b", kind: "concept", title: "B", tags: [] },
      { id: "c", kind: "concept", title: "C", tags: [] },
      { id: "d", kind: "concept", title: "D", tags: [] },
    ],
    edges: [
      { source: "a", target: "b", kind: "wikilink", weight: 3.0 },
      { source: "a", target: "c", kind: "shared-source", weight: 4.0 },
      { source: "b", target: "d", kind: "wikilink", weight: 3.0 },
    ],
  }
  let rows = expand(graph, ["a"], 2)
  assert_eq(rows.map(row => row.id), ["c", "b", "d"])
  assert_eq(rows[0].score, 4.0)
  assert_eq(rows[1].score, 3.0)
  assert_eq(rows[2].score, 1.5)
  assert_true(expand(graph, ["a"], 0).is_empty())
  assert_true(expand(graph, [], 2).is_empty())
  assert_true(try { ignore(expand(graph, ["missing"], 1)); false } catch { _ => true })
  let invalid = { ..graph, edges: [{ source: "a", target: "b", kind: "bad", weight: -1.0 }] }
  assert_true(try { ignore(expand(invalid, ["a"], 1)); false } catch { _ => true })
  let tied : Graph = {
    nodes: [{ id: "s", kind: "concept", title: "S", tags: [] },
      { id: "z", kind: "concept", title: "Z", tags: [] },
      { id: "y", kind: "concept", title: "Y", tags: [] }],
    edges: [
      { source: "s", target: "z", kind: "wikilink", weight: 3.0 },
      { source: "s", target: "y", kind: "wikilink", weight: 3.0 },
    ],
  }
  assert_eq(expand(tied, ["s"], 1).map(row => row.id), ["y", "z"])
}

test "insights reports disconnected components and weighted degree" {
  let graph : Graph = {
    nodes: [
      { id: "a", kind: "concept", title: "A", tags: [] },
      { id: "b", kind: "concept", title: "B", tags: [] },
      { id: "c", kind: "concept", title: "C", tags: [] },
    ],
    edges: [{ source: "a", target: "b", kind: "wikilink", weight: 3.0 }],
  }
  let report = insights(graph)
  assert_eq(@base.array(@base.field(report, "components")), [["a", "b"].to_json(), ["c"].to_json()])
  let degree = @base.array(@base.field(report, "degree"))
  let first = degree[0]
  assert_eq(@base.text(@base.field(first, "id")), "a")
  assert_eq(@base.field(first, "degree"), Json::number(1.0))
  assert_eq(@base.field(first, "weighted_degree"), Json::number(3.0))
}

test "insights reports deterministic weighted communities" {
  let graph : Graph = {
    nodes: [
      { id: "a", kind: "concept", title: "A", tags: [] },
      { id: "b", kind: "concept", title: "B", tags: [] },
      { id: "c", kind: "concept", title: "C", tags: [] },
      { id: "d", kind: "concept", title: "D", tags: [] },
      { id: "e", kind: "concept", title: "E", tags: [] },
    ],
    edges: [
      { source: "a", target: "b", kind: "wikilink", weight: 3.0 },
      { source: "b", target: "c", kind: "wikilink", weight: 3.0 },
      { source: "d", target: "e", kind: "shared-source", weight: 2.0 },
    ],
  }
  let report = insights(graph)
  let groups = @base.array(@base.field(report, "communities"))
  assert_eq(groups.length(), 2)
  assert_eq(@base.array(@base.field(groups[0], "members")), ["a".to_json(), "b".to_json(), "c".to_json()])
  assert_eq(@base.array(@base.field(groups[1], "members")), ["d".to_json(), "e".to_json()])
  assert_eq(@base.field(groups[0], "weight"), Json::number(6.0))
}
