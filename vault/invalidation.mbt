pub fn invalidate_dependents(store : Storage, entries : Array[@core.Entry]) -> Array[@core.Entry] raise @base.Fault {
  let mut next = entries.copy()
  let mut changed = true
  while changed {
    changed = false
    let before = next
    let after : Array[@core.Entry] = []
    for entry in before {
      if !@core.is_page(entry) || entry.stale { after.push(entry); continue }
      let page = @core.parse_page(required(store, entry.path))
      let missing_source = entry.sources.iter().any(s => !before.iter().any(e => e.id == s && e.kind == "raw" && !e.stale))
      let stale_link = page.links.iter().any(id => before.iter().any(e => e.id == id && e.stale))
      if missing_source || stale_link {
        after.push({ ..entry, stale: true })
        changed = true
      } else { after.push(entry) }
    }
    next = after
  }
  next
}
