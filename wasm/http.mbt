// HTTP serve face for the wasm service module: the connection socket arrives
// as a corridor-host handle from the accept loop in hosts/wasm-host.py, and
// engine dispatch runs through the same service_run session glue as the
// stdio face. HTTP parsing/response logic is ported from web/main.mbt.

fn sock_read(conn : Int, buf : Bytes) -> Int {
  sock_recv_ffi(conn, bytes2ptr(buf), buf.length())
}

fn sock_write(conn : Int, bytes : Bytes) -> Unit {
  let _ = sock_send_ffi(conn, bytes2ptr(bytes), bytes.length())
}

priv struct Response {
  status : Int
  mime : String
  body : Bytes
}

priv struct ReadyRequest {
  verb : String
  host : String?
  target : Array[Int] // raw request-target bytes
}

priv enum ReadOutcome {
  Disconnect
  Rejected(Int, String)
  Ready(ReadyRequest)
}

priv enum Query {
  Invalid
  Valid(Array[(String, String)])
}

priv enum Target {
  Invalid
  Split(String, Array[Int])
}

priv enum Built {
  InvalidParameter(String)
  Built(Map[String, Json])
}

// ------------------------------------------------------------- sockets

// ---------------------------------------------------------------- engine

fn fault_payload(message : String) -> Json {
  let data = @base.fault_data(message)
  match data {
    Object(fields) => {
      fields["ok"] = false.to_json()
      fields["error"] = message.to_json()
      fields["request_id"] = Json::null()
      Json::object(fields)
    }
    _ => { "ok": false, "error": message, "request_id": Json::null() }
  }
}

/// Run one engine operation with a fresh session: open root, take the vault
/// lock, dispatch, release. Never holds the lock between requests.
fn web_invoke(root : String, op : String, fields : Map[String, Json]) -> Json raise @base.Fault {
  let request : Map[String, Json] = Map([])
  request["op"] = op.to_json()
  request["vault"] = root.to_json()
  for key, value in fields {
    request[key] = value
  }
  let value = service_run(new_service(), Json::object(request))
  { "ok": true, "op": op, "result": value, "request_id": Json::null() }
}

// ------------------------------------------------------------- responses

fn reason(status : Int) -> String {
  match status {
    200 => "OK"
    400 => "Bad Request"
    403 => "Forbidden"
    404 => "Not Found"
    405 => "Method Not Allowed"
    409 => "Conflict"
    431 => "Request Header Fields Too Large"
    501 => "Unsupported Method"
    _ => "Bad Gateway"
  }
}

fn json_response(status : Int, value : Json) -> Response {
  {
    status,
    mime: "application/json; charset=utf-8",
    body: @utf8.encode(@base.canonical(value)),
  }
}

fn error_response(status : Int, code : String) -> Response {
  json_response(status, { "ok": false, "error": code })
}

fn send_response(conn : Int, response : Response, head_only : Bool) -> Unit {
  let head = "HTTP/1.1 " + response.status.to_string() + " " + reason(response.status) + "\r\n" +
    "Content-Type: " + response.mime + "\r\n" +
    "Content-Length: " + response.body.length().to_string() + "\r\n" +
    "Cache-Control: no-store\r\n" +
    "X-Content-Type-Options: nosniff\r\n" +
    "Referrer-Policy: no-referrer\r\n" +
    "Connection: close\r\n\r\n"
  let _ = sock_write(conn, @utf8.encode(head))
  if !head_only {
    let _ = sock_write(conn, response.body)
  }
}

// ------------------------------------------------------------ byte tools

fn ascii_range(data : Array[Int], start : Int, end : Int) -> String {
  let sb = StringBuilder()
  for i = start; i < end; i = i + 1 {
    let b = data[i]
    sb.write_char((if b >= 0x20 && b < 0x7F { b } else { 0xFFFD }).unsafe_to_char())
  }
  sb.to_string()
}

fn hex_value(b : Int) -> Int {
  if b >= 0x30 && b <= 0x39 {
    b - 0x30
  } else if b >= 0x61 && b <= 0x66 {
    b - 0x61 + 10
  } else {
    b - 0x41 + 10
  }
}

