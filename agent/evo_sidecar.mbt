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
