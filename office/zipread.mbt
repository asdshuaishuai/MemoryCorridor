// A permissive, read-only ZIP container reader for office originals. Real
// Word/Excel/PowerPoint files are DEFLATE-compressed and carry extra fields
// and data descriptors, so they can never satisfy the pack/zip canonical
// byte-for-byte contract the corridor bundle uses. This reader trusts only
// the central directory (sizes, CRC, offsets), verifies each entry's local
// header and CRC against the actual bytes, decrypts nothing, and enforces
// the office caps: no encrypted entries, method in {store, deflate}, names
// through the engine path validator, per-entry and total expansion bounds.

fn le16(bytes : Bytes, at : Int) -> Int {
  bytes[at].to_int() | (bytes[at+1].to_int() << 8)
}

fn le32(bytes : Bytes, at : Int) -> UInt {
  bytes[at].to_uint() | (bytes[at+1].to_uint() << 8) | (bytes[at+2].to_uint() << 16) |
    (bytes[at+3].to_uint() << 24)
}

// Bounded unsigned 32-bit field to Int: values beyond the cap are refused
// before conversion so the sign bit can never turn a huge size negative.
fn bounded_size(value : UInt, cap : UInt, what : String) -> Int raise @base.Fault {
  if value > cap { raise @base.Fault("office_zip_invalid: " + what + " over limit") }
  value.reinterpret_as_int()
}

fn read_slice(bytes : Bytes, at : Int, size : Int) -> Bytes raise @base.Fault {
  if at < 0 || size < 0 || at + size > bytes.length() { raise @base.Fault("office_zip_invalid: outside archive") }
  bytes[at:at+size].to_owned()
}

fn decode_name(bytes : Bytes) -> String raise @base.Fault {
  try @utf8.decode(bytes) catch { _ => raise @base.Fault("office_zip_invalid: name not utf8") }
}

pub fn read_package(bytes : Bytes) -> Array[@pack.File] raise @base.Fault {
  let total : Int = bytes.length()
  if total > 16777216 { raise @base.Fault("office_zip_invalid: archive over 16 MiB") }
  // End of central directory: 22 fixed bytes plus an optional comment.
  // Scan the tail backwards; a real archive's record sits within the last
  // 65557 bytes.
  let floor = if total >= 65557 { total - 65557 } else { 0 }
  let mut eocd = -1
  let mut scan = total - 22
  if scan >= 0 {
    while scan >= floor {
      if le32(bytes, scan) == 0x06054b50U { eocd = scan; break }
      scan = scan - 1
    }
  }
  if eocd < 0 { raise @base.Fault("office_zip_invalid: no end of central directory") }
  if le16(bytes, eocd + 20) != 0 { raise @base.Fault("office_zip_invalid: zip64 not supported") }
  let count = le16(bytes, eocd + 10)
  if count > 4096 { raise @base.Fault("office_part_count: > 4096") }
  let directory_size = bounded_size(le32(bytes, eocd + 12), 16777216U, "central directory")
  let directory_at = bounded_size(le32(bytes, eocd + 16), 16777216U, "central directory offset")
  if directory_at < 0 || directory_at + directory_size > eocd {
    raise @base.Fault("office_zip_invalid: central directory bounds")
  }
  let files : Array[@pack.File] = []
  let seen : Map[String, Bool] = Map([])
  let mut at = directory_at
  let end = directory_at + directory_size
  let mut expanded = 0
  while at < end {
    if end - at < 46 || le32(bytes, at) != 0x02014b50U {
      raise @base.Fault("office_zip_invalid: central record signature")
    }
    let flags = le16(bytes, at + 8)
    let compression = le16(bytes, at + 10)
    let crc = le32(bytes, at + 16)
    let size_compressed = le32(bytes, at + 20)
    let size_uncompressed = le32(bytes, at + 24)
    let name_size = le16(bytes, at + 28)
    let extra_size = le16(bytes, at + 30)
    let comment_size = le16(bytes, at + 32)
    let local_at = bounded_size(le32(bytes, at + 42), 16777216U, "local offset")
    if at + 46 + name_size + extra_size + comment_size > end {
      raise @base.Fault("office_zip_invalid: central record bounds")
    }
    let name = decode_name(read_slice(bytes, at + 46, name_size))
    if (flags & 1) != 0 { raise @base.Fault("office_zip_encrypted: " + name) }
    if compression != 0 && compression != 8 {
      raise @base.Fault("office_zip_method_unsupported: " + compression.to_string() + " in " + name)
    }
    let compressed = bounded_size(size_compressed, 16777216U, "compressed size " + name)
    let uncompressed = bounded_size(size_uncompressed, 16777216U, "uncompressed size " + name)
    if compression == 0 && uncompressed != compressed {
      raise @base.Fault("office_zip_invalid: stored entry size " + name)
    }
    @base.path(name)
    if seen.contains(name) { raise @base.Fault("office_zip_invalid: duplicate entry " + name) }
    if name.length() > 0 && name[name.length() - 1] == b'/'.to_uint16() {
      raise @base.Fault("office_zip_invalid: directory entry " + name)
    }
    seen[name] = true
    expanded = expanded + uncompressed
    if expanded > 33554432 { raise @base.Fault("office_expansion_limit: office archive") }
    // The local header must agree with the central record; the data window
    // is computed from the local extra field length.
    if local_at + 30 > total || le32(bytes, local_at) != 0x04034b50U {
      raise @base.Fault("office_zip_invalid: local header " + name)
    }
    if le16(bytes, local_at + 26) != name_size {
      raise @base.Fault("office_zip_invalid: local name length " + name)
    }
    let local_extra = le16(bytes, local_at + 28)
    let data_at = local_at + 30 + name_size + local_extra
    let raw = read_slice(bytes, data_at, compressed)
    let data = if compression == 8 { inflate(raw, 0, raw.length(), uncompressed) } else { raw }
    if @pack.crc32(data) != crc { raise @base.Fault("office_zip_crc: " + name) }
    files.push({ path: name, data })
    at = at + 46 + name_size + extra_size + comment_size
  }
  if files.length() != count { raise @base.Fault("office_zip_invalid: entry count mismatch") }
  files
}
