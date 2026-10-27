fn binary_memory() -> (Storage, Map[String, Bytes]) {
  let data : Map[String, Bytes] = Map([])
  let store : Storage = {
    read: path => match data.get(path) { None => None; Some(bytes) => Some(text_bytes(bytes)) },
    read_bytes: path => data.get(path),
    mkdirs: _ => (),
    digest: path => data.get(path).map(@base.sha256_hex),
    write: (path, text) => { data[path] = @utf8.encode(text) },
    write_bytes: (path, bytes) => { data[path] = bytes },
    remove: path => { data.remove(path) },
    files: prefix => data.keys().filter(p => p.has_prefix(prefix + "/")).to_array(),
    check: path => { ignore(@decl.parse(text_bytes(data[path]))) },
  }
  (store, data)
}

fn sample_bundle() -> Bytes raise @base.Fault {
  let raw = Bytes::from_array([0, 255, 128, 1])
  let purpose = "研究目标\n"
  let entries : Array[@core.Entry] = [
    { id: "raw/binary.pdf", path: "raw/binary.pdf", kind: "raw", format: "binary", sha256: @base.sha256_hex(raw), sources: [], stale: false },
    { id: "purpose.md", path: "purpose.md", kind: "purpose", format: "markdown", sha256: @base.hex_hash(purpose), sources: [], stale: false },
  ]
  @pack.encode([
    { path: "index.mbt.md", data: @utf8.encode(@decl.generate(entries)) },
    { path: "purpose.md", data: @utf8.encode(purpose) },
    { path: "raw/binary.pdf", data: raw },
    { path: "staging/draft.md", data: @utf8.encode("draft") },
  ])
}

test "every unpack publication interruption recovers forward byte-exactly" {
  let bytes = sample_bundle()
  for interruption = 0; interruption <= 4; interruption = interruption+1 {
    let (store, data) = binary_memory()
    assert_true(try { ignore(unpack(store, bytes, interrupt_after=interruption)); false } catch { _ => true })
    assert_true(data.contains("state/transactions/unpack.json"))
    assert_eq(data.contains("index.mbt.md"), interruption == 4)
    assert_true(recover_unpack(store))
    assert_false(recover_unpack(store))
    for file in @pack.decode(bytes) { assert_eq(data[file.path], file.data) }
    verify(store, load(store))
    assert_false(data.contains("state/transactions/unpack.mcpack"))
    assert_true(try { ignore(unpack(store, bytes)); false } catch { _ => true })
  }
}

test "unpack checks all conflicts before touching files and retains recovery" {
  let (store, data) = binary_memory()
  let bytes = sample_bundle()
  ignore(try { unpack(store, bytes, interrupt_after=1) } catch { _ => "" })
  data["purpose.md"] = @utf8.encode("human edit")
  assert_true(try { ignore(recover_unpack(store)); false } catch { _ => true })
  assert_eq(text_bytes(data["purpose.md"]), "human edit")
  assert_false(data.contains("raw/binary.pdf"))
  assert_true(data.contains("state/transactions/unpack.json"))
}

test "orphaned payload cleanup and semantic validation precede prepare" {
  let (store, data) = binary_memory()
  data["state/transactions/unpack.mcpack"] = sample_bundle()
  assert_false(recover_unpack(store))
  assert_false(data.contains("state/transactions/unpack.mcpack"))
  let invalid = @pack.encode([{ path: "index.mbt.md", data: @utf8.encode("invalid MoonBit") }])
  assert_true(try { ignore(unpack(store, invalid)); false } catch { _ => true })
  assert_false(data.contains("state/transactions/unpack.json"))
  let unsupported = @pack.decode(sample_bundle())
  unsupported.push({ path: "outside.txt", data: @utf8.encode("invalid destination") })
  assert_true(try { ignore(unpack(store, @pack.encode(unsupported))); false } catch { _ => true })
  assert_false(data.contains("index.mbt.md"))
}
