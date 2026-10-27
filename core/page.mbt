pub(all) struct Page {
  title : String
  kind : String
  sources : Array[String]
  tags : Array[String]
  body : String
  links : Array[String]
} derive(ToJson)

pub extend Page with ToJson::{to_json}

pub fn parse_page(text : String) -> Page raise @base.Fault {
  let lines = text.split("\n").map(x => x.to_owned()).to_array()
  if lines.length() < 3 || lines[0] != "---" {
    @base.fail("frontmatter_required")
  }
  let mut end = -1
  for i = 1; i < lines.length(); i = i + 1 {
    let line = lines[i].trim().to_owned()
    if line == "---" { end = i; break }
  }
  if end < 0 { @base.fail("unterminated_frontmatter") }
  let yaml = lines[1:end].join("\n")
  let flavor = @yaml.Flavor::new(depth=64, duplicates=Reject, budget=100000)
  let metadata = try @yaml.loads(yaml, flavor~) catch {
    _ => raise @base.Fault("unknown_or_duplicate_frontmatter")
  }
  let fields = match metadata {
    Object(fields) => fields
    _ => raise @base.Fault("frontmatter_mapping_required")
  }
  let mut title = ""
  let mut kind = ""
  let sources : Array[String] = []
  let tags : Array[String] = []
  for (key, value) in fields {
    if !["type", "title", "sources", "tags"].contains(key) {
      @base.fail("unknown_or_duplicate_frontmatter: " + key)
    }
    match key {
      "type" => match value { String(v) => kind = v; _ => @base.fail("frontmatter_string_required: type") }
      "title" => match value { String(v) => title = v; _ => @base.fail("frontmatter_string_required: title") }
      "sources" => for item in @base.strings(value) { sources.push(item) }
      "tags" => for item in @base.strings(value) { tags.push(item) }
      _ => ()
    }
  }
  if title.is_empty() { @base.fail("title_required") }
  if kind.is_empty() { @base.fail("type_required") }
  let body = lines[end+1:].join("\n")
  { title, kind, sources, tags, body, links: wikilinks(body) }
}

pub fn wikilinks(body : String) -> Array[String] raise @base.Fault {
  let result : Array[String] = []
  let mut fence = ""
  let mut fence_length = 0
  let mut indented_code = false
  let mut code_ticks = 0
  let lines = body.split("\n").map(x => x.to_owned()).to_array()
  for line_index = 0; line_index < lines.length(); line_index = line_index + 1 {
    let line = lines[line_index]
    // A fenced block may start with at most three spaces/tabs. Its closing
    // fence must use the same marker and at least the opening run length.
    let mut prefix_end = 0
    let mut indent = 0
    while prefix_end < line.length() && (line[prefix_end] == b' '.to_uint16() || line[prefix_end] == b'\t'.to_uint16()) {
      if line[prefix_end] == b'\t'.to_uint16() {
        indent = indent + (4 - indent % 4)
      } else {
        indent = indent + 1
      }
      prefix_end = prefix_end + 1
    }
    if indent <= 3 && prefix_end < line.length() &&
      (line[prefix_end] == b'`'.to_uint16() || line[prefix_end] == b'~'.to_uint16()) {
      let marker = line[prefix_end:prefix_end+1].to_owned()
      let mut run = 0
      while prefix_end + run < line.length() && line[prefix_end+run] == line[prefix_end] { run = run + 1 }
      if run >= 3 {
        if fence == "" {
          fence = marker
          fence_length = run
          code_ticks = 0
          continue
        }
        if marker == fence && run >= fence_length && line[prefix_end+run:].trim().is_empty() {
          fence = ""
          fence_length = 0
          continue
        }
      }
    }
    if fence != "" { continue }
    // Four-column indentation is a Markdown code block. Blank lines belong
    // to the block; the next non-indented line resumes normal scanning.
    if indent >= 4 {
      indented_code = true
      code_ticks = 0
      continue
    }
    if indented_code {
      if line.trim().is_empty() { continue }
      indented_code = false
    }
    // CommonMark code spans are delimited by runs of backticks. Keep the run
    // length across lines so a span cannot expose links in its middle.
    let mut i = 0
    while i < line.length() {
      if line[i] == b'`'.to_uint16() && !escaped_marker(line, i) {
        let start = i
        while i < line.length() && line[i] == b'`'.to_uint16() { i = i + 1 }
        let run = i - start
        if code_ticks == 0 {
          if has_code_closer(lines, line_index, i, run) { code_ticks = run }
        } else if code_ticks == run { code_ticks = 0 }
        continue
      }
      if code_ticks == 0 && i + 1 < line.length() && line[i] == b'['.to_uint16() && line[i+1] == b'['.to_uint16() && !escaped_marker(line, i) {
        let mut j = i + 2
        while j + 1 < line.length() && !(line[j] == b']'.to_uint16() && line[j+1] == b']'.to_uint16()) {
          j = j + 1
        }
        if j + 1 >= line.length() { @base.fail("unterminated_wikilink") }
        let target = line[i+2:j].split("|").next().unwrap().to_owned()
        // Anchors are presentation-only: the dependency graph keeps the page
        // id, while the renderer resolves the fragment against heading ids.
        let page_id = wikilink_page_id(target)
        if !result.contains(page_id) { result.push(page_id) }
        i = j + 2
      } else { i = i + 1 }
    }
  }
  result
}

