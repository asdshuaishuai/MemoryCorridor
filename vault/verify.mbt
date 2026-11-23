// Verification memo. A native process may serve many requests against the same
// vault (the CLI reads one request per line; the MCP server and the emotional
// daemon keep sessions open). Re-reading and re-hashing every cataloged file on
// every request is correct but makes a large catalog unusable, so unchanged
// files are trusted only while their change signal and catalog hash both match
// what was verified earlier in this process.
//
// The memo is memory-only, is never written to disk, and never becomes a
// source of truth: a changed signal forces a full read, `verify` without a
// signal reads everything, and a memo entry may only answer for the exact
// SHA-256 the catalog records. The differential test suite pins every reuse
// and discard rule, including edits that restore mtime (ctime still moves) and
// symlink swaps (the signal reports a non-regular file).

pub(all) struct VerifiedFile {
  sha256 : String
  signature : String
  // Links a page declared when its structure was validated. A page may be
  // reused only while every link still resolves to an active page, which is
  // the only part of `validate_page` that depends on the rest of the catalog.
  // Records keep this empty: their shape is self-contained.
  page_links : Array[String]
}

pub(all) struct VerifyMemo {
  files : Map[String, VerifiedFile]
  mut catalog_text : String?
  mut catalog_entries : Array[@core.Entry]?
  mut catalog_fingerprint : String?
}

pub fn VerifyMemo::new() -> VerifyMemo {
  { files: Map([]), catalog_text: None, catalog_entries: None, catalog_fingerprint: None }
}

// Parsed catalog and fingerprint, reused while the exact catalog text is
// unchanged. Parsing and fingerprinting are pure functions of that text, so a
// hit cannot go stale: any edit changes the text, and any catalog change makes
// the next lookup miss.
pub fn catalog_memo(store : Storage, text : String) -> (Array[@core.Entry], String) raise @base.Fault {
  match store.memo.catalog_text {
    Some(cached) if cached == text => match store.memo.catalog_entries {
      Some(entries) => match store.memo.catalog_fingerprint {
        Some(fingerprint) => return (entries, fingerprint)
        None => ()
      }
      None => ()
    }
    _ => ()
  }
  let entries = @decl.parse(text)
  let fingerprint = fingerprint(entries)
  store.memo.catalog_text = Some(text)
  store.memo.catalog_entries = Some(entries)
  store.memo.catalog_fingerprint = Some(fingerprint)
  (entries, fingerprint)
}

pub fn verify(store : Storage, entries : Array[@core.Entry]) -> Unit raise @base.Fault {
  verify_rows(store, entries, true)
}

// Explicit audit: every file is read and hashed even when this process verified
// it moments ago. The `verify` and `rebuild` operations use this.
pub fn verify_full(store : Storage, entries : Array[@core.Entry]) -> Unit raise @base.Fault {
  verify_rows(store, entries, false)
}

// A page's links must resolve to active pages, so its structural validation is
// reusable only while that set is unchanged. Records are self-contained.
fn verify_rows(store : Storage, entries : Array[@core.Entry], reuse : Bool) -> Unit raise @base.Fault {
  @core.validate_entries(entries)
  let active : Map[String, Bool] = Map([])
  for e in entries {
    if @core.is_page(e) && !e.stale { active[e.id] = true }
  }
  for e in entries {
    if e.kind == "raw" && e.stale { continue }
    verify_entry(store, e, entries, active, reuse)
  }
}

fn verify_entry(
  store : Storage, e : @core.Entry, entries : Array[@core.Entry],
  active : Map[String, Bool], reuse : Bool,
) -> Unit raise @base.Fault {
  let page = @core.is_page(e)
  if reuse && reusable(store, e, page, active) { return }
  // Sampled before and after the read: a file edited while it is being verified
  // must not be memoized under its new signal with the old bytes.
  let before = (store.stat)(e.path)
  let mut links : Array[String] = []
  if e.kind == "raw" {
    if (store.digest)(e.path) != Some(e.sha256) {
      @base.fail("source_missing_or_changed: " + e.path + "; run scan")
    }
  } else {
    let text = required(store, e.path)
    if @base.hex_hash(text) != e.sha256 {
      @base.fail("content_changed: " + e.path + "; rescan sources or submit explicit page edit")
    }
    if page {
      links = (@core.validate_page(e, text, entries)).links
    } else if e.kind == "state" || e.kind == "vector" {
      @core.validate_record(e, text)
    }
  }
  let after = (store.stat)(e.path)
  match (before, after) {
    (Some(first), Some(second)) if first == second =>
      store.memo.files[e.path] = { sha256: e.sha256, signature: second, page_links: links }
    _ => ()
  }
}

fn reusable(
  store : Storage, e : @core.Entry, page : Bool, active : Map[String, Bool],
) -> Bool raise @base.Fault {
  match (store.stat)(e.path) {
    None => false
    Some(signature) => match store.memo.files.get(e.path) {
      Some(file) =>
        file.signature == signature && file.sha256 == e.sha256 &&
        (!page || file.page_links.iter().all(id => active.get(id).unwrap_or(false)))
      None => false
    }
  }
}
