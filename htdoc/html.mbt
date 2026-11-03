// HTML visible-text extraction inside the engine. Web *fetching* is a
// network ability and stays host-side (AGENTS boundary), but the bytes a
// host stores are text: their projection to visible content is deterministic
// data processing -- the same channel shape OOXML had in 续十一.
// `read-source` keeps reporting raw bytes, `context` serves this extraction,
// and the extraction sidecar refuses to shadow it.
//
// The scanner honours HTML tolerance where tolerance cannot change published
// text (lowercase tags, void elements, quoted or bare attributes, a bare `<`
// as literal, comments closing at EOF) and refuses where a silent choice
// would publish wrong or partial text: non-UTF-8 bytes (`html_utf8_invalid`,
// transcode host-side), numeric entities with illegal codepoints, and an
// unterminated `<script>`/`<style>` whose skip region would otherwise
// swallow the rest of the visible document -- the 续十六 F1/F2 latch lesson
// applied proactively. Whitespace-only text nodes between tags are treated
// as formatting, never body (unlike OOXML, where `<w:t> </w:t>` *is* body).
// Indexing follows the ByteUnit (UTF-16 code unit) idiom of office/xml.mbt.

///|
pub fn is_html_format(format : String) -> Bool { format == "html" }

///|
pub fn text(bytes : Bytes) -> String raise @base.Fault {
  let source = @utf8.decode(bytes) catch {
    _ => raise @base.Fault("html_utf8_invalid: transcode host-side before registering")
  }
  extract(source)
}

// ------------------------------------------------------------- scanning

enum HEvent {
  HStart(String, Bool) // lowercased name, self-closing/void
  HEnd(String)
  HText(String) // entity-decoded text; script/style interiors are dropped
}

///|
fn is_name_unit(u : UInt16) -> Bool {
  (u >= b'a'.to_uint16() && u <= b'z'.to_uint16()) ||
    (u >= b'A'.to_uint16() && u <= b'Z'.to_uint16()) ||
    (u >= b'0'.to_uint16() && u <= b'9'.to_uint16()) ||
    u == b'-'.to_uint16() || u == b'_'.to_uint16() || u == b':'.to_uint16()
}

///|
fn lower_name(slice : String) -> String raise @base.Fault {
  let bytes : Array[Byte] = []
  for c in slice {
    let v = c.to_int()
    bytes.push(if v >= 65 && v <= 90 { (v + 32).to_byte() } else { v.to_byte() })
  }
  @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => raise @base.Fault("html_tag_name_invalid")
  }
}

///|
fn is_void(name : String) -> Bool {
  ["area", "base", "br", "col", "embed", "hr", "img", "input",
   "link", "meta", "param", "source", "track", "wbr"].contains(name)
}

///|
fn has_prefix_at(source : String, at : Int, prefix : String) -> Bool {
  at >= 0 && at + prefix.length() <= source.length() &&
    source[at:at + prefix.length()].to_owned() == prefix
}

