// Deterministic CommonMark-subset renderer: the no-JS baseline for reading
// snapshots. The browser hydrates over it with the full MarkdownIt pipeline,
// but a snapshot opened without scripts still shows structured HTML instead
// of raw Markdown. Blocks: ATX headings, fenced and indented code, bullet
// and ordered lists, blockquotes, thematic breaks, paragraphs. Inline: code
// spans, backslash escapes, wikilinks (resolved to in-snapshot page anchors
// only when the target exists), images and links (scheme-whitelisted),
// strong and emphasis. Every interpolated text passes escape(); the output
// for the same verified page bytes is byte-identical on every target.

fn markdown_anchor(id : String) -> String {
  "p-" + @base.hex_hash(id)
}

fn find_from(text : String, needle : String, from : Int) -> Int? {
  if needle.is_empty() { return Some(from) }
  let mut i = from
  while i + needle.length() <= text.length() {
    if text[i:i+needle.length()].to_owned() == needle { return Some(i) }
    i = i + 1
  }
  None
}

fn starts_at(text : String, needle : String, at : Int) -> Bool {
  at + needle.length() <= text.length() && text[at:at+needle.length()].to_owned() == needle
}

fn is_punct_code(code : UInt16) -> Bool {
  (code >= b'!'.to_uint16() && code <= b'/'.to_uint16()) ||
  (code >= b':'.to_uint16() && code <= b'@'.to_uint16()) ||
  (code >= b'['.to_uint16() && code <= b'`'.to_uint16()) ||
  (code >= b'{'.to_uint16() && code <= b'~'.to_uint16())
}

fn is_list_marker_line(line : String) -> Bool {
  // A line "starts a list item" when an optional indent is followed by a
  // bullet marker or an ordered marker plus one space and content.
  let mut i = 0
  while i < line.length() && line[i] == b' '.to_uint16() { i = i + 1 }
  if i >= line.length() - 0 { return false }
  let first = line[i]
  if (first == b'-'.to_uint16() || first == b'*'.to_uint16() || first == b'+'.to_uint16()) &&
    i + 1 < line.length() && line[i+1] == b' '.to_uint16() {
    return true
  }
  let mut digits = 0
  while i + digits < line.length() && line[i+digits] >= b'0'.to_uint16() && line[i+digits] <= b'9'.to_uint16() {
    digits = digits + 1
  }
  digits > 0 && digits <= 9 && i + digits + 1 < line.length() &&
    (line[i+digits] == b'.'.to_uint16() || line[i+digits] == b')'.to_uint16()) &&
    line[i+digits+1] == b' '.to_uint16()
}

fn list_item_content(line : String) -> String {
  let trimmed = line.trim().to_owned()
  let mut k = 0
  while k < trimmed.length() && trimmed[k] != b' '.to_uint16() { k = k + 1 }
  let mut content = trimmed[k:].to_owned()
  while !content.is_empty() && content[0] == b' '.to_uint16() {
    content = content[1:].to_owned()
  }
  content
}

fn safe_url(url : String) -> String? {
  // Scheme whitelist: absolute http(s)/mailto, inline data images, and
  // scheme-less relative paths. Anything else (javascript:, vbscript:, ...)
  // renders as plain text instead of a link.
  let trimmed = url.trim().to_owned()
  let lowered = trimmed.to_lower()
  if lowered.has_prefix("http://") || lowered.has_prefix("https://") || lowered.has_prefix("mailto:") {
    return Some(trimmed)
  }
  if lowered.has_prefix("data:image/") { return Some(trimmed) }
  if !trimmed.contains(":") { return Some(trimmed) }
  None
}

