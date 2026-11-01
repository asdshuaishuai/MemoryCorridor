// A reader for the closed MoonBit literal subset the literate IR blocks use
// (catalog rows, the view declaration). It understands what moon's own lexer
// understands for that subset — whitespace, `//` comments, string escapes,
// trailing commas — so a block is accepted whenever it is the same program,
// not only when it is the same bytes. The grammar stays closed: tokens are
// words, single punctuation characters and decoded strings; the callers only
// admit `entry(...)`/`view(...)` rows whose arguments are strings, string
// arrays and booleans, and compare the surrounding scaffolding token by
// token. Anything else is refused as non-literal.

pub(all) enum LiteralToken {
  Word(String)
  Str(String)
} derive(Eq)
pub extend LiteralToken with Eq::{not_equal, equal}

pub fn LiteralToken::describe(self : LiteralToken) -> String {
  match self {
    Word(text) => "`" + text + "`"
    Str(text) => quoted(text)
  }
}

fn is_word_unit(code : UInt16) -> Bool {
  (code >= b'a'.to_uint16() && code <= b'z'.to_uint16()) ||
  (code >= b'A'.to_uint16() && code <= b'Z'.to_uint16()) ||
  (code >= b'0'.to_uint16() && code <= b'9'.to_uint16()) ||
  code == b'_'.to_uint16()
}

fn is_space_unit(code : UInt16) -> Bool {
  code == b' '.to_uint16() || code == b'\t'.to_uint16() ||
  code == b'\n'.to_uint16() || code == b'\r'.to_uint16()
}

fn hex_value(code : UInt16) -> Int {
  if code >= b'0'.to_uint16() && code <= b'9'.to_uint16() { return (code - b'0'.to_uint16()).to_int() }
  if code >= b'a'.to_uint16() && code <= b'f'.to_uint16() { return (code - b'a'.to_uint16()).to_int() + 10 }
  if code >= b'A'.to_uint16() && code <= b'F'.to_uint16() { return (code - b'A'.to_uint16()).to_int() + 10 }
  -1
}

fn hex4(value : Int) -> String {
  let digits = "0123456789abcdef"
  let mut out = ""
  for shift in [12, 8, 4, 0] {
    let nibble = (value >> shift) & 15
    out = out + digits[nibble:nibble+1].to_owned()
  }
  out
}

// Translate one MoonBit string literal body into JSON escape syntax and let
// the JSON decoder produce the value, so surrogate pairs and every escape are
// handled by one battle-tested path. Returns the decoded string and the index
// just past the closing quote.
fn read_string(code : String, open : Int) -> (String, Int) raise Fault {
  let out = StringBuilder()
  let mut i = open + 1
  while true {
    if i >= code.length() { raise Fault("unterminated string literal") }
    let unit = code[i]
    if unit == b'"'.to_uint16() { break }
    if unit == b'\n'.to_uint16() || unit == b'\r'.to_uint16() { raise Fault("unterminated string literal") }
    if unit < 0x20 { raise Fault("control character inside string literal") }
    if unit != b'\\'.to_uint16() {
      out.write_string(code[i:i+1].to_owned())
      i = i + 1
      continue
    }
    if i + 1 >= code.length() { raise Fault("unterminated string literal") }
    let esc = code[i+1]
    if esc == b'n'.to_uint16() || esc == b't'.to_uint16() || esc == b'r'.to_uint16() ||
      esc == b'b'.to_uint16() || esc == b'f'.to_uint16() || esc == b'"'.to_uint16() ||
      esc == b'\\'.to_uint16() || esc == b'/'.to_uint16() {
      out.write_string(code[i:i+2].to_owned())
      i = i + 2
      continue
    }
    if esc == b'\''.to_uint16() {
      out.write_string("'")
      i = i + 2
      continue
    }
    if esc == b'u'.to_uint16() {
      if i + 2 < code.length() && code[i+2] == b'{'.to_uint16() {
        // \u{H..H}: one to six hex digits, any scalar value.
        let mut j = i + 3
        let mut value = 0
        let mut digits = 0
        while j < code.length() && code[j] != b'}'.to_uint16() {
          let h = hex_value(code[j])
          if h < 0 || digits >= 6 { raise Fault("invalid \\u{...} escape") }
          value = value * 16 + h
          digits = digits + 1
          j = j + 1
        }
        if j >= code.length() || digits == 0 { raise Fault("invalid \\u{...} escape") }
        if value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF) { raise Fault("invalid \\u{...} escape") }
        if value <= 0xFFFF {
          out.write_string("\\u" + hex4(value))
        } else {
          let offset = value - 0x10000
          out.write_string("\\u" + hex4(0xD800 + (offset >> 10)) + "\\u" + hex4(0xDC00 + (offset & 0x3FF)))
        }
        i = j + 1
        continue
      }
      // \uXXXX: exactly four hex digits (JSON form).
      if i + 5 >= code.length() { raise Fault("invalid \\u escape") }
      for k in 2..<6 {
        if hex_value(code[i+k]) < 0 { raise Fault("invalid \\u escape") }
      }
      out.write_string(code[i:i+6].to_owned())
      i = i + 6
      continue
    }
    raise Fault("unknown escape \\" + code[i+1:i+2].to_owned())
  }
  let decoded = try @json.parse("\"" + out.to_string() + "\"") catch {
    _ => raise Fault("invalid string literal")
  }
  match decoded {
    String(value) => (value, i + 1)
    _ => raise Fault("invalid string literal")
  }
}

