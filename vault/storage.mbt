pub(all) struct Storage {
  read : (String) -> String? raise @base.Fault
  read_bytes : (String) -> Bytes? raise @base.Fault
  digest : (String) -> String? raise @base.Fault
  write : (String, String) -> Unit raise @base.Fault
  write_bytes : (String, Bytes) -> Unit raise @base.Fault
  mkdirs : (String) -> Unit raise @base.Fault
  remove : (String) -> Unit raise @base.Fault
  files : (String) -> Array[String] raise @base.Fault
  check : (String) -> Unit raise @base.Fault
}

pub fn required(store : Storage, path : String) -> String raise @base.Fault {
  match (store.read)(path) {
    Some(text) => text
    None => raise @base.Fault("file_missing: " + path)
  }
}

pub fn load(store : Storage) -> Array[@core.Entry] raise @base.Fault {
  @decl.parse(required(store, "index.mbt.md"))
}

pub fn verify(store : Storage, entries : Array[@core.Entry]) -> Unit raise @base.Fault {
  @core.validate_entries(entries)
  for e in entries {
    if e.kind == "raw" && e.stale { continue }
    if e.kind == "raw" {
      if (store.digest)(e.path) != Some(e.sha256) { @base.fail("source_missing_or_changed: " + e.path + "; run scan") }
      continue
    }
    let text = required(store, e.path)
    if @base.hex_hash(text) != e.sha256 {
      @base.fail("content_changed: " + e.path + "; rescan sources or submit explicit page edit")
    }
    if @core.is_page(e) { ignore(@core.validate_page(e, text, entries)) }
    if e.kind == "state" || e.kind == "vector" { @core.validate_record(e, text) }
  }
}

pub fn fingerprint(entries : Array[@core.Entry]) -> String {
  @base.hex_hash(@decl.generate(entries))
}

pub(all) struct Change {
  path : String
  before : String?
  after : String?
}
pub extend Change with ToJson::{to_json}
pub impl ToJson for Change with to_json(self) {
  let before = match self.before { None => Json::null(); Some(text) => text.to_json() }
  let after = match self.after { None => Json::null(); Some(text) => text.to_json() }
  { "path": self.path, "before": before, "after": after }
}

fn decode_change(value : Json) -> Change raise @base.Fault {
  @base.keys(value, ["path", "before", "after"])
  let decode = value => match value {
    Null => None
    _ => Some(@base.text(value))
  }
  { path: @base.text(@base.field(value, "path")),
    before: decode(@base.field(value, "before")),
    after: decode(@base.field(value, "after")) }
}

fn apply(store : Storage, change : Change, forward : Bool) -> Unit raise @base.Fault {
  let value = if forward { change.after } else { change.before }
  match value {
    Some(text) => (store.write)(change.path, text)
    None => (store.remove)(change.path)
  }
}

// Caller holds a vault OS lock. A missing/unknown journal never gets guessed away.
pub fn recover(store : Storage) -> Bool raise @base.Fault {
  let journal = match (store.read)("state/transactions/pending.json") {
    None => return false
    Some(text) => @base.parse(text)
  }
  @base.keys(journal, ["version", "changes", "old_index", "new_index"])
  if @base.field(journal, "version") != Json::number(1.0) {
    @base.fail("journal_version_unsupported")
  }
  let old_index = @base.text(@base.field(journal, "old_index"))
  let new_index = @base.text(@base.field(journal, "new_index"))
  let changes = @base.array(@base.field(journal, "changes")).map(v => decode_change(v))
  let current = required(store, "index.mbt.md")
  if current != old_index && current != new_index {
    @base.fail("recovery_conflict: catalog edited outside transaction; journal retained")
  }
  // Check all affected bytes before touching any file; preserve external edits.
  for change in changes {
    validate_change_path(change.path)
    let actual = (store.read)(change.path)
    if actual != change.before && actual != change.after {
      @base.fail("recovery_conflict: " + change.path + "; journal retained")
    }
  }
  let forward = current == new_index
  let direction = if forward { "forward" } else { "rollback" }
  let history : Json = { "version": 1, "direction": direction, "journal": journal }
  let history_text = @base.canonical(history)
  let history_path = "state/transactions/history/" + @base.hex_hash(history_text) + ".json"
  match (store.read)(history_path) {
    Some(existing) => if existing != history_text { @base.fail("recovery_history_conflict: " + history_path) }
    None => (store.write)(history_path, history_text)
  }
  for change in changes { apply(store, change, forward) }
  (store.write)(".corridor/last-valid.mbt.md", current)
  (store.remove)("state/transactions/pending.json")
  true
}

