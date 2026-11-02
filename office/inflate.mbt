// RFC 1951 DEFLATE decompressor — self-implemented, total and deterministic,
// sized for OOXML document parts rather than general-purpose archival. Only
// the raw (zlib-less) stream is handled; every structure is bounds-checked
// against the input and the produced length, and output stops at a hard cap
// so a hostile archive can neither read past the buffer nor expand beyond
// the office budget.

const INFLATE_LIMIT : Int = 33_554_432 // 32 MiB, the office expansion budget

// Canonical Huffman decoding: counts[len] symbols of that bit length,
// symbols[] in canonical order. Decoding walks one bit at a time.
priv struct Huff {
  counts : Array[Int]
  symbols : Array[Int]
}

fn build_huff(lens : Array[Int]) -> Huff {
  let counts = Array::makei(16, _ => 0)
  for length in lens { counts[length] = counts[length] + 1 }
  let offsets = Array::makei(16, _ => 0)
  let mut total = 0
  for length = 1; length < 16; length = length + 1 {
    offsets[length] = total
    total = total + counts[length]
  }
  let symbols = Array::makei(lens.length(), _ => 0)
  for value = 0; value < lens.length(); value = value + 1 {
    let length = lens[value]
    if length > 0 {
      symbols[offsets[length]] = value
      offsets[length] = offsets[length] + 1
    }
  }
  { counts, symbols }
}

priv struct Reader {
  bytes : Bytes
  pos : Ref[Int] // byte position
  bit : Ref[Int] // bit consumed within bytes[pos], LSB first
}

fn take_bit(reader : Reader) -> Int raise @base.Fault {
  if reader.pos.val >= reader.bytes.length() { raise @base.Fault("inflate_truncated") }
  let value = (reader.bytes[reader.pos.val].to_int() >> reader.bit.val) & 1
  reader.bit.val = reader.bit.val + 1
  if reader.bit.val == 8 {
    reader.bit.val = 0
    reader.pos.val = reader.pos.val + 1
  }
  value
}

fn take_bits(reader : Reader, count : Int) -> Int raise @base.Fault {
  let mut value = 0
  for i = 0; i < count; i = i + 1 {
    value = value | (take_bit(reader) << i)
  }
  value
}

fn take_byte(reader : Reader) -> Int raise @base.Fault {
  reader.bit.val = 0
  if reader.pos.val >= reader.bytes.length() { raise @base.Fault("inflate_truncated") }
  let value = reader.bytes[reader.pos.val].to_int()
  reader.pos.val = reader.pos.val + 1
  value
}

fn decode_symbol(reader : Reader, huff : Huff) -> Int raise @base.Fault {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for length = 1; length < 16; length = length + 1 {
    code = code | take_bit(reader)
    let count = huff.counts[length]
    if code - first < count { return huff.symbols[index + (code - first)] }
    index = index + count
    first = (first + count) << 1
    code = code << 1
  }
  raise @base.Fault("inflate_bad_code")
}

// Fixed tables per RFC 1951 3.2.6.
fn fixed_literal() -> Huff {
  let lens = Array::makei(288, _ => 0)
  for i = 0; i < 144; i = i + 1 { lens[i] = 8 }
  for i = 144; i < 256; i = i + 1 { lens[i] = 9 }
  for i = 256; i < 280; i = i + 1 { lens[i] = 7 }
  for i = 280; i < 288; i = i + 1 { lens[i] = 8 }
  build_huff(lens)
}

fn fixed_distance() -> Huff {
  build_huff(Array::makei(30, _ => 5))
}

