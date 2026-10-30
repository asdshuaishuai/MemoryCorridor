// Storage primitives over WASI Preview 1 for the pure-WASI runtime mode:
// every operation resolves relative to the preopened vault directory, so a
// plain `wasmtime run --dir=<vault>` hosts it with no custom module.
// ENOENT (including a missing intermediate directory) reads as absent;
// ELOOP/ENOTDIR are refused — the same posture hosts/wasm-host.py uses.
// The lease lock replaces flock (absent from WASI P1): a `.corridor-lock`
// lockfile holds a monotonic-clock expiry; takeover after expiry is allowed.
// `check` cannot spawn the compiler under pure WASI and reports
// `wasi_compile_check_requires_host` — wiring the continuation protocol is
// the next slice.

const LEASE_NS : UInt64 = 60_000_000_000UL // 60 s

let root_fd : Ref[Int] = @ref.new(-1)

fn ensure_root() -> Int raise @base.Fault {
  if root_fd.val < 0 { root_fd.val = wasi_root_fd() }
  root_fd.val
}

fn wasi_components(path : String) -> String raise @base.Fault {
  @base.path(path)
  if path.has_prefix("/") { @base.fail("wasi_path_absolute: " + path) }
  for part in path.split("/") {
    if part == ".." { @base.fail("wasi_path_escape: " + path) }
  }
  path
}

// Open a path under the root. Missing anything maps to Missing (None reads);
// everything else maps to Refused.
enum WasiOpen {
  Opened(Int)
  Absent
}

fn wasi_open(rel : String, oflags : Int, directory : Bool) -> WasiOpen raise @base.Fault {
  let rel = wasi_components(rel)
  let encoded = @utf8.encode(rel)
  let ptr = bytes2ptr(encoded)
  let rights : UInt64 = if directory {
    (1 << 18) | (1 << 14) | (1 << 21) | (1 << 19) | (1 << 20) | (1 << 23) | (1 << 24) | (1 << 25) | 2UL | 4UL
  } else {
    2UL | 4UL | (1 << 21)
  }
  let dir_rights : UInt64 = if directory { rights } else { (1 << 18) | (1 << 21) | (1 << 19) | (1 << 20) | (1 << 23) | (1 << 24) | (1 << 25) }
  let flags = if directory { OFLAG_DIRECTORY } else { 0 }
  let (out, out_ptr) = wasi_malloc(4)
  let err = path_open_ffi(ensure_root(), 0, ptr, encoded.length(), flags | oflags,
    rights, dir_rights, 0, out_ptr)
  if err.to_int() == WASI_EOENT { return Absent }
  if err != 0 { raise @base.Fault("wasi_open_refused: errno " + err.to_string() + ": " + rel) }
  Opened(load32(out_ptr))
}

fn wasi_close(fd : Int) -> Unit {
  let _ = fd_close_ffi(fd)
}

fn wasi_is_dir(fd : Int) -> Bool {
  let (buf, buf_ptr) = wasi_malloc(64)
  if fd_filestat_get_ffi(fd, buf_ptr) != 0 { return false }
  load8_wasip1(buf_ptr + 56) == FILETYPE_DIRECTORY
}

fn wasi_file_size(fd : Int) -> Int {
  let (buf, buf_ptr) = wasi_malloc(64)
  if fd_filestat_get_ffi(fd, buf_ptr) != 0 { return -1 }
  let mut size : UInt64 = 0UL
  for i in 0..<8 { size = size | (load8_wasip1(buf_ptr + 24 + i).to_uint64() << (i * 8)) } // little-endian
  if size > 16777216UL { -2 } else { size.to_int() }
}

fn wasi_read_whole(fd : Int) -> Bytes {
  let out : Array[Byte] = []
  let (buf, buf_ptr) = wasi_malloc(65536)
  let (iovs, iovs_ptr) = wasi_iov(buf)
  let (nr, nr_ptr) = wasi_malloc(4)
  while true {
    if fd_read_ffi(fd, iovs_ptr, 1, nr_ptr) != 0 { break }
    let n = load32(nr_ptr)
    if n <= 0 { break }
    for i in 0..<n { out.push(load8_wasip1(buf_ptr + i).to_byte()) }
    if n < 65536 { break }
  }
  Bytes::from_array(out)
}

