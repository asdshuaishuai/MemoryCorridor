// Compact host exchange format for vectors. Values are IEEE-754 binary32,
// little-endian, then RFC 4648 Base64 encoded. Native records stay canonical
// JSON arrays so the vault remains inspectable and deterministic.
pub fn values_from_base64(space : VectorSpace, encoded : String) -> Array[Double] raise @base.Fault {
  let bytes = try @base64.decode(encoded) catch { _ => raise @base.Fault("vector_base64_invalid") }
  if bytes.length() != space.dimensions * 4 { @base.fail("vector_base64_length_mismatch") }
  let values : Array[Double] = []
  for i = 0; i < space.dimensions; i = i + 1 {
    let offset = i * 4
    let bits = bytes[offset].to_int() |
      (bytes[offset + 1].to_int() << 8) |
      (bytes[offset + 2].to_int() << 16) |
      (bytes[offset + 3].to_int() << 24)
    let value = Float::reinterpret_from_uint(bits.reinterpret_as_uint()).to_double()
    if value.is_nan() || value.is_inf() { @base.fail("vector_base64_nonfinite") }
    values.push(value)
  }
  ignore(normalize(space, values))
  values
}

pub fn values_to_base64(space : VectorSpace, values : Array[Double]) -> String raise @base.Fault {
  ignore(normalize(space, values))
  let bytes : Array[Byte] = []
  for value in values {
    let bits = Float::from_double(value).reinterpret_as_uint()
    bytes.push((bits & 0xff).to_byte())
    bytes.push(((bits >> 8) & 0xff).to_byte())
    bytes.push(((bits >> 16) & 0xff).to_byte())
    bytes.push(((bits >> 24) & 0xff).to_byte())
  }
  @base64.encode(Bytes::from_array(bytes))
}