let length_base : Array[Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
let length_extra : Array[Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
let distance_base : Array[Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
let distance_extra : Array[Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
let code_order : Array[Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

fn read_dynamic(reader : Reader) -> (Huff, Huff) raise @base.Fault {
  let hlit = take_bits(reader, 5) + 257
  let hdist = take_bits(reader, 5) + 1
  let hclen = take_bits(reader, 4) + 4
  if hlit > 286 || hdist > 30 { raise @base.Fault("inflate_bad_tables") }
  let code_lens = Array::makei(19, _ => 0)
  for i = 0; i < hclen; i = i + 1 { code_lens[code_order[i]] = take_bits(reader, 3) }
  let code_huff = build_huff(code_lens)
  let lens = Array::makei(hlit + hdist, _ => -1)
  let mut i = 0
  while i < hlit + hdist {
    let symbol = decode_symbol(reader, code_huff)
    if symbol < 16 {
      lens[i] = symbol
      i = i + 1
    } else if symbol == 16 {
      if i == 0 || lens[i-1] < 0 { raise @base.Fault("inflate_bad_rle") }
      let repeat = 3 + take_bits(reader, 2)
      if i + repeat > hlit + hdist { raise @base.Fault("inflate_bad_rle") }
      for r = 0; r < repeat; r = r + 1 { lens[i+r] = lens[i-1] }
      i = i + repeat
    } else if symbol == 17 {
      let repeat = 3 + take_bits(reader, 3)
      if i + repeat > hlit + hdist { raise @base.Fault("inflate_bad_rle") }
      for r = 0; r < repeat; r = r + 1 { lens[i+r] = 0 }
      i = i + repeat
    } else {
      let repeat = 11 + take_bits(reader, 7)
      if i + repeat > hlit + hdist { raise @base.Fault("inflate_bad_rle") }
      for r = 0; r < repeat; r = r + 1 { lens[i+r] = 0 }
      i = i + repeat
    }
  }
  // A block with no distance codes still decodes as long as none are used;
  // build a permissive all-zero table so the decoder refuses with a clean
  // error instead of a crash if one is referenced.
  let literal_lens = lens[:hlit].to_owned()
  let distance_lens = lens[hlit:].to_owned()
  (build_huff(literal_lens), build_huff(distance_lens))
}

/// Inflate one raw DEFLATE stream. `expected` is the exact declared output
/// length; the result is verified against it, keeping hostile or corrupt
/// data from producing a different-size buffer than the ZIP central
/// directory promised.
pub fn inflate(data : Bytes, start : Int, size : Int, expected : Int) -> Bytes raise @base.Fault {
  if expected < 0 || expected > INFLATE_LIMIT { raise @base.Fault("office_expansion_limit") }
  let reader : Reader = { bytes: data[start:start+size].to_owned(), pos: @ref.new(0), bit: @ref.new(0) }
  let out : Array[Byte] = []
  let mut final_block = false
  while !final_block {
    final_block = take_bit(reader) == 1
    match take_bits(reader, 2) {
      0 => {
        // Discard the rest of the partial byte: the block header ends on a
        // byte boundary.
        if reader.bit.val > 0 {
          reader.pos.val = reader.pos.val + 1
          reader.bit.val = 0
        }
        let len = take_byte(reader) | (take_byte(reader) << 8)
        let nlen = take_byte(reader) | (take_byte(reader) << 8)
        if (len ^ 0xFFFF) != nlen { raise @base.Fault("inflate_stored_length") }
        if reader.pos.val + len > reader.bytes.length() { raise @base.Fault("inflate_truncated") }
        for i = 0; i < len; i = i + 1 { out.push(reader.bytes[reader.pos.val+i]) }
        reader.pos.val = reader.pos.val + len
      }
      1 => {
        inflate_block(reader, fixed_literal(), fixed_distance(), out)
      }
      2 => {
        let (literal, distance) = read_dynamic(reader)
        inflate_block(reader, literal, distance, out)
      }
      _ => raise @base.Fault("inflate_bad_block_type")
    }
  }
  if out.length() != expected { raise @base.Fault("inflate_size_mismatch") }
  Bytes::from_array(out)
}

fn inflate_block(reader : Reader, literal : Huff, distance : Huff, out : Array[Byte]) -> Unit raise @base.Fault {
  while true {
    let symbol = decode_symbol(reader, literal)
    if symbol < 256 {
      out.push(symbol.to_byte())
    } else if symbol == 256 {
      return
    } else {
      let index = symbol - 257
      if index >= length_base.length() { raise @base.Fault("inflate_bad_length") }
      let length = length_base[index] + take_bits(reader, length_extra[index])
      let distance_symbol = decode_symbol(reader, distance)
      if distance_symbol >= distance_base.length() { raise @base.Fault("inflate_bad_distance") }
      let back = distance_base[distance_symbol] + take_bits(reader, distance_extra[distance_symbol])
      if back > out.length() { raise @base.Fault("inflate_bad_back_distance") }
      if out.length() + length > INFLATE_LIMIT { raise @base.Fault("office_expansion_limit") }
      for i = 0; i < length; i = i + 1 {
        let source = out[out.length() - back]
        out.push(source)
      }
    }
  }
}
