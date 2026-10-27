pub(all) struct View {
  title : String
  accent : String
  paper : String
  panels : Array[String]
  features : Array[String]
} derive(ToJson)
pub extend View with ToJson::{to_json}

fn prefix() -> String {
  "---\nmoonbit:\n  backend: native\n---\n\n# MemoryCorridor 阅读页面 v1\n\n页面布局和数据绑定由下面的 MoonBit 声明决定。正文保留在知识文件中。\n\n```mbt check\npub(all) struct CorridorView {\n  title : String\n  accent : String\n  paper : String\n  panels : Array[String]\n  features : Array[String]\n}\npub fn view(title : String, accent : String, paper : String, panels : Array[String], features : Array[String]) -> CorridorView {\n  { title, accent, paper, panels, features }\n}\npub fn corridor_view() -> CorridorView {\n  "
}

fn suffix() -> String {
  "\n}\ntest \"visual declaration\" {\n  assert_eq(corridor_view().panels.length(), 3)\n}\n```\n"
}

fn code_header() -> String {
  match prefix().split_once("```mbt check\n") {
    Some((_, code)) => code.to_owned()
    None => ""
  }
}

fn code_footer() -> String {
  match suffix().split_once("\n```\n") {
    Some((code, _)) => code.to_owned()
    None => ""
  }
}

fn code_block(text : String) -> String raise @base.Fault {
  try { @base.first_checked_block(text).code } catch {
    @base.Fault(message) => if message == "literate_tail_content" {
      raise @base.Fault("view_literate_tail: separate trailing content from the closing fence with a blank line")
    } else {
      raise @base.Fault("view_literal_required: corridor-view-v1")
    }
  }
}

fn default_features() -> Array[String] {
  ["search", "routing", "rich-render", "code-format", "source-links"]
}

fn validate_features(features : Array[String]) -> Unit raise @base.Fault {
  if features.length() > 8 { @base.fail("view_feature_count: 0..8") }
  let seen : Map[String, Bool] = Map([])
  for feature in features {
    if !["search", "routing", "rich-render", "code-format", "source-links"].contains(feature) || seen.contains(feature) {
      @base.fail("view_feature_invalid: " + feature)
    }
    seen[feature] = true
  }
}

pub fn default_view() -> View {
  { title: "MemoryCorridor", accent: "#315B47", paper: "#F4F1E9", panels: ["catalog", "page", "sources"], features: default_features() }
}

pub fn generate(view : View) -> String {
  let args : Array[Json] = [view.title.to_json(), view.accent.to_json(), view.paper.to_json(), view.panels.to_json(), view.features.to_json()]
  prefix() + "view(" + args.map(@base.canonical).join(", ") + ")" + suffix()
}

pub fn parse(text : String) -> View raise @base.Fault {
  let code = code_block(text)
  let start = code_header() + "view("
  let end = ")" + code_footer()
  if !code.has_prefix(start) || !code.has_suffix(end) { @base.fail("view_literal_required: corridor-view-v1") }
  let args = @base.array(@base.parse("[" + code[start.length():code.length()-end.length()].to_owned() + "]"))
  if args.length() != 4 && args.length() != 5 { @base.fail("view_arity: expected 4 or 5") }
  let features = if args.length() == 5 { @base.strings(args[4]) } else { default_features() }
  let view : View = { title: @base.text(args[0]), accent: @base.text(args[1]), paper: @base.text(args[2]), panels: @base.strings(args[3]), features }
  if view.title.is_empty() || view.title.length() > 100 { @base.fail("view_title_length: 1..100") }
  for color in [view.accent, view.paper] {
    if color.length() != 7 || !color.has_prefix("#") || !color[1:].iter().all(c =>
      (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f')) { @base.fail("view_color_hex_required") }
  }
  if view.panels.length() < 3 || view.panels.length() > 5 ||
    !["catalog", "page", "sources"].all(p => view.panels.contains(p)) { @base.fail("view_panel_bindings_required") }
  let seen_panels : Map[String, Bool] = Map([])
  for panel in view.panels {
    if !["catalog", "page", "sources", "graph", "insights"].contains(panel) || seen_panels.contains(panel) {
      @base.fail("view_panel_binding_invalid: " + panel)
    }
    seen_panels[panel] = true
  }
  validate_features(view.features)
  let expected = start + args.map(@base.canonical).join(", ") + end
  if expected != code { @base.fail("view_noncanonical") }
  view
}
