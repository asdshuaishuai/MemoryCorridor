// Minimal XML event scanner for OOXML parts. OOXML restricts itself to plain
// elements, attributes and character data; this reader produces the same
// events for that shape and refuses malformed markup deterministically rather
// than recovering silently. Processing instructions and comments are skipped;
// character entities (named and numeric, decimal and hex) are decoded. The
// grammar is deliberately not full XML: DTDs and CDATA are rejected so a part
// can never smuggle external references.

pub(all) enum XmlEvent {
  Start(String, Map[String, String], Bool)
  End(String)
  Text(String)
} derive(Eq)
pub extend XmlEvent with Eq::{not_equal, equal}

// Test-facing rendering of events; the production extractors never stringify.
pub fn XmlEvent::describe(self : XmlEvent) -> String {
  match self {
    Start(name, attrs, self_closing) => {
      let mut rendered = "start " + name
      for (key, value) in attrs.iter() { rendered = rendered + " " + key + "=" + value }
      if self_closing { rendered = rendered + " /" }
      rendered
    }
    End(name) => "end " + name
    Text(value) => "text " + value
  }
}

fn is_name_start(unit : UInt16) -> Bool {
  (unit >= b'a'.to_uint16() && unit <= b'z'.to_uint16()) ||
  (unit >= b'A'.to_uint16() && unit <= b'Z'.to_uint16()) ||
  unit == b'_'.to_uint16() || unit == b':'.to_uint16()
}

fn is_name_char(unit : UInt16) -> Bool {
  is_name_start(unit) || (unit >= b'0'.to_uint16() && unit <= b'9'.to_uint16()) ||
  unit == b'-'.to_uint16() || unit == b'.'.to_uint16()
}

fn is_ws(unit : UInt16) -> Bool {
  unit == b' '.to_uint16() || unit == b'\t'.to_uint16() ||
  unit == b'\n'.to_uint16() || unit == b'\r'.to_uint16()
}

fn skip_ws(source : String, from : Int) -> Int {
  let mut i = from
  while i < source.length() && is_ws(source[i]) { i = i + 1 }
  i
}

fn read_name(source : String, from : Int) -> (String, Int) {
  let mut i = from
  while i < source.length() && is_name_char(source[i]) { i = i + 1 }
  (source[from:i].to_owned(), i)
}

// Encode one Unicode scalar as UTF-8; the code point is already validated.
fn code_point_string(value : Int) -> String raise @base.Fault {
  let bytes : Array[Byte] = []
  if value < 0x80 {
    bytes.push(value.to_byte())
  } else if value < 0x800 {
    bytes.push((0xC0 + (value >> 6)).to_byte())
    bytes.push((0x80 + (value & 0x3F)).to_byte())
  } else if value < 0x10000 {
    bytes.push((0xE0 + (value >> 12)).to_byte())
    bytes.push((0x80 + ((value >> 6) & 0x3F)).to_byte())
    bytes.push((0x80 + (value & 0x3F)).to_byte())
  } else {
    bytes.push((0xF0 + (value >> 18)).to_byte())
    bytes.push((0x80 + ((value >> 12) & 0x3F)).to_byte())
    bytes.push((0x80 + ((value >> 6) & 0x3F)).to_byte())
    bytes.push((0x80 + (value & 0x3F)).to_byte())
  }
  try @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => raise @base.Fault("xml_code_point_invalid")
  }
}

// source[from] == '&'; decode up to ';' within a short entity window.
fn entity_value(source : String, from : Int) -> (String, Int)? raise @base.Fault {
  let mut j = from + 1
  while j < source.length() && j - from <= 12 && source[j] != b';'.to_uint16() { j = j + 1 }
  if j >= source.length() || source[j] != b';'.to_uint16() { return None }
  let body = source[from+1:j].to_owned()
  let mut value = 0
  if body.has_prefix("#x") || body.has_prefix("#X") {
    let digits = body[2:].to_owned()
    if digits.is_empty() { return None }
    for c in digits {
      let d = if c >= '0' && c <= '9' { c.to_int() - '0'.to_int() }
        else if c >= 'a' && c <= 'f' { c.to_int() - 'a'.to_int() + 10 }
      else if c >= 'A' && c <= 'F' { c.to_int() - 'A'.to_int() + 10 }
      else { return None }
      value = value * 16 + d
    }
  } else if body.has_prefix("#") {
    let digits = body[1:].to_owned()
    if digits.is_empty() { return None }
    for c in digits {
      if c < '0' || c > '9' { return None }
      value = value * 10 + (c.to_int() - '0'.to_int())
    }
  } else {
    value = match body {
      "amp" => 38
      "lt" => 60
      "gt" => 62
      "quot" => 34
      "apos" => 39
      _ => return None
    }
  }
  if value == 0 || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) { return None }
  Some((code_point_string(value), j + 1))
}

