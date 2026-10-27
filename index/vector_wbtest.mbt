test "brute force exact ranking, stable ties and space separation" {
  let space : VectorSpace = { id: "model-v1:normalized", dimensions: 2 }
  let make = (page, values) => VectorRecord::{ page, sha256: "hash", space, values }
  let records = [make("b", [1.0,0.0]), make("a", [1.0,0.0]), make("c", [0.0,1.0]),
    { ..make("other", [1.0,0.0]), space: { id: "other-model", dimensions: 2 } }]
  let hits = search_vectors(space, [1.0,0.0], records, 3)
  assert_eq(hits.map(h => h.id), ["a", "b", "c"])
  assert_true(hits[0].score.is_close(1.0))
  assert_true(hits[2].score.is_close(0.0))
  assert_eq(search_vectors(space, [1.0,0.0], [], 2).length(), 0)
}

test "external search overrides built-in and invalid candidates rejected" {
  let space : VectorSpace = { id: "s", dimensions: 2 }
  let records : Array[VectorRecord] = [{ page: "p", sha256: "h", space, values: [1.0,0.0] }]
  let external : VectorSearchBackend = { search: (_, _, _, _) => [{ id: "p", score: 0.25 }] }
  assert_eq(search_vectors(space, [1.0,0.0], records, 1, backend=external)[0].score, 0.25)
  let bad : VectorSearchBackend = { search: (_, _, _, _) => [{ id: "unknown", score: 0.9 }] }
  assert_true(try { ignore(search_vectors(space, [1.0,0.0], records, 1, backend=bad)); false } catch { _ => true })
  assert_true(try { ignore(normalize(space, [0.0,0.0])); false } catch { _ => true })
  assert_true(try { ignore(normalize(space, [1.0])); false } catch { _ => true })
  assert_true(normalize(space, [1.0e300,1.0e300])[0].is_close(0.5.sqrt()))
}

test "external embedding provider validated independently of search" {
  let space : VectorSpace = { id: "s", dimensions: 2 }
  let provider : EmbeddingProvider = { space, embed: texts => texts.map(_ => [1.0,0.0]) }
  assert_eq(embed_texts(provider, ["文档", "查询"]).length(), 2)
  let invalid = { ..provider, embed: _ => [[1.0]] }
  assert_true(try { ignore(embed_texts(invalid, ["x"])); false } catch { _ => true })
}

test "binary32 little-endian base64 wire is bounded and deterministic" {
  let space : VectorSpace = { id: "wire-v1", dimensions: 3 }
  let values = [1.25, -2.5, 0.125]
  let encoded = values_to_base64(space, values)
  assert_eq(encoded, "AACgPwAAIMAAAAA+")
  let decoded = values_from_base64(space, encoded)
  for i = 0; i < values.length(); i = i + 1 { assert_true(decoded[i].is_close(values[i])) }
  assert_true(try { ignore(values_from_base64(space, "bad")); false } catch { _ => true })
  let short = values_to_base64({ id: "wire-v1", dimensions: 2 }, [1.25, -2.5])
  assert_true(short != encoded)
}
