// Topic browsing.
//
// A5's Context index pairs material nodes with semantic nodes that organise
// them by topic into a hierarchy you can browse level by level: explore the
// topics first, locate the material, then return to the original source to
// verify a detail. Here the synthesis pages are that semantic layer and the
// entity/concept/source-summary pages are the material layer. This view lists
// the topic layer with its links and sources so a host can browse without
// reading every page, and still knows which pages are stale.

fn topic_view(store : @vault.Storage, entries : Array[@core.Entry], entry : @core.Entry) -> Json raise @base.Fault {
  let text = @vault.required(store, entry.path)
  let page = @core.parse_page(text)
  let sources = entry.sources.filter(s => entries.iter().any(e => e.id == s && e.kind == "raw" && !e.stale))
  let stale_sources = entry.sources.filter(s => !sources.contains(s))
  {
    "id": entry.id,
    "path": entry.path,
    "title": page.title,
    "kind": entry.kind,
    "stale": entry.stale,
    "sha256": entry.sha256,
    "links": page.links.to_json(),
    "sources": sources.to_json(),
    "stale_sources": stale_sources.to_json(),
    "body_bytes": @base.utf8_size(page.body),
  }
}

pub fn topics(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let rows = entries.filter(e => @core.is_page(e) && e.kind == "synthesis")
  rows.sort_by((a, b) => @base.compare(a.id, b.id))
  let views : Array[Json] = []
  let mut links = 0
  let mut stale = 0
  for entry in rows {
    if entry.stale { stale += 1 }
    let view = topic_view(store, entries, entry)
    links += @base.array(@base.field(view, "links")).length()
    views.push(view)
  }
  { "topics": views.to_json(),
    "counts": { "topics": rows.length(), "stale": stale, "links": links },
    "fingerprint": @vault.fingerprint(entries) }
}
