fn text_bytes(bytes : Bytes) -> String raise @base.Fault {
  try @utf8.decode(bytes) catch { _ => raise @base.Fault("pack_text_utf8_required") }
}

fn validate_recovery_history(text : String) -> Unit raise @base.Fault {
  let value = @base.parse(text)
  @base.keys(value, ["version", "direction", "journal"])
  if @base.field(value, "version") != Json::number(1.0) { @base.fail("recovery_history_version_unsupported") }
  let direction = @base.text(@base.field(value, "direction"))
  if !["forward", "rollback"].contains(direction) { @base.fail("recovery_history_direction_invalid") }
  let journal = @base.field(value, "journal")
  @base.keys(journal, ["version", "changes", "old_index", "new_index"])
  if @base.field(journal, "version") != Json::number(1.0) { @base.fail("journal_version_unsupported") }
  let old_index = @base.text(@base.field(journal, "old_index"))
  let new_index = @base.text(@base.field(journal, "new_index"))
  ignore(@decl.parse(old_index))
  ignore(@decl.parse(new_index))
  for change in @base.array(@base.field(journal, "changes")) {
    @base.keys(change, ["path", "before", "after"])
    let path = @base.text(@base.field(change, "path"))
    @base.path(path)
    if !(path == "purpose.md" || path.has_prefix("wiki/") || path.has_prefix("state/orders/") ||
      path.has_prefix("state/events/") || path.has_prefix("state/reviews/") || path.has_prefix("state/research/") ||
      path.has_prefix("state/suggestions/") || path.has_prefix("state/overview/") || path.has_prefix("state/evidence/") ||
      path.has_prefix("state/providers/") || path.has_prefix("state/provider-jobs/") || path.has_prefix("vectors/")) {
      @base.fail("recovery_history_path_refused: " + path)
    }
    for key in ["before", "after"] {
      match @base.field(change, key) {
        Null => ()
        String(_) => ()
        _ => @base.fail("recovery_history_value_invalid: " + key)
      }
    }
  }
}

pub fn snapshot_entries(store : Storage, files : Array[@pack.File], compile? : Bool = false) -> Array[@core.Entry] raise @base.Fault {
  let data : Map[String, Bytes] = Map([])
  for file in files {
    if data.contains(file.path) { @base.fail("pack_duplicate_path") }
    data[file.path] = file.data
  }
  let index = match data.get("index.mbt.md") { None => raise @base.Fault("pack_index_required"); Some(bytes) => text_bytes(bytes) }
  match data.get("purpose.md") { None => @base.fail("pack_purpose_required"); Some(bytes) => ignore(text_bytes(bytes)) }
  let entries = @decl.parse(index)
  for file in files {
    let path = file.path
    let registered = entries.any(e => e.path == path)
    let extra = ["index.mbt.md", "purpose.md", "schema.md", "wiki/index.md", "wiki/log.md"].contains(path) ||
      (path.has_prefix("views/") && path.has_suffix(".mbt.md")) || path.has_prefix("staging/") ||
      path.has_prefix("state/transactions/history/")
    if (!registered && !extra) ||
      (path.has_prefix("state/transactions/") && !path.has_prefix("state/transactions/history/")) ||
      (path.has_prefix("state/") && !path.has_prefix("state/transactions/history/") &&
        !@core.state_directories().any(p => path.has_prefix(p + "/"))) {
      @base.fail("pack_path_refused: " + path)
    }
    if path.has_prefix("state/transactions/history/") {
      if !path.has_suffix(".json") { @base.fail("pack_path_refused: " + path) }
      validate_recovery_history(text_bytes(file.data))
    }
    if path.has_prefix("views/") {
      ignore(@visual.parse(text_bytes(file.data)))
      if compile {
        (store.write)(".corridor/unpack-view.mbt.md", text_bytes(file.data))
        (store.check)(".corridor/unpack-view.mbt.md")
      }
    }
  }
  let proposed : Storage = { ..store,
    read: path => match data.get(path) { None => None; Some(bytes) => Some(text_bytes(bytes)) },
    read_bytes: path => data.get(path),
    digest: path => data.get(path).map(@base.sha256_hex),
  }
  verify(proposed, entries)
  if compile {
    (store.write)(".corridor/unpack-candidate.mbt.md", index)
    (store.check)(".corridor/unpack-candidate.mbt.md")
  }
  entries
}

