pub(all) struct Node {
  id : String
  kind : String
  title : String
  tags : Array[String]
} derive(ToJson)
pub extend Node with ToJson::{to_json}

pub(all) struct Edge {
  source : String
  target : String
  kind : String
  weight : Double
} derive(ToJson)
pub extend Edge with ToJson::{to_json}

pub(all) struct Graph {
  nodes : Array[Node]
  edges : Array[Edge]
} derive(ToJson)
pub extend Graph with ToJson::{to_json}

pub fn build_graph(pages : Array[(@core.Entry, @core.Page)]) -> Graph {
  let sorted = pages.filter(p => !p.0.stale)
  sorted.sort_by((a,b) => @base.compare(a.0.id, b.0.id))
  let nodes = sorted.map(p => Node::{ id: p.0.id, kind: p.0.kind, title: p.1.title, tags: p.1.tags })
  let edges : Array[Edge] = []
  for (entry, page) in sorted {
    let links = page.links.copy()
    links.sort_by(@base.compare)
    for target in links {
      if nodes.any(n => n.id == target) {
        edges.push({ source: entry.id, target, kind: "wikilink", weight: 3.0 })
      }
    }
  }
  for i = 0; i < sorted.length(); i = i + 1 {
    for j = i+1; j < sorted.length(); j = j + 1 {
      let a = sorted[i].0
      let b = sorted[j].0
      if a.sources.any(s => b.sources.contains(s)) {
        edges.push({ source: a.id, target: b.id, kind: "shared-source", weight: 4.0 })
      }
    }
  }
  { nodes, edges }
}

pub fn neighbors(graph : Graph, id : String) -> Array[String] raise @base.Fault {
  if !graph.nodes.any(n => n.id == id) { @base.fail("graph_node_not_found: " + id) }
  let found : Array[String] = []
  for edge in graph.edges {
    let other = if edge.source == id { edge.target } else if edge.target == id { edge.source } else { continue }
    if !found.contains(other) { found.push(other) }
  }
  found.sort_by(@base.compare)
  found
}

// Paths and exploration traverse both directions; edge kind preserves authorship.
pub fn path(graph : Graph, from : String, to : String) -> Array[String] raise @base.Fault {
  ignore(neighbors(graph, from))
  ignore(neighbors(graph, to))
  let queue = [from]
  let parent : Map[String, String] = Map([])
  parent[from] = from
  let mut i = 0
  while i < queue.length() {
    let current = queue[i]
    i = i+1
    if current == to {
      let found = [to]
      let mut p = to
      while p != from { p = parent[p]; found.push(p) }
      let ordered : Array[String] = []
      for j = found.length()-1; j >= 0; j = j-1 { ordered.push(found[j]) }
      return ordered
    }
    for n in neighbors(graph, current) {
      if !parent.contains(n) { parent[n] = current; queue.push(n) }
    }
  }
  []
}

// Return a deterministic shortest path using the graph's relationship
// weights. Exploration treats edges as undirected, matching `path`; a direct
// wikilink (3.0) is cheaper than a shared-source edge (4.0). Ties are resolved
// by node id so callers receive stable results across map iteration and
// rebuilds.
pub fn weighted_path(graph : Graph, from : String, to : String) -> Array[String] raise @base.Fault {
  ignore(neighbors(graph, from))
  ignore(neighbors(graph, to))
  let distances : Map[String, Double] = Map([])
  let parent : Map[String, String] = Map([])
  let visited : Map[String, Bool] = Map([])
  for node in graph.nodes { distances[node.id] = 1.0e300 }
  distances[from] = 0.0
  while true {
    let mut current = ""
    let mut best = 1.0e300
    for node in graph.nodes {
      if visited.contains(node.id) { continue }
      let distance = distances[node.id]
      if distance < best || (distance == best && (current == "" || @base.compare(node.id, current) < 0)) {
        current = node.id
        best = distance
      }
    }
    if current == "" || best == 1.0e300 { break }
    visited[current] = true
    if current == to {
      let reversed = [to]
      let mut cursor = to
      while cursor != from {
        cursor = parent[cursor]
        reversed.push(cursor)
      }
      let result : Array[String] = []
      for i = reversed.length() - 1; i >= 0; i = i - 1 { result.push(reversed[i]) }
      return result
    }
    for edge in graph.edges {
      let neighbor = if edge.source == current { edge.target }
        else if edge.target == current { edge.source }
        else { continue }
      if visited.contains(neighbor) { continue }
      if edge.weight.is_nan() || edge.weight.is_inf() || edge.weight <= 0.0 {
        @base.fail("graph_edge_weight_invalid")
      }
      let candidate = best + edge.weight
      let old = distances[neighbor]
      if candidate < old {
        distances[neighbor] = candidate
        parent[neighbor] = current
      } else if candidate == old && (parent.get(neighbor) is None || @base.compare(current, parent[neighbor]) < 0) {
        parent[neighbor] = current
      }
    }
  }
  []
}