// One segmentation pass: backslash escapes, code spans, wikilinks and
// links/images become final HTML segments; the untouched remainder comes
// back as raw text so emphasis markers can never pair across a code span,
// an escape or a link boundary.
fn inline_segments(text : String, page_ids : Map[String, Bool]) -> (Array[String], String) {
  let out : Array[String] = []
  let mut raw = ""
  let flush = fn() -> Unit {
    if !raw.is_empty() {
      out.push(escape(raw))
      raw = ""
    }
  }
  let mut i = 0
  while i < text.length() {
    let code = text[i]
    // Backslash escape: the next ASCII punctuation becomes literal text.
    if code == b'\\'.to_uint16() && i + 1 < text.length() && is_punct_code(text[i+1]) {
      flush()
      out.push(escape(text[i+1:i+2].to_owned()))
      i = i + 2
      continue
    }
    // Code span: a backtick run; content is verbatim escaped.
    if code == b'`'.to_uint16() {
      let mut run = 0
      while i + run < text.length() && text[i+run] == b'`'.to_uint16() { run = run + 1 }
      let mut found = -1
      let mut cursor = i + run
      while cursor < text.length() {
        if text[cursor] == b'`'.to_uint16() {
          let mut close_run = 0
          while cursor + close_run < text.length() && text[cursor+close_run] == b'`'.to_uint16() {
            close_run = close_run + 1
          }
          if close_run == run { found = cursor; break }
          cursor = cursor + close_run
        } else {
          cursor = cursor + 1
        }
      }
      if found >= 0 {
        flush()
        out.push("<code>" + escape(text[i+run:found].trim().to_owned()) + "</code>")
        i = found + run
        continue
      }
      raw = raw + text[i:i+run].to_owned()
      i = i + run
      continue
    }
    // Engine wikilink: [[page#fragment|label]]. Resolves only to pages in
    // the current snapshot; unknown targets stay literal text.
    if code == b'['.to_uint16() && i + 1 < text.length() && text[i+1] == b'['.to_uint16() {
      let mut j = i + 2
      while j + 1 < text.length() && !(text[j] == b']'.to_uint16() && text[j+1] == b']'.to_uint16()) {
        j = j + 1
      }
      if j + 1 < text.length() {
        let spec = text[i+2:j].to_owned()
        let parts = spec.split("|").to_array()
        let target = parts[0].trim().to_owned()
        let label = if parts.length() > 1 { parts[1].trim().to_owned() } else { target }
        let page_id = match target.split_once("#") {
          Some((pid, _)) => pid.to_owned()
          None => target
        }
        if !page_id.is_empty() && page_ids.contains(page_id) {
          flush()
          out.push("<a href='#" + markdown_anchor(page_id) + "'>" + escape(label) + "</a>")
          i = j + 2
          continue
        }
      }
    }
    // Image ![alt](src), then link [text](href).
    let mut image = false
    let mut bracket = i
    if code == b'!'.to_uint16() && i + 1 < text.length() && text[i+1] == b'['.to_uint16() {
      image = true
      bracket = i + 1
    } else if code == b'['.to_uint16() {
      bracket = i
    }
    if bracket < text.length() && text[bracket] == b'['.to_uint16() {
      let mut close = bracket + 1
      let mut depth = 1
      while close < text.length() && depth > 0 {
        if text[close] == b'['.to_uint16() { depth = depth + 1 }
        if text[close] == b']'.to_uint16() { depth = depth - 1 }
        close = close + 1
      }
      if depth == 0 && close < text.length() && text[close] == b'('.to_uint16() {
        let mut end = close + 1
        let mut paren = 1
        while end < text.length() && paren > 0 {
          if text[end] == b'('.to_uint16() { paren = paren + 1 }
          if text[end] == b')'.to_uint16() { paren = paren - 1 }
          end = end + 1
        }
        if paren == 0 {
          let inner = text[bracket+1:close-1].to_owned()
          let url = text[close+1:end-1].trim().to_owned()
          match safe_url(url) {
            Some(clean) => {
              flush()
              if image {
                out.push("<img src=\"" + escape(clean) + "\" alt=\"" + escape(inner) + "\">")
              } else {
                out.push("<a href=\"" + escape(clean) + "\">" + inline_render(inner, page_ids) + "</a>")
              }
              i = end
              continue
            }
            None => ()
          }
        }
      }
    }
    raw = raw + text[i:i+1].to_owned()
    i = i + 1
  }
  (out, raw)
}

