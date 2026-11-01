// A closed literal grammar is shared with the generated, standalone MoonBit code.
fn prefix() -> String {
  "---\nmoonbit:\n  backend: native\n---\n\n# MemoryCorridor 目录 v1\n\n正文位于引用文件中；请通过引擎提交目录变更。\n\n```mbt check\npub(all) struct CorridorEntry {\n  id : String\n  path : String\n  kind : String\n  format : String\n  sha256 : String\n  sources : Array[String]\n  stale : Bool\n}\npub fn entry(id : String, path : String, kind : String, format : String, sha256 : String, sources : Array[String], stale : Bool) -> CorridorEntry {\n  { id, path, kind, format, sha256, sources, stale }\n}\npub fn corridor_entries() -> Array[CorridorEntry] {\n  [\n"
}

fn suffix(count : Int) -> String {
  "  ]\n}\ntest \"catalog declarations\" {\n  assert_eq(corridor_entries().length(), \{count})\n}\n```\n"
}

fn code_header() -> String {
  match prefix().split_once("```mbt check\n") {
    Some((_, code)) => code.to_owned()
    None => ""
  }
}

fn code_footer(count : Int) -> String {
  match suffix(count).split_once("\n```\n") {
    Some((code, _)) => code.to_owned()
    None => ""
  }
}

fn code_block(text : String) -> String raise @base.Fault {
  try { @base.first_checked_block(text).code } catch {
    @base.Fault(message) => if message == "literate_tail_content" {
      raise @base.Fault("catalog_literate_tail: separate trailing content from the closing fence with a blank line")
    } else {
      raise @base.Fault("catalog_header_invalid: require one mbt check block")
    }
  }
}

pub fn generate(entries : Array[@core.Entry]) -> String {
  let sorted = entries.copy()
  sorted.sort_by((a,b) => @base.compare(a.id, b.id))
  let lines = sorted.map(e => {
    let args : Array[Json] = [
      e.id.to_json(), e.path.to_json(), e.kind.to_json(), e.format.to_json(), e.sha256.to_json(),
      e.sources.to_json(), e.stale.to_json(),
    ]
    "    entry(" + args.map(@base.canonical).join(", ") + "),\n"
  })
  prefix() + lines.join("") + suffix(sorted.length())
}

// Replace only the canonical IR block in an existing literate catalog. The
// prose around it and any later mbt/mbt check blocks are user-authored inputs
// and must survive a catalog publication or cache snapshot.
pub fn generate_preserving(source : String, entries : Array[@core.Entry]) -> String raise @base.Fault {
  ignore(parse(source))
  let generated = code_block(generate(entries))
  @base.replace_first_checked(source, generated)
}

// Parse the literal rows without applying entry relationship validation.
// Lint uses this boundary to report several independent issues in one
// deterministic response; normal callers should use parse().
//
// The block is read as the closed MoonBit literal subset (@base.literal_*):
// the scaffolding before and after the rows must match the v1 declarations
// token for token (so no code can be smuggled in), while whitespace,
// comments, trailing commas and MoonBit string escapes inside the block are
// accepted exactly as moon itself accepts them. Publication always rewrites
// the block in canonical form; parse(generate(x)) round-trips by value.
pub fn parse_unchecked(text : String) -> Array[@core.Entry] raise @base.Fault {
  let code = code_block(text)
  let tokens = try @base.literal_tokens(code) catch {
    @base.Fault(message) => raise @base.Fault("catalog_non_literal: " + message)
  }
  let header = try @base.literal_tokens(code_header()) catch { _ => [] }
  if !@base.literal_prefix_matches(tokens, header) {
    @base.fail("catalog_header_invalid: require v1 literal DSL")
  }
  let result : Array[@core.Entry] = []
  let mut arity = 0
  let mut pos = header.length()
  while true {
    if pos >= tokens.length() { @base.fail("catalog_non_literal: unterminated entry list") }
    if tokens[pos] == Word("]") { break }
    let (args, next) = try @base.literal_call(tokens, pos, "entry") catch {
      @base.Fault(message) => raise @base.Fault("catalog_non_literal: only entry literal rows allowed (" + message + ")")
    }
    pos = next
    if pos < tokens.length() && tokens[pos] == Word(",") { pos = pos + 1 }
    if args.length() != 6 && args.length() != 7 { @base.fail("entry_arity: expected 6 or 7") }
    if arity == 0 { arity = args.length() }
    if arity != args.length() { @base.fail("entry_arity: mixed legacy and current rows") }
    let id = @base.text(args[0])
    let path = @base.text(args[1])
    let kind = @base.text(args[2])
    if args.length() == 7 {
      result.push({
        id, path, kind, format: @base.text(args[3]), sha256: @base.text(args[4]),
        sources: @base.strings(args[5]), stale: @base.boolean(args[6]),
      })
    } else {
      // v0 catalogs did not record the source format. Infer it once during
      // migration; the next generated catalog records it explicitly.
      result.push({
        id, path, kind, format: @core.expected_format(kind, path), sha256: @base.text(args[3]),
        sources: @base.strings(args[4]), stale: @base.boolean(args[5]),
      })
    }
  }
  // The footer closes the list and declares the row count; it must say
  // exactly what the rows say and contain nothing else.
  let footer = try @base.literal_tokens(code_footer(result.length())) catch { _ => [] }
  if !@base.literal_tail_matches(tokens, pos, footer) {
    @base.fail("catalog_noncanonical: footer must close the list and declare \{result.length()} entries")
  }
  result
}

pub fn parse(text : String) -> Array[@core.Entry] raise @base.Fault {
  let result = parse_unchecked(text)
  @core.validate_entries(result)
  result
}
