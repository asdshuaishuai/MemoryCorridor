// WASI Preview 1 import surface for the pure-WASI runtime mode: with these,
// the service can run under a plain `wasmtime run --dir=<vault>` with no
// custom host module. Declaration style and dirent/iovec layouts follow
// moonbit-community/wasip1 (Apache-2.0), trimmed to the storage subset.
// Paths default to no symlink following (dirflags omit symlink_follow),
// matching platform/fs.c's AT_SYMLINK_NOFOLLOW posture.

// WASI errno values this layer distinguishes.
const WASI_EOENT : Int = 44

// oflags bits for path_open.
const OFLAG_CREAT : Int = 1
const OFLAG_DIRECTORY : Int = 2
const OFLAG_EXCL : Int = 4

// filestat/dirent filetype discriminators.
const FILETYPE_DIRECTORY : Int = 3

fn fd_read_ffi(fd : Int, iovs : Int, iovs_len : Int, nread : Int) -> UInt = "wasi_snapshot_preview1" "fd_read"
fn fd_write_ffi(fd : Int, iovs : Int, iovs_len : Int, nwritten : Int) -> UInt = "wasi_snapshot_preview1" "fd_write"
fn fd_close_ffi(fd : Int) -> UInt = "wasi_snapshot_preview1" "fd_close"
fn fd_sync_ffi(fd : Int) -> UInt = "wasi_snapshot_preview1" "fd_sync"
fn fd_filestat_get_ffi(fd : Int, buf : Int) -> UInt = "wasi_snapshot_preview1" "fd_filestat_get"
fn fd_readdir_ffi(fd : Int, buf : Int, buf_len : Int, cookie : UInt64, nread : Int) -> UInt = "wasi_snapshot_preview1" "fd_readdir"
fn fd_prestat_get_ffi(fd : Int, buf : Int) -> UInt = "wasi_snapshot_preview1" "fd_prestat_get"
fn path_open_ffi(
  dirfd : Int, dirflags : Int, path : Int, path_len : Int, oflags : Int,
  rights_base : UInt64, rights_inheriting : UInt64, fdflags : Int, opened : Int,
) -> UInt = "wasi_snapshot_preview1" "path_open"
fn path_create_directory_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_create_directory"
fn path_remove_directory_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_remove_directory"
fn path_unlink_file_ffi(fd : Int, path : Int, len : Int) -> UInt = "wasi_snapshot_preview1" "path_unlink_file"
fn path_rename_ffi(fd : Int, old_path : Int, old_len : Int, new_fd : Int, new_path : Int, new_len : Int) -> UInt = "wasi_snapshot_preview1" "path_rename"
fn clock_time_get_ffi(clock_id : Int, precision : UInt64, time : Int) -> UInt = "wasi_snapshot_preview1" "clock_time_get"

extern "wasm" fn store32(offset : Int, value : Int) = #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store)
extern "wasm" fn load32(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load)
extern "wasm" fn load8_wasip1(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load8_u)

// Scratch allocation: the Bytes object doubles as the linear-memory buffer
// that WASI writes into; keeping the local alive spans the host call.
fn wasi_malloc(size : Int) -> (Bytes, Int) {
  let buf = Bytes::new(size)
  (buf, bytes2ptr(buf))
}

// WASI needs an iovec pair (ptr, len) in linear memory.
fn wasi_iov(buf : Bytes) -> (Bytes, Int) {
  let ptr = bytes2ptr(buf)
  let iovs = Bytes::new(8)
  let base = bytes2ptr(iovs)
  store32(base, ptr)
  store32(base + 4, buf.length())
  (iovs, base)
}

// The first preopened directory (wasmtime --dir) lands on fd 3.
fn wasi_root_fd() -> Int raise @base.Fault {
  let (_, buf_ptr) = wasi_malloc(8)
  let err = fd_prestat_get_ffi(3, buf_ptr)
  if err == 0 { return 3 }
  raise @base.Fault("wasi_preopen_missing: run with --dir=<vault> (errno " + err.to_string() + ")")
}

fn wasi_time_ns() -> UInt64 raise @base.Fault {
  let (_, buf_ptr) = wasi_malloc(8)
  let err = clock_time_get_ffi(1, 1_000_000UL, buf_ptr) // clock 1 = monotonic
  if err != 0 { raise @base.Fault("wasi_clock_failed") }
  let mut value : UInt64 = 0UL
  for i in 0..<8 { value = (value << 8) | load8_wasip1(buf_ptr + i).to_uint64() }
  value
}
