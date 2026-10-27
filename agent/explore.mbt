fn graph(store : @vault.Storage, entries : Array[@core.Entry]) -> @index.Graph raise @base.Fault {
  @vault.verify(store, entries)
  graph_unchecked(store, entries)
}

// The caller must have verified the vault already. Operations that dispatch
// straight into an aggregator verify once at the top, and `graph`'s own verify
// then re-hashed every file in the vault on top of that.
fn graph_unchecked(store : @vault.Storage, entries : Array[@core.Entry]) -> @index.Graph raise @base.Fault {
  let pages : Array[(@core.Entry, @core.Page)] = []
  for e in entries {
    if @core.is_page(e) && !e.stale { pages.push((e, @core.parse_page(@vault.required(store, e.path)))) }
  }
  @index.build_graph(pages)
}

fn optional(value : Json, key : String) -> Json? {
  match value { Object(fields) => fields.get(key); _ => None }
}

fn integer(value : Json, key : String, default : Int, low : Int, high : Int) -> Int raise @base.Fault {
  match optional(value, key) {
    None => default
    Some(Number(n, ..)) if n >= low.to_double() && n <= high.to_double() && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("invalid_integer: " + key + "; \{low}..\{high}")
  }
}

fn choice(value : Json, key : String, default : String, allowed : Array[String]) -> String raise @base.Fault {
  match optional(value, key) {
    None => default
    Some(String(s)) => if allowed.contains(s) { s } else {
      raise @base.Fault("invalid_choice: " + key + "=" + s + "; allowed=" + allowed.join(","))
    }
    _ => raise @base.Fault("invalid_choice: " + key)
  }
}

priv struct TreePage {
  name : String
  id : String
  title : String
  path : String
  kind : String
  stale : Bool
} derive(ToJson)

priv struct TreeDir {
  name : String
  dirs : Map[String, TreeDir]
  pages : Array[TreePage]
}

fn tree_dir(name : String) -> TreeDir {
  { name, dirs: Map([]), pages: [] }
}

fn tree_insert(dir : TreeDir, parts : Array[String], page : TreePage) -> TreeDir {
  if parts.is_empty() {
    dir.pages.push(page)
    return dir
  }
  let name = parts[0]
  if name.is_empty() { return tree_insert(dir, parts[1:].to_owned(), page) }
  let child = dir.dirs.get(name).unwrap_or(tree_dir(name))
  dir.dirs[name] = tree_insert(child, parts[1:].to_owned(), page)
  dir
}

fn tree_page_order(a : TreePage, b : TreePage) -> Int {
  let a_index = a.name == "index"
  let b_index = b.name == "index"
  if a_index && !b_index { -1 }
  else if !a_index && b_index { 1 }
  else {
    let by_name = @base.compare(a.name, b.name)
    if by_name != 0 { by_name } else { @base.compare(a.id, b.id) }
  }
}

fn tree_json(dir : TreeDir) -> Json {
  let names = dir.dirs.keys().to_array()
  names.sort_by(@base.compare)
  let dirs = names.map(name => tree_json(dir.dirs[name]))
  let pages = dir.pages.copy()
  pages.sort_by(tree_page_order)
  { "name": dir.name, "dirs": dirs.to_json(), "pages": pages.to_json() }
}

fn page_tree(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  let mut root = tree_dir("wiki")
  for entry in entries {
    if !@core.is_page(entry) { continue }
    let page = @core.parse_page(@vault.required(store, entry.path))
    if !entry.path.has_prefix("wiki/") || !entry.path.has_suffix(".md") {
      @base.fail("invalid_page_entry: " + entry.id)
    }
    let relative = entry.path[5:entry.path.length()-3].to_owned()
    let segments = relative.split("/").map(part => part.to_owned()).to_array()
    if segments.is_empty() { @base.fail("invalid_page_entry: " + entry.id) }
    let name = segments[segments.length()-1]
    let dirs = segments[:segments.length()-1].to_owned()
    let item : TreePage = { name, id: entry.id, title: page.title, path: entry.path, kind: entry.kind, stale: entry.stale }
    root = tree_insert(root, dirs, item)
  }
  tree_json(root)
}

fn explore(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  let g = graph(store, entries)
  let id = key => @base.text(@base.field(request, key))
  match op {
    "graph" => match optional(request, "seed") {
      None => g.to_json()
      Some(seed) => @index.subgraph(g, @base.text(seed), integer(request, "hops", 2, 0, 8)).to_json()
    }
    "neighbors" => { "id": id("id"), "neighbors": @index.neighbors(g, id("id")).to_json() }
    "path" => { "path": @index.path(g, id("from"), id("to")).to_json() }
    "weighted-path" => { "path": @index.weighted_path(g, id("from"), id("to")).to_json() }
    "insights" => @index.insights(g)
    "tree" => page_tree(store, entries)
    _ => raise @base.Fault("unknown_exploration")
  }
}

// Explicit upper-bound estimate: one UTF-8 byte per budget unit. Host tokenizers
// can refine it, but this bound never silently exceeds the requested allocation.
fn assemble(
  store : @vault.Storage, entries : Array[@core.Entry], result : Json, request : Json,
) -> Json raise @base.Fault {
  let budget = integer(request, "budget", 4096, 1, 65536)
  let hops = integer(request, "hops", 2, 0, 2)
  let dedup = choice(request, "dedup", "exact", ["exact", "similar"])
  let spread = choice(request, "spread", "ranked", ["ranked", "even"])
  let hits = @base.array(@base.field(result, "hits"))
  let ids = hits.map(h => @base.text(@base.field(h, "id")))
  let seeds = ids.copy()
  let g = graph_unchecked(store, entries)
  for expansion in @index.expand(g, seeds, hops) {
    if !ids.contains(expansion.id) { ids.push(expansion.id) }
  }
  let candidates : Array[@index.ContextPage] = []
  for id in ids {
    let e = @core.find(entries, id)
    let page = @core.parse_page(@vault.required(store, e.path))
    candidates.push({ entry: e, page, origin: if seeds.contains(id) { "retrieval" } else { "graph" } })
  }
  let assembled = @index.assemble_context(candidates, @base.text(@base.field(request, "query")), budget,
    dedup~, spread~)
  match assembled {
    Object(fields) => {
      let blocks = @base.array(@base.field(assembled, "blocks"))
      let enriched : Array[Json] = []
      for block in blocks {
        let id = @base.text(@base.field(block, "id"))
        let evidence = evidence_for_page_checked(store, entries, id)
        match block {
          Object(block_fields) => {
            block_fields["evidence"] = evidence
            enriched.push(Json::object(block_fields))
          }
          _ => @base.fail("internal_context_block")
        }
      }
      fields["blocks"] = enriched.to_json()
      Json::object(fields)
    }
    _ => raise @base.Fault("internal_context_result")
  }
}
