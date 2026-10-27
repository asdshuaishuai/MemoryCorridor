// Small, deterministic lexer for MoonBit literate fences. It deliberately
// understands fence boundaries only; Markdown prose remains opaque to the
// engine and is preserved byte-for-byte by callers.
pub(all) struct LiterateBlock {
  checked : Bool
  open_line : Int
  close_line : Int
  code : String
}

fn normalized(text : String) -> String {
  replace_all(text, "\r\n", "\n")
}

fn indent_width(line : String) -> Int {
  let mut cursor = 0
  let mut width = 0
  while cursor < line.length() {
    if line[cursor] == b' '.to_uint16() {
      width = width + 1
    } else if line[cursor] == b'\t'.to_uint16() {
      width = width + (4 - width % 4)
    } else {
      break
    }
    cursor = cursor + 1
  }
  width
}

// Returns marker, run length and info string for a possible opening fence.
fn fence_open(line : String) -> (String, Int, String)? {
  let width = indent_width(line)
  let mut cursor = 0
  while cursor < line.length() && (line[cursor] == b' '.to_uint16() || line[cursor] == b'\t'.to_uint16()) {
    cursor = cursor + 1
  }
  if width > 3 || cursor >= line.length() { return None }
  if line[cursor] != b'`'.to_uint16() && line[cursor] != b'~'.to_uint16() { return None }
  let marker = line[cursor:cursor+1].to_owned()
  let mut run = 0
  while cursor + run < line.length() && line[cursor+run] == line[cursor] { run = run + 1 }
  if run < 3 { return None }
  Some((marker, run, line[cursor+run:].trim().to_owned()))
}

fn fence_close(line : String, marker : String, minimum : Int) -> Bool {
  let width = indent_width(line)
  let mut cursor = 0
  while cursor < line.length() && (line[cursor] == b' '.to_uint16() || line[cursor] == b'\t'.to_uint16()) {
    cursor = cursor + 1
  }
  if width > 3 || cursor >= line.length() || line[cursor:cursor+1] != marker { return false }
  let mut run = 0
  while cursor + run < line.length() && line[cursor+run] == line[cursor] { run = run + 1 }
  run >= minimum && line[cursor+run:].trim().is_empty()
}

pub fn literate_blocks(text : String) -> Array[LiterateBlock] raise Fault {
  let lines = normalized(text).split("\n").map(x => x.to_owned()).to_array()
  let blocks : Array[LiterateBlock] = []
  let mut active_marker = ""
  let mut active_length = 0
  let mut active_info = ""
  let mut active_open = -1
  let code : Array[String] = []
  for i = 0; i < lines.length(); i = i + 1 {
    let line = lines[i]
    if active_marker != "" {
      if fence_close(line, active_marker, active_length) {
        if active_info == "mbt" || active_info == "mbt check" {
          blocks.push({
            checked: active_info == "mbt check",
            open_line: active_open,
            close_line: i,
            code: code.join("\n"),
          })
        }
        active_marker = ""
        active_length = 0
        active_info = ""
        active_open = -1
        code.clear()
      } else if active_info == "mbt" || active_info == "mbt check" {
        code.push(line)
      }
      continue
    }
    match fence_open(line) {
      Some((marker, run, info)) => {
        active_marker = marker
        active_length = run
        active_info = info
        active_open = i
        code.clear()
      }
      None => ()
    }
  }
  if active_marker != "" && (active_info == "mbt" || active_info == "mbt check") {
    fail("literate_block_unclosed")
  }
  blocks
}

// Anything after the closing fence still lives in the literate document.
// Prose or further blocks must be separated from the fence by a blank line
// (the next character is a newline, or the document ends); text glued to the
// fence is malformed Markdown that would compile as stray code, so refuse it.
fn checked_tail_valid(text : String, close_line : Int) -> Bool {
  let lines = text.split("\n").map(x => x.to_owned()).to_array()
  if close_line + 1 >= lines.length() { return true }
  let mut offset = 0
  for i = 0; i <= close_line; i = i + 1 {
    offset = offset + lines[i].length() + 1
  }
  if offset >= text.length() { return true }
  text[offset] == b'\n'.to_uint16()
}

pub fn first_checked_block(text : String) -> LiterateBlock raise Fault {
  for block in literate_blocks(text) {
    if block.checked {
      if !checked_tail_valid(normalized(text), block.close_line) { fail("literate_tail_content") }
      return block
    }
  }
  fail("literate_checked_block_missing")
  raise Fault("literate_checked_block_missing")
}

// Replace only the code in the first checked block. The opening/closing fence
// and all Markdown before/after it remain author-owned text.
pub fn replace_first_checked(text : String, code : String) -> String raise Fault {
  let normalized_text = normalized(text)
  let block = first_checked_block(normalized_text)
  let lines = normalized_text.split("\n").map(x => x.to_owned()).to_array()
  let before = lines[:block.open_line+1].join("\n") + "\n"
  let after = lines[block.close_line:].join("\n")
  let mut rendered = before + code + "\n" + after
  if !normalized_text.has_suffix("\n") && rendered.has_suffix("\n") {
    rendered = rendered[:rendered.length()-1].to_owned()
  }
  if text.contains("\r\n") { replace_all(rendered, "\n", "\r\n") } else { rendered }
}
