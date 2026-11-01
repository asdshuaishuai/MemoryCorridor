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

// YAML 键引号补写。moonyaml 的写入端按块上下文判定键可否裸写，但读取端
// 扫描映射键时按 flow 规则处理 plain 标量：任意冒号或 ,[]{} 都会断开。于是
// "a:b" 这样的未知元数据键会被裸写出，而引擎自己的 parse 必拒这个文件——
// 违反未知字段往返保留的要求。dumps 之后把这类键补上双引号（moonyaml 与
// 常见 YAML 解析器都接受带引号的键），写读两端就回到同一套判定。字面量块
// 标量与序列项的行内标量是值不是键，跳过不碰。
fn quote_reader_keys(yaml : String) -> String {
  let offending = c => c == ':' || c == ',' || c == '[' || c == ']' || c == '{' || c == '}'
  let quoted = (key : String) => {
    let out = StringBuilder()
    out.write_char('"')
    for i = 0; i < key.length(); i = i + 1 {
      let c = key[i]
      if c == b'\\'.to_uint16() { out.write_string("\\\\") } else if c == b'"'.to_uint16() { out.write_string("\\\"") }
      else { out.write_char(c.unsafe_to_char()) }
    }
    out.write_char('"')
    out.to_string()
  }
  let out : Array[String] = []
  let mut in_literal = false
  let mut literal_indent = 0
  for view in yaml.split("\n") {
    let line = view.to_owned()
    if in_literal {
      if line.trim().is_empty() || line.length() - line.trim_start().length() > literal_indent {
        out.push(line); continue
      }
      in_literal = false
    }
    let indent = line.length() - line.trim_start().length()
    let mut content = line[indent:].to_owned()
    let mut prefix = line[:indent].to_owned()
    if content.has_prefix("- ") {
      // 序列项内联的嵌套映射（`- a:b: 1`）同样以键开头；裸的 `- |` 项头
      // 则开启一个字面量块，内容行同样不是键。
      prefix = prefix + "- "
      content = content[2:].to_owned()
      if content == "|" || content == "|-" || content == "|+" {
        in_literal = true
        literal_indent = indent
        out.push(line); continue
      }
    }
    if content.is_empty() || content.has_prefix("\"") { out.push(line); continue }
    // 键与值的分界是第一个后跟空格或行尾的冒号；裸键里的冒号后面必然不是
    // 空白（那种键 moonyaml 自己就会加引号），所以扫描不会越过真分界。
    let mut separator = -1
    let mut at = 0
    while at < content.length() {
      if content[at] == b':'.to_uint16() && (at + 1 == content.length() || content[at + 1] == b' '.to_uint16()) {
        separator = at
        break
      }
      at = at + 1
    }
    if separator <= 0 { out.push(line); continue }
    let key = content[:separator].to_owned()
    let rest = content[separator:].to_owned()
    if rest == ": |" || rest == ": |-" || rest == ": |+" {
      in_literal = true
      literal_indent = indent
    }
    let mut dirty = false
    for i = 0; i < key.length(); i = i + 1 {
      if offending(key[i].unsafe_to_char()) { dirty = true; break }
    }
    if !dirty { out.push(line); continue }
    out.push(prefix + quoted(key) + rest)
  }
  out.join("\n")
}

pub fn emit(metadata : Json, body : String) -> String {
  "---\n" + quote_reader_keys(@yaml.dumps(metadata, sort=true)) + "---\n" + body
}
