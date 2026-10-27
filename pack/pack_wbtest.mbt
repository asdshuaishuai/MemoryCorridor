test "CRC reference and deterministic content addressed ZIP roundtrip" {
  assert_eq(crc32(@utf8.encode("123456789")), 0xcbf43926U)
  let files : Array[File] = [
    { path: "raw/中文.pdf", data: Bytes::from_array([0, 255, 128, 1]) },
    { path: "index.mbt.md", data: @utf8.encode("catalog") },
    { path: "raw/copy.pdf", data: Bytes::from_array([0, 255, 128, 1]) },
  ]
  let bytes = encode(files)
  assert_eq(bytes, encode([files[2], files[1], files[0]]))
  let decoded = decode(bytes)
  assert_eq(decoded.length(), 3)
  assert_eq(decoded[0].path, "index.mbt.md")
  assert_eq(decoded[1].data, files[0].data)
  assert_eq(encode(decoded), bytes)
}

test "malformed ZIP, CRC, paths, versions and hidden trailing bytes refused" {
  let files : Array[File] = [{ path: "index.mbt.md", data: @utf8.encode("catalog") }]
  let bytes = encode(files)
  for length in [0, 1, 20, bytes.length()-1] {
    assert_true(try { ignore(decode(bytes[:length].to_owned())); false } catch { _ => true })
  }
  let corrupt = bytes.to_array()
  corrupt[14] = corrupt[14] ^ 1
  assert_true(try { ignore(decode(Bytes::from_array(corrupt))); false } catch { _ => true })
  let trailing = bytes.to_array()
  trailing.push(0)
  assert_true(try { ignore(decode(Bytes::from_array(trailing))); false } catch { _ => true })
  assert_true(try { ignore(encode([{ path: "../escape", data: @utf8.encode("x") }])); false } catch { _ => true })
  assert_true(try { ignore(encode([files[0], files[0]])); false } catch { _ => true })
}
