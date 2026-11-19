// Sidecar storage machinery for evolution state (续六十二, slice 1).
//
// The evo subsystem will move its records out of the vault catalog so that
// enabling evolution never changes the vault fingerprint, verify, read-log or
// pack. Everything evo owns then lives under a sidecar root with its own
// integrity: a mini-catalog (evo/index.json binding every record's sha256)
// and a two-phase journal (evo/transactions/pending.json) that recovers
// forward to exactly one consistent state, the same guarantee @vault.commit
// gives state/ records today. The trade is explicit and documented: packs no
// longer carry evo state.
//
// This file is deliberately additive: nothing routes through it yet. Slices
// that follow will move the evo ops' writes onto it.

const EVO_SIDECAR_ROOT : String = "evo/"
const EVO_SIDECAR_INDEX : String = "evo/index.json"
const EVO_SIDECAR_JOURNAL : String = "evo/transactions/pending.json"

fn evo_sidecar_validate_path(path : String) -> Unit raise @base.Fault {
  if !path.has_prefix(EVO_SIDECAR_ROOT) {
    @base.fail("evo_sidecar_path_invalid: " + path)
  }
  let segments = path.split("/")
  for segment in segments {
    if segment == ".." || segment == "." {
      @base.fail("evo_sidecar_path_invalid: " + path)
    }
  }
  if path == EVO_SIDECAR_INDEX || path == EVO_SIDECAR_JOURNAL {
    @base.fail("evo_sidecar_path_reserved: " + path)
  }
}

fn evo_sidecar_index_json(files : Map[String, String]) -> Json {
  let entries : Map[String, Json] = Map([])
  for path in files.keys() {
    match files.get(path) {
      Some(digest) => entries[path] = digest.to_json()
      None => ()
    }
  }
  { "version": (1 : Int).to_json(), "files": Json::object(entries) }
}

fn evo_sidecar_parse_index(text : String) -> Map[String, String] raise @base.Fault {
  let value = @base.parse(text)
  @base.keys(value, ["version", "files"])
  match @base.field(value, "version") {
    Number(n, ..) => if n != 1.0 { @base.fail("evo_sidecar_index_invalid:version") }
    _ => @base.fail("evo_sidecar_index_invalid:version")
  }
  let files : Map[String, String] = Map([])
  match @base.field(value, "files") {
    Object(fields) => for (path, digest) in fields {
      ignore(@base.path(path))
      evo_sidecar_validate_path(path)
      let text = @base.text(digest)
      if text.length() != 64 { @base.fail("evo_sidecar_index_invalid:digest") }
      files[path] = text
    }
    _ => @base.fail("evo_sidecar_index_invalid:files")
  }
  files
}

/// Read the sidecar index after making sure no interrupted transaction is
/// pending, then verify every indexed record against its digest. A hand-edited
/// or deleted record fails closed with the offending path.
pub fn evo_sidecar_load(store : @vault.Storage) -> Map[String, String] raise @base.Fault {
  ignore(evo_sidecar_recover(store))
  let files = match (store.read)(EVO_SIDECAR_INDEX) {
    None => {
      let empty : Map[String, String] = Map([])
      empty
    }
    Some(text) => evo_sidecar_parse_index(text)
  }
  for path in files.keys() {
    match (store.digest)(path) {
      Some(digest) => if digest != files[path] {
        @base.fail("evo_sidecar_corrupt: " + path)
      }
      None => @base.fail("evo_sidecar_corrupt: " + path)
    }
  }
  files
}

