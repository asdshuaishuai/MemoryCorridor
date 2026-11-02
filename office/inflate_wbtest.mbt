// RFC 1951 conformance fixtures produced by zlib raw-deflate at levels
// 0/1/6/9: stored blocks, fixed and dynamic Huffman, and long-range back
// references. The decompressor must reproduce the exact plaintext, refuse
// over-long or corrupted streams, and never read past the buffer.

fn bytes_of(csv : String) -> Bytes raise @base.Fault {
  let items : Array[Byte] = []
  for part in csv.split(",") {
    let value = part.trim()
    let mut acc = 0
    if value.is_empty() { continue }
    for c in value { acc = acc * 10 + (c.to_int() - '0'.to_int()) }
    items.push(acc.to_byte())
  }
  Bytes::from_array(items)
}

fn stored_deflate() -> Bytes raise @base.Fault { bytes_of("1,80,0,175,255,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106") }
fn stored_plain() -> Bytes raise @base.Fault { bytes_of("97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106,97,98,99,100,101,102,103,104,105,106") }

fn fixed_deflate() -> Bytes raise @base.Fault { bytes_of("11,201,72,85,40,44,205,76,206,86,72,42,202,47,207,83,72,203,175,80,200,42,205,45,40,86,200,47,75,45,82,40,1,74,231,36,86,85,42,164,228,167,235,41,132,12,14,197,0") }
fn fixed_plain() -> Bytes raise @base.Fault { bytes_of("84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,46,32,84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,46,32,84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,46,32,84,104,101,32,113,117,105,99,107,32,98,114,111,119,110,32,102,111,120,32,106,117,109,112,115,32,111,118,101,114,32,116,104,101,32,108,97,122,121,32,100,111,103,46,32") }

fn dynamic_deflate() -> Bytes raise @base.Fault { bytes_of("123,185,111,230,179,205,157,47,231,78,122,62,121,251,203,246,206,23,157,155,158,237,88,249,108,219,178,167,203,154,158,247,117,62,110,104,122,57,20,20,0,0") }
fn dynamic_plain() -> Bytes raise @base.Fault { bytes_of("233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130,233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130,233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130,233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130,233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130,233,190,153,230,179,137,233,157,146,231,147,183,233,135,137,232,137,178,230,184,169,230,182,166,229,166,130,231,142,137,227,128,130") }

fn lz77_deflate() -> Bytes raise @base.Fault { bytes_of("75,76,74,78,68,66,47,219,123,159,46,233,165,5,9,0") }
fn lz77_plain() -> Bytes raise @base.Fault { bytes_of("97,98,99,97,98,99,97,98,99,97,98,99,97,98,99,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141,233,135,141,229,164,141") }

test "inflate stored" {
  let expect = stored_plain()
  assert_eq(inflate(stored_deflate(), 0, stored_deflate().length(), expect.length()), expect)
  // Wrong expected length is a hard refusal, not a silent resize.
  assert_true(try { ignore(inflate(stored_deflate(), 0, stored_deflate().length(), expect.length() - 1)); false } catch { _ => true })
}

test "inflate fixed" {
  let expect = fixed_plain()
  assert_eq(inflate(fixed_deflate(), 0, fixed_deflate().length(), expect.length()), expect)
  // Wrong expected length is a hard refusal, not a silent resize.
  assert_true(try { ignore(inflate(fixed_deflate(), 0, fixed_deflate().length(), expect.length() - 1)); false } catch { _ => true })
}

test "inflate dynamic" {
  let expect = dynamic_plain()
  assert_eq(inflate(dynamic_deflate(), 0, dynamic_deflate().length(), expect.length()), expect)
  // Wrong expected length is a hard refusal, not a silent resize.
  assert_true(try { ignore(inflate(dynamic_deflate(), 0, dynamic_deflate().length(), expect.length() - 1)); false } catch { _ => true })
}

test "inflate lz77" {
  let expect = lz77_plain()
  assert_eq(inflate(lz77_deflate(), 0, lz77_deflate().length(), expect.length()), expect)
  // Wrong expected length is a hard refusal, not a silent resize.
  assert_true(try { ignore(inflate(lz77_deflate(), 0, lz77_deflate().length(), expect.length() - 1)); false } catch { _ => true })
}

test "inflate refuses truncated and malformed streams" {
  let whole = lz77_deflate()
  assert_true(try { ignore(inflate(whole, 0, whole.length() - 6, 200000000)); false } catch { _ => true })
  let junk = bytes_of("6,3,255") // block type 3 is invalid
  assert_true(try { ignore(inflate(junk, 0, junk.length(), 4)); false } catch { _ => true })
}