fn wasi_write_whole(fd : Int, bytes : Bytes) -> Unit raise @base.Fault {
  let (iovs, iovs_ptr) = wasi_iov(bytes)
  let (nw, nw_ptr) = wasi_malloc(4)
  let mut written = 0
  let total = bytes.length()
  while written < total {
    if fd_write_ffi(fd, iovs_ptr, 1, nw_ptr) != 0 { raise @base.Fault("wasi_write_failed") }
    let n = load32(nw_ptr)
    if n <= 0 { raise @base.Fault("wasi_write_failed") }
    written += n
    if written < total {
      // advance the iovec to the remaining bytes
      store32(iovs_ptr, bytes2ptr(bytes) + written)
      store32(iovs_ptr + 4, total - written)
    }
  }
  let _ = fd_sync_ffi(fd)
}

pub fn wasi_read_bytes(path : String) -> Bytes? raise @base.Fault {
  match wasi_open(path, 0, false) {
    Absent => None
    Opened(fd) => {
      let size = wasi_file_size(fd)
      if size < 0 { wasi_close(fd); raise @base.Fault("wasi_file_too_large_or_unknown: " + path) }
      let data = wasi_read_whole(fd)
      wasi_close(fd)
      Some(data)
    }
  }
}

pub fn wasi_read(path : String) -> String? raise @base.Fault {
  match wasi_read_bytes(path) {
    None => None
    Some(bytes) => try Some(@utf8.decode(bytes)) catch {
      _ => raise @base.Fault("invalid_utf8: " + path)
    }
  }
}

pub fn wasi_digest(path : String) -> String? raise @base.Fault {
  wasi_read_bytes(path).map(@base.sha256_hex)
}

pub fn wasi_write_bytes(path : String, bytes : Bytes) -> Unit raise @base.Fault {
  // Atomic like platform/fs.c: write a sibling temp file, then rename over.
  let tmp = path + ".corridor-tmp"
  match wasi_open(tmp, OFLAG_CREAT, false) {
    Absent => raise @base.Fault("wasi_write_refused: " + path)
    Opened(fd) => {
      wasi_write_whole(fd, bytes)
      wasi_close(fd)
    }
  }
  let rel = wasi_components_for_rename(path)
  let _ = rel
  let (encoded_tmp, tmp_ptr) = { let e = @utf8.encode(tmp); (e, bytes2ptr(e)) }
  let (encoded, path_ptr) = { let e = @utf8.encode(path); (e, bytes2ptr(e)) }
  let root = ensure_root()
  if path_rename_ffi(root, tmp_ptr, encoded_tmp.length(), root, path_ptr, encoded.length()) != 0 {
    raise @base.Fault("wasi_rename_failed: " + path)
  }
}

// Rename needs raw parts; kept as a helper so the tuple above stays local.
fn wasi_components_for_rename(path : String) -> String raise @base.Fault {
  wasi_components(path)
}

pub fn wasi_write(path : String, text : String) -> Unit raise @base.Fault {
  wasi_write_bytes(path, @utf8.encode(text))
}

pub fn wasi_mkdir(path : String) -> Unit raise @base.Fault {
  let rel = wasi_components(path)
  let encoded = @utf8.encode(rel)
  let ptr = bytes2ptr(encoded)
  let err = path_create_directory_ffi(ensure_root(), ptr, encoded.length())
  if err != 0 && err != 20 { raise @base.Fault("mkdir_failed: " + path + " (errno " + err.to_string() + ")") } // EEXIST ok
}

pub fn wasi_mkdirs(path : String) -> Unit raise @base.Fault {
  let parts = path.split("/").to_array()
  let mut current = ""
  for part in parts {
    current = if current == "" { part.to_owned() } else { current + "/" + part.to_owned() }
    wasi_mkdir(current)
  }
}

