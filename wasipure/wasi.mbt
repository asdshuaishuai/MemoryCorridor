// WASI Preview 1 import surface for the pure-WASI runtime mode: with these,
// the service can run under a plain `wasmtime run --dir=<vault>` with no
// custom host module. Declaration style and dirent/iovec layouts follow
// moonbit-community/wasip1 (Apache-2.0), trimmed to the storage subset.
// Paths default to no symlink following (dirflags omit symlink_follow),
// matching platform/fs.c's AT_SYMLINK_NOFOLLOW posture.
// Under the native target every import compiles as an inert stub so the
// package passes `moon check --target native --deny-warn`; the pure-WASI
// service is only reachable through the wasm artifact.

const WASI_EOENT : Int = 44
const OFLAG_CREAT : Int = 1
const OFLAG_DIRECTORY : Int = 2
const OFLAG_EXCL : Int = 4
const FILETYPE_DIRECTORY : Int = 3


#cfg(target="wasm")
fn fd_read_ffi(fd : Int, iovs : Int, iovs_len : Int, nread : Int) -> UInt = "wasi_snapshot_preview1" "fd_read"
#cfg(target="native")
fn fd_read_ffi(_fd : Int, _iovs : Int, _iovs_len : Int, _nread : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_write_ffi(fd : Int, iovs : Int, iovs_len : Int, nwritten : Int) -> UInt = "wasi_snapshot_preview1" "fd_write"
#cfg(target="native")
fn fd_write_ffi(_fd : Int, _iovs : Int, _iovs_len : Int, _nwritten : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_close_ffi(fd : Int) -> UInt = "wasi_snapshot_preview1" "fd_close"
#cfg(target="native")
fn fd_close_ffi(_fd : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_sync_ffi(fd : Int) -> UInt = "wasi_snapshot_preview1" "fd_sync"
#cfg(target="native")
fn fd_sync_ffi(_fd : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_filestat_get_ffi(fd : Int, buf : Int) -> UInt = "wasi_snapshot_preview1" "fd_filestat_get"
#cfg(target="native")
fn fd_filestat_get_ffi(_fd : Int, _buf : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_readdir_ffi(fd : Int, buf : Int, buf_len : Int, cookie : UInt64, nread : Int) -> UInt = "wasi_snapshot_preview1" "fd_readdir"
#cfg(target="native")
fn fd_readdir_ffi(_fd : Int, _buf : Int, _buf_len : Int, _cookie : UInt64, _nread : Int) -> UInt { 0 }
#cfg(target="wasm")
fn fd_prestat_get_ffi(fd : Int, buf : Int) -> UInt = "wasi_snapshot_preview1" "fd_prestat_get"
#cfg(target="native")
fn fd_prestat_get_ffi(_fd : Int, _buf : Int) -> UInt { 0 }
#cfg(target="wasm")
fn path_open_ffi(dirfd : Int, dirflags : Int, path : Int, path_len : Int, oflags : Int, rights_base : UInt64, rights_inheriting : UInt64, fdflags : Int, opened : Int) -> UInt = "wasi_snapshot_preview1" "path_open"
#cfg(target="native")
fn path_open_ffi(_dirfd : Int, _dirflags : Int, _path : Int, _path_len : Int, _oflags : Int, _rights_base : UInt64, _rights_inheriting : UInt64, _fdflags : Int, _opened : Int) -> UInt { 0 }
#cfg(target="wasm")
fn path_create_directory_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_create_directory"
#cfg(target="native")
fn path_create_directory_ffi(_fd : Int, _path : Int, _len : Int) -> UInt { 0 }
#cfg(target="wasm")
fn path_remove_directory_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_remove_directory"
#cfg(target="native")
fn path_remove_directory_ffi(_fd : Int, _path : Int, _len : Int) -> UInt { 0 }
#cfg(target="wasm")
fn path_unlink_file_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_unlink_file"
#cfg(target="native")
fn path_unlink_file_ffi(_fd : Int, _path : Int, _len : Int) -> UInt { 0 }
#cfg(target="wasm")
fn path_rename_ffi(fd : Int, old_path : Int, old_len : Int, new_fd : Int, new_path : Int, new_len : Int) -> UInt = "wasi_snapshot_preview1" "path_rename"
#cfg(target="native")
fn path_rename_ffi(_fd : Int, _old_path : Int, _old_len : Int, _new_fd : Int, _new_path : Int, _new_len : Int) -> UInt { 0 }
#cfg(target="wasm")
fn clock_time_get_ffi(clock_id : Int, precision : UInt64, time : Int) -> UInt = "wasi_snapshot_preview1" "clock_time_get"
#cfg(target="native")
fn clock_time_get_ffi(_clock_id : Int, _precision : UInt64, _time : Int) -> UInt { 0 }
#cfg(target="wasm")
#owned(bytes)
extern "wasm" fn bytes2ptr(bytes : Bytes) -> Int = #|(func (param i32) (result i32) local.get 0)
#cfg(target="native")
fn bytes2ptr(_bytes : Bytes) -> Int { 0 }
#cfg(target="wasm")
extern "wasm" fn store32(offset : Int, value : Int) = #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store)
#cfg(target="native")
fn store32(_offset : Int, _value : Int) -> Int { 0 }
#cfg(target="wasm")
extern "wasm" fn load32(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load)
#cfg(target="native")
fn load32(_offset : Int) -> Int { 0 }
#cfg(target="wasm")
extern "wasm" fn load8_wasip1(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load8_u)
#cfg(target="native")
fn load8_wasip1(_offset : Int) -> Int { 0 }

// Scratch allocation: the Bytes object doubles as the linear-memory buffer
// that WASI writes into; keeping the local alive spans the host call.
#cfg(target="wasm")
fn wasi_malloc(size : Int) -> (Bytes, Int) {
  let buf = Bytes::new(size)
  (buf, bytes2ptr(buf))
}
#cfg(target="native")
fn wasi_malloc(size : Int) -> (Bytes, Int) {
  (Bytes::new(size), 0)
}

// WASI needs an iovec pair (ptr, len) in linear memory.
#cfg(target="wasm")
fn wasi_iov(buf : Bytes) -> (Bytes, Int) {
  let ptr = bytes2ptr(buf)
  let iovs = Bytes::new(8)
  let base = bytes2ptr(iovs)
  store32(base, ptr)
  store32(base + 4, buf.length())
  (iovs, base)
}
#cfg(target="native")
fn wasi_iov(buf : Bytes) -> (Bytes, Int) {
  (buf, 0)
}

// The first preopened directory (wasmtime --dir) lands on fd 3.
#cfg(target="wasm")
fn wasi_root_fd() -> Int raise @base.Fault {
  let (buf, buf_ptr) = wasi_malloc(8)
  let err = fd_prestat_get_ffi(3, buf_ptr)
  ignore(buf)
  if err == 0 { return 3 }
  raise @base.Fault("wasi_preopen_missing: run with --dir=<vault> (errno " + err.to_string() + ")")
}
#cfg(target="native")
fn wasi_root_fd() -> Int raise @base.Fault {
  let _ = fd_prestat_get_ffi(3, 0)
  raise @base.Fault("wasi_preopen_missing: pure-WASI storage requires the wasm artifact")
}

#cfg(target="wasm")
fn wasi_time_ns() -> UInt64 raise @base.Fault {
  let (buf, buf_ptr) = wasi_malloc(8)
  let err = clock_time_get_ffi(1, 1_000_000UL, buf_ptr)
  ignore(buf) // clock 1 = monotonic
  if err != 0 { raise @base.Fault("wasi_clock_failed") }
  let mut value : UInt64 = 0UL
  for i in 0..<8 { value = value | (load8_wasip1(buf_ptr + i).to_uint64() << (i * 8)) } // little-endian
  value
}
#cfg(target="native")
fn wasi_time_ns() -> UInt64 raise @base.Fault {
  let _ = clock_time_get_ffi(1, 1_000_000UL, 0)
  raise @base.Fault("wasi_clock_failed: pure-WASI storage requires the wasm artifact")
}
