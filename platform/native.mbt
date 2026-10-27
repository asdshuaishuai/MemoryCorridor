#borrow(path)
extern "c" fn root_native(path : Bytes) -> Int = "mc_root"
#borrow(path)
extern "c" fn size_native(path : Bytes) -> Int = "mc_size"
#borrow(path, buf)
extern "c" fn read_native(path : Bytes, buf : Bytes, cap : Int) -> Int = "mc_read"
#borrow(path, buf)
extern "c" fn write_native(path : Bytes, buf : Bytes, len : Int) -> Int = "mc_write"
#borrow(path)
extern "c" fn mkdir_native(path : Bytes) -> Int = "mc_mkdir"
#borrow(path)
extern "c" fn remove_native(path : Bytes) -> Int = "mc_remove"
#borrow(path, buf)
extern "c" fn list_native(path : Bytes, buf : Bytes, cap : Int) -> Int = "mc_list"
extern "c" fn lock_native() -> Int = "mc_lock"
extern "c" fn unlock_native() -> Int = "mc_unlock"
#borrow(path)
extern "c" fn check_native(path : Bytes) -> Int = "mc_check"

fn cstr(value : String) -> Bytes raise @base.Fault {
  if value.contains_char('\u0000') { @base.fail("nul_in_path") }
  @utf8.encode(value + "\u0000")
}

pub fn open_root(path : String) -> Unit raise @base.Fault {
  if root_native(cstr(path)) != 0 { @base.fail("vault_directory_required: create root directory first") }
}

pub fn read_bytes(path : String) -> Bytes? raise @base.Fault {
  @base.path(path)
  let size = size_native(cstr(path))
  if size == -1 { return None }
  if size < 0 { @base.fail("read_refused: non-regular, unsafe, missing parent, or >16MiB: " + path) }
  let buf = Bytes::new(size)
  if read_native(cstr(path), buf, size) != size { @base.fail("read_failed_or_changed: " + path) }
  Some(buf)
}

pub fn read(path : String) -> String? raise @base.Fault {
  match read_bytes(path) {
    None => None
    Some(bytes) => try Some(@utf8.decode(bytes)) catch {
      _ => raise @base.Fault("invalid_utf8: " + path)
    }
  }
}

pub fn digest(path : String) -> String? raise @base.Fault {
  read_bytes(path).map(@base.sha256_hex)
}

pub fn mkdirs(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  let parts = path.split("/").to_array()
  let mut current = ""
  for part in parts {
    current = if current == "" { part.to_owned() } else { current + "/" + part.to_owned() }
    if mkdir_native(cstr(current)) != 0 { @base.fail("mkdir_failed: " + current) }
  }
}

pub fn write(path : String, text : String) -> Unit raise @base.Fault {
  write_bytes(path, @utf8.encode(text))
}

pub fn write_bytes(path : String, bytes : Bytes) -> Unit raise @base.Fault {
  @base.path(path)
  match path.rev_split_once("/") {
    Some((parent, _)) => mkdirs(parent.to_owned())
    None => ()
  }
  if bytes.length() > 16777216 { @base.fail("file_too_large") }
  if write_native(cstr(path), bytes, bytes.length()) != 0 {
    @base.fail("atomic_write_failed: " + path)
  }
}

pub fn remove(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  if remove_native(cstr(path)) != 0 { @base.fail("remove_failed: " + path) }
}

pub fn files(directory : String) -> Array[String] raise @base.Fault {
  @base.path(directory)
  let buf = Bytes::new(1048576)
  let size = list_native(cstr(directory), buf, buf.length())
  if size < 0 { @base.fail("list_failed_or_symlink: " + directory) }
  let listing = try @utf8.decode(buf[:size]) catch {
    _ => raise @base.Fault("invalid_utf8_filename")
  }
  let result : Array[String] = []
  for line in listing.split("\n") {
    if line.is_empty() { continue }
    let child = directory + "/" + line[1:].to_owned()
    if line.has_prefix("d") {
      for file in files(child) { result.push(file) }
    } else { result.push(child) }
  }
  result.sort_by(@base.compare)
  result
}

pub fn lock() -> Unit raise @base.Fault {
  if lock_native() != 0 { @base.fail("vault_locked: another writer is active") }
}

pub fn unlock() -> Unit {
  let _ = unlock_native()
}

pub fn check(path : String) -> Unit raise @base.Fault {
  @base.path(path)
  mkdirs(".corridor/compiler")
  if check_native(cstr(path)) != 0 {
    @base.fail("moon_check_failed: inspect stderr; install matching MoonBit toolchain")
  }
}