pub fn subgraph(graph : Graph, seed : String, hops : Int) -> Graph raise @base.Fault {
  let selected = [seed]
  let mut frontier = [seed]
  ignore(neighbors(graph, seed))
  for step = 0; step < hops; step = step + 1 {
    let next : Array[String] = []
    for id in frontier {
      for n in neighbors(graph, id) {
        if !selected.contains(n) { selected.push(n); next.push(n) }
      }
    }
    frontier = next
  }
  { nodes: graph.nodes.filter(n => selected.contains(n.id)),
    edges: graph.edges.filter(e => selected.contains(e.source) && selected.contains(e.target)) }
}

pub(all) struct Expansion {
  id : String
  score : Double
} derive(ToJson)
pub extend Expansion with ToJson::{to_json}

// Search-side expansion. Each seed spreads up to `hops`, and a node's score is
// the edge weight entering it at that hop divided by the hop distance
// (edge.weight x hop^-1); the best path score wins. Seeds are validated but
// never returned. Higher scores sort first, then id, so budget allocation is
// stable. Invalid edge weights are rejected instead of silently collapsing.
pub fn expand(graph : Graph, seeds : Array[String], hops : Int) -> Array[Expansion] raise @base.Fault {
  if hops <= 0 { return [] }
  let seed_set : Map[String, Bool] = Map([])
  let frontier : Array[String] = []
  for seed in seeds {
    ignore(neighbors(graph, seed))
    if !seed_set.contains(seed) { seed_set[seed] = true; frontier.push(seed) }
  }
  let best : Map[String, Double] = Map([])
  let mut layer = frontier
  for hop = 1; hop <= hops; hop = hop + 1 {
    let next : Array[String] = []
    for id in layer {
      for edge in graph.edges {
        let other = if edge.source == id { edge.target } else if edge.target == id { edge.source } else { continue }
        if edge.weight.is_nan() || edge.weight.is_inf() || edge.weight <= 0.0 {
          @base.fail("graph_edge_weight_invalid")
        }
        let candidate = edge.weight / hop.to_double()
        if !best.contains(other) || candidate > best[other] {
          best[other] = candidate
          if !next.contains(other) { next.push(other) }
        }
      }
    }
    layer = next
  }
  let rows : Array[Expansion] = []
  for id in best.keys() {
    if !seed_set.contains(id) { rows.push({ id, score: best[id] }) }
  }
  rows.sort_by((a, b) => if a.score != b.score { b.score.compare(a.score) } else { @base.compare(a.id, b.id) })
  rows
}

// Deterministic weighted label propagation. Each node starts in its own
// community; in sorted node order it adopts the neighboring label with the
// greatest incident weight, breaking ties by label id. Strict improvement and
// a bounded number of rounds keep the result reproducible on cyclic graphs.
fn communities(graph : Graph) -> Array[Json] raise @base.Fault {
  let ids = graph.nodes.map(n => n.id)
  ids.sort_by(@base.compare)
  let labels : Map[String, String] = Map([])
  for id in ids { labels[id] = id }
  for edge in graph.edges {
    if edge.weight.is_nan() || edge.weight.is_inf() || edge.weight <= 0.0 {
      @base.fail("graph_edge_weight_invalid")
    }
  }
  let rounds = Int::max(1, ids.length())
  let mut round = 0
  while round < rounds {
    let mut changed = false
    for id in ids {
      let scores : Map[String, Double] = Map([])
      for edge in graph.edges {
        let other = if edge.source == id { edge.target }
          else if edge.target == id { edge.source }
          else { continue }
        let label = labels.get(other).unwrap_or(other)
        scores[label] = scores.get(label).unwrap_or(0.0) + edge.weight
      }
      if scores.is_empty() { continue }
      let current = labels[id]
      let mut best_label = current
      let mut best_score = scores.get(current).unwrap_or(0.0)
      let candidates = scores.keys().to_array()
      candidates.sort_by(@base.compare)
      for label in candidates {
        let score = scores[label]
        if score > best_score || (score == best_score && @base.compare(label, best_label) < 0) {
          best_label = label
          best_score = score
        }
      }
      if best_label != current {
        labels[id] = best_label
        changed = true
      }
    }
    if !changed {
      round = rounds
    } else {
      round = round + 1
    }
  }
  let groups : Map[String, Array[String]] = Map([])
  for id in ids {
    let label = labels[id]
    let members = groups.get_or_init(label, () => [])
    members.push(id)
  }
  let keys = groups.keys().to_array()
  keys.sort_by(@base.compare)
  keys.map(label => {
    let members = groups[label]
    members.sort_by(@base.compare)
    let mut weight = 0.0
    for edge in graph.edges {
      if members.contains(edge.source) && members.contains(edge.target) {
        weight = weight + edge.weight
      }
    }
    { "id": label, "members": members.to_json(), "weight": weight }
  })
}

