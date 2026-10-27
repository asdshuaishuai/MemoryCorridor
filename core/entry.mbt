pub(all) struct Entry {
  id : String
  path : String
  kind : String
  format : String
  sha256 : String
  sources : Array[String]
  stale : Bool
} derive(Eq, ToJson)

pub extend Entry with Eq::{equal, not_equal}
pub extend Entry with ToJson::{to_json}

pub fn is_page(entry : Entry) -> Bool {
  ["entity", "concept", "source-summary", "synthesis", "query"].contains(entry.kind)
}

// The format is part of the catalog contract, rather than a renderer-only
// guess. Unknown extensions remain readable as binary and can be replaced by
// a future extractor without changing the entry identity.
pub fn format_for_path(path : String) -> String {
  let normalized = path.to_lower()
  if normalized == "dockerfile" || normalized.has_suffix("/dockerfile") { return "dockerfile" }
  if normalized == "makefile" || normalized.has_suffix("/makefile") { return "makefile" }
  let ext = normalized.rev_split_once(".").map(p => p.1.to_owned()).unwrap_or("")
  if ["md", "markdown", "mdx"].contains(ext) { return "markdown" }
  if ["html", "htm"].contains(ext) { return "html" }
  if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return "image" }
  if ["txt", "csv", "log", "rst"].contains(ext) || normalized.has_suffix("/license") { return "text" }
  let languages = Map([
    ("mbt", "moonbit"), ("js", "javascript"), ("mjs", "javascript"), ("cjs", "javascript"),
    ("ts", "typescript"), ("tsx", "tsx"), ("jsx", "jsx"), ("json", "json"),
    ("py", "python"), ("rs", "rust"), ("go", "go"), ("c", "c"), ("h", "c"),
    ("cpp", "cpp"), ("hpp", "cpp"), ("cs", "csharp"), ("java", "java"),
    ("kt", "kotlin"), ("kts", "kotlin"), ("swift", "swift"), ("dart", "dart"), ("rb", "ruby"),
    ("php", "php"), ("lua", "lua"), ("scala", "scala"), ("hs", "haskell"), ("lhs", "haskell"),
    ("ex", "elixir"), ("exs", "elixir"), ("clj", "clojure"), ("cljs", "clojure"),
    ("fs", "fsharp"), ("fsx", "fsharp"), ("pl", "perl"), ("r", "r"), ("jl", "julia"),
    ("sh", "bash"), ("zsh", "bash"), ("fish", "bash"), ("ps1", "powershell"), ("sql", "sql"),
    ("toml", "ini"), ("ini", "ini"), ("cfg", "ini"), ("conf", "ini"),
    ("yaml", "yaml"), ("yml", "yaml"), ("xml", "xml"), ("css", "css"),
    ("scss", "scss"), ("less", "less"), ("graphql", "graphql"), ("gql", "graphql"), ("vue", "vue"),
    ("proto", "protobuf"), ("tex", "latex"), ("mk", "makefile"),
  ])
  languages.get(ext).unwrap_or("binary")
}

pub fn expected_format(kind : String, path : String) -> String {
  if kind == "raw" { format_for_path(path) }
  else if is_page({ id: "", path, kind, format: "", sha256: "", sources: [], stale: false }) || kind == "purpose" { "markdown" }
  else { "json" }
}

pub fn entry_from_json(value : Json) -> Entry raise @base.Fault {
  @base.keys(value, ["id", "path", "kind", "format", "sha256", "sources", "stale"])
  let path = @base.text(@base.field(value, "path"))
  let kind = @base.text(@base.field(value, "kind"))
  // Snapshots written before format became part of the catalog remain
  // readable; generation always emits the explicit field.
  let format = match value {
    Object(fields) => match fields.get("format") {
      Some(v) => @base.text(v)
      None => expected_format(kind, path)
    }
    _ => @base.text(@base.field(value, "format"))
  }
  {
    id: @base.text(@base.field(value, "id")),
    path,
    kind,
    format,
    sha256: @base.text(@base.field(value, "sha256")),
    sources: @base.strings(@base.field(value, "sources")),
    stale: @base.boolean(@base.field(value, "stale")),
  }
}

pub fn validate_entries(entries : Array[Entry]) -> Unit raise @base.Fault {
  let ids : Map[String, Bool] = Map([])
  let paths : Map[String, Bool] = Map([])
  for e in entries {
    @base.path(e.id)
    @base.path(e.path)
    if e.format.is_empty() || e.format.length() > 64 || e.format.contains("\n") || e.format.contains("\r") {
      @base.fail("invalid_entry_format: " + e.id)
    }
    if ids.contains(e.id) || paths.contains(e.path) {
      @base.fail("duplicate_entry: " + e.id)
    }
    ids[e.id] = true
    paths[e.path] = true
    if e.sha256.length() != 64 || !e.sha256.iter().all(c =>
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      @base.fail("invalid_sha256: " + e.id)
    }
    if is_page(e) {
      if !e.path.has_prefix("wiki/") || !e.path.has_suffix(".md") || e.format != "markdown" || e.sources.is_empty() {
        @base.fail("invalid_page_entry: " + e.id)
      }
    } else if e.kind == "purpose" {
      if e.id != "purpose.md" || e.path != "purpose.md" || e.format != "markdown" || !e.sources.is_empty() || e.stale { @base.fail("invalid_purpose_entry") }
    } else if e.kind == "raw" {
      // Raw ids are also the source references carried by pages and evidence.
      // Keeping id and path identical prevents a source reference from being
      // resolved as one file while its bytes are verified from another.
      if e.id != e.path || !e.path.has_prefix("raw/") || !e.sources.is_empty() || e.format != expected_format(e.kind, e.path) {
        @base.fail("invalid_raw_entry: " + e.id)
      }
    } else if e.kind == "vector" {
      if !e.path.has_prefix("vectors/") || e.format != "json" || !e.sources.is_empty() {
        @base.fail("invalid_vector_entry: " + e.id)
      }
    } else if e.kind == "state" {
      if !e.path.has_prefix("state/") || e.format != "json" || !e.sources.is_empty() {
        @base.fail("invalid_state_entry: " + e.id)
      }
    } else {
      @base.fail("unsupported_entry_kind: " + e.kind)
    }
    let seen : Map[String, Bool] = Map([])
    for source in e.sources {
      @base.path(source)
      if seen.contains(source) { @base.fail("duplicate_source: " + e.id) }
      seen[source] = true
    }
  }
  for e in entries {
    for source in e.sources {
      if !entries.iter().any(s => s.id == source && s.kind == "raw" && !s.stale) && !e.stale {
        @base.fail("source_unresolved: " + e.id + " -> " + source)
      }
    }
  }
}

pub fn find(entries : Array[Entry], id : String) -> Entry raise @base.Fault {
  for e in entries { if e.id == id { return e } }
  raise @base.Fault("entry_not_found: " + id)
}