fn decode_entities(source : String) -> String raise @base.Fault {
  let out = StringBuilder()
  let mut i = 0
  while i < source.length() {
    if source[i] == b'&'.to_uint16() {
      match entity_value(source, i) {
        Some((value, next)) => {
          out.write_string(value)
          i = next
        }
        None => { out.write_string("&"); i = i + 1 }
      }
    } else {
      out.write_string(source[i:i+1].to_owned())
      i = i + 1
    }
  }
  out.to_string()
}

fn has_prefix_at(source : String, at : Int, prefix : String) -> Bool {
  at + prefix.length() <= source.length() && source[at:at+prefix.length()].to_owned() == prefix
}

/// Scan an OOXML part into events. A nameless tag, a stray `<`, an unclosed
/// tag, a CDATA section or a DTD all raise; document text extraction never
/// needs them and refusing keeps the parser total and deterministic.
pub fn xml_events(source : String) -> Array[XmlEvent] raise @base.Fault {
  let events : Array[XmlEvent] = []
  let mut i = 0
  while i < source.length() {
    if source[i] != b'<'.to_uint16() {
      let start = i
      while i < source.length() && source[i] != b'<'.to_uint16() { i = i + 1 }
      let text = source[start:i].to_owned()
      if !text.trim().is_empty() { events.push(Text(decode_entities(text))) }
      continue
    }
    if i + 1 < source.length() && source[i+1] == b'?'.to_uint16() {
      let mut j = i + 2
      while j + 1 < source.length() && !(source[j] == b'?'.to_uint16() && source[j+1] == b'>'.to_uint16()) { j = j + 1 }
      if j + 1 >= source.length() { raise @base.Fault("xml_unterminated_instruction") }
      i = j + 2
      continue
    }
    if has_prefix_at(source, i + 1, "!--") {
      let mut j = i + 4
      while j + 2 < source.length() && source[j:j+3].to_owned() != "-->" { j = j + 1 }
      if j + 2 >= source.length() { raise @base.Fault("xml_unterminated_comment") }
      i = j + 3
      continue
    }
    if has_prefix_at(source, i + 1, "![CDATA[") { raise @base.Fault("xml_cdata_unsupported") }
    if has_prefix_at(source, i + 1, "!DOCTYPE") { raise @base.Fault("xml_dtd_unsupported") }
    let mut j = i + 1
    let closing = j < source.length() && source[j] == b'/'.to_uint16()
    if closing { j = j + 1 }
    let (name, after_name) = read_name(source, j)
    if name.is_empty() { raise @base.Fault("xml_unnamed_tag") }
    let mut k = after_name
    let attrs : Map[String, String] = Map([])
    let mut self_closing = false
    while true {
      k = skip_ws(source, k)
      if k >= source.length() { raise @base.Fault("xml_unterminated_tag") }
      if source[k] == b'>'.to_uint16() { k = k + 1; break }
      if source[k] == b'/'.to_uint16() {
        if k + 1 < source.length() && source[k+1] == b'>'.to_uint16() {
          self_closing = true
          k = k + 2
          break
        }
        raise @base.Fault("xml_unterminated_tag")
      }
      let (attr_name, after_attr) = read_name(source, k)
      if attr_name.is_empty() { raise @base.Fault("xml_attribute_unnamed") }
      let mut pos = skip_ws(source, after_attr)
      if pos < source.length() && source[pos] == b'='.to_uint16() {
        pos = skip_ws(source, pos + 1)
        if pos >= source.length() || (source[pos] != b'"'.to_uint16() && source[pos] != b'\''.to_uint16()) {
          raise @base.Fault("xml_attribute_value_unquoted")
        }
        let quote = source[pos]
        let start = pos + 1
        pos = pos + 1
        while pos < source.length() && source[pos] != quote { pos = pos + 1 }
        if pos >= source.length() { raise @base.Fault("xml_attribute_unterminated") }
        attrs[attr_name] = decode_entities(source[start:pos].to_owned())
        pos = pos + 1
      } else {
        attrs[attr_name] = ""
      }
      k = pos
    }
    if closing {
      if !attrs.is_empty() || self_closing { raise @base.Fault("xml_close_tag_with_data") }
      events.push(End(name))
    } else {
      events.push(Start(name, attrs, self_closing))
    }
    i = k
  }
  events
}