pub fn validate_change_path(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  if path == "purpose.md" || path.has_prefix("wiki/") || path.has_prefix("vectors/") ||
    path.has_prefix("state/transactions/history/") {
    return
  }
  // Record directories come from one shared list, so adding a durable-work kind
  // cannot leave it writable by the engine but refused by the transaction.
  for directory in @core.state_directories() {
    if path.has_prefix(directory + "/") { return }
  }
  @base.fail("transaction_path_refused: " + path)
}

pub fn commit(
  store : Storage,
  baseline : String,
  entries : Array[@core.Entry],
  changes : Array[Change],
  interrupt_after? : Int = -1,
) -> Unit raise @base.Fault {
  if (store.read)("state/transactions/pending.json") is Some(_) {
    @base.fail("recovery_required")
  }
  let old_index = required(store, "index.mbt.md")
  // The catalog fingerprint is semantic: prose and auxiliary literate blocks
  // are preserved inputs, but they do not change the entry IR baseline.
  let old_catalog = @decl.parse(old_index)
  if fingerprint(old_catalog) != baseline { @base.fail("catalog_conflict") }
  let paths : Map[String, Bool] = Map([])
  for change in changes {
    validate_change_path(change.path)
    if paths.contains(change.path) { @base.fail("duplicate_change: " + change.path) }
    paths[change.path] = true
    if (store.read)(change.path) != change.before { @base.fail("write_conflict: " + change.path) }
  }
  @core.validate_entries(entries)
  let proposed : Storage = {
    ..store,
    read: path => {
      for change in changes { if change.path == path { return change.after } }
      (store.read)(path)
    },
  }
  verify(proposed, entries)
  let next_index = @decl.generate_preserving(old_index, entries)
  (store.write)(".corridor/candidate.mbt.md", next_index)
  (store.check)(".corridor/candidate.mbt.md")
  if required(store, "index.mbt.md") != old_index { @base.fail("catalog_conflict") }
  for change in changes {
    if (store.read)(change.path) != change.before { @base.fail("write_conflict: " + change.path) }
  }
  // A human editor need not hold our lock. Recheck unchanged dependencies after
  // the compiler returns, before recording any publishable transaction.
  verify(proposed, entries)
  let journal : Json = {
    "version": 1, "old_index": old_index, "new_index": next_index,
    "changes": changes.to_json(),
  }
  (store.write)("state/transactions/pending.json", @base.canonical(journal))
  if interrupt_after == 0 { @base.fail("injected_interrupt: journal prepared") }
  for i = 0; i < changes.length(); i = i + 1 {
    apply(store, changes[i], true)
    if interrupt_after == i+1 { @base.fail("injected_interrupt: files applied") }
  }
  (store.write)("index.mbt.md", next_index)
  // `candidate.mbt.md` was checked before the transaction was prepared. The
  // receipt lets the next read reuse that result while still binding it to
  // the exact literate bytes and semantic catalog fingerprint.
  let compile_receipt : Json = {
    "version": 1,
    "source_sha256": @base.hex_hash(next_index),
    "fingerprint": fingerprint(entries),
    "compiled": true,
  }
  (store.write)(".corridor/catalog-compile.json", @base.canonical(compile_receipt))
  if interrupt_after == changes.length()+1 { @base.fail("injected_interrupt: catalog published") }
  (store.write)(".corridor/last-valid.mbt.md", next_index)
  (store.remove)("state/transactions/pending.json")
}
