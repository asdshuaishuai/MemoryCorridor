fn decode_url(path : String) -> String? {
  let bytes : Array[Byte] = []
  let mut i = 0
  let hex = c => if c >= b'0'.to_uint16() && c <= b'9'.to_uint16() { c.to_int()-48 }
    else if c >= b'A'.to_uint16() && c <= b'F'.to_uint16() { c.to_int()-55 }
    else if c >= b'a'.to_uint16() && c <= b'f'.to_uint16() { c.to_int()-87 } else { -1 }
  while i < path.length() {
    if path[i] == b'%'.to_uint16() {
      if i+2 >= path.length() { return None }
      let a = hex(path[i+1])
      let b = hex(path[i+2])
      if a < 0 || b < 0 { return None }
      bytes.push((a*16+b).to_byte()); i = i+3
    } else {
      let mut end = i+1
      if path[i] >= 0xd800 && path[i] <= 0xdbff && end < path.length() { end = end+1 }
      for b in @utf8.encode(path[i:end]) { bytes.push(b) }
      i = end
    }
  }
  try Some(@utf8.decode(Bytes::from_array(bytes))) catch { _ => None }
}

pub fn encode_url(path : String) -> String {
  let hex = "0123456789ABCDEF"
  let out : Array[String] = []
  for b in @utf8.encode(path) {
    let c = b.to_int()
    if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || [45,46,47,95,126].contains(c) {
      out.push(c.unsafe_to_char().to_string())
    } else { out.push("%" + hex[c/16:c/16+1].to_owned() + hex[c%16:c%16+1].to_owned()) }
  }
  out.join("")
}

pub fn markdown_label(label : String) -> String {
  let slash = @base.replace_all(label, "\\", "\\\\")
  @base.replace_all(@base.replace_all(@base.replace_all(slash, "[", "\\["), "]", "\\]"), "\n", " ")
}

fn anchor_parts(value : String) -> (String, String) {
  match value.split_once("#") {
    Some((path, fragment)) => (path.to_owned(), fragment.to_owned())
    None => (value, "")
  }
}

fn valid_anchor(fragment : String) -> Bool {
  !fragment.is_empty() && !fragment.trim().is_empty() &&
    !fragment.contains("#") && !fragment.contains("\n") && !fragment.contains("\r") &&
    !fragment.contains_char('\u0000')
}

fn resolve(path : String, from : String) -> String? {
  if path.contains(":") || path.has_prefix("#") || path.has_prefix("//") { return None }
  let without_anchor = path.split("#").next().unwrap().to_owned()
  let decoded = match decode_url(without_anchor) { None => return None; Some(s) => s }
  let parts : Array[String] = []
  if !decoded.has_prefix("/") {
    match from.rev_split_once("/") { Some((parent, _)) => for part in parent.split("/") { parts.push(part.to_owned()) }; None => () }
  }
  for part in decoded.split("/") {
    if part == "" || part == "." { continue }
    if part == ".." { if parts.is_empty() { return None }; ignore(parts.pop()) }
    else { parts.push(part.to_owned()) }
  }
  let result = parts.join("/")
  if result == "" { None } else { Some(result) }
}