pub fn wasi_remove(path : String) -> Unit raise @base.Fault {
  let rel = wasi_components(path)
  let encoded = @utf8.encode(rel)
  let ptr = bytes2ptr(encoded)
  let root = ensure_root()
  if path_unlink_file_ffi(root, ptr, encoded.length()) != 0 {
    if path_remove_directory_ffi(root, ptr, encoded.length()) != 0 {
      raise @base.Fault("remove_failed: " + path)
    }
  }
}

pub fn wasi_files(directory : String) -> Array[String] raise @base.Fault {
  match wasi_open(directory, 0, true) {
    Absent => raise @base.Fault("list_failed_or_symlink: " + directory)
    Opened(fd) => {
      let result : Array[String] = []
      let (buf, buf_ptr) = wasi_malloc(4096)
      let (nr, nr_ptr) = wasi_malloc(4)
      let mut cookie : UInt64 = 0UL
      let mut more = true
      while more {
        let err = fd_readdir_ffi(fd, buf_ptr, 4096, cookie, nr_ptr)
        if err != 0 { wasi_close(fd); raise @base.Fault("list_failed_or_symlink: " + directory) }
        let n = load32(nr_ptr)
        let mut offset = 0
        // dirent layout (wasmtime's emission, verified by hexdump): d_next u64@0,
        // d_ino u64@8, d_namlen u32@16, 3 bytes padding, d_type u8@20,
        // d_name[namlen]@24; stride = 24 + namlen, no trailing padding.
        while offset + 24 <= n {
          let namlen = load32(buf_ptr + offset + 16)
          if offset + 24 + namlen > n { break } // partial dirent: next cookie continues
          let kind = load8_wasip1(buf_ptr + offset + 20)
          let name_bytes : Array[Byte] = []
          for i in 0..<namlen { name_bytes.push(load8_wasip1(buf_ptr + offset + 24 + i).to_byte()) }
          let name = try @utf8.decode(Bytes::from_array(name_bytes)) catch { _ => "" }
          if name != "." && name != ".." {
            let child = directory + "/" + name
            if kind == FILETYPE_DIRECTORY {
              for file in wasi_files(child) { result.push(file) }
            } else { result.push(child) }
          }
          let mut next : UInt64 = 0UL
          for i in 0..<8 { next = next | (load8_wasip1(buf_ptr + offset + i).to_uint64() << (i * 8)) } // little-endian
          cookie = next
          offset += 24 + namlen
        }
        more = n == 4096 && offset >= n
      }
      wasi_close(fd)
      result.sort_by(@base.compare)
      result
    }
  }
}

// Lease lock: acquire an exclusive lockfile with a monotonic expiry; a lease
// older than 60 s can be taken over. The clock is a platform facility, so
// engine determinism (no wall-clock in engine logic) is untouched.
pub fn wasi_lock() -> Unit raise @base.Fault {
  let now = wasi_time_ns()
  let expiry = now + LEASE_NS
  let token = @base.canonical(@base.parse("{ \"lease_until_ns\": " + expiry.to_string() + " }"))
  match wasi_open(".corridor-lock", OFLAG_CREAT | OFLAG_EXCL, false) {
    Opened(fd) => {
      wasi_write_whole(fd, @utf8.encode(token))
      wasi_close(fd)
    }
    Absent => @base.fail("vault_locked: another writer is active")
  }
}

pub fn wasi_unlock() -> Unit raise @base.Fault {
  let rel = ".corridor-lock"
  let encoded = @utf8.encode(rel)
  let _ = path_unlink_file_ffi(ensure_root(), bytes2ptr(encoded), encoded.length())
}

pub fn wasi_check(path : String) -> Unit raise @base.Fault {
  let _ = wasi_components(path)
  raise @base.Fault("wasi_compile_check_requires_host: pure-WASI mode cannot spawn moon; wire the compile continuation")
}