fn wikilink_page_id(target : String) -> String raise @base.Fault {
  match target.split_once("#") {
    None => {
      @base.path(target)
      target
    }
    Some((page_id, fragment)) => {
      // Keep the fragment syntax deliberately small and deterministic. URL
      // escaping is handled by the visual runtime; raw '#' would be ambiguous
      // and an empty fragment cannot identify a heading.
      if page_id.is_empty() || fragment.is_empty() || fragment.trim().is_empty() ||
        fragment.contains("#") || fragment.contains("\n") || fragment.contains("\r") ||
        fragment.contains_char('\u0000') {
        @base.fail("invalid_wikilink_anchor: " + target)
      }
      @base.path(page_id.to_owned())
      page_id.to_owned()
    }
  }
}

fn has_code_closer(lines : Array[String], line_index : Int, from : Int, run : Int) -> Bool {
  let mut cursor = from
  let first = lines[line_index]
  while cursor < first.length() {
    if first[cursor] == b'`'.to_uint16() && !escaped_marker(first, cursor) {
      let start = cursor
      while cursor < first.length() && first[cursor] == b'`'.to_uint16() { cursor = cursor + 1 }
      if cursor - start == run { return true }
    } else {
      cursor = cursor + 1
    }
  }
  let mut next = line_index + 1
  while next < lines.length() {
    let line = lines[next]
    cursor = 0
    while cursor < line.length() {
      if line[cursor] == b'`'.to_uint16() && !escaped_marker(line, cursor) {
        let start = cursor
        while cursor < line.length() && line[cursor] == b'`'.to_uint16() { cursor = cursor + 1 }
        if cursor - start == run { return true }
      } else {
        cursor = cursor + 1
      }
    }
    next = next + 1
  }
  false
}

fn escaped_marker(line : String, index : Int) -> Bool {
  let mut slashes = 0
  let mut cursor = index
  while cursor > 0 && line[cursor-1] == b'\\'.to_uint16() {
    slashes = slashes + 1
    cursor = cursor - 1
  }
  slashes % 2 == 1
}

pub fn validate_page(entry : Entry, text : String, entries : Array[Entry]) -> Page raise @base.Fault {
  let page = parse_page(text)
  if page.kind != entry.kind || page.sources != entry.sources || page.title.is_empty() {
    @base.fail("page_metadata_mismatch: " + entry.id)
  }
  if !entry.stale {
    for link in page.links {
      if !entries.iter().any(e => e.id == link && is_page(e) && !e.stale) {
        @base.fail("wikilink_unresolved: " + entry.id + " -> " + link)
      }
    }
  }
  page
}
