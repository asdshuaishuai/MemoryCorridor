pub(all) struct File {
  path : String
  data : Bytes
}

let crc_table : Array[UInt] = Array::makei(256, i => {
  let mut value = i.reinterpret_as_uint()
  for bit = 0; bit < 8; bit = bit+1 {
    value = if (value & 1U) == 0U { value >> 1 } else { (value >> 1) ^ 0xedb88320U }
  }
  value
})

pub fn crc32(bytes : Bytes) -> UInt {
  let mut crc = 0xffffffffU
  for byte in bytes { crc = (crc >> 8) ^ crc_table[((crc ^ byte.to_uint()) & 255U).reinterpret_as_int()] }
  crc ^ 0xffffffffU
}

fn u16(out : Array[Byte], value : Int) -> Unit {
  out.push((value & 255).to_byte())
  out.push(((value >> 8) & 255).to_byte())
}

fn u32(out : Array[Byte], value : UInt) -> Unit {
  for shift = 0; shift < 32; shift = shift+8 { out.push(((value >> shift) & 255U).to_byte()) }
}

fn append(out : Array[Byte], bytes : Bytes) -> Unit {
  for byte in bytes { out.push(byte) }
}

fn read16(bytes : Bytes, at : Int) -> Int raise @base.Fault {
  if at < 0 || at > bytes.length()-2 { @base.fail("zip_truncated") }
  bytes[at].to_int() | (bytes[at+1].to_int() << 8)
}

fn read32(bytes : Bytes, at : Int) -> UInt raise @base.Fault {
  if at < 0 || at > bytes.length()-4 { @base.fail("zip_truncated") }
  bytes[at].to_uint() | (bytes[at+1].to_uint() << 8) | (bytes[at+2].to_uint() << 16) | (bytes[at+3].to_uint() << 24)
}

fn zip_encode(files : Array[File]) -> Bytes raise @base.Fault {
  let sorted = files.copy()
  sorted.sort_by((a,b) => @base.compare(a.path, b.path))
  let out : Array[Byte] = []
  let directory : Array[Byte] = []
  for file in sorted {
    @base.path(file.path)
    let name = @utf8.encode(file.path)
    if name.length() > 4096 || file.data.length() > 16777216 { @base.fail("zip_entry_limit") }
    let offset = out.length()
    let crc = crc32(file.data)
    let size = file.data.length().reinterpret_as_uint()
    u32(out, 0x04034b50U)
    u16(out, 20); u16(out, 0x800); u16(out, 0); u16(out, 0); u16(out, 0x21)
    u32(out, crc); u32(out, size); u32(out, size)
    u16(out, name.length()); u16(out, 0)
    append(out, name); append(out, file.data)
    u32(directory, 0x02014b50U)
    u16(directory, 0x0314); u16(directory, 20); u16(directory, 0x800)
    u16(directory, 0); u16(directory, 0); u16(directory, 0x21)
    u32(directory, crc); u32(directory, size); u32(directory, size)
    u16(directory, name.length()); u16(directory, 0); u16(directory, 0)
    u16(directory, 0); u16(directory, 0); u32(directory, 0x81a40000U)
    u32(directory, offset.reinterpret_as_uint()); append(directory, name)
    if out.length()+directory.length() > 16777194 { @base.fail("zip_total_limit") }
  }
  let central_offset = out.length()
  append(out, Bytes::from_array(directory))
  u32(out, 0x06054b50U)
  u16(out, 0); u16(out, 0); u16(out, sorted.length()); u16(out, sorted.length())
  u32(out, directory.length().reinterpret_as_uint()); u32(out, central_offset.reinterpret_as_uint()); u16(out, 0)
  Bytes::from_array(out)
}

fn zip_decode(bytes : Bytes) -> Array[File] raise @base.Fault {
  if bytes.length() > 16777216 { @base.fail("zip_total_limit") }
  let files : Array[File] = []
  let seen : Map[String, Bool] = Map([])
  let mut at = 0
  while read32(bytes, at) == 0x04034b50U {
    if files.length() >= 4097 { @base.fail("zip_file_count_limit") }
    if read16(bytes, at+4) != 20 || read16(bytes, at+6) != 0x800 || read16(bytes, at+8) != 0 {
      @base.fail("zip_feature_unsupported: STORE/UTF8 v20 only")
    }
    let size = read32(bytes, at+18)
    if size > 16777216U || size != read32(bytes, at+22) || read16(bytes, at+28) != 0 { @base.fail("zip_size_or_extra_refused") }
    let name_size = read16(bytes, at+26)
    if name_size == 0 || name_size > 4096 { @base.fail("zip_name_limit") }
    let start = at+30+name_size
    let end = start+size.reinterpret_as_int()
    if end > bytes.length() { @base.fail("zip_truncated") }
    let name = try @utf8.decode(bytes[at+30:start]) catch { _ => raise @base.Fault("zip_filename_utf8") }
    @base.path(name)
    if seen.contains(name) { @base.fail("zip_duplicate_name") }
    seen[name] = true
    let data = bytes[start:end].to_owned()
    if crc32(data) != read32(bytes, at+14) { @base.fail("zip_crc_mismatch: " + name) }
    files.push({ path: name, data })
    at = end
  }
  // Reconstructing all central records also checks offsets, flags, permissions,
  // entry order, duplicates, signatures, trailing data and hidden link entries.
  if zip_encode(files) != bytes { @base.fail("zip_noncanonical_or_corrupt") }
  files
}