fn is_hex(b : Int) -> Bool {
  (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
}

fn is_scheme_char(b : Int) -> Bool {
  (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2D || b == 0x2E
}

/// unquote_plus over data[start..end]: '+' becomes a space, %XX decodes to a
/// byte, invalid escapes stay literal; the result is decoded as UTF-8 with
/// replacement characters, matching urllib.parse.unquote_plus(errors=replace).
fn unquote_plus(data : Array[Int], start : Int, end : Int) -> String {
  let bytes : Array[Int] = []
  let mut i = start
  while i < end {
    let b = data[i]
    if b == 0x2B {
      bytes.push(0x20)
      i = i + 1
    } else if b == 0x25 && i + 2 < end && is_hex(data[i + 1]) && is_hex(data[i + 2]) {
      bytes.push(hex_value(data[i + 1]) * 16 + hex_value(data[i + 2]))
      i = i + 3
    } else {
      bytes.push(b)
      i = i + 1
    }
  }
  lenient_utf8(bytes)
}

/// Lenient UTF-8 decode: valid sequences become characters, anything else
/// becomes U+FFFD per byte.
fn lenient_utf8(bytes : Array[Int]) -> String {
  let sb = StringBuilder()
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i]
    if b0 < 0x80 {
      sb.write_char(b0.unsafe_to_char())
      i = i + 1
      continue
    }
    let need = if b0 >= 0xC2 && b0 <= 0xDF {
      1
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      2
    } else if b0 >= 0xF0 && b0 <= 0xF4 {
      3
    } else {
      -1
    }
    let mut ok = need > 0 && i + need < n + 1
    let mut cp = if b0 >= 0xC2 && b0 <= 0xDF {
      b0 & 0x1F
    } else if b0 >= 0xE0 && b0 <= 0xEF {
      b0 & 0x0F
    } else {
      b0 & 0x07
    }
    if ok {
      for k = 1; k <= need; k = k + 1 {
        let bx = bytes[i + k]
        if (bx & 0xC0) != 0x80 {
          ok = false
          break
        }
        cp = (cp << 6) | (bx & 0x3F)
      }
    }
    if ok && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) {
      sb.write_char(cp.unsafe_to_char())
      i = i + need + 1
    } else {
      sb.write_char(Int::unsafe_to_char(0xFFFD))
      i = i + 1
    }
  }
  sb.to_string()
}

/// Python int() over a query value: surrounding ASCII whitespace, optional
/// sign, decimal digits.
fn parse_int_strict(text : String) -> Int? {
  let bytes = @utf8.encode(text)
  let n = bytes.length()
  let is_space = fn(b : Int) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C
  }
  let mut start = 0
  while start < n && is_space(bytes[start].to_int()) {
    start = start + 1
  }
  let mut stop = n
  while stop > start && is_space(bytes[stop - 1].to_int()) {
    stop = stop - 1
  }
  if start >= stop {
    return None
  }
  let mut i = start
  let mut negative = false
  if bytes[i].to_int() == 0x2B || bytes[i].to_int() == 0x2D {
    negative = bytes[i].to_int() == 0x2D
    i = i + 1
    if i >= stop {
      return None
    }
  }
  let mut value = 0L
  let mut digits = 0
  while i < stop {
    let b = bytes[i].to_int()
    if b < 0x30 || b > 0x39 {
      return None
    }
    if value > 214748364L {
      return None
    }
    value = value * 10L + (b - 0x30).to_int64()
    if value > 2147483647L {
      return None
    }
    digits = digits + 1
    i = i + 1
  }
  if digits == 0 {
    return None
  }
  let magnitude = value.to_int()
  Some(if negative { -magnitude } else { magnitude })
}

fn lowercase_range(data : Array[Int], start : Int, end : Int) -> String {
  let sb = StringBuilder()
  for i = start; i < end; i = i + 1 {
    let b = data[i]
    sb.write_char((if b >= 0x41 && b <= 0x5A { b + 0x20 } else { b }).unsafe_to_char())
  }
  sb.to_string()
}

