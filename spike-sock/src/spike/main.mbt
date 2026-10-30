fn sock_accept_ffi(fd : Int, flags : Int, opened : Int) -> UInt = "wasi_snapshot_preview1" "sock_accept"
fn sock_recv_ffi(fd : Int, iovs : Int, iovs_len : Int, ri_flags : Int, ro_datalen : Int, ro_flags : Int) -> UInt = "wasi_snapshot_preview1" "sock_recv"
fn sock_send_ffi(fd : Int, si_data : Int, si_data_len : Int, si_flags : Int, so_datalen : Int) -> UInt = "wasi_snapshot_preview1" "sock_send"
fn fd_write_ffi(fd : Int, iovs : Int, iovs_len : Int, nwritten : Int) -> UInt = "wasi_snapshot_preview1" "fd_write"
fn fd_close_ffi(fd : Int) -> UInt = "wasi_snapshot_preview1" "fd_close"

extern "wasm" fn store32(offset : Int, value : Int) = #|(func (param i32) (param i32) local.get 0 local.get 1 i32.store)
extern "wasm" fn load32(offset : Int) -> Int = #|(func (param i32) (result i32) local.get 0 i32.load)
#owned(bytes)
extern "wasm" fn bytes2ptr(bytes : Bytes) -> Int = #|(func (param i32) (result i32) local.get 0)

fn mk_iov(bytes : Bytes) -> (Bytes, Int) {
  let ptr = bytes2ptr(bytes)
  let iovs = Bytes::new(8)
  let base = bytes2ptr(iovs)
  store32(base, ptr)
  store32(base + 4, bytes.length())
  (iovs, base)
}

fn log(text : String) -> Unit {
  let payload = @utf8.encode(text)
  let (iovs, iovs_ptr) = mk_iov(payload)
  let nw = Bytes::new(4)
  let nw_ptr = bytes2ptr(nw)
  let _ = fd_write_ffi(1, iovs_ptr, 1, nw_ptr)
}

pub fn _start() -> Unit {
  // 在 fd 3..8 中寻找 --tcplisten 注入的监听 socket
  for listen_fd in 3..<9 {
    let opened_buf = Bytes::new(4)
    let opened_ptr = bytes2ptr(opened_buf)
    let err = sock_accept_ffi(listen_fd, 0, opened_ptr)
    log("fd " + listen_fd.to_string() + " accept errno=" + err.to_string() + "\n")
    if err == 0 {
      let conn = load32(opened_ptr)
      let req = Bytes::new(4096)
      let (riovs, riovsp) = mk_iov(req)
      let rdlen = Bytes::new(4)
      let rdlen_ptr = bytes2ptr(rdlen)
      let rflags = Bytes::new(4)
      let rflags_ptr = bytes2ptr(rflags)
      let rerr = sock_recv_ffi(conn, riovsp, 1, 0, rdlen_ptr, rflags_ptr)
      let n = load32(rdlen_ptr)
      log("recv errno=" + rerr.to_string() + " n=" + n.to_string() + "\n")
      let (siov, siov_ptr) = mk_iov(req)
      let sdl = Bytes::new(4)
      let sdl_ptr = bytes2ptr(sdl)
      let serr = sock_send_ffi(conn, siov_ptr, 1, 0, sdl_ptr)
      log("send errno=" + serr.to_string() + "\n")
      let _ = fd_close_ffi(conn)
      let _ = fd_close_ffi(listen_fd)
      return
    }
  }
  log("no listener fd found in 3..8\n")
}
