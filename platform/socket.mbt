#borrow(addr)
extern "c" fn listen_native(addr : Bytes, port : Int) -> Int = "mc_tcp_listen"
extern "c" fn port_native(fd : Int) -> Int = "mc_tcp_port"
extern "c" fn accept_native(fd : Int) -> Int = "mc_tcp_accept"
#borrow(buf)
extern "c" fn recv_native(fd : Int, buf : Bytes, cap : Int) -> Int = "mc_tcp_recv"
#borrow(buf)
extern "c" fn send_native(fd : Int, buf : Bytes, len : Int) -> Int = "mc_tcp_send"
extern "c" fn close_native(fd : Int) -> Unit = "mc_tcp_close"
extern "c" fn exit_native(code : Int) -> Unit = "mc_exit"

/// Bind a TCP listener on the given IPv4 address and port. Returns the
/// listener descriptor; a negative result or fault means startup must stop.
pub fn tcp_listen(addr : String, port : Int) -> Int raise @base.Fault {
  let fd = listen_native(cstr(addr), port)
  if fd < 0 { @base.fail("tcp_listen_failed: " + addr + ":" + port.to_string()) }
  fd
}

/// Report the port actually bound by the listener (differs from the request
/// when the caller asked for port 0).
pub fn tcp_port(fd : Int) -> Int raise @base.Fault {
  let port = port_native(fd)
  if port < 0 { @base.fail("tcp_port_failed") }
  port
}

/// Block for one connection. Returns the connection descriptor, or a
/// negative value when accept failed transiently and the caller may retry.
pub fn tcp_accept(fd : Int) -> Int {
  accept_native(fd)
}

/// Read up to cap bytes. Positive is a byte count, 0 means the peer closed,
/// negative means the connection failed.
pub fn tcp_recv(fd : Int, buf : Bytes, cap : Int) -> Int {
  recv_native(fd, buf, cap)
}

/// Send the whole buffer or fail; the connection must then be closed.
pub fn tcp_send(fd : Int, buf : Bytes) -> Unit raise @base.Fault {
  if send_native(fd, buf, buf.length()) != 0 { @base.fail("tcp_send_failed") }
}

pub fn tcp_close(fd : Int) -> Unit {
  close_native(fd)
}

/// Terminate the process with the given status; used for startup failures
/// after the ready/failure payload has already been written.
pub fn halt(code : Int) -> Unit {
  exit_native(code)
}