fn preflight_restore(store : Storage, files : Array[@pack.File], resuming : Bool) -> Unit raise @base.Fault {
  let expected : Map[String, String] = Map([])
  for file in files { expected[file.path] = @base.sha256_hex(file.data) }
  if !resuming && (store.read_bytes)("index.mbt.md") is Some(_) { @base.fail("unpack_requires_empty_vault") }
  for file in files {
    match (store.digest)(file.path) {
      None => ()
      Some(actual) => if !resuming || actual != expected[file.path] { @base.fail("unpack_conflict: " + file.path) }
    }
  }
  for dir in ["raw", "wiki", "state", "views", "vectors", "staging"] {
    for path in (store.files)(dir) {
      if resuming && ["state/transactions/unpack.json", "state/transactions/unpack.mcpack"].contains(path) { continue }
      if !expected.contains(path) { @base.fail("unpack_unrelated_file: " + path) }
    }
  }
  for path in ["purpose.md", "schema.md"] {
    if !expected.contains(path) && (store.read_bytes)(path) is Some(_) { @base.fail("unpack_unrelated_file: " + path) }
  }
}

fn finish_restore(store : Storage, files : Array[@pack.File], interrupt_after : Int) -> Unit raise @base.Fault {
  let mut index = ""
  let mut applied = 0
  for file in files {
    if file.path == "index.mbt.md" { index = text_bytes(file.data); continue }
    (store.write_bytes)(file.path, file.data)
    applied = applied+1
    if interrupt_after == applied { @base.fail("injected_unpack_interrupt: files applied") }
  }
  (store.write)("index.mbt.md", index)
  if interrupt_after == files.length() { @base.fail("injected_unpack_interrupt: index published") }
  (store.write)(".corridor/last-valid.mbt.md", index)
  (store.remove)("state/transactions/unpack.json")
  (store.remove)("state/transactions/unpack.mcpack")
}

pub fn recover_unpack(store : Storage) -> Bool raise @base.Fault {
  let marker = match (store.read)("state/transactions/unpack.json") {
    None => {
      // A crash can leave only the payload, either before prepare or after the
      // published journal was removed. No user destination is touched here.
      if (store.read_bytes)("state/transactions/unpack.mcpack") is Some(_) { (store.remove)("state/transactions/unpack.mcpack") }
      return false
    }
    Some(text) => @base.parse(text)
  }
  @base.keys(marker, ["version", "sha256"])
  if @base.field(marker, "version") != Json::number(1.0) { @base.fail("unpack_journal_version_unsupported") }
  let bytes = match (store.read_bytes)("state/transactions/unpack.mcpack") { None => raise @base.Fault("unpack_payload_missing"); Some(bytes) => bytes }
  if @base.field(marker, "sha256") != @base.sha256_hex(bytes).to_json() { @base.fail("unpack_payload_changed") }
  let files = @pack.decode(bytes)
  ignore(snapshot_entries(store, files, compile=true))
  preflight_restore(store, files, true)
  finish_restore(store, files, -1)
  true
}

pub fn unpack(store : Storage, bytes : Bytes, interrupt_after? : Int = -1) -> String raise @base.Fault {
  if (store.read)("state/transactions/unpack.json") is Some(_) { @base.fail("unpack_recovery_required") }
  let files = @pack.decode(bytes)
  let entries = snapshot_entries(store, files, compile=true)
  preflight_restore(store, files, false)
  (store.write_bytes)("state/transactions/unpack.mcpack", bytes)
  let marker : Json = { "version": 1, "sha256": @base.sha256_hex(bytes) }
  (store.write)("state/transactions/unpack.json", @base.canonical(marker))
  if interrupt_after == 0 { @base.fail("injected_unpack_interrupt: prepared") }
  finish_restore(store, files, interrupt_after)
  fingerprint(entries)
}