///|
pub fn scan(source : String) -> Array[HEvent] raise @base.Fault {
  let events : Array[HEvent] = []
  let mut i = 0
  let mut skip : String? = None // "script"/"style": interior dropped
  let n = source.length()
  while i < n {
    match skip {
      Some(region) => {
        // interior of script/style is raw text: find `</region` verbatim
        // (case-insensitive), never tag-parse inside it
        let mut closed = false
        while i < n {
          if source[i] == b'<'.to_uint16() && i + 2 <= n && source[i + 1] == b'/'.to_uint16() &&
            lower_name(source[i + 2:((i + 2) + region.length()).min(n)].to_owned()) == region {
            let mut j = i + 2 + region.length()
            while j < n && source[j] != b'>'.to_uint16() { j = j + 1 }
            i = if j < n { j + 1 } else { j }
            skip = None
            closed = true
            break
          }
          i = i + 1
        }
        if !closed { @base.fail("html_unterminated_" + region) }
        continue
      }
      None => ()
    }
    if source[i] != b'<'.to_uint16() {
      let start = i
      while i < n && source[i] != b'<'.to_uint16() { i = i + 1 }
      events.push(HText(decode_entities(source[start:i].to_owned())))
      continue
    }
    if has_prefix_at(source, i + 1, "!--") {
      // comment: unterminated runs to EOF (legal HTML; deletes only content
      // that was never visible text, unlike a skip region over the body)
      let mut j = i + 4
      let mut closed = false
      while j + 2 < n {
        if has_prefix_at(source, j, "-->") { closed = true; j = j + 3; break }
        j = j + 1
      }
      i = if closed { j } else { n }
      continue
    }
    if source.get(i + 1).map(u => u == b'!'.to_uint16() || u == b'?'.to_uint16()).unwrap_or(false) {
      let mut j = i + 1
      while j < n && source[j] != b'>'.to_uint16() { j = j + 1 }
      i = if j < n { j + 1 } else { j }
      continue
    }
    let mut j = i + 1
    let closing_tag = j < n && source[j] == b'/'.to_uint16()
    if closing_tag { j = j + 1 }
    let name_start = j
    while j < n && is_name_unit(source[j]) { j = j + 1 }
    if j == name_start {
      match skip {
        None => events.push(HText("<"))
        Some(_) => ()
      }
      i = i + 1
      continue
    }
    let name = lower_name(source[name_start:j].to_owned())
    let mut k = j
    let mut self_close = false
    while k < n {
      let c = source[k]
      if c == b'"'.to_uint16() || c == b'\''.to_uint16() {
        k = k + 1
        while k < n && source[k] != c { k = k + 1 }
        if k >= n { @base.fail("html_unterminated_attribute") }
        k = k + 1
        continue
      }
      if c == b'>'.to_uint16() { break }
      if c == b'/'.to_uint16() && k + 1 < n && source[k + 1] == b'>'.to_uint16() { self_close = true; break }
      k = k + 1
    }
    if k >= n { @base.fail("html_unterminated_tag") }
    i = if self_close { k + 2 } else { k + 1 }
    if closing_tag {
      events.push(HEnd(name))
      continue
    }
    let closed = is_void(name) || self_close
    if (name == "script" || name == "style" || name == "template") && !closed {
      skip = Some(name)
    }
    events.push(HStart(name, closed))
  }
  events
}

// ------------------------------------------------------------- entities

///|
fn entity_end(text : String, from : Int) -> Int? {
  let mut j = from + 1
  let mut found = false
  while j < text.length() && j - from <= 12 {
    let c = text[j]
    if c == b';'.to_uint16() {
      found = true
      break
    }
    if !(is_name_unit(c) || c == b'#'.to_uint16()) {
      return None
    }
    j = j + 1
  }
  if found { Some(j) } else { None }
}

///|
fn named_entity(body : String) -> String? {
  match body {
    "amp" => Some("&")
    "lt" => Some("<")
    "gt" => Some(">")
    "quot" => Some("\"")
    "apos" => Some("'")
    "nbsp" => Some(" ")
    _ => None
  }
}

///|
fn digit_of(c : Char, base : Int) -> Int raise @base.Fault {
  let v = c.to_int()
  if v >= 48 && v <= 57 {
    v - 48
  } else if base == 16 && v >= 97 && v <= 102 {
    v - 97 + 10
  } else if base == 16 && v >= 65 && v <= 70 {
    v - 65 + 10
  } else {
    raise @base.Fault("html_entity_invalid")
  }
}

///|
fn numeric_value(digits : String, base : Int) -> Int raise @base.Fault {
  if digits.is_empty() { @base.fail("html_entity_invalid") }
  let mut acc = 0
  for c in digits {
    acc = acc * base + digit_of(c, base)
    if acc > 0x10_FFFF { @base.fail("html_entity_invalid") }
  }
  acc
}

///|
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
  @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => raise @base.Fault("html_code_point_invalid")
  }
}

