// Workspace wiki projection (read-only). The global catalog is the only
// knowledge authority; this operation selects a deterministic subset for one
// workspace and hands the host everything needed to write the derived OKF copy
// under `workspaces/<id>/wiki`. It never writes, never adds catalog entries,
// and never lets a generated page become a source for the global base.
//
// Selection is deliberately source-based: a page belongs to a workspace when
// it cites a raw source under the workspace's namespace, shares a source with
// such a page, or is named explicitly. No page gets a persistent workspace
// field, so the global index stays one general-purpose knowledge base.

fn workspace_wiki_namespace(value : String) -> Unit raise @base.Fault {
  if value.is_empty() || value.length() > 128 || value.contains("\n") ||
    value.contains("\r") || value.has_prefix("/") || value.has_suffix("/") ||
    value.contains("..") {
    @base.fail("workspace_namespace_invalid")
  }
  @base.path("raw/" + value + "/placeholder")
}

fn workspace_wiki_page_row(entry : @core.Entry, explicit : Bool, shared : Bool,
  source_hashes : Map[String, String]) -> Json {
  let hashes : Array[Json] = []
  for source in entry.sources {
    hashes.push({
      "source": source,
      "hash": match source_hashes.get(source) {
        None => Json::null()
        Some(value) => value.to_json()
      },
    })
  }
  { "id": entry.id, "path": entry.path, "kind": entry.kind, "sha256": entry.sha256,
    "sources": entry.sources.to_json(), "source_hashes": hashes.to_json(),
    "stale": entry.stale, "explicit": explicit, "shared": shared }
}

pub fn workspace_wiki_plan(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "workspace", "namespace", "pages", "limit"])
  let workspace = @base.text(@base.field(request, "workspace"))
  memory_workspace(workspace)
  let record_path = "state/workspaces/" + workspace + ".json"
  let record = @base.parse(@vault.required(store, record_path))
  let path = @base.text(@base.field(record, "path"))
  let namespace_name = match optional(request, "namespace") {
    None | Some(Null) => None
    Some(value) => {
      let text = @base.text(value)
      workspace_wiki_namespace(text)
      Some(text)
    }
  }
  let explicit = match optional(request, "pages") {
    None | Some(Null) => []
    Some(value) => @base.strings(value)
  }
  let limit = integer(request, "limit", 100, 1, 500)
  let selected : Map[String, Bool] = Map([])
  let explicit_set : Map[String, Bool] = Map([])
  for id in explicit {
    let entry = @core.find(entries, id)
    if !@core.is_page(entry) { @base.fail("workspace_wiki_page_invalid: " + id) }
    selected[id] = true
    explicit_set[id] = true
  }
  let prefix = match namespace_name {
    None => ""
    Some(value) => "raw/" + value + "/"
  }
  for entry in entries {
    if !@core.is_page(entry) { continue }
    if prefix != "" && entry.sources.any(source => source.has_prefix(prefix)) {
      selected[entry.id] = true
    }
  }
  let selected_sources : Map[String, Bool] = Map([])
  for id in selected.keys() {
    let entry = @core.find(entries, id)
    for source in entry.sources { selected_sources[source] = true }
  }
  // One hop only: a page that merely shares raw evidence with a selected page
  // is included as `shared`. It does not pull in the next ring, so a large
  // global base cannot leak into a workspace by transitive closure.
  for entry in entries {
    if !@core.is_page(entry) || selected.contains(entry.id) { continue }
    if entry.sources.any(source => selected_sources.contains(source)) {
      selected[entry.id] = true
    }
  }
  let source_hashes : Map[String, String] = Map([])
  for entry in entries {
    if entry.kind == "raw" { source_hashes[entry.id] = entry.sha256 }
  }
  let keyed : Array[(String, Json)] = []
  for id in selected.keys() {
    let entry = @core.find(entries, id)
    keyed.push((id, workspace_wiki_page_row(entry, explicit_set.contains(id),
      !explicit_set.contains(id) && !(prefix != "" &&
        entry.sources.any(source => source.has_prefix(prefix))), source_hashes)))
  }
  keyed.sort_by((a, b) => @base.compare(a.0, b.0))
  let rows = keyed.map(pair => pair.1)
  let listed = rows[:Int::min(limit, rows.length())]
  let claims : Array[Json] = []
  for row in listed {
    claims.push({
      "page": @base.field(row, "id"),
      "page_hash": @base.field(row, "sha256"),
      "sources": @base.field(row, "sources"),
      "source_hashes": @base.field(row, "source_hashes"),
      "generated": true,
    })
  }
  let mut index = "# 工作区索引\n\n" +
    "> 本文件由 workspace-wiki-plan 与宿主脚本派生，仅索引 `workspaces/` 分层；" +
    "不进入全局知识目录，不替代根目录 `index.mbt.md`。\n\n" +
    "## 工作区\n\n- id: `" + workspace + "`\n- path: `" + path + "`\n"
  if namespace_name is Some(value) {
    index = index + "- namespace: `raw/" + value + "/`\n"
  }
  index = index + "\n## 页面\n\n"
  for row in listed {
    index = index + "- `" + @base.text(@base.field(row, "path")) + "`" +
      (if @base.boolean(@base.field(row, "shared")) { "（共享）" } else { "" }) + "\n"
  }
  let mut shared = 0
  for row in listed {
    if @base.boolean(@base.field(row, "shared")) { shared = shared + 1 }
  }
  let manifest : Json = {
    "version": 1,
    "workspace": workspace,
    "path": path,
    "namespace": match namespace_name {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "fingerprint": @vault.fingerprint(entries),
    "selection": { "explicit": explicit.to_json(), "namespace": match namespace_name {
      None => Json::null()
      Some(value) => value.to_json()
    } },
    "pages": listed.length(),
    "shared": shared,
    "generated": true,
  }
  {
    "workspace": workspace,
    "path": path,
    "namespace": match namespace_name {
      None => Json::null()
      Some(value) => value.to_json()
    },
    "pages": listed.to_json(),
    "claims": claims.to_json(),
    "manifest": manifest,
    "index_text": index,
    "fingerprint": @vault.fingerprint(entries),
  }
}
