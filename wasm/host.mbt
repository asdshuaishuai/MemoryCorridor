// The service face reaches the outside world exclusively through these host
// imports. The host (hosts/wasm-host.py) mirrors platform/fs.c semantics:
// per-component symlink refusal, atomic tmp+fsync+rename writes, an exclusive
// flock on <vault>/.corridor-lock, and a real `moon check` subprocess.
// Status protocol shared by the result-buffer imports: >=0 result bytes
// written into the scratch buffer; -(needed+8) retry with that many bytes;
// -3 missing (reads become None); -1 refused (the module raises the same
// fixed message the native platform would).
// Under the native target the whole face compiles as inert stubs (every call
// is refused); the native CLI/MCP path uses nativehost instead. The stubs
// exist so the package checks under `moon check --target native --deny-warn`.

#cfg(target="wasm")
fn h_read(path_ptr : Int, path_len : Int, res_ptr : Int, res_cap : Int) -> Int = "corridor-host" "storage_read"
#cfg(target="native")
fn h_read(_path_ptr : Int, _path_len : Int, _res_ptr : Int, _res_cap : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_write(path_ptr : Int, path_len : Int, data_ptr : Int, data_len : Int) -> Int = "corridor-host" "storage_write"
#cfg(target="native")
fn h_write(_path_ptr : Int, _path_len : Int, _data_ptr : Int, _data_len : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_mkdir(path_ptr : Int, path_len : Int) -> Int = "corridor-host" "storage_mkdir"
#cfg(target="native")
fn h_mkdir(_path_ptr : Int, _path_len : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_remove(path_ptr : Int, path_len : Int) -> Int = "corridor-host" "storage_remove"
#cfg(target="native")
fn h_remove(_path_ptr : Int, _path_len : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_list(path_ptr : Int, path_len : Int, res_ptr : Int, res_cap : Int) -> Int = "corridor-host" "storage_list"
#cfg(target="native")
fn h_list(_path_ptr : Int, _path_len : Int, _res_ptr : Int, _res_cap : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_check(path_ptr : Int, path_len : Int) -> Int = "corridor-host" "storage_check"
#cfg(target="native")
fn h_check(_path_ptr : Int, _path_len : Int) -> Int { -1 }

#cfg(target="wasm")
fn h_lock() -> Int = "corridor-host" "storage_lock"
#cfg(target="native")
fn h_lock() -> Int { -1 }

#cfg(target="wasm")
fn h_unlock() -> Int = "corridor-host" "storage_unlock"
#cfg(target="native")
fn h_unlock() -> Int { 0 }

// Linear-memory helpers, pattern from moonbit-community/wasip1 (Apache-2.0).
// Native builds never run this face, so the stubs only need to typecheck.
#cfg(target="wasm")
#owned(bytes)
extern "wasm" fn bytes2ptr(bytes : Bytes) -> Int = #|(func (param i32) (result i32) local.get 0)
#cfg(target="native")
fn bytes2ptr(_bytes : Bytes) -> Int { 0 }
#cfg(target="wasm")
extern "wasm" fn load8(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load8_u)
#cfg(target="native")
fn load8(_offset : Int) -> Int { 0 }

const RETRY_BASE : Int = 8

// Keep the encoded path alive across the host call and hand its data to the host.
fn path_ptr_of(text : String) -> (Bytes, Int) raise @base.Fault {
  @base.path(text)
  let encoded = @utf8.encode(text)
  (encoded, bytes2ptr(encoded))
}

// One host round trip with the retry protocol; returns the result bytes.
// `missing` (status -3) maps to None; `refused` (status -1) raises, mirroring
// the native platform's fixed messages. The host writes result bytes straight
// into the linear memory of a locally-owned Bytes, so the copy below reads the
// same object the GC keeps alive across the call.
fn host_call_buffer(path : String, refused : String, call : (Int, Int, Int, Int) -> Int) -> Bytes? raise @base.Fault {
  let (encoded, path_ptr) = path_ptr_of(path)
  let mut cap = 1048576
  for _ in 0..<24 {
    let res = Bytes::new(cap)
    let res_ptr = bytes2ptr(res)
    let status = call(path_ptr, encoded.length(), res_ptr, cap)
    if status >= 0 {
      let out : Array[Byte] = []
      for i in 0..<status { out.push(res[i]) }
      return Some(Bytes::from_array(out))
    }
    if status == -3 { return None }
    if status == -1 { raise @base.Fault(refused) }
    if status <= -RETRY_BASE {
      let needed = -status - RETRY_BASE
      if needed <= cap { raise @base.Fault("host_protocol_invalid: " + path) }
      cap = needed
      continue
    }
    raise @base.Fault("host_status_invalid: " + path)
  }
  raise @base.Fault("read_failed_or_changed: " + path)
}

fn host_read_bytes(path : String) -> Bytes? raise @base.Fault {
  host_call_buffer(path, "read_refused: non-regular, unsafe, missing parent, or >16MiB: " + path, h_read)
}

fn host_read(path : String) -> String? raise @base.Fault {
  match host_read_bytes(path) {
    None => None
    Some(bytes) => try Some(@utf8.decode(bytes)) catch {
      _ => raise @base.Fault("invalid_utf8: " + path)
    }
  }
}

fn host_digest(path : String) -> String? raise @base.Fault {
  host_read_bytes(path).map(@base.sha256_hex)
}

fn host_write_bytes(path : String, bytes : Bytes) -> Unit raise @base.Fault {
  @base.path(path)
  match path.rev_split_once("/") {
    Some((parent, _)) => host_mkdirs(parent.to_owned())
    None => ()
  }
  if bytes.length() > 16777216 { @base.fail("file_too_large") }
  let (encoded, path_ptr) = path_ptr_of(path)
  let data_ptr = bytes2ptr(bytes)
  if h_write(path_ptr, encoded.length(), data_ptr, bytes.length()) != 0 {
    @base.fail("atomic_write_failed: " + path)
  }
}

fn host_write(path : String, text : String) -> Unit raise @base.Fault {
  host_write_bytes(path, @utf8.encode(text))
}

fn host_mkdir(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  let (encoded, path_ptr) = path_ptr_of(path)
  if h_mkdir(path_ptr, encoded.length()) != 0 { @base.fail("mkdir_failed: " + path) }
}

fn host_mkdirs(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  let parts = path.split("/").to_array()
  let mut current = ""
  for part in parts {
    current = if current == "" { part.to_owned() } else { current + "/" + part.to_owned() }
    host_mkdir(current)
  }
}

fn host_remove(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  let (encoded, path_ptr) = path_ptr_of(path)
  if h_remove(path_ptr, encoded.length()) != 0 { @base.fail("remove_failed: " + path) }
}

fn host_files(directory : String) -> Array[String] raise @base.Fault {
  @base.path(directory)
  let listing = match host_call_buffer(directory, "list_failed_or_symlink: " + directory, h_list) {
    None => raise @base.Fault("list_failed_or_symlink: " + directory)
    Some(bytes) => try @utf8.decode(bytes) catch {
      _ => raise @base.Fault("invalid_utf8_filename")
    }
  }
  let result : Array[String] = []
  for line in listing.split("\n") {
    if line.is_empty() { continue }
    let child = directory + "/" + line[1:].to_owned()
    if line.has_prefix("d") {
      for file in host_files(child) { result.push(file) }
    } else { result.push(child) }
  }
  result.sort_by(@base.compare)
  result
}

fn host_check(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  host_mkdirs(".corridor/compiler")
  let (encoded, path_ptr) = path_ptr_of(path)
  if h_check(path_ptr, encoded.length()) != 0 {
    @base.fail("moon_check_failed: inspect stderr; install matching MoonBit toolchain")
  }
}

fn host_lock() -> Unit raise @base.Fault {
  if h_lock() != 0 { @base.fail("vault_locked: another writer is active") }
}

fn host_unlock() -> Unit {
  let _ = h_unlock()
}

// Same literal the native host builds in nativehost/host.mbt; every field now
// resolves through the corridor-host imports instead of the C adapter.
fn host_store() -> @vault.Storage {
  {
    read: host_read, digest: host_digest, write: host_write, remove: host_remove,
    files: host_files, check: host_check,
    read_bytes: host_read_bytes, write_bytes: host_write_bytes,
    mkdirs: host_mkdirs,
  }
}