pub fn native_links(doc : Document, ids : Map[String, String]) -> (String, Array[String]) {
  let broken : Array[String] = []
  let lines : Array[String] = []
  let mut fence = ""
  for view in doc.body.split("\n") {
    let line = view.to_owned()
    let trim = line.trim_start()
    if trim.has_prefix("```") || trim.has_prefix("~~~") {
      let marker = trim[:3].to_owned()
      if fence == "" { fence = marker } else if fence == marker { fence = "" }
      lines.push(line); continue
    }
    if fence != "" { lines.push(line); continue }
    let out : Array[String] = []
    let mut i = 0
    let mut inline = false
    while i < line.length() {
      if line[i] == b'`'.to_uint16() { inline = !inline }
      if !inline && i+1 < line.length() && line[i:i+2] == "[[" {
        match line[i+2:].split_once("]]") {
          Some((inside, after)) => {
            let args = inside.split("|").map(s => s.to_owned()).to_array()
            let (target_path, fragment) = anchor_parts(args[0])
            let key = if target_path.has_suffix(".md") { target_path } else { target_path + ".md" }
            let resolved = resolve(key, doc.path)
            let id = match resolved { Some(p) => match ids.get(p) { Some(id) => Some(id); None => ids.get(key) }; None => ids.get(key) }
            match id {
              Some(id) if fragment.is_empty() || valid_anchor(fragment) => out.push("[[" + id + (if fragment.is_empty() { "" } else { "#" + fragment }) + (if args.length() > 1 { "|" + args[1] } else { "" }) + "]]")
              _ => { out.push("\\[\\[" + @base.replace_all(inside.to_owned(), "[[", "\\[\\[") + "]]"); if !broken.contains(args[0]) { broken.push(args[0]) } }
            }
            i = line.length()-after.length(); continue
          }
          None => { out.push("\\[\\["); i = i+2; continue }
        }
      }
      if !inline && line[i] == b'['.to_uint16() && (i == 0 || line[i-1] != b'!'.to_uint16()) {
        match line[i+1:].split_once("](") {
          Some((label, tail)) => match tail.split_once(")") {
            Some((url, after)) => {
              let target = url.trim().to_owned()
              let (target_path, raw_fragment) = anchor_parts(target)
              let fragment = if raw_fragment.is_empty() { "" } else { decode_url(raw_fragment).unwrap_or("") }
              let resolved = resolve(target_path, doc.path)
              let id = match resolved { Some(p) => ids.get(p); None => None }
              if id is Some(id) && (raw_fragment.is_empty() || valid_anchor(fragment)) && !label.contains("[") && !label.contains("]") && !label.contains("|") {
                out.push("[[" + id + (if fragment.is_empty() { "" } else { "#" + fragment }) + "|" + label.to_owned() + "]]")
              } else {
                let end = line.length()-after.length()
                out.push(@base.replace_all(line[i:end].to_owned(), "[[", "\\[\\["))
                if id is None && resolved is Some(p) && p.has_suffix(".md") && !broken.contains(p) { broken.push(p) }
              }
              i = line.length()-after.length(); continue
            }
            None => ()
          }
          None => ()
        }
      }
      out.push(line[i:i+1].to_owned()); i = i+1
    }
    lines.push(out.join(""))
  }
  (lines.join("\n"), broken)
}

pub fn okf_links(body : String, paths : Map[String, String]) -> String {
  let lines : Array[String] = []
  let mut fence = ""
  for view in body.split("\n") {
    let line = view.to_owned()
    let trim = line.trim_start()
    if trim.has_prefix("```") || trim.has_prefix("~~~") {
      let marker = trim[:3].to_owned()
      if fence == "" { fence = marker } else if fence == marker { fence = "" }
      lines.push(line); continue
    }
    if fence != "" { lines.push(line); continue }
    let out : Array[String] = []
    let mut inline = false
    let mut i = 0
    while i < line.length() {
      if line[i] == b'`'.to_uint16() { inline = !inline }
      if !inline && i+1 < line.length() && line[i:i+2] == "[[" {
        match line[i+2:].split_once("]]") {
          Some((inside, after)) => {
            let args = inside.split("|").map(s => s.to_owned()).to_array()
            let (target_id, fragment) = anchor_parts(args[0])
            let label = if args.length() > 1 { args[1] } else { target_id }
            let escaped = @base.replace_all(@base.replace_all(label, "[", "\\["), "]", "\\]")
            let target = paths.get(target_id).unwrap_or(target_id+".md")
            out.push("[" + escaped + "](/" + encode_url(target) + (if fragment.is_empty() { "" } else { "#" + encode_url(fragment) }) + ")")
            i = line.length()-after.length(); continue
          }
          None => ()
        }
      }
      out.push(line[i:i+1].to_owned()); i = i+1
    }
    lines.push(out.join(""))
  }
  lines.join("\n")
}
