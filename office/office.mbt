// Deterministic text extraction for OOXML originals. Word/Excel/PowerPoint
// files are ZIP packages of XML parts; the visible text is plain data, so
// parsing it needs no model and stays inside the engine's determinism
// contract. The extractors walk only the document-body parts, refuse to
// follow any external reference, and cap the expanded bytes and part count so
// a small archive cannot unfold into an unbounded context payload.

///|
const EXPANSION_LIMIT : Int = 33_554_432 // 32 MiB across all parts

///|
const PART_LIMIT : Int = 4096

///|
const OFFICE_WORD = "office-word"

///|
const OFFICE_SPREADSHEET = "office-spreadsheet"

///|
const OFFICE_SLIDES = "office-slides"

///|
pub fn is_office_format(format : String) -> Bool {
  format == OFFICE_WORD ||
  format == OFFICE_SPREADSHEET ||
  format == OFFICE_SLIDES
}

///|
pub fn formats() -> Array[String] {
  [OFFICE_WORD, OFFICE_SPREADSHEET, OFFICE_SLIDES]
}

///|
fn part_text(
  files : Array[@pack.File],
  name : String,
) -> String raise @base.Fault {
  for file in files {
    if file.path == name {
      return @utf8.decode(file.data) catch {
        _ => raise @base.Fault("office_part_invalid: " + name)
      }
    }
  }
  raise @base.Fault("office_part_missing: " + name)
}

///|
fn find_part(files : Array[@pack.File], name : String) -> Bool {
  files.iter().any(file => file.path == name)
}

///|
fn parse_decimal(value : String) -> Int? {
  if value.is_empty() {
    return None
  }
  // Bound before accumulating: an unbounded multiply wraps i64 silently and
  // folds an astronomical index back into range (11*2^63+1 -> 1), defeating
  // the out-of-range guard entirely (续十六围猎 F5). 18 digits still fits
  // i64 without wrapping; real indices and slide numbers never approach it.
  if value.length() > 18 {
    return None
  }
  let mut acc = 0
  for c in value {
    if c < '0' || c > '9' {
      return None
    }
    acc = acc * 10 + (c.to_int() - '0'.to_int())
    if acc > 0x7FFF_FFFF {
      return None
    }
  }
  Some(acc)
}

// ---------------------------------------------------------------- Word

///|
fn word_text(part : String) -> String raise @base.Fault {
  let events = xml_events(part)
  let out = StringBuilder()
  let mut para_seen = false
  let mut capturing = false
  for event in events {
    match event {
      // Whitelist capture (续十六围猎 F1): text is taken only inside
      // `<w:t>` leaf elements. instrText/delText and anything else are
      // excluded by not being whitelisted -- a blacklist `skip` latch had
      // no End event for self-closing tags and silently hid the rest of
      // the document. Self-closing `<w:t/>` carries no text and sets
      // nothing.
      Start(name, _, self_closing) =>
        if name == "w:p" && !self_closing {
          if para_seen {
            out.write_string("\n")
          }
          para_seen = true
        } else if name == "w:t" && !self_closing {
          capturing = true
        } else if name == "w:tab" {
          out.write_string("\t")
        } else if name == "w:br" || name == "w:cr" {
          out.write_string("\n")
        }
      End(name) => if name == "w:t" { capturing = false }
      Text(value) => if capturing { out.write_string(value) }
    }
  }
  out.to_string()
}

// ---------------------------------------------------------------- Spreadsheet

///|
fn shared_strings(files : Array[@pack.File]) -> Array[String] raise @base.Fault {
  if !find_part(files, "xl/sharedStrings.xml") {
    return []
  }
  let events = xml_events(part_text(files, "xl/sharedStrings.xml"))
  let items : Array[String] = []
  let mut current : StringBuilder? = None
  for event in events {
    match event {
      // `<si/>` self-closing is a legitimate empty shared string; dropping
      // it silently shifts every later index by one (续十六围猎 F4).
      Start(name, _, self_closing) =>
        if name == "si" {
          if self_closing {
            items.push("")
            current = None
          } else {
            current = Some(StringBuilder())
          }
        }
      End(name) =>
        if name == "si" {
          match current {
            Some(builder) => items.push(builder.to_string())
            None => ()
          }
          current = None
        }
      Text(value) =>
        match current {
          Some(builder) => builder.write_string(value)
          None => ()
        }
    }
  }
  items
}

///|
fn resolve_target(target : String) -> String {
  // Relationship targets are relative to xl/ unless already rooted there.
  let cleaned = if target.has_prefix("/") {
    target[1:].to_owned()
  } else {
    target
  }
  if cleaned.has_prefix("xl/") {
    cleaned
  } else {
    "xl/" + cleaned
  }
}

///|
fn sheet_order(
  files : Array[@pack.File],
) -> Array[(String, String)] raise @base.Fault {
  let workbook = xml_events(part_text(files, "xl/workbook.xml"))
  let rels = xml_events(part_text(files, "xl/_rels/workbook.xml.rels"))
  let targets : Map[String, String] = Map([])
  for event in rels {
    match event {
      Start(name, attrs, _) =>
        if name == "Relationship" {
          match (attrs.get("Id"), attrs.get("Target")) {
            (Some(id), Some(target)) => targets[id] = resolve_target(target)
            _ => ()
          }
        }
      _ => ()
    }
  }
  let result : Array[(String, String)] = []
  for event in workbook {
    match event {
      Start(name, attrs, _) =>
        if name == "sheet" {
          let title = attrs.get("name").unwrap_or("")
          let target = match attrs.get("r:id") {
            Some(id) => targets.get(id).unwrap_or("")
            None => ""
          }
          if title.is_empty() || target.is_empty() {
            @base.fail("office_sheet_unresolved")
          }
          result.push((title, target))
        }
      _ => ()
    }
  }
  result
}

