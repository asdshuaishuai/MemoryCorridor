fn memory() -> (Storage, Map[String, String]) {
  let files : Map[String, String] = Map([])
  files["index.mbt.md"] = @decl.generate([])
  let store : Storage = {
    read: path => files.get(path),
    read_bytes: path => files.get(path).map(text => @utf8.encode(text)),
    mkdirs: _ => (),
    digest: path => files.get(path).map(@base.hex_hash),
    write: (path, text) => { files[path] = text },
    write_bytes: (path, bytes) => { files[path] = try @utf8.decode(bytes) catch { _ => raise @base.Fault("invalid_utf8_fixture") } },
    remove: path => { files.remove(path) },
    files: prefix => files.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: path => { ignore(@decl.parse(files[path])) },
  }
  (store, files)
}

test "every transaction interruption recovers to old or committed version" {
  for interruption in [0, 1, 2, 3] {
    let (store, files) = memory()
    let text = "{\"before\":\"" + "0".repeat(64) + "\",\"changes\":[],\"op\":\"refresh\"}"
    let e : @core.Entry = { id: "state/events/test.json", path: "state/events/test.json", kind: "state", format: "json", sha256: @base.hex_hash(text), sources: [], stale: false }
    let changes : Array[Change] = [
      { path: e.path, before: None, after: Some(text) },
      { path: "wiki/index.md", before: None, after: Some("# 目录\n") },
    ]
    let failed = try { commit(store, fingerprint([]), [e], changes, interrupt_after=interruption); false } catch { _ => true }
    assert_true(failed)
    assert_true(recover(store))
    assert_false(recover(store))
    assert_false(files.contains("state/transactions/pending.json"))
    let histories = files.keys().filter(p => p.has_prefix("state/transactions/history/")).to_array()
    assert_eq(histories.length(), 1)
    let history = files[histories[0]]
    if interruption < 3 {
      assert_true(history.contains("\"direction\":\"rollback\""))
    } else {
      assert_true(history.contains("\"direction\":\"forward\""))
    }
    let entries = load(store)
    if interruption < 3 {
      assert_eq(entries.length(), 0)
      assert_false(files.contains(e.path))
      assert_false(files.contains("wiki/index.md"))
    } else {
      assert_eq(entries.length(), 1)
      assert_eq(required(store, e.path), text)
      verify(store, entries)
    }
  }
}

test "external edits during recovery preserved and journal retained" {
  let (store, files) = memory()
  let change : Change = { path: "wiki/index.md", before: None, after: Some("planned") }
  ignore(try { commit(store, fingerprint([]), [], [change], interrupt_after=1); false } catch { _ => true })
  files[change.path] = "human edit"
  assert_true(try { ignore(recover(store)); false } catch { _ => true })
  assert_eq(files[change.path], "human edit")
  assert_true(files.contains("state/transactions/pending.json"))
}

test "recovery history content conflict retains the journal" {
  let (store, files) = memory()
  let change : Change = { path: "wiki/index.md", before: None, after: Some("planned") }
  ignore(try { commit(store, fingerprint([]), [], [change], interrupt_after=0); false } catch { _ => true })
  let journal = @base.parse(files["state/transactions/pending.json"])
  let expected : Json = { "version": 1, "direction": "forward", "journal": journal }
  let history_path = "state/transactions/history/" + @base.hex_hash(@base.canonical(expected)) + ".json"
  files[history_path] = "{}"
  assert_true(files.contains(history_path))
  assert_true(try { ignore(recover(store)); false } catch { _ => true })
  assert_true(files.contains("state/transactions/pending.json"))
  assert_eq(files[history_path], "{}")
}

test "content corruption detected but clean and empty vault pass" {
  let (store, files) = memory()
  verify(store, [])
  let e : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("clean"), sources: [], stale: false }
  files[e.path] = "clean"
  verify(store, [e])
  files[e.path] = "damaged"
  assert_true(try { verify(store, [e]); false } catch { _ => true })
}

test "source changed by concurrent editor during compilation aborts before journal" {
  let (store, files) = memory()
  let source : @core.Entry = { id: "raw/a.md", path: "raw/a.md", kind: "raw", format: "markdown", sha256: @base.hex_hash("clean"), sources: [], stale: false }
  files[source.path] = "clean"
  files["index.mbt.md"] = @decl.generate([source])
  let racing = { ..store, check: _ => { files[source.path] = "edited during compilation" } }
  assert_true(try { commit(racing, fingerprint([source]), [source], []); false } catch { _ => true })
  assert_false(files.contains("state/transactions/pending.json"))
  assert_eq(files["index.mbt.md"], @decl.generate([source]))
}

test "compiler rejection never publishes or prepares a transaction" {
  let (store, files) = memory()
  let refused = { ..store, check: _ => raise @base.Fault("compiler rejected candidate") }
  let change : Change = { path: "wiki/index.md", before: None, after: Some("new directory") }
  assert_true(try { commit(refused, fingerprint([]), [], [change]); false } catch { _ => true })
  assert_eq(files["index.mbt.md"], @decl.generate([]))
  assert_false(files.contains(change.path))
  assert_false(files.contains("state/transactions/pending.json"))
}