fn array_slice(data : Array[Int], start : Int, end : Int) -> Array[Int] {
  let out : Array[Int] = []
  let from = if start < 0 { 0 } else { start }
  let stop = if end > data.length() { data.length() } else { end }
  for i = from; i < stop; i = i + 1 {
    out.push(data[i])
  }
  out
}

// ------------------------------------------------------- request reading

/// Read one connection until the header terminator. Bodies are never consumed:
/// the response always closes the connection, so unread bytes die with it.
fn read_request(conn : Int) -> ReadOutcome {
  let data : Array[Int] = []
  let mut scanned = 0
  let mut end = -1
  while true {
    let limit = data.length() - 3
    while scanned <= limit {
      if data[scanned] == 0x0D && data[scanned + 1] == 0x0A && data[scanned + 2] == 0x0D && data[scanned + 3] == 0x0A {
        end = scanned
        break
      }
      scanned = scanned + 1
    }
    if end >= 0 {
      break
    }
    if data.length() > 131072 {
      return Rejected(431, "headers_too_large")
    }
    let buf = Bytes::new(16384)
    let n = sock_read(conn, buf)
    if n <= 0 {
      return Disconnect
    }
    for i = 0; i < n; i = i + 1 {
      data.push(buf[i].to_int())
    }
  }
  // Split the header block into lines (\n separated, trailing \r dropped).
  let lines : Array[(Int, Int)] = [] // (start, stop) over data
  let mut line_start = 0
  for i = 0; i < end; i = i + 1 {
    if data[i] == 0x0A {
      let mut stop = i
      if stop > line_start && data[stop - 1] == 0x0D {
        stop = stop - 1
      }
      lines.push((line_start, stop))
      line_start = i + 1
    }
  }
  if lines.length() > 101 {
    return Rejected(431, "headers_too_large")
  }
  if lines.is_empty() {
    return Rejected(400, "invalid_request")
  }
  // Request line: exactly three whitespace-separated words, HTTP/1.x.
  let (rl_start, rl_stop) = lines[0]
  let words : Array[(Int, Int)] = []
  let mut word_start = -1
  for i = rl_start; i < rl_stop; i = i + 1 {
    let b = data[i]
    if b == 0x20 || b == 0x09 {
      if word_start >= 0 {
        words.push((word_start, i))
        word_start = -1
      }
    } else if word_start < 0 {
      word_start = i
    }
  }
  if word_start >= 0 {
    words.push((word_start, rl_stop))
  }
  if words.length() != 3 {
    return Rejected(400, "invalid_request")
  }
  let (m_start, m_stop) = words[0]
  let verb = ascii_range(data, m_start, m_stop)
  let (t_start, t_stop) = words[1]
  let (v_start, v_stop) = words[2]
  let version = ascii_range(data, v_start, v_stop)
  if version != "HTTP/1.0" && version != "HTTP/1.1" {
    return Rejected(400, "invalid_request_version")
  }
  if t_stop - t_start > 16384 {
    return Rejected(400, "invalid_request_target")
  }
  let target : Array[Int] = []
  for i = t_start; i < t_stop; i = i + 1 {
    target.push(data[i])
  }
  // Headers: first Host wins, mirroring email.Message.get.
  let mut host : String? = None
  let mut count = 0
  for k = 1; k < lines.length(); k = k + 1 {
    let (h_start, h_stop) = lines[k]
    if h_stop == h_start {
      continue
    }
    let mut colon = -1
    for i = h_start; i < h_stop; i = i + 1 {
      if data[i] == 0x3A {
        colon = i
        break
      }
    }
    if colon <= h_start {
      return Rejected(400, "invalid_request_headers")
    }
    count = count + 1
    if count > 100 {
      return Rejected(431, "headers_too_large")
    }
    let name = lowercase_range(data, h_start, colon)
    let mut value_start = colon + 1
    let mut value_stop = h_stop
    while value_start < value_stop && (data[value_start] == 0x20 || data[value_start] == 0x09) {
      value_start = value_start + 1
    }
    while value_stop > value_start && (data[value_stop - 1] == 0x20 || data[value_stop - 1] == 0x09) {
      value_stop = value_stop - 1
    }
    if name == "host" && host is None {
      host = Some(ascii_range(data, value_start, value_stop))
    }
  }
  Ready({ verb, host, target })
}

