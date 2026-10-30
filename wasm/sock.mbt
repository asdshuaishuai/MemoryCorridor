// Socket imports for the HTTP serve face: the thin host (hosts/wasm-host.py)
// owns the POSIX listener and connected sockets, exposing accept/recv/send/
// close as corridor-host functions. Under the native target these compile as
// inert stubs (the native web transport is platform/socket.c).

#cfg(target="wasm")
fn sock_recv_ffi(handle : Int, buf : Int, cap : Int) -> Int = "corridor-host" "sock_recv"
#cfg(target="native")
fn sock_recv_ffi(_handle : Int, _buf : Int, _cap : Int) -> Int { -1 }
#cfg(target="wasm")
fn sock_send_ffi(handle : Int, buf : Int, len : Int) -> Int = "corridor-host" "sock_send"
#cfg(target="native")
fn sock_send_ffi(_handle : Int, _buf : Int, _len : Int) -> Int { -1 }