fn emphasis_html(text : String) -> String {
  // Strong before emphasis. An unpaired marker is emitted literally; all
  // leftover text is escaped here, so raw text never bypasses escape().
  let mut html = ""
  let mut rest = text
  for marker in ["**", "__"] {
    while true {
      match find_from(rest, marker, 0) {
        Some(open) => match find_from(rest, marker, open + marker.length()) {
          Some(close) if close > open + marker.length() => {
            html = html + escape(rest[:open].to_owned()) +
              "<strong>" + emphasis_html(rest[open+marker.length():close].to_owned()) + "</strong>"
            rest = rest[close+marker.length():].to_owned()
          }
          _ => {
            html = html + escape(rest[:open+marker.length()].to_owned())
            rest = rest[open+marker.length():].to_owned()
          }
        }
        None => break
      }
    }
  }
  let mut remainder = rest
  for marker in ["*", "_"] {
    while true {
      match find_from(remainder, marker, 0) {
        Some(open) => match find_from(remainder, marker, open + 1) {
          Some(close) if close > open + 1 => {
            html = html + escape(remainder[:open].to_owned()) +
              "<em>" + emphasis_html(remainder[open+1:close].to_owned()) + "</em>"
            remainder = remainder[close+1:].to_owned()
          }
          _ => {
            html = html + escape(remainder[:open+1].to_owned())
            remainder = remainder[open+1:].to_owned()
          }
        }
        None => break
      }
    }
  }
  html + escape(remainder)
}

fn inline_render(text : String, page_ids : Map[String, Bool]) -> String {
  let (segments, raw) = inline_segments(text, page_ids)
  segments.push(emphasis_html(raw))
  segments.join("")
}

// A fence opens at at most three leading spaces with a run of at least
// three ` or ~ markers; the rest of the line is the info string.
fn fence_open(line : String) -> (String, Int)? {
  let trimmed = line.trim().to_owned()
  let indent = line.length() - trimmed.length()
  if indent > 3 || trimmed.is_empty() { return None }
  let marker = trimmed[0]
  if marker != b'`'.to_uint16() && marker != b'~'.to_uint16() { return None }
  let mut run = 0
  while run < trimmed.length() && trimmed[run] == marker { run = run + 1 }
  if run < 3 { return None }
  if marker == b'`'.to_uint16() && trimmed[run:].contains("`") { return None }
  Some((trimmed[0:1].to_owned(), run))
}

fn fence_close(line : String, marker : String, run : Int) -> Bool {
  let trimmed = line.trim().to_owned()
  if !starts_at(trimmed, marker, 0) { return false }
  let mut actual = 0
  while actual < trimmed.length() && trimmed[actual] == marker[0] { actual = actual + 1 }
  actual >= run && trimmed[actual:].trim().is_empty()
}

fn fence_language(info : String) -> String {
  let mut language = ""
  let mut seen_space = false
  for c in info {
    if c == ' ' || c == '\t' { seen_space = true; continue }
    if seen_space { break }
    let safe = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
      c == '+' || c == '-' || c == '.' || c == '#'
    if safe { language = language + c.to_string() }
  }
  language
}

