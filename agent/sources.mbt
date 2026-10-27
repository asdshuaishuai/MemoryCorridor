// Reading original sources.
//
// A5's agent "returns to the original sources to verify details", and its Diff
// Engine "consults the original source when necessary". The engine registers,
// hashes and cites raw sources, and evidence binds claims to raw byte ranges,
// but until now it never served the bytes: a host had to read the file off disk
// and could not tell whether what it read was what the catalog registered.
//
// This closes that loop with a read-only view that reports the registered
// metadata, whether the digest still matches, and the content itself — with an
// optional byte range so an evidence anchor can be checked exactly.

// Bounded like every other text the engine returns, so one huge source cannot
// turn a read into a transfer. The cap counts UTF-8 bytes, matching `bytes`.
const SOURCE_READ_LIMIT : Int = 65536

fn source_capped(text : String, total : Int) -> String {
  if total <= SOURCE_READ_LIMIT { return text }
  // A byte cap can land inside a character, so step back to a boundary. UTF-8
  // characters are at most four bytes, so this settles immediately.
  let mut stop = SOURCE_READ_LIMIT
  while stop > 0 {
    let sliced = try { Some(@base.utf8_slice(text, 0, stop)) } catch { _ => None }
    match sliced {
      Some(value) => return value
      None => stop -= 1
    }
  }
  ""
}

fn source_bound(value : Json, field : String) -> Int raise @base.Fault {
  match value {
    Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()
    _ => raise @base.Fault("source_range_invalid: " + field)
  }
}

pub fn read_source(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  @base.path(id)
  let entry = @core.find(entries, id)
  if entry.kind != "raw" { @base.fail("expected_raw_source") }
  let textual = entry.format != "binary" && entry.format != "image"
  let bytes = (store.read_bytes)(entry.path)
  let digest = (store.digest)(entry.path)
  // A revoked source keeps its tombstone entry, so a read reports the state
  // rather than pretending the bytes are still the registered ones.
  let verified = digest == Some(entry.sha256)
  let base : Json = {
    "id": entry.id,
    "path": entry.path,
    "format": entry.format,
    "stale": entry.stale,
    "verified": verified,
    "registered_sha256": entry.sha256,
    "textual": textual,
    "extraction_required": !textual,
    "present": bytes is Some(_),
  }
  if !textual {
    return match base {
      Object(fields) => {
        // `extraction_required` is the specific signal here; a generic
        // `execution` would imply the host still owes the engine an action.
        fields["bytes"] = match bytes { Some(data) => data.length().to_json(); None => Json::null() }
        fields["text"] = Json::null()
        Json::object(fields)
      }
      other => other
    }
  }
  let text = match (store.read)(entry.path) {
    Some(value) => value
    None => return match base {
      Object(fields) => {
        fields["bytes"] = Json::null()
        fields["text"] = Json::null()
        Json::object(fields)
      }
      other => other
    }
  }
  let total = @base.utf8_size(text)
  let has_start = optional(request, "start") is Some(_)
  let has_end = optional(request, "end") is Some(_)
  let start = if has_start { source_bound(@base.field(request, "start"), "start") } else { 0 }
  let stop = if has_end { source_bound(@base.field(request, "end"), "end") } else { total }
  if has_start || has_end {
    if stop <= start || stop > total { @base.fail("source_range_invalid: 0 <= start < end <= " + total.to_string()) }
  }
  // A bounded read is exact; a whole-source read is capped and says so.
  let window = if has_start || has_end {
    @base.utf8_slice(text, start, stop)
  } else { source_capped(text, total) }
  match base {
    Object(fields) => {
      fields["bytes"] = total.to_json()
      fields["text"] = window.to_json()
      fields["truncated"] = (if has_start || has_end { false } else { total > SOURCE_READ_LIMIT }).to_json()
      fields["range"] = if has_start || has_end {
        { "start": start, "end": stop }
      } else {
        { "start": 0, "end": @base.utf8_size(window) }
      }
      Json::object(fields)
    }
    other => other
  }
}