// ------------------------------------------------------- target and query

/// Mirror urllib.parse.urlsplit as used by serve.py: any scheme or netloc,
/// or a target over 16384 bytes, is an invalid request target. Fragment is
/// dropped, path stays percent-encoded, query is kept raw.
fn split_target(target : Array[Int]) -> Target {
  if target.length() > 16384 {
    return Invalid
  }
  let n = target.length()
  let mut colon = -1
  for i = 0; i < n; i = i + 1 {
    if target[i] == 0x3A {
      colon = i
      break
    }
  }
  if colon > 0 && target[0] >= 0x41 && target[0] <= 0x7A {
    let mut scheme = true
    for j = 0; j < colon; j = j + 1 {
      if !is_scheme_char(target[j]) {
        scheme = false
        break
      }
    }
    if scheme {
      return Invalid
    }
  }
  if n >= 2 && target[0] == 0x2F && target[1] == 0x2F {
    return Invalid
  }
  let mut hash = n
  for i = 0; i < n; i = i + 1 {
    if target[i] == 0x23 {
      hash = i
      break
    }
  }
  let mut qmark = -1
  for i = 0; i < hash; i = i + 1 {
    if target[i] == 0x3F {
      qmark = i
      break
    }
  }
  let path_end = if qmark >= 0 { qmark } else { hash }
  let raw_query = if qmark >= 0 {
    array_slice(target, qmark + 1, hash)
  } else {
    []
  }
  Split(ascii_range(target, 0, path_end), raw_query)
}

/// Strict parse_qs (keep_blank_values, max 12 fields): empty or '='-less
/// fields and an excess of fields are invalid, everything decodes with
/// unquote_plus.
fn parse_query(raw : Array[Int]) -> Query {
  if raw.is_empty() {
    return Valid([])
  }
  let parts : Array[(Int, Int)] = []
  let mut part_start = 0
  for i = 0; i < raw.length(); i = i + 1 {
    if raw[i] == 0x26 {
      parts.push((part_start, i))
      part_start = i + 1
    }
  }
  parts.push((part_start, raw.length()))
  if parts.length() > 12 {
    return Invalid
  }
  let fields : Array[(String, String)] = []
  for part in parts {
    let (p_start, p_stop) = part
    let mut eq = -1
    for i = p_start; i < p_stop; i = i + 1 {
      if raw[i] == 0x3D {
        eq = i
        break
      }
    }
    if eq < 0 {
      return Invalid
    }
    fields.push((unquote_plus(raw, p_start, eq), unquote_plus(raw, eq + 1, p_stop)))
  }
  Valid(fields)
}

// --------------------------------------------------------------- routing

fn route_lookup(path : String) -> (String, String?)? {
  match path {
    "/" => Some(("render-view", None))
    "/api/status" => Some(("status", None))
    "/api/pages" => Some(("list-pages", None))
    "/api/page" => Some(("read-page", Some("id")))
    "/api/search" => Some(("search", Some("q")))
    "/api/tree" => Some(("tree", None))
    "/api/topics" => Some(("topics", None))
    "/api/lint" => Some(("lint", None))
    _ => None
  }
}