///|
fn sheet_text(part : String, shared : Array[String]) -> String raise @base.Fault {
  let events = xml_events(part)
  let out = StringBuilder()
  let mut have_row = false
  let mut row_started = false
  let mut cell = ""
  let mut cell_shared = false
  let mut capturing = false
  let mut inline = false
  for event in events {
    match event {
      Start(name, attrs, self_closing) => {
        if name == "row" && !self_closing {
          if have_row { out.write_string("\n") }
          have_row = true
          row_started = false
        } else if name == "c" {
          if row_started { out.write_string("\t") }
          cell = ""
          cell_shared = attrs.get("t").unwrap_or("") == "s"
        } else if name == "v" && !self_closing {
          capturing = true
        } else if name == "is" && !self_closing {
          // `<is/>` self-closing must not latch inline on (续十六围猎 F2 同族)
          inline = true
        } else if name == "t" {
          if inline && !self_closing { capturing = true }
        }
        // `<f>` needs no skip latch: cell text is captured only inside
        // `<v>`/`<is><t>`, formula bodies are outside the whitelist. The
        // old latch never cleared for `<f/>` and zeroed every later cell.
      }
      End(name) =>
        if name == "c" {
          // A shared-string cell resolves to its table entry; the engine
          // refuses rather than guessing when the stored index is invalid.
          if cell_shared && !cell.is_empty() {
            let index = match parse_decimal(cell) {
              Some(index) => index
              None => -1
            }
            if index < 0 { @base.fail("office_shared_index: " + cell) }
            if index >= shared.length() { @base.fail("office_shared_index: out of range") }
            cell = shared[index]
          }
          out.write_string(cell)
          row_started = true
        } else if name == "v" {
          capturing = false
        } else if name == "t" {
          if inline { capturing = false }
        } else if name == "is" {
          inline = false
        }
      Text(value) => if capturing { cell = cell + value }
    }
  }
  out.to_string()
}

// ---------------------------------------------------------------- Slides

///|
fn slide_number(path : String) -> Int? {
  if !path.has_prefix("ppt/slides/slide") || !path.has_suffix(".xml") {
    return None
  }
  let middle = path["ppt/slides/slide".length():path.length() - 4].to_owned()
  if middle.is_empty() {
    return None
  }
  parse_decimal(middle)
}

///|
fn slide_text(part : String) -> String raise @base.Fault {
  let events = xml_events(part)
  let out = StringBuilder()
  let mut capturing = false
  for event in events {
    match event {
      // Only `a:t` runs are slide text (续十六围猎 F6): capturing every
      // Text node published cached field values, metadata and arbitrary
      // namespaced elements that PowerPoint does not show.
      Start(name, _, self_closing) =>
        if name == "a:p" {
          out.write_string("\n")
        } else if name == "a:t" && !self_closing {
          capturing = true
        }
      End(name) => if name == "a:t" { capturing = false }
      Text(value) => if capturing { out.write_string(value) }
    }
  }
  out.to_string()
}

// ---------------------------------------------------------------- Entry

///|
pub fn text(format : String, bytes : Bytes) -> String raise @base.Fault {
  if !is_office_format(format) {
    @base.fail("office_format_unsupported: " + format)
  }
  let files = read_package(bytes)
  if files.length() > PART_LIMIT {
    @base.fail("office_part_count: > \{PART_LIMIT}")
  }
  let mut expanded = 0
  for file in files {
    expanded = expanded + file.data.length()
    if expanded > EXPANSION_LIMIT {
      @base.fail("office_expansion_limit: > \{EXPANSION_LIMIT}")
    }
  }
  // Every OPC package announces its content types; without that entry the
  // archive is not an office document and extraction must not guess.
  if !find_part(files, "[Content_Types].xml") {
    @base.fail("office_not_office: [Content_Types].xml missing")
  }
  if format == OFFICE_WORD {
    word_text(part_text(files, "word/document.xml"))
  } else if format == OFFICE_SPREADSHEET {
    let shared = shared_strings(files)
    let out : Array[String] = []
    for (title, target) in sheet_order(files) {
      if !find_part(files, target) {
        @base.fail("office_part_missing: " + target)
      }
      out.push(
        "# sheet " + title + "\n" + sheet_text(part_text(files, target), shared),
      )
    }
    out.join("\n\n")
  } else {
    let slides : Array[(Int, String)] = []
    for file in files {
      if file.path.has_prefix("ppt/slides/") && file.path.has_suffix(".xml") &&
        slide_number(file.path) == None {
        // A slide part outside `slide<N>.xml` was previously dropped silently;
        // its content then vanishes from the extraction while the rest passes
        // (续十六围猎 F6). Refuse instead of publishing a partial deck.
        @base.fail("office_slide_unnamed: " + file.path)
      }
      match slide_number(file.path) {
        Some(number) => {
          if slides.iter().any(s => s.0 == number) {
            @base.fail("office_slide_duplicate: " + file.path)
          }
          slides.push((number, file.path))
        }
        None => ()
      }
    }
    if slides.is_empty() {
      @base.fail("office_not_office: no slides found")
    }
    slides.sort_by((a, b) => {
      if a.0 < b.0 {
        -1
      } else if a.0 == b.0 {
        0
      } else {
        1
      }
    })
    let out : Array[String] = []
    for (number, path) in slides {
      out.push(
        "# slide " + number.to_string() + slide_text(part_text(files, path)),
      )
    }
    out.join("\n\n")
  }
}
