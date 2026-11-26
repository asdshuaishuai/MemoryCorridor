// Assistant export (memory isolation, phase 2).
//
// The engine is the only writer that knows which notes are current, so it also
// publishes a read-only view for global assistants (Siri, OpenClaw-style
// agents). This is derived data: every file is rebuilt from the authoritative
// `state/workspaces/` and `state/memory/` records, never read back by the
// engine, and never part of the catalog fingerprint. Deleting `index/` loses
// nothing; running `memory-export` again restores it.
//
// Only active project-scope notes are exported. Session notes are intentionally
// counted but not written: their content belongs to one conversation and would
// otherwise become visible to every assistant reading the vault.

fn memory_export_workspace_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let listed = workspace_list(store, entries)
  @base.array(@base.field(listed, "workspaces"))
}

fn memory_export_projects_text(rows : Array[Json]) -> String raise @base.Fault {
  let projects : Array[Json] = []
  for row in rows {
    projects.push({
      "id": @base.field(row, "id"),
      "path": @base.field(row, "path"),
      "created_at": @base.field(row, "created_at"),
      "last_opened_at": @base.field(row, "last_opened_at"),
    })
  }
  @base.canonical({ "version": Json::number(1.0), "workspaces": projects.to_json() })
}

fn memory_export_markdown(note : MemoryNote, entries : Array[@core.Entry]) -> String {
  let invalid = invalid_memory_sources(note, entries)
  let drifted = drifted_memory_sources(note, entries)
  // JSON scalars are valid YAML 1.2, so quoting stays deterministic without a
  // YAML writer. Conditions cannot contain newlines (enforced at submit).
  let line = (key : String, value : Json) => key + ": " + @base.canonical(value) + "\n"
  "---\n" +
  line("id", note.id.to_json()) +
  line("workspace", note.workspace.to_json()) +
  line("kind", note.kind.to_json()) +
  line("scope", note.scope.to_json()) +
  line("status", note.status.to_json()) +
  line("conditions", note.conditions.to_json()) +
  line("sources", note.sources.to_json()) +
  line("source_hashes", note.source_hashes.to_json()) +
  line("pinned", note.pinned.to_json()) +
  line("importance", match note.importance {
    None => Json::null()
    Some(value) => value.to_json()
  }) +
  line("emotion", memory_emotion_json(note.emotion)) +
  line("episodic", note.episodic.to_json()) +
  line("promoted_at", match note.promoted_at {
    None => Json::null()
    Some(value) => value.to_json()
  }) +
  line("use_count", note.use_count.to_json()) +
  line("created_at", note.created_at.to_json()) +
  line("updated_at", note.updated_at.to_json()) +
  line("valid", (invalid.is_empty() && drifted.is_empty()).to_json()) +
  line("invalid_sources", invalid.to_json()) +
  line("drifted_sources", drifted.to_json()) +
  line("note_hash", note.note_hash.to_json()) +
  "---\n" + note.text + "\n"
}

pub fn memory_export(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let target = match optional(request, "workspace") {
    None => None
    Some(value) => {
      let workspace = @base.text(value)
      memory_workspace(workspace)
      if (store.read)("state/workspaces/" + workspace + ".json") is None {
        @base.fail("memory_workspace_unknown: " + workspace + "; run workspace-open first")
      }
      Some(workspace)
    }
  }
  let workspaces = memory_export_workspace_rows(store, entries)
  // Plan every file before writing anything: a failed export must be
  // retryable, and unchanged runs must not touch mtimes.
  let expected : Map[String, String] = Map([])
  let owners : Map[String, String] = Map([])
  let mut session_notes = 0
  let mut notes = 0
  for row in workspaces {
    let workspace = @base.text(@base.field(row, "id"))
    if target is Some(only) && only != workspace { continue }
    for entry in memory_entries(entries, workspace) {
      let note = memory_from_json(@base.parse(@vault.required(store, entry.path)))
      if note.scope == "session" { session_notes += 1 }
      if note.status != "active" || note.scope != "project" { continue }
      let path = ".corridor/memory/" + workspace + "/" + note.id + ".md"
      expected[path] = memory_export_markdown(note, entries)
      owners[path] = workspace
      notes += 1
    }
  }
  // `.corridor/memory/projects.json` always lists every registered workspace, even when a
  // single workspace was requested: it is the assistant's map of the vault.
  let projects_path = ".corridor/memory/projects.json"
  let projects_text = memory_export_projects_text(workspaces)
  (store.mkdirs)(".corridor/memory")
  let mut written = 0
  let mut unchanged = 0
  match (store.read)(projects_path) {
    Some(old) => if old == projects_text { unchanged += 1 } else {
      (store.write)(projects_path, projects_text); written += 1
    }
    None => { (store.write)(projects_path, projects_text); written += 1 }
  }
  for path in expected.keys() {
    let content = expected[path]
    match (store.read)(path) {
      Some(old) => if old == content { unchanged += 1 } else {
        (store.write)(path, content); written += 1
      }
      None => {
        (store.mkdirs)(".corridor/memory/" + owners[path])
        (store.write)(path, content)
        written += 1
      }
    }
  }
  // Remove exports that no longer correspond to an active project note. A
  // workspace-scoped export only reconciles its own directory so one workspace
  // cannot erase another's view.
  let mut removed = 0
  let directories : Array[String] = match target {
    None => [".corridor/memory"]
    Some(workspace) => [".corridor/memory/" + workspace]
  }
  for directory in directories {
    let existing = try { (store.files)(directory) } catch { _ => [] }
    for path in existing {
      if expected.contains(path) || path == ".corridor/memory/projects.json" { continue }
      match target {
        None => ()
        Some(workspace) => if !path.has_prefix(".corridor/memory/" + workspace + "/") { continue }
      }
      (store.remove)(path)
      removed += 1
    }
  }
  {
    "directory": ".corridor/memory".to_json(),
    "projects": projects_path.to_json(),
    "workspaces": workspaces.length().to_json(),
    "notes": notes.to_json(),
    "session_notes": session_notes.to_json(),
    "written": written.to_json(),
    "unchanged": unchanged.to_json(),
    "removed": removed.to_json(),
    "fingerprint": @vault.fingerprint(entries).to_json(),
  }
}