/// Apply one transaction to the sidecar: journal first, then the files, then
/// the index swap, then the journal removal. `interrupt_after` fails after
/// the Nth write exactly like @vault.commit, so the recovery tests can crash
/// at every publish point.
pub fn evo_sidecar_commit(
  store : @vault.Storage,
  changes : Array[@vault.Change],
  interrupt_after? : Int = -1,
) -> Unit raise @base.Fault {
  if (store.read)(EVO_SIDECAR_JOURNAL) is Some(_) {
    @base.fail("evo_sidecar_recovery_required")
  }
  let seen : Map[String, Bool] = Map([])
  for change in changes {
    evo_sidecar_validate_path(change.path)
    match change.after {
      Some(text) => {
        // Sidecar records satisfy the same closed schemas as vault state
        // records (AGENTS: unknown fields rejected), so the commit
        // synthesizes the catalog entry @core.validate_record expects.
        let entry : @core.Entry = {
          id: change.path, path: change.path, kind: "state", format: "json",
          sha256: @base.hex_hash(text), sources: [], stale: false,
        }
        @core.validate_record(entry, text)
      }
      None => ()
    }
    if seen.contains(change.path) {
      @base.fail("evo_sidecar_duplicate_change: " + change.path)
    }
    seen[change.path] = true
    let matches = match ((store.read)(change.path), change.before) {
      (None, None) => true
      (Some(current), Some(expected)) => current == expected
      _ => false
    }
    if !matches {
      @base.fail("evo_sidecar_write_conflict: " + change.path)
    }
  }
  let old_files = match (store.read)(EVO_SIDECAR_INDEX) {
    None => {
      let empty : Map[String, String] = Map([])
      empty
    }
    Some(text) => evo_sidecar_parse_index(text)
  }
  let next_files = old_files.copy()
  for change in changes {
    match change.after {
      Some(text) => next_files[change.path] = @base.hex_hash(text)
      None => next_files.remove(change.path)
    }
  }
  let old_index = match (store.read)(EVO_SIDECAR_INDEX) {
    None => ""
    Some(text) => text
  }
  let next_index = @base.canonical(evo_sidecar_index_json(next_files))
  let journal = @base.canonical({
    "version": (1 : Int).to_json(),
    "old_index": old_index.to_json(),
    "new_index": next_index.to_json(),
    "changes": changes.to_json(),
  })
  let mut writes = 0
  (store.write)(EVO_SIDECAR_JOURNAL, journal)
  writes = writes + 1
  if interrupt_after == writes { @base.fail("injected_interrupt: journal prepared") }
  for change in changes {
    match change.after {
      Some(text) => (store.write)(change.path, text)
      None => (store.remove)(change.path)
    }
    writes = writes + 1
    if interrupt_after == writes { @base.fail("injected_interrupt: files applied") }
  }
  (store.write)(EVO_SIDECAR_INDEX, next_index)
  writes = writes + 1
  if interrupt_after == writes { @base.fail("injected_interrupt: index swapped") }
  (store.remove)(EVO_SIDECAR_JOURNAL)
  writes = writes + 1
  if interrupt_after == writes { @base.fail("injected_interrupt: journal removed") }
}

/// Roll an interrupted transaction forward to its intended state. Re-applying
/// is safe because every change carries the exact after-bytes and the index
/// is a single-file swap, so recovery always converges to one consistent
/// state no matter where the crash landed.
pub fn evo_sidecar_recover(store : @vault.Storage) -> Bool raise @base.Fault {
  let journal_text = match (store.read)(EVO_SIDECAR_JOURNAL) {
    None => return false
    Some(text) => text
  }
  let journal = @base.parse(journal_text)
  @base.keys(journal, ["version", "old_index", "new_index", "changes"])
  let changes = @base.array(@base.field(journal, "changes"))
  for item in changes {
    let change : @vault.Change = {
      path: @base.text(@base.field(item, "path")),
      before: match @base.field(item, "before") {
        String(text) => Some(text)
        _ => None
      },
      after: match @base.field(item, "after") {
        String(text) => Some(text)
        _ => None
      },
    }
    evo_sidecar_validate_path(change.path)
    match change.after {
      Some(text) => (store.write)(change.path, text)
      None => (store.remove)(change.path)
    }
  }
  (store.write)(EVO_SIDECAR_INDEX,
    @base.text(@base.field(journal, "new_index")))
  (store.remove)(EVO_SIDECAR_JOURNAL)
  true
}

