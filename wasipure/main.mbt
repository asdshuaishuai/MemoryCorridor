// WASI command entry: a line-protocol server on stdin/stdout. Each request
// line produces exactly one response line; `:exit` or EOF ends the session.
// Run with: wasmtime run --dir=<vault> wasipure.wasm

let pending : Ref[Array[Byte]] = @ref.new([])

fn decode_line(bytes : Array[Byte]) -> String {
  try @utf8.decode(Bytes::from_array(bytes)) catch { _ => "invalid_utf8_request" }
}

// Read one request line from fd 0 (chunked reads; EOF ends the session).
fn stdin_line() -> String? {
  let bytes : Array[Byte] = []
  let mut too_long = false
  while true {
    let (buf, buf_ptr) = wasi_malloc(1)
    let (iovs, iovs_ptr) = wasi_iov(buf)
    let (nr, nr_ptr) = wasi_malloc(4)
    if fd_read_ffi(0, iovs_ptr, 1, nr_ptr) != 0 { return None }
    let n = load32(nr_ptr)
    if n <= 0 {
      if bytes.is_empty() { return None }
      break
    }
    for i in 0..<n {
      let byte = load8_wasip1(buf_ptr + i)
      if byte == 10 {
        if too_long { return Some("invalid_request_exceeds_2MiB") }
        return Some(decode_line(bytes))
      }
      if bytes.length() < 2097152 {
        bytes.push(byte.to_byte())
      } else {
        too_long = true
      }
    }
  }
  if too_long { return Some("invalid_request_exceeds_2MiB") }
  Some(decode_line(bytes))
}

pub fn _start() -> Unit {
  let mut serving = true
  while serving {
    match stdin_line() {
      None => serving = false
      Some(text) => {
        if text == ":exit" {
          serving = false
        } else {
          let response = service_execute_text(text)
          try { wasi_write_whole(1, @utf8.encode(response + "\n")) } catch { _ => () }
        }
      }
    }
  }
}