///|
fn push_codepoint(out : StringBuilder, value : Int, body : String) -> Unit raise @base.Fault {
  let legal = value == 9 || value == 10 || value == 13 ||
    (value >= 32 && value <= 0xD7FF) ||
    (value >= 0xE000 && value <= 0xFFFD) ||
    (value >= 0x10000 && value <= 0x10FFFF)
  if !legal { @base.fail("html_entity_codepoint_invalid: &" + body + ";") }
  out.write_string(code_point_string(value))
}

///|
fn decode_entities(text : String) -> String raise @base.Fault {
  let out = StringBuilder()
  let mut i = 0
  let n = text.length()
  while i < n {
    if text[i] == b'&'.to_uint16() {
      match entity_end(text, i) {
        Some(j) => {
          let body = text[i + 1:j].to_owned()
          if body.has_prefix("#x") || body.has_prefix("#X") {
            push_codepoint(out, numeric_value(body[2:].to_owned(), 16), body)
          } else if body.has_prefix("#") {
            push_codepoint(out, numeric_value(body[1:].to_owned(), 10), body)
          } else {
            match named_entity(body) {
              Some(s) => out.write_string(s)
              None => {
                // unknown named entity stays literal (HTML leniency)
                out.write_string("&")
                out.write_string(body)
                out.write_string(";")
              }
            }
          }
          i = j + 1
          continue
        }
        None => ()
      }
    }
    out.write_string(text[i:i + 1].to_owned())
    i = i + 1
  }
  out.to_string()
}

// ------------------------------------------------------------- extraction

///|
fn is_block(name : String) -> Bool {
  ["p", "div", "li", "ul", "ol", "tr", "table", "h1", "h2", "h3",
   "h4", "h5", "h6", "blockquote", "pre", "article", "section", "header",
   "footer", "main", "aside", "figcaption", "dl", "dt", "dd", "body"].contains(name)
}

///|
fn flush_line(lines : Array[String], current : String) -> String {
  let s = current.trim().to_owned()
  if !s.is_empty() { lines.push(s) }
  ""
}

/// pre content is verbatim: interior indentation is body, not noise. Only
/// the surrounding newline (right after `<pre>` / before `</pre>`) is cut.
fn trim_newlines(s0 : String) -> String {
  let mut a = 0
  let mut b = s0.length()
  while a < b && s0[a] == b'\n'.to_uint16() { a = a + 1 }
  while b > a && s0[b - 1] == b'\n'.to_uint16() { b = b - 1 }
  s0[a:b].to_owned()
}

fn flush_pre(lines : Array[String], current : String) -> String {
  let s = trim_newlines(current)
  if !s.is_empty() { lines.push(s) }
  ""
}

///|
fn extract(source : String) -> String raise @base.Fault {
  let events = scan(source)
  let lines : Array[String] = []
  let mut current = ""
  let mut in_head = false
  let mut in_title = false
  let mut in_pre = false
  let mut pending_break = false
  for e in events {
    match e {
      HStart(name, closed) =>
        if name == "br" {
          if in_pre { current = current + "\n" } else { current = flush_line(lines, current) }
        } else if name == "head" {
          in_head = true
        } else if name == "title" && !closed {
          // a self-closing `<title/>` must not latch title capture to EOF
          // (the 续十六 F1 family applied here proactively)
          in_title = true
          current = flush_line(lines, current)
        } else if name == "pre" && !closed {
          in_pre = true
          current = flush_line(lines, current)
          pending_break = false
        } else if is_block(name) {
          current = flush_line(lines, current)
          pending_break = true
        }
      HEnd(name) =>
        if name == "head" {
          in_head = false
        } else if name == "title" {
          in_title = false
          current = flush_line(lines, current)
        } else if name == "pre" {
          in_pre = false
          current = flush_pre(lines, current)
        } else if is_block(name) {
          current = flush_line(lines, current)
        }
      HText(value) =>
        if in_title || in_pre {
          current = current + value
        } else if in_head {
          () // non-title head content contributes nothing
        } else if value.trim().is_empty() {
          if value.contains("\n") { pending_break = true }
        } else {
          if pending_break { current = flush_line(lines, current) }
          pending_break = false
          current = current + value
        }
    }
  }
  current = flush_line(lines, current)
  lines.join("\n")
}