fn render_blocks(lines : Array[String], page_ids : Map[String, Bool]) -> String {
  let out : Array[String] = []
  let mask = @core.code_line_mask(lines)
  let inline = fn(text : String) -> String { inline_render(text, page_ids) }
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if mask[i] {
      // One atomic code region: fenced when the first line opens a fence,
      // indented code otherwise.
      match fence_open(line) {
        Some((marker, run)) => {
          let info = line.trim().to_owned()
          let language = fence_language(info[run:].to_owned())
          let mut body_text = ""
          i = i + 1
          while i < lines.length() && !fence_close(lines[i], marker, run) {
            body_text = body_text + lines[i] + "\n"
            i = i + 1
          }
          if i < lines.length() { i = i + 1 }
          let class = if language.is_empty() { "" } else { " class=\"language-" + language + "\"" }
          out.push("<pre><code" + class + ">" + escape(body_text) + "</code></pre>")
        }
        None => {
          let mut body_text = ""
          while i < lines.length() && mask[i] {
            body_text = body_text + lines[i].trim().to_owned() + "\n"
            i = i + 1
          }
          out.push("<pre><code>" + escape(body_text) + "</code></pre>")
        }
      }
      continue
    }
    let trimmed = line.trim().to_owned()
    if trimmed.is_empty() {
      i = i + 1
      continue
    }
    // ATX heading: 1-6 # followed by a space or end of line.
    let mut hashes = 0
    while hashes < trimmed.length() && trimmed[hashes] == b'#'.to_uint16() && hashes < 6 {
      hashes = hashes + 1
    }
    if hashes > 0 && (hashes >= trimmed.length() || trimmed[hashes] == b' '.to_uint16()) {
      let level = hashes.to_string()
      let mut content = trimmed[hashes:].to_owned()
      if !content.is_empty() && content[0] == b' '.to_uint16() { content = content[1:].to_owned() }
      out.push("<h" + level + ">" + inline(content) + "</h" + level + ">")
      i = i + 1
      continue
    }
    // Thematic break: three or more -, * or _ (spaces allowed between).
    let compact = @base.replace_all(@base.replace_all(@base.replace_all(trimmed, "-", ""), "*", ""), "_", "")
    if compact.is_empty() && trimmed.length() >= 3 {
      out.push("<hr>")
      i = i + 1
      continue
    }
    // Blockquote: consecutive > lines render as a nested block.
    if trimmed.has_prefix(">") {
      let inner : Array[String] = []
      while i < lines.length() {
        let current = lines[i].trim().to_owned()
        if !current.has_prefix(">") { break }
        let mut rest = current[1:].to_owned()
        while !rest.is_empty() && rest[0] == b' '.to_uint16() { rest = rest[1:].to_owned() }
        inner.push(rest)
        i = i + 1
      }
      out.push("<blockquote>" + render_blocks(inner, page_ids) + "</blockquote>")
      continue
    }
    // Lists: items render tight; continuation lines join their item.
    if is_list_marker_line(trimmed) {
      let tag = if trimmed[0] >= b'0'.to_uint16() && trimmed[0] <= b'9'.to_uint16() { "ol" } else { "ul" }
      let items : Array[String] = []
      while i < lines.length() {
        let current = lines[i].trim().to_owned()
        if current.is_empty() || mask[i] || !is_list_marker_line(current) { break }
        let mut content = list_item_content(current)
        i = i + 1
        while i < lines.length() {
          let next = lines[i]
          if mask[i] || next.trim().is_empty() || is_list_marker_line(next.trim().to_owned()) { break }
          if next.trim().to_owned() == next { break } // not indented: lazy continuation only
          content = content + " " + next.trim().to_owned()
          i = i + 1
        }
        items.push("<li>" + inline(content) + "</li>")
      }
      out.push("<" + tag + ">" + items.join("") + "</" + tag + ">")
      continue
    }
    // Paragraph: consecutive ordinary lines.
    let paragraph : Array[String] = []
    while i < lines.length() {
      let current = lines[i]
      if mask[i] || current.trim().is_empty() { break }
      let current_trimmed = current.trim().to_owned()
      if current_trimmed.has_prefix(">") || is_list_marker_line(current_trimmed) { break }
      paragraph.push(current_trimmed)
      i = i + 1
    }
    out.push("<p>" + inline(paragraph.join("\n")) + "</p>")
  }
  out.join("")
}

/// Render a page (or raw source) body into the static HTML baseline.
pub fn render_markdown(body : String, page_ids : Array[String]) -> String {
  let ids : Map[String, Bool] = Map([])
  for id in page_ids { ids[id] = true }
  render_blocks(body.split("\n").map(x => x.to_owned()).to_array(), ids)
}