fn build_fields(
  op : String,
  parameter : String?,
  pairs : Array[(String, String)]
) -> Built {
  let fields : Map[String, Json] = Map([])
  if op == "search" {
    let allowed = ["q", "limit", "budget", "hops", "query_vector", "vector_candidates", "dedup", "spread", "provider"]
    for pair in pairs {
      let mut known = false
      for name in allowed {
        if pair.0 == name {
          known = true
        }
      }
      if !known {
        return InvalidParameter("invalid_query_parameters")
      }
    }
    for name in allowed {
      let mut occurrences = 0
      let mut value = ""
      for pair in pairs {
        if pair.0 == name {
          occurrences = occurrences + 1
          value = pair.1
        }
      }
      if occurrences > 1 {
        return InvalidParameter("invalid_query_parameters")
      }
      if occurrences == 0 {
        continue
      }
      if name == "q" {
        let mut has_vector = false
        for pair in pairs {
          if pair.0 == "query_vector" || pair.0 == "vector_candidates" {
            has_vector = true
          }
        }
        if value == "" && !has_vector {
          return InvalidParameter("invalid_query_parameters")
        }
        fields["query"] = value.to_json()
      } else if name == "limit" || name == "budget" || name == "hops" {
        match parse_int_strict(value) {
          Some(number) => fields[name] = number.to_json()
          None => return InvalidParameter("invalid_" + name)
        }
      } else if name == "query_vector" || name == "vector_candidates" {
        let mut vector : Json = Json::null()
        let mut parsed = true
        try {
          vector = @base.parse(value)
        } catch {
          @base.Fault(_) => parsed = false
        }
        if !parsed {
          return InvalidParameter("invalid_" + name)
        }
        match vector {
          Object(_) => fields[name] = vector
          _ => return InvalidParameter("invalid_" + name)
        }
      } else {
        fields[name] = value.to_json()
      }
    }
    if fields.get("query") is None {
      return InvalidParameter("invalid_query_parameters")
    }
  } else {
    match parameter {
      None => if !pairs.is_empty() {
        return InvalidParameter("invalid_query_parameters")
      }
      Some(name) => {
        if pairs.length() != 1 || pairs[0].0 != name || pairs[0].1 == "" {
          return InvalidParameter("invalid_query_parameters")
        }
        let key = if name == "q" { "query" } else { name }
        fields[key] = pairs[0].1.to_json()
      }
    }
  }
  Built(fields)
}

fn dispatch(root : String, op : String, fields : Map[String, Json], view : Bool) -> Response {
  // lint is the recovery-facing read: it must describe drift that would make
  // verify reject the vault, so it alone skips the pre-verification.
  if op != "lint" {
    try {
      let _ = web_invoke(root, "verify", Map([]))
    } catch {
      @base.Fault(message) => return json_response(409, fault_payload(message))
    }
  }
  let result = try {
    web_invoke(root, op, fields)
  } catch {
    @base.Fault(message) => return json_response(409, fault_payload(message))
  }
  if view {
    let html : Bytes? = try {
      host_read_bytes(".corridor/viewer.html")
    } catch {
      _ => None
    }
    match html {
      Some(bytes) => Response::{ status: 200, mime: "text/html; charset=utf-8", body: bytes }
      None => error_response(502, "engine_unavailable_or_invalid_response")
    }
  } else {
    json_response(200, result)
  }
}

fn route_request(root : String, bound : Int, request : ReadyRequest) -> Response {
  if request.verb == "POST" {
    return error_response(405, "read_only_service")
  }
  if request.verb != "GET" && request.verb != "HEAD" {
    return error_response(501, "unsupported_method")
  }
  match request.host {
    None => return error_response(403, "invalid_host")
    Some(host) => {
      let expected = bound.to_string()
      if host != "127.0.0.1:" + expected && host != "localhost:" + expected {
        return error_response(403, "invalid_host")
      }
    }
  }
  let (path, raw_query) = match split_target(request.target) {
    Invalid => return error_response(400, "invalid_request_target")
    Split(path, raw_query) => (path, raw_query)
  }
  let pairs = match parse_query(raw_query) {
    Invalid => return error_response(400, "invalid_query_parameters")
    Valid(pairs) => pairs
  }
  let (op, parameter) = match route_lookup(path) {
    None => return error_response(404, "not_found")
    Some(route) => route
  }
  let fields = match build_fields(op, parameter, pairs) {
    InvalidParameter(code) => return error_response(400, code)
    Built(fields) => fields
  }
  dispatch(root, op, fields, path == "/")
}


// 导出入口：host 的 accept 循环每接受一条连接调用一次；head_only=1 表示
// 客户端为 HEAD（只发头）。root 固定为 "."（preopen 根即 vault）。
pub fn web_handle_connection(conn : Int, port : Int, head_only : Int) -> Int {
  let response = match read_request(conn) {
    Disconnect => return 0
    Rejected(status, code) => error_response(status, code)
    Ready(request) => route_request(".", port, request)
  }
  send_response(conn, response, head_only == 1)
  0
}
