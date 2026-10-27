extern "c" fn input_char() -> Int = "getchar"
extern "c" fn flush_all(stream : Int) -> Int = "fflush"

pub(all) struct SessionState {
  root : Ref[String?]
  held : Ref[Bool]
  catalog : Ref[String?]
}

pub fn new_session() -> SessionState {
  { root: @ref.new(None), held: @ref.new(false), catalog: @ref.new(None) }
}

pub fn line() -> String? {
  let bytes : Array[Byte] = []
  let mut too_long = false
  while true {
    let c = input_char()
    if c < 0 { if bytes.is_empty() { return None } else { break } }
    if c == 10 { break }
    if bytes.length() < 2097152 { bytes.push(c.to_byte()) } else { too_long = true }
  }
  if too_long { return Some("invalid_request_exceeds_2MiB") }
  try Some(@utf8.decode(Bytes::from_array(bytes))) catch { _ => Some("invalid_utf8_request") }
}

pub fn execute(session : SessionState, request : Json) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  ignore(@agent.tool(op))
  if op == "session-close" {
    if session.root.val is None { @base.fail("session_not_open") }
    if session.held.val { @platform.unlock() }
    session.root.val = None
    session.held.val = false
    session.catalog.val = None
    return { "closed": true }
  }
  if op == "session-open" {
    let requested = @base.text(@base.field(request, "vault"))
    match session.root.val {
      Some(current) => {
        if current != requested { @base.fail("session_already_open: " + current) }
        if !session.held.val {
          @platform.open_root(current)
          @platform.lock()
          session.held.val = true
          return { "opened": true, "upgraded": true, "vault": current }
        }
        return { "opened": false, "reused": true, "vault": current }
      }
      None => ()
    }
    @platform.open_root(requested)
    @platform.lock()
    session.root.val = Some(requested)
    session.held.val = true
    return { "opened": true, "vault": requested }
  }
  let requested_json = try @base.field(request, "vault") catch { _ => Json::null() }
  let requested = match requested_json {
    Null => None
    value => Some(@base.text(value))
  }
  let root = match session.root.val {
    Some(current) => {
      match requested {
        Some(value) if value != current => @base.fail("session_vault_mismatch")
        None if !session.held.val => @base.fail("vault_required: use session-open or provide vault")
        _ => ()
      }
      current
    }
    None => match requested {
      Some(value) => value
      None => { @base.fail("vault_required: use session-open or provide vault"); "" }
    }
  }
  let legacy = !session.held.val
  if session.root.val is None { session.root.val = Some(root) }
  if legacy { @platform.open_root(root); @platform.lock() }
  let result = try {
    if op == "init" || op == "pack" || op == "unpack" {
      for dir in ["raw", "wiki", "staging", "views", "vectors", "state/orders", "state/events", "state/reviews", "state/research", "state/suggestions", "state/overview", "state/evidence", "state/providers", "state/transactions", "state/transactions/history", ".corridor"] { @platform.mkdirs(dir) }
    }
    let store : @vault.Storage = {
      read: @platform.read, digest: @platform.digest, write: @platform.write, remove: @platform.remove,
      files: @platform.files, check: @platform.check,
      read_bytes: @platform.read_bytes, write_bytes: @platform.write_bytes,
      mkdirs: @platform.mkdirs,
    }
    let cached_catalog = match session.catalog.val {
      None => None
      Some(previous) => match @platform.read("index.mbt.md") {
        Some(current) if current == previous => Some(previous)
        _ => None
      }
    }
    let value = @agent.dispatch_with_catalog(store, request, cached_catalog)
    match @platform.read("index.mbt.md") {
      Some(current) => session.catalog.val = Some(current)
      None => session.catalog.val = None
    }
    value
  } catch {
    @base.Fault(message) => {
      if legacy { @platform.unlock() }
      raise @base.Fault(message)
    }
  }
  if legacy { @platform.unlock() }
  result
}

pub fn emit(value : Json) -> Unit {
  println(@base.canonical(value))
  let _ = flush_all(0)
}
