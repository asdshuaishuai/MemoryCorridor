pub(all) struct Document {
  path : String
  metadata : Json
  body : String
  raw : String
}

pub fn reserved(path : String) -> Bool {
  let name = path.rev_split_once("/").map(p => p.1.to_owned()).unwrap_or(path)
  name == "index.md" || name == "log.md"
}

pub fn title_from_path(path : String) -> String {
  let name = path.rev_split_once("/").map(p => p.1.to_owned()).unwrap_or(path)
  if name.has_suffix(".md") { name[:name.length()-3].to_owned() } else { name }
}

pub fn metadata_field(meta : Json, key : String) -> Json? {
  match meta { Object(fields) => fields.get(key); _ => None }
}

pub fn parse(path : String, text : String, format : String) -> Document raise @base.Fault {
  @base.path(path)
  if !["okf", "markdown"].contains(format) { @base.fail("interop_format_unsupported") }
  let mut normalized = @base.replace_all(text, "\r\n", "\n")
  if normalized.has_prefix("\uFEFF") { normalized = normalized[1:].to_owned() }
  if !normalized.has_prefix("---\n") {
    if format == "okf" && !reserved(path) { @base.fail("okf_frontmatter_required: " + path) }
    let metadata : Json = if reserved(path) { Json::object(Map([])) } else { { "type": "Reference", "title": title_from_path(path) } }
    return { path, metadata, body: normalized, raw: text }
  }
  let rest = normalized[4:].to_owned()
  let mut offset = 0
  let mut end = -1
  for line in rest.split("\n") {
    if line == "---" { end = offset; break }
    offset = offset+line.length()+1
  }
  if end < 0 { @base.fail("interop_frontmatter_unterminated: " + path) }
  let flavor = @yaml.Flavor::new(depth=64, duplicates=Reject, budget=100000)
  let metadata = try @yaml.loads(rest[:end], flavor~) catch {
    _ => raise @base.Fault("interop_yaml_invalid_or_unsupported: " + path)
  }
  match metadata { Object(_) => (); _ => @base.fail("interop_frontmatter_mapping_required") }
  if !reserved(path) {
    match metadata_field(metadata, "type") {
      Some(String(kind)) if !kind.trim().is_empty() => ()
      None if format == "markdown" => ()
      _ => @base.fail("okf_type_required: " + path)
    }
  }
  let start = Int::min(rest.length(), end+4)
  { path, metadata, body: rest[start:].to_owned(), raw: text }
}

pub fn display_title(doc : Document) -> String {
  match metadata_field(doc.metadata, "title") { Some(String(title)) if !title.is_empty() => title; _ => title_from_path(doc.path) }
}

pub fn tags(doc : Document) -> Array[String] {
  match metadata_field(doc.metadata, "tags") {
    Some(Array(values)) => values.filter_map(v => match v { String(tag) => Some(tag); _ => None })
    _ => []
  }
}

pub fn emit(metadata : Json, body : String) -> String {
  "---\n" + @yaml.dumps(metadata, sort=true) + "---\n" + body
}
