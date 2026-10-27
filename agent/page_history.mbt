// Page version history.
//
// A5's Workspace Wiki keeps source citations and version history on each page
// "so users can read, verify, and correct them". The engine already records a
// hash on every archive and restore, and a commit now records the hash of every
// page it published, so a page's whole lifecycle is recoverable from the event
// log without storing a second copy of any content.

priv struct PageVersion {
  at : String
  op : String
  page_hash : String
  detail : String
  event : String
}

fn page_version_view(row : PageVersion) -> Json {
  { "at": row.at, "op": row.op, "page_hash": row.page_hash,
    "detail": row.detail, "event": row.event }
}

// Events are content addressed, so their file order is not time order. Sorting
// by the caller-supplied timestamp keeps the history readable while staying
// deterministic for a fixed vault.
fn page_version_sort(rows : Array[PageVersion]) -> Unit {
  rows.sort_by((a, b) => {
    let key = (row : PageVersion) => row.at + "\u0000" + row.op + "\u0000" + row.event
    @base.compare(key(a), key(b))
  })
}

fn event_text(value : Json, key : String) -> String {
  match optional(value, key) {
    Some(String(text)) => text
    _ => ""
  }
}

pub fn page_history(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let id = @base.text(@base.field(request, "id"))
  @base.path(id)
  let entry = @core.find(entries, id)
  if !@core.is_page(entry) { @base.fail("not_a_page") }
  let events = entries.filter(e => e.kind == "state" && e.path.has_prefix("state/events/"))
  events.sort_by((a, b) => @base.compare(a.id, b.id))
  let versions : Array[PageVersion] = []
  for e in events {
    let row = @base.parse(@vault.required(store, e.path))
    let op = event_text(row, "op")
    let at = event_text(row, "at")
    if op == "ingest" {
      // A commit only concerns this page when it published it.
      match optional(row, "pages") {
        Some(Object(hashes)) => match hashes.get(id) {
          Some(hash) => versions.push({ at, op: "commit", page_hash: @base.text(hash),
            detail: "published from " + event_text(row, "source"), event: e.path })
          None => ()
        }
        _ => ()
      }
    } else if op == "page-archive" && event_text(row, "page") == id {
      versions.push({ at, op: "archive", page_hash: event_text(row, "page_hash"),
        detail: event_text(row, "reason"), event: e.path })
    } else if op == "page-restore" && event_text(row, "page") == id {
      versions.push({ at, op: "restore", page_hash: event_text(row, "page_hash"),
        detail: "restored after " + event_text(row, "archive"), event: e.path })
    } else if op == "forget" {
      // A revoked source invalidates the page, which is part of its history.
      let invalidated = @base.strings(@base.field(row, "invalidated"))
      if invalidated.contains(id) {
        versions.push({ at, op: "invalidate", page_hash: "",
          detail: "source revoked: " + event_text(row, "source"), event: e.path })
      }
    }
  }
  page_version_sort(versions)
  let commits = versions.filter(v => v.op == "commit").length()
  {
    "id": id,
    "current": { "path": entry.path, "kind": entry.kind, "sha256": entry.sha256,
      "stale": entry.stale, "sources": entry.sources.to_json() },
    "versions": versions.map(page_version_view).to_json(),
    "counts": { "versions": versions.length(), "commits": commits },
    "fingerprint": @vault.fingerprint(entries),
  }
}
