// Probes for the round-1 hunt fixes: graph endpoint validation, wire-format
// overflow, negative-k semantics, empty-token dedup, shared CJK predicate and
// duplicate document ids.

fn node(id : String) -> Node {
  { id, kind: "concept", title: id, tags: [] }
}

test "weighted_path survives edges to unknown endpoints and returns cleanly" {
  // Graph is pub(all): a host can hand-build edges whose endpoints are not
  // nodes. Relaxation must treat them as unreachable, not abort the process.
  let g : Graph = {
    nodes: [node("a"), node("b")],
    edges: [{ source: "a", target: "ghost", kind: "wikilink", weight: 3.0 }],
  }
  assert_eq(weighted_path(g, "a", "b"), [])
  assert_eq(weighted_path(g, "a", "a"), ["a"])
  // Lookup-facing APIs keep their clean Fault contract.
  assert_true(try { ignore(neighbors(g, "ghost")); false } catch { _ => true })
}

test "expand never returns endpoints that are absent from nodes" {
  let g : Graph = {
    nodes: [node("a"), node("b")],
    edges: [
      { source: "a", target: "ghost", kind: "wikilink", weight: 3.0 },
      { source: "a", target: "b", kind: "wikilink", weight: 3.0 },
    ],
  }
  let rows = expand(g, ["a"], 1)
  assert_eq(rows.map(r => r.id), ["b"])
  assert_true(rows[0].score.is_close(3.0))
}

test "self links do not leak into neighbor semantics or degree" {
  let make = (id, links, source) => {
    let entry : @core.Entry = { id, path: "wiki/" + id + ".md", kind: "concept", format: "markdown",
      sha256: "a".repeat(64), sources: [source], stale: false }
    let page : @core.Page = { title: id, kind: "concept", sources: [source], tags: [], body: "", links }
    (entry, page)
  }
  let g = build_graph([make("x", ["x"], "raw/x"), make("y", ["x"], "raw/y"), make("z", [], "raw/z")])
  // build_graph refuses the x->x self edge.
  assert_eq(g.edges.map(e => e.source + ">" + e.target), ["y>x"])
  assert_eq(neighbors(g, "x"), ["y"])
  assert_eq(neighbors(g, "z"), [])
  let report = insights(g)
  let degree = @base.array(@base.field(report, "degree"))
  let by_id : Map[String, Json] = Map([])
  for row in degree { by_id[@base.text(@base.field(row, "id"))] = row }
  // weighted degree counts real relationships only: the self edge carries none.
  assert_eq(@base.field(by_id["x"], "weighted_degree"), 3.0.to_json())
  assert_eq(@base.field(by_id["x"], "degree"), 1)
  // Hand-built self-loop edges are excluded from the neighbor table too.
  let manual : Graph = {
    nodes: [node("x"), node("y")],
    edges: [{ source: "x", target: "x", kind: "wikilink", weight: 3.0 }],
  }
  assert_eq(neighbors(manual, "x"), [])
}

test "negative result caps clamp to zero instead of accusing the backend" {
  let space : VectorSpace = { id: "s", dimensions: 2 }
  let records : Array[VectorRecord] = [{ page: "p", sha256: "h", space, values: [1.0, 0.0] }]
  // brute_force clamps internally, so k=-1 quietly yields no hits.
  assert_eq(search_vectors(space, [1.0, 0.0], records, -1).length(), 0)
  // An external backend returning hits past a clamped cap is a real excess.
  let external : VectorSearchBackend = { search: (_, _, _, _) => [{ id: "p", score: 1.0 }] }
  assert_true(try { ignore(search_vectors(space, [1.0, 0.0], records, -1, backend=external)); false }
    catch { @base.Fault(m) => m == "backend_excess_results" })
  // validate_external_hits mirrors the clamp.
  assert_eq(validate_external_hits(["p"], [], -1).length(), 0)
  assert_true(try { ignore(validate_external_hits(["p"], [{ id: "p", score: 1.0 }], -1)); false }
    catch { @base.Fault(m) => m == "backend_excess_results" })
}

test "binary32 encoding fails closed beyond the f32 range" {
  let space : VectorSpace = { id: "wire-v1", dimensions: 2 }
  // 1e300 survives the Double-side normalize but rounds to Inf in binary32:
  // the encoder must refuse before producing bytes its own decoder rejects.
  assert_true(try { ignore(values_to_base64(space, [1.0e300, 1.0])); false }
    catch { @base.Fault(m) => m == "vector_base64_overflow" })
  assert_true(try { ignore(values_to_base64(space, [-1.0e300, 1.0])); false }
    catch { @base.Fault(m) => m == "vector_base64_overflow" })
  // The largest finite binary32 and subnormals still round-trip.
  let encoded = values_to_base64(space, [3.4028235e38, 1.0e-45])
  assert_eq(values_from_base64(space, encoded)[0].is_inf(), false)
}

test "empty token sequences never merge as near-duplicates" {
  assert_false(similar_merge([], []))
  assert_false(similar_merge(similar_tokens("!".repeat(80)), similar_tokens("#".repeat(80))))
  assert_true(similar_merge(similar_tokens("alpha relay"), similar_tokens("alpha relay")))
  assert_false(similar_merge(similar_tokens("alpha relay"), similar_tokens("relay alpha")))
  // Two punctuation-only pages that both clear the byte gate stay distinct.
  let result = assemble_context([candidate("bang", "!".repeat(80)), candidate("quest", "#".repeat(80))],
    "查询", 4096, dedup="similar")
  assert_eq(@base.array(@base.field(result, "blocks")).length(), 2)
  assert_eq(@base.array(@base.field(result, "similar_duplicates")).length(), 0)
}

test "estimate and tokenizer agree on the shared cjk predicate" {
  // Halfwidth katakana, kana punctuation, kana supplement and compatibility
  // ideographs are indexable units, so the estimate sees them too.
  assert_true(@base.cjk_unit(0xff76))
  assert_true(@base.cjk_unit(0x30fb))
  assert_true(@base.cjk_unit(0x31f0))
  assert_true(@base.cjk_unit(0xfa45))
  assert_eq(@base.estimate_tokens("ｶﾀｶﾅ"), 4)
  assert_eq(@base.estimate_tokens("コーヒー"), 4)
  assert_eq(@base.estimate_tokens("六"), 1)
  // Tokenizer output is unchanged by the predicate move.
  assert_eq(tokens("ｶﾀｶﾅ").length(), 7)
}

test "duplicate document ids are refused instead of silently fused" {
  let doc = (id, title) =>
    { id, title, body: "relay content", title_terms: tokens(title), body_terms: tokens("relay") }
  assert_true(try { ignore(build_index([doc("same/x", "Alpha Relay"), doc("same/x", "Beta Relay")])); false }
    catch { @base.Fault(m) => m == "index_duplicate_id: same/x" })
  assert_true(try { ignore(search([doc("same/x", "Alpha Relay"), doc("same/x", "Beta Relay")], "relay")); false }
    catch { @base.Fault(m) => m == "index_duplicate_id: same/x" })
  // Distinct ids keep working.
  assert_eq(search([doc("a", "Alpha Relay"), doc("b", "Beta Relay")], "relay").length(), 2)
}
