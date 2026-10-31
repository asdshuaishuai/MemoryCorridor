// Deterministic CommonMark-subset renderer: the no-JS baseline for reading
// snapshots. The browser hydrates over it with the full MarkdownIt pipeline,
// but a snapshot opened without scripts still shows structured HTML instead
// of raw Markdown. Blocks: ATX and setext headings, fenced and indented code,
// bullet and ordered lists (nested, with the ordered start number),
// blockquotes, thematic breaks, link reference definitions, paragraphs.
// Inline: code spans, backslash escapes, wikilinks (resolved to in-snapshot
// page anchors only when the target exists), images and links (scheme-
// whitelisted, with optional titles and reference definitions), strong and
// emphasis (CommonMark delimiter runs, so a link label can never nest
// another anchor). Every interpolated text passes escape(); the output for
// the same verified page bytes is byte-identical on every target.

fn markdown_anchor(id : String) -> String {
  "p-" + @base.hex_hash(id)
}

// A registered link reference definition: [label]: url "optional title".
priv struct LinkDef {
  url : String
  title : String
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

fn is_emph_space(code : UInt16) -> Bool {
  code == b' '.to_uint16() || code == b'\t'.to_uint16() || code == b'\n'.to_uint16() ||
  code == b'\r'.to_uint16() || code == 11 || code == 12
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

fn leading_spaces(line : String) -> Int {
  let mut i = 0
  while i < line.length() && line[i] == b' '.to_uint16() { i = i + 1 }
  i
}

// Width of the list marker on an already-trimmed marker line: the marker
// plus its trailing spaces, i.e. where the item content column begins.
fn marker_width(trimmed : String) -> Int {
  let mut k = 0
  if trimmed[0] >= b'0'.to_uint16() && trimmed[0] <= b'9'.to_uint16() {
    while k < trimmed.length() && trimmed[k] >= b'0'.to_uint16() && trimmed[k] <= b'9'.to_uint16() {
      k = k + 1
    }
  } else {
    k = 1
  }
  k = k + 1 // '.' or ')'
  while k < trimmed.length() && trimmed[k] == b' '.to_uint16() { k = k + 1 }
  k
}

// The start number of an ordered marker ("3." -> 3); bullets report 1.
fn ordered_marker_start(trimmed : String) -> Int {
  let mut value = 0
  let mut k = 0
  while k < trimmed.length() && trimmed[k] >= b'0'.to_uint16() && trimmed[k] <= b'9'.to_uint16() {
    value = value * 10 + (trimmed[k] - b'0'.to_uint16()).to_int()
    k = k + 1
  }
  if k == 0 { 1 } else { value }
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

// Split a link destination spec into (url, title). The optional title is
// "…", '…' or (…) after whitespace; a tail that is not a title keeps the
// whole spec as the destination.
fn split_link_target(spec : String) -> (String, String) {
  if spec.has_prefix("<") {
    match find_from(spec, ">", 1) {
      Some(gt) => {
        let rest = spec[gt+1:].trim().to_owned()
        if rest.is_empty() { return (spec[1:gt].to_owned(), "") }
        match title_of(rest) {
          Some(title) => (spec[1:gt].to_owned(), title)
          None => (spec, "")
        }
      }
      None => (spec, "")
    }
  } else {
    let mut k = 0
    while k < spec.length() && spec[k] != b' '.to_uint16() && spec[k] != b'\t'.to_uint16() {
      k = k + 1
    }
    if k >= spec.length() { return (spec, "") }
    match title_of(spec[k:].trim().to_owned()) {
      Some(title) => (spec[:k].to_owned(), title)
      None => (spec, "")
    }
  }
}

fn title_of(text : String) -> String? {
  if text.length() < 2 { return None }
  let first = text[0]
  let last = text[text.length()-1]
  if (first == b'"'.to_uint16() && last == b'"'.to_uint16()) ||
    (first == b'\''.to_uint16() && last == b'\''.to_uint16()) ||
    (first == b'('.to_uint16() && last == b')'.to_uint16()) {
    return Some(text[1:text.length()-1].to_owned())
  }
  None
}

// A top-level link reference definition "[label]: url \"title\"".
fn link_definition(line : String) -> (String, LinkDef)? {
  let trimmed = line.trim().to_owned()
  if !trimmed.has_prefix("[") { return None }
  let mut close = 1
  let mut depth = 1
  while close < trimmed.length() && depth > 0 {
    if trimmed[close] == b'['.to_uint16() { depth = depth + 1 }
    if trimmed[close] == b']'.to_uint16() { depth = depth - 1 }
    close = close + 1
  }
  if depth != 0 || close >= trimmed.length() || trimmed[close] != b':'.to_uint16() { return None }
  let label = trimmed[1:close-1].trim().to_owned()
  if label.is_empty() { return None }
  let rest = trimmed[close+1:].trim().to_owned()
  let (url, title) = split_link_target(rest)
  match safe_url(url) {
    Some(clean) => Some((label.to_lower(), { url: clean, title }))
    None => None
  }
}

// A '](' in the label whose bracket is not an image opener: the label
// carries a nested link, so the enclosing link must not render (CommonMark
// lets the inner link win and leaves the outer construct literal).
fn label_has_link(label : String) -> Bool {
  let mut k = 0
  while k + 1 < label.length() {
    if label[k] == b']'.to_uint16() && label[k+1] == b'('.to_uint16() {
      let mut j = k
      while j >= 0 {
        if label[j] == b'['.to_uint16() {
          if j == 0 || label[j-1] != b'!'.to_uint16() { return true }
          break
        }
        j = j - 1
      }
    }
    k = k + 1
  }
  false
}

// One segmentation pass: backslash escapes, code spans, wikilinks, links,
// images and reference links become final HTML segments; the untouched
// remainder comes back as raw text so emphasis markers can never pair across
// a code span, an escape or a link boundary. With allow_links=false the
// anchor-producing branches degrade to literal text (used for link labels,
// which must not nest another <a>).
fn inline_segments(text : String, page_ids : Map[String, Bool], refs : Map[String, LinkDef], allow_links : Bool) -> (Array[String], String) {
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
    if allow_links && code == b'['.to_uint16() && i + 1 < text.length() && text[i+1] == b'['.to_uint16() {
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
    // Image ![alt](src "title"), link [text](href "title"), then the
    // reference forms [label][ref], [label][] and [label].
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
      if depth == 0 {
        let inner = text[bracket+1:close-1].to_owned()
        if close < text.length() && text[close] == b'('.to_uint16() {
          let mut end = close + 1
          let mut paren = 1
          while end < text.length() && paren > 0 {
            if text[end] == b'('.to_uint16() { paren = paren + 1 }
            if text[end] == b')'.to_uint16() { paren = paren - 1 }
            end = end + 1
          }
          if paren == 0 {
            let (url, title) = split_link_target(text[close+1:end-1].trim().to_owned())
            match safe_url(url) {
              Some(clean) => {
                flush()
                let title_attr = if title.is_empty() { "" } else { " title=\"" + escape(title) + "\"" }
                let nested = !image && label_has_link(inner)
                if image {
                  out.push("<img src=\"" + escape(clean) + "\" alt=\"" + escape(inner) + "\"" + title_attr + ">")
                } else if nested {
                  // CommonMark: the inner link wins, so the outer construct
                  // degrades to literal text instead of nesting anchors.
                } else {
                  out.push("<a href=\"" + escape(clean) + "\"" + title_attr + ">" +
                    inline_no_links(inner, page_ids, refs) + "</a>")
                }
                if !nested {
                  i = end
                  continue
                }
              }
              None => ()
            }
          }
        } else if allow_links {
          // Reference forms: [label][ref], collapsed [label][] and the
          // shortcut [label]; labels are matched case-insensitively.
          let candidate : (String, Int)? = if close < text.length() && text[close] == b'['.to_uint16() {
            let mut ref_end = close + 1
            let mut ref_depth = 1
            while ref_end < text.length() && ref_depth > 0 {
              if text[ref_end] == b'['.to_uint16() { ref_depth = ref_depth + 1 }
              if text[ref_end] == b']'.to_uint16() { ref_depth = ref_depth - 1 }
              ref_end = ref_end + 1
            }
            if ref_depth == 0 {
              let refspec = text[close+1:ref_end-1].trim().to_owned()
              Some((if refspec.is_empty() { inner } else { refspec }, ref_end))
            } else {
              None
            }
          } else {
            Some((inner, close))
          }
          match candidate {
            Some((label, end_pos)) => match refs.get(label.trim().to_owned().to_lower()) {
              Some(def) => {
                flush()
                let title_attr = if def.title.is_empty() { "" } else { " title=\"" + escape(def.title) + "\"" }
                out.push("<a href=\"" + escape(def.url) + "\"" + title_attr + ">" +
                  inline_no_links(inner, page_ids, refs) + "</a>")
                i = end_pos
                continue
              }
              None => ()
            }
            None => ()
          }
        }
      }
    }
    // Default: copy one code unit, or a whole surrogate pair — slicing a
    // single UTF-16 unit would orphan half of an astral character (emoji,
    // extension-plane hanzi) and drop it from the output.
    if code >= 0xD800 && code <= 0xDBFF && i + 1 < text.length() &&
      text[i+1] >= 0xDC00 && text[i+1] <= 0xDFFF {
      raw = raw + text[i:i+2].to_owned()
      i = i + 2
    } else {
      raw = raw + text[i:i+1].to_owned()
      i = i + 1
    }
  }
  (out, raw)
}

fn inline_no_links(text : String, page_ids : Map[String, Bool], refs : Map[String, LinkDef]) -> String {
  let (segments, raw) = inline_segments(text, page_ids, refs, false)
  segments.push(emphasis_html(raw))
  segments.join("")
}

fn inline_render(text : String, page_ids : Map[String, Bool], refs : Map[String, LinkDef]) -> String {
  let (segments, raw) = inline_segments(text, page_ids, refs, true)
  segments.push(emphasis_html(raw))
  segments.join("")
}

// One emphasis delimiter run over the raw text between final segments.
priv struct Delim {
  ch : UInt16
  pos : Int
  count : Int
  orig : Int
  can_open : Bool
  can_close : Bool
}

priv enum EmChunk {
  Lit(String)
  Tag(String)
  Del(Delim)
}

fn emphasis_html(text : String) -> String {
  // CommonMark delimiter runs: flanking rules decide which runs may open or
  // close, closers match the nearest eligible opener of the same marker
  // character (rule of three included), and leftover units stay literal —
  // so word-internal underscores never pair and *** nests em in strong.
  let chunks : Array[EmChunk] = []
  let mut i = 0
  while i < text.length() {
    let code = text[i]
    if code == b'*'.to_uint16() || code == b'_'.to_uint16() {
      let mut run = 0
      while i + run < text.length() && text[i+run] == code { run = run + 1 }
      // Non-ASCII units count as neither whitespace nor punctuation (CJK
      // and emoji are word characters for flanking purposes here).
      let before = if i > 0 { Some(text[i-1]) } else { None }
      let after = if i + run < text.length() { Some(text[i+run]) } else { None }
      let before_space = match before { None => true; Some(c) => is_emph_space(c) }
      let after_space = match after { None => true; Some(c) => is_emph_space(c) }
      let before_punct = match before { None => false; Some(c) => is_punct_code(c) }
      let after_punct = match after { None => false; Some(c) => is_punct_code(c) }
      let left = !after_space && (!after_punct || before_space || before_punct)
      let right = !before_space && (!before_punct || after_space || after_punct)
      let (can_open, can_close) = if code == b'*'.to_uint16() {
        (left, right)
      } else {
        (left && (!right || before_punct), right && (!left || after_punct))
      }
      chunks.push(Del({ ch: code, pos: i, count: run, orig: run, can_open, can_close }))
      i = i + run
    } else {
      let start = i
      while i < text.length() && text[i] != b'*'.to_uint16() && text[i] != b'_'.to_uint16() {
        i = i + 1
      }
      chunks.push(Lit(text[start:i].to_owned()))
    }
  }
  let mut closer = 0
  while closer < chunks.length() {
    let is_closer = match chunks[closer] {
      Del(d) => d.can_close && d.count > 0
      _ => false
    }
    if !is_closer { closer = closer + 1; continue }
    let closer_ch = match chunks[closer] { Del(d) => d.ch; _ => b' '.to_uint16() }
    let closer_orig = match chunks[closer] { Del(d) => d.orig; _ => 0 }
    let mut opener = -1
    let closer_both = match chunks[closer] { Del(c) => c.can_open && c.can_close; _ => false }
    let mut scan = closer - 1
    while scan >= 0 {
      match chunks[scan] {
        Del(d) => if d.ch == closer_ch && d.can_open && d.count > 0 {
          // Rule of three: when either delimiter can both open and close,
          // the original lengths must avoid summing to a multiple of 3
          // (unless both lengths are multiples of 3).
          let either_both = (d.can_open && d.can_close) || closer_both
          if !either_both || ((d.orig + closer_orig) % 3 != 0) || (d.orig % 3 == 0 && closer_orig % 3 == 0) {
            opener = scan
            break
          }
        }
        _ => ()
      }
      scan = scan - 1
    }
    if opener < 0 { closer = closer + 1; continue }
    let open_count = match chunks[opener] { Del(d) => d.count; _ => 0 }
    let close_count = match chunks[closer] { Del(d) => d.count; _ => 0 }
    let used = if open_count >= 2 && close_count >= 2 { 2 } else { 1 }
    let open_tag = if used == 2 { "<strong>" } else { "<em>" }
    let close_tag = if used == 2 { "</strong>" } else { "</em>" }
    chunks.insert(closer, Tag(close_tag))
    chunks.insert(opener + 1, Tag(open_tag))
    // The closer chunk moved behind both insertions.
    match chunks[opener] {
      Del(d) => chunks[opener] = Del({ ..d, count: d.count - used })
      _ => ()
    }
    match chunks[closer + 2] {
      Del(d) => chunks[closer + 2] = Del({ ..d, count: d.count - used })
      _ => ()
    }
    let closer_left = match chunks[closer + 2] { Del(d) => d.count; _ => 0 }
    closer = if closer_left > 0 { closer + 2 } else { closer + 3 }
  }
  let out : Array[String] = []
  for chunk in chunks {
    match chunk {
      Lit(text) => out.push(escape(text))
      Tag(tag) => out.push(tag)
      Del(d) => if d.count > 0 { out.push(escape(text[d.pos:d.pos+d.count].to_owned())) }
    }
  }
  out.join("")
}

// A fence opens at at most three leading spaces with a run of at least
// three ` or ~ markers; the rest of the line is the info string. A backtick
// fence whose info string contains a backtick is not a fence (CommonMark),
// matching the shared core classification.
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
  // The first whitespace-separated word of the info string; the class
  // attribute is escaped at the render site, so non-ASCII names survive.
  let trimmed = info.trim().to_owned()
  let mut end = 0
  while end < trimmed.length() && trimmed[end] != b' '.to_uint16() && trimmed[end] != b'\t'.to_uint16() {
    end = end + 1
  }
  trimmed[:end].to_owned()
}

// Setext underline: a bare = run is h1, a bare - run is h2.
fn setext_level(trimmed : String) -> Int? {
  if trimmed.is_empty() { return None }
  let mut eq = 0
  let mut dash = 0
  for c in trimmed {
    if c == '=' { eq = eq + 1 }
    if c == '-' { dash = dash + 1 }
  }
  if eq == trimmed.length() { Some(1) } else if dash == trimmed.length() { Some(2) } else { None }
}

// Strip the optional ATX closing sequence: whitespace + any number of #,
// with optional trailing whitespace ("# 标题 #" -> "标题").
fn strip_atx_closing(content : String) -> String {
  let mut end = content.length()
  while end > 0 && content[end-1] == b' '.to_uint16() { end = end - 1 }
  let mut hash_end = end
  while hash_end > 0 && content[hash_end-1] == b'#'.to_uint16() { hash_end = hash_end - 1 }
  if end - hash_end > 0 && (hash_end == 0 || content[hash_end-1] == b' '.to_uint16()) {
    end = hash_end
    while end > 0 && content[end-1] == b' '.to_uint16() { end = end - 1 }
  }
  content[:end].to_owned()
}

fn render_blocks(lines : Array[String], page_ids : Map[String, Bool], refs : Map[String, LinkDef]) -> String {
  let out : Array[String] = []
  let mask = @core.code_line_mask(lines)
  let inline = fn(text : String) -> String { inline_render(text, page_ids, refs) }
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    if mask[i] {
      // One masked region may interleave indented code with fenced blocks
      // (the mask classification is shared with fence_open): walk it block
      // by block so each renders in document order.
      while i < lines.length() && mask[i] {
        match fence_open(lines[i]) {
          Some((marker, run)) => {
            let info = lines[i].trim().to_owned()
            let language = fence_language(info[run:].to_owned())
            let mut body_text = ""
            i = i + 1
            while i < lines.length() && !fence_close(lines[i], marker, run) {
              body_text = body_text + lines[i] + "\n"
              i = i + 1
            }
            if i < lines.length() { i = i + 1 }
            let class = if language.is_empty() { "" } else { " class=\"language-" + escape(language) + "\"" }
            out.push("<pre><code" + class + ">" + escape(body_text) + "</code></pre>")
          }
          None => {
            let mut body_text = ""
            while i < lines.length() && mask[i] {
              match fence_open(lines[i]) {
                Some(_) => break
                None => {
                  body_text = body_text + lines[i].trim().to_owned() + "\n"
                  i = i + 1
                }
              }
            }
            out.push("<pre><code>" + escape(body_text) + "</code></pre>")
          }
        }
      }
      continue
    }
    let trimmed = line.trim().to_owned()
    if trimmed.is_empty() {
      i = i + 1
      continue
    }
    // ATX heading: 1-6 # followed by a space or end of line; an optional
    // closing # sequence is stripped from the content.
    let mut hashes = 0
    while hashes < trimmed.length() && trimmed[hashes] == b'#'.to_uint16() && hashes < 6 {
      hashes = hashes + 1
    }
    if hashes > 0 && (hashes >= trimmed.length() || trimmed[hashes] == b' '.to_uint16()) {
      let level = hashes.to_string()
      let mut content = trimmed[hashes:].to_owned()
      if !content.is_empty() && content[0] == b' '.to_uint16() { content = content[1:].to_owned() }
      out.push("<h" + level + ">" + inline(strip_atx_closing(content)) + "</h" + level + ">")
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
    // Link reference definition: consumed, never rendered.
    if link_definition(trimmed) is Some(_) {
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
      out.push("<blockquote>" + render_blocks(inner, page_ids, refs) + "</blockquote>")
      continue
    }
    // Lists: items render tight; a marker line indented deeper than its
    // item nests inside it (rendered recursively), continuation lines join
    // the item text, and the ordered start number is kept.
    if is_list_marker_line(trimmed) {
      let tag = if trimmed[0] >= b'0'.to_uint16() && trimmed[0] <= b'9'.to_uint16() { "ol" } else { "ul" }
      let start = ordered_marker_start(trimmed)
      let start_attr = if tag == "ol" && start != 1 { " start=\"" + start.to_string() + "\"" } else { "" }
      let items : Array[String] = []
      while i < lines.length() {
        let current = lines[i]
        if current.trim().is_empty() || mask[i] { break }
        let current_trimmed = current.trim().to_owned()
        if !is_list_marker_line(current_trimmed) { break }
        let item_indent = leading_spaces(current)
        let content_col = item_indent + marker_width(current_trimmed)
        let mut content = list_item_content(current_trimmed)
        i = i + 1
        let inner : Array[String] = []
        while i < lines.length() {
          let next = lines[i]
          if mask[i] {
            // Code (or a fence) indented under the item stays inside it; a
            // blank line the mask folded into that code region comes along,
            // so the region never leaks past the list as a separate block.
            if next.trim().is_empty() || leading_spaces(next) >= content_col {
              inner.push(next)
              i = i + 1
              continue
            }
            break
          }
          if next.trim().is_empty() { break }
          let next_trimmed = next.trim().to_owned()
          if is_list_marker_line(next_trimmed) {
            if leading_spaces(next) > item_indent {
              inner.push(next)
              i = i + 1
              continue
            }
            break // sibling or dedented marker: the item ends here
          }
          if next_trimmed == next {
            content = content + " " + next_trimmed // lazy continuation
          } else if leading_spaces(next) > item_indent {
            content = content + " " + next_trimmed
          } else {
            break
          }
          i = i + 1
        }
        let inner_html = if inner.is_empty() { "" } else { render_blocks(inner, page_ids, refs) }
        items.push("<li>" + inline(content) + inner_html + "</li>")
      }
      out.push("<" + tag + start_attr + ">" + items.join("") + "</" + tag + ">")
      continue
    }
    // Paragraph: consecutive ordinary lines, until a setext underline turns
    // them into a heading.
    let paragraph : Array[String] = []
    let mut underline : Int? = None
    while i < lines.length() {
      let current = lines[i]
      if mask[i] || current.trim().is_empty() { break }
      let current_trimmed = current.trim().to_owned()
      if current_trimmed.has_prefix(">") || is_list_marker_line(current_trimmed) { break }
      match setext_level(current_trimmed) {
        Some(level) if !paragraph.is_empty() => { underline = Some(level); i = i + 1; break }
        _ => ()
      }
      if link_definition(current_trimmed) is Some(_) { break }
      paragraph.push(current_trimmed)
      i = i + 1
    }
    let body = inline(paragraph.join("\n"))
    match underline {
      Some(level) => {
        let level_text = level.to_string()
        out.push("<h" + level_text + ">" + body + "</h" + level_text + ">")
      }
      None => out.push("<p>" + body + "</p>")
    }
  }
  out.join("")
}

/// Render a page (or raw source) body into the static HTML baseline.
pub fn render_markdown(body : String, page_ids : Array[String]) -> String {
  let ids : Map[String, Bool] = Map([])
  for id in page_ids { ids[id] = true }
  let lines = body.split("\n").map(x => x.to_owned()).to_array()
  // Register link reference definitions up front: CommonMark allows forward
  // references, so every definition must be known before any inline pass.
  let mask = @core.code_line_mask(lines)
  let refs : Map[String, LinkDef] = Map([])
  for i = 0; i < lines.length(); i = i + 1 {
    if !mask[i] {
      match link_definition(lines[i]) {
        Some((label, def)) => refs[label] = def
        None => ()
      }
    }
  }
  render_blocks(lines, ids, refs)
}