/// Digest-verified (path, text) pairs for every indexed record under a
/// sidecar prefix, sorted by path for deterministic iteration.
pub fn evo_sidecar_records(
  store : @vault.Storage, prefix : String,
) -> Array[(String, String)] raise @base.Fault {
  let files = evo_sidecar_load(store)
  // Host `files` implementations take a DIRECTORY (they join the child name
  // themselves), so list the prefix's own directory and filter by the full
  // prefix afterwards — a count prefix like "evo/events/evo-regression-" is
  // not a directory.
  let normalized = if prefix.has_suffix("/") {
    let chars = prefix.to_array()
    let kept : Array[Char] = []
    for i = 0; i < chars.length() - 1; i = i + 1 { kept.push(chars[i]) }
    String::from_array(kept)
  } else {
    prefix
  }
  let chars = normalized.to_array()
  let mut last = -1
  for i = 0; i < chars.length(); i = i + 1 {
    if chars[i] == '/' { last = i }
  }
  let kept_dir : Array[Char] = []
  for i = 0; i < last; i = i + 1 { kept_dir.push(chars[i]) }
  let directory = String::from_array(kept_dir)
  // The prefix is a plain path prefix: it may name a record directory
  // ("evo/fossils") or a filename family ("evo/events/evo-rollback-<hash>").
  let marker = normalized
  let rows : Array[(String, String)] = []
  for path in (store.files)(directory) {
    if path.has_prefix(marker) && files.contains(path) {
      match (store.read)(path) {
        Some(text) => rows.push((path, text))
        None => @base.fail("evo_sidecar_corrupt: " + path)
      }
    }
  }
  rows.sort_by((a, b) => @base.compare(a.0, b.0))
  rows
}

/// One-time forward migration: vault records from the pre-sidecar layout
/// (state/evo/... and state/events/evo-...) move into the sidecar and leave
/// the vault catalog, so an enabled vault stops polluting the fingerprint.
/// Interrupted runs converge: the sidecar overwrite is byte-identical and the
/// vault removal simply retries. Returns the entries the caller must use from
/// now on (legacy entries dropped once the removal has landed).
pub fn evo_migrate_legacy(
  store : @vault.Storage, entries : Array[@core.Entry],
) -> Array[@core.Entry] raise @base.Fault {
  let legacy = entries.filter(e =>
    e.path.has_prefix("state/evo/") || e.path.has_prefix("state/events/evo-"))
  if legacy.is_empty() { return entries }
  let sidecar_changes : Array[@vault.Change] = []
  let vault_changes : Array[@vault.Change] = []
  for entry in legacy {
    let text = @vault.required(store, entry.path)
    if @base.hex_hash(text) != entry.sha256 {
      @base.fail("content_changed: " + entry.path +
        "; rescan sources or submit explicit page edit")
    }
    let tail = if entry.path.has_prefix("state/events/") {
      evo_after_prefix(entry.path, "state/events/")
    } else {
      evo_after_prefix(entry.path, "state/evo/")
    }
    let target = if entry.path.has_prefix("state/events/") {
      "evo/events/" + tail
    } else {
      "evo/" + tail
    }
    sidecar_changes.push({ path: target, before: (store.read)(target), after: Some(text) })
    vault_changes.push({ path: entry.path, before: Some(text), after: None })
  }
  evo_sidecar_commit(store, sidecar_changes)
  let kept = entries.filter(e =>
    !(e.path.has_prefix("state/evo/") || e.path.has_prefix("state/events/evo-")))
  @vault.commit(store, @vault.fingerprint(entries), kept, vault_changes)
  kept
}

fn evo_after_prefix(path : String, prefix : String) -> String {
  let chars = path.to_array()
  let head = prefix.length()
  let tail : Array[Char] = []
  for i = head; i < chars.length(); i = i + 1 { tail.push(chars[i]) }
  String::from_array(tail)
}