pub fn insights(graph : Graph) -> Json raise @base.Fault {
  let orphans : Array[String] = []
  let bridges : Array[Json] = []
  let groups : Map[String, Array[String]] = Map([])
  for n in graph.nodes {
    let adjacent = neighbors(graph, n.id)
    if adjacent.length() <= 1 { orphans.push(n.id) }
    let cross = graph.nodes.filter(other => adjacent.contains(other.id) && other.kind != n.kind).length()
    if cross > 0 { bridges.push({ "id": n.id, "cross_type_neighbors": cross }) }
    for tag in n.tags { let ids = groups.get_or_init(tag, () => []); if !ids.contains(n.id) { ids.push(n.id) } }
  }
  let sparse : Array[Json] = []
  let tags = groups.keys().to_array()
  tags.sort_by(@base.compare)
  for tag in tags {
    let ids = groups[tag]
    if ids.length() < 2 { continue }
    let count = graph.edges.filter(e => e.kind == "wikilink" && ids.contains(e.source) && ids.contains(e.target)).length()
    let density = count.to_double() / (ids.length() * (ids.length()-1)).to_double()
    if density < 0.25 { sparse.push({ "tag": tag, "density": density, "pages": ids.to_json() }) }
  }
  let ids = graph.nodes.map(n => n.id)
  ids.sort_by(@base.compare)
  let assigned : Map[String, Bool] = Map([])
  let components : Array[Json] = []
  for seed in ids {
    if assigned.contains(seed) { continue }
    let queue = [seed]
    assigned[seed] = true
    let members : Array[String] = []
    let mut cursor = 0
    while cursor < queue.length() {
      let current = queue[cursor]
      cursor = cursor + 1
      members.push(current)
      for neighbor in neighbors(graph, current) {
        if !assigned.contains(neighbor) {
          assigned[neighbor] = true
          queue.push(neighbor)
        }
      }
    }
    members.sort_by(@base.compare)
    components.push(members.to_json())
  }
  let degree : Array[Json] = []
  for id in ids {
    let mut weighted = 0.0
    for edge in graph.edges {
      if edge.source == id || edge.target == id {
        if edge.weight.is_nan() || edge.weight.is_inf() || edge.weight <= 0.0 {
          @base.fail("graph_edge_weight_invalid")
        }
        weighted = weighted + edge.weight
      }
    }
    degree.push({ "id": id, "degree": neighbors(graph, id).length(), "weighted_degree": weighted })
  }
  let edge_kinds : Map[String, Int] = Map([])
  for edge in graph.edges { edge_kinds[edge.kind] = edge_kinds.get(edge.kind).unwrap_or(0) + 1 }
  let kind_rows : Array[Json] = []
  let kinds = edge_kinds.keys().to_array()
  kinds.sort_by(@base.compare)
  for kind in kinds { kind_rows.push({ "kind": kind, "count": edge_kinds[kind] }) }
  { "orphans": orphans.to_json(), "bridges": bridges.to_json(), "sparse_tags": sparse.to_json(),
    "components": components.to_json(), "communities": communities(graph).to_json(),
    "degree": degree.to_json(), "edge_kinds": kind_rows.to_json() }
}