/// Tokenize a block of the literal subset. Whitespace and `//` comments are
/// skipped; identifiers and digit runs become words, every other character
/// is its own punctuation word, and string literals are decoded.
pub fn literal_tokens(code : String) -> Array[LiteralToken] raise Fault {
  let tokens : Array[LiteralToken] = []
  let mut i = 0
  while i < code.length() {
    let unit = code[i]
    if is_space_unit(unit) {
      i = i + 1
      continue
    }
    if unit == b'/'.to_uint16() && i + 1 < code.length() && code[i+1] == b'/'.to_uint16() {
      while i < code.length() && code[i] != b'\n'.to_uint16() { i = i + 1 }
      continue
    }
    if unit == b'"'.to_uint16() {
      let (value, next) = read_string(code, i)
      tokens.push(Str(value))
      i = next
      continue
    }
    if is_word_unit(unit) {
      let start = i
      while i < code.length() && is_word_unit(code[i]) { i = i + 1 }
      tokens.push(Word(code[start:i].to_owned()))
      continue
    }
    tokens.push(Word(code[i:i+1].to_owned()))
    i = i + 1
  }
  tokens
}

/// Read one literal value at `pos`: a string, a boolean word, or an array of
/// strings (trailing comma allowed). Returns the JSON value and the next index.
pub fn literal_value(tokens : Array[LiteralToken], pos : Int) -> (Json, Int) raise Fault {
  if pos >= tokens.length() { raise Fault("unexpected end of literal") }
  match tokens[pos] {
    Str(value) => (value.to_json(), pos + 1)
    Word("true") => (true.to_json(), pos + 1)
    Word("false") => (false.to_json(), pos + 1)
    Word("[") => {
      let items : Array[Json] = []
      let mut i = pos + 1
      while true {
        if i >= tokens.length() { raise Fault("unterminated array literal") }
        if tokens[i] == Word("]") { break }
        match tokens[i] {
          Str(value) => items.push(value.to_json())
          other => raise Fault("array items must be string literals, got " + other.describe())
        }
        i = i + 1
        if i < tokens.length() && tokens[i] == Word(",") { i = i + 1 }
      }
      (Json::array(items), i + 1)
    }
    other => raise Fault("expected a literal, got " + other.describe())
  }
}

/// Read a call `name(lit, lit, ...)` at `pos` (trailing comma allowed) and
/// return its literal arguments and the index just past the closing paren.
pub fn literal_call(tokens : Array[LiteralToken], pos : Int, name : String) -> (Array[Json], Int) raise Fault {
  if pos >= tokens.length() || tokens[pos] != Word(name) {
    raise Fault("expected " + name + "(...)")
  }
  if pos + 1 >= tokens.length() || tokens[pos+1] != Word("(") { raise Fault("expected ( after " + name) }
  let args : Array[Json] = []
  let mut i = pos + 2
  while true {
    if i >= tokens.length() { raise Fault("unterminated " + name + "(...)") }
    if tokens[i] == Word(")") { break }
    let (value, next) = literal_value(tokens, i)
    args.push(value)
    i = next
    if i < tokens.length() && tokens[i] == Word(",") { i = i + 1 }
  }
  (args, i + 1)
}

/// True when `tokens[from..]` equals `expected` exactly (same length, same
/// tokens): the way the IR scaffolding is matched without caring about bytes.
pub fn literal_tail_matches(tokens : Array[LiteralToken], from : Int, expected : Array[LiteralToken]) -> Bool {
  if tokens.length() - from != expected.length() { return false }
  for i in 0..<expected.length() {
    if tokens[from + i] != expected[i] { return false }
  }
  true
}

/// True when `expected` is a token-wise prefix of `tokens`.
pub fn literal_prefix_matches(tokens : Array[LiteralToken], expected : Array[LiteralToken]) -> Bool {
  if tokens.length() < expected.length() { return false }
  for i in 0..<expected.length() {
    if tokens[i] != expected[i] { return false }
  }
  true
}
