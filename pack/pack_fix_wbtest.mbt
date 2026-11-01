// Probes for the round-1 hunt fixes: ambiguous path refusal (NFC/NFD and case
// folds collapse on normalization-insensitive file systems) and the single
// 16 MiB ceiling shared by the pack and zip layers.

fn index_file() -> File {
  { path: "index.mbt.md", data: @utf8.encode("index") }
}

fn manifest_row(path : String, data : Bytes) -> Json {
  { "path": path, "sha256": @base.sha256_hex(data), "size": data.length() }
}

test "paths that fold together on a real filesystem are refused" {
  // NFC and NFD spellings of the same name must not coexist in one pack.
  let nfc = { path: "raw/caf\u{00e9}.pdf", data: Bytes::from_array([1, 1, 1, 1]) }
  let nfd = { path: "raw/caf\u{0301}.pdf", data: Bytes::from_array([2, 2, 2, 2]) }
  assert_true(try { ignore(encode([index_file(), nfc, nfd])); false }
    catch { @base.Fault(m) => m.has_prefix("pack_path_ambiguous") })
  // Case variants are refused the same way (macOS APFS folds case).
  assert_true(try { ignore(encode([index_file(), { path: "raw/A.md", data: nfc.data }, { path: "raw/a.md", data: nfd.data }])); false }
    catch { @base.Fault(m) => m.has_prefix("pack_path_ambiguous") })
  // A precomposed spelling on its own encodes and round-trips byte-exactly.
  let encoded = encode([index_file(), nfc])
  assert_eq(decode(encoded).filter(f => f.path == nfc.path)[0].data, nfc.data)
  // Exact duplicates keep their dedicated code.
  assert_true(try { ignore(encode([index_file(), index_file()])); false }
    catch { @base.Fault(m) => m == "pack_duplicate_path" })
}

test "decode refuses a manifest whose entries fold together" {
  let payload = Bytes::from_array([9, 9])
  let other = Bytes::from_array([7, 7])
  let files : Array[Json] = [
    manifest_row(index_file().path, index_file().data),
    manifest_row("raw/A.md", payload),
    manifest_row("raw/a.md", other),
  ]
  let manifest : Json = {
    "format": "memorycorridor-pack", "version": 1,
    "vault_fingerprint": @base.sha256_hex(index_file().data).to_json(),
    "files": files.to_json(),
  }
  let entries : Array[File] = [
    { path: "manifest.json", data: @utf8.encode(@base.canonical(manifest)) },
    { path: "objects/" + @base.sha256_hex(index_file().data), data: index_file().data },
    { path: "objects/" + @base.sha256_hex(payload), data: payload },
    { path: "objects/" + @base.sha256_hex(other), data: other },
  ]
  assert_true(try { ignore(decode(zip_encode(entries))); false }
    catch { @base.Fault(m) => m.has_prefix("pack_path_ambiguous") })
}

test "the 16 MiB ceiling is one constant and one error code" {
  // Payload sized so the logical total (index + payload) stays under 16 MiB
  // while the encoded stream crosses it: the bundle layer must reject with the
  // pack code instead of letting the zip layer reject with zip_total_limit.
  let payload = Bytes::new(16777130)
  assert_true(try {
    ignore(encode([index_file(), { path: "raw/blob.bin", data: payload }]))
    false
  } catch { @base.Fault(m) => m == "pack_expanded_limit" })
  // Gross overflow keeps failing early in the loop.
  assert_true(try {
    ignore(encode([index_file(), { path: "raw/big.bin", data: Bytes::new(16777216) }]))
    false
  } catch { @base.Fault(m) => m == "pack_expanded_limit" })
  // A small pack still round-trips.
  let small = encode([index_file(), { path: "raw/tiny.bin", data: Bytes::from_array([1]) }])
  assert_eq(decode(small).length(), 2)
}
