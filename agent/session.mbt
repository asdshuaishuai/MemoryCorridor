pub fn initialize(store : @vault.Storage, purpose : String) -> Json raise @base.Fault {
  if (store.read)("index.mbt.md") is Some(_) { @base.fail("vault_already_initialized") }
  if !(store.files)("wiki").is_empty() || !(store.files)("state").is_empty() {
    @base.fail("init_refused: existing wiki/state files; will not overwrite")
  }
  let content = (store.read)("purpose.md").unwrap_or(purpose + "\n")
  let entry : @core.Entry = { id: "purpose.md", path: "purpose.md", kind: "purpose", format: "markdown", sha256: @base.hex_hash(content), sources: [], stale: false }
  let entries = [entry]
  let catalog = @decl.generate(entries)
  (store.write)(".corridor/candidate.mbt.md", catalog)
  (store.check)(".corridor/candidate.mbt.md")
  if (store.read)("purpose.md") is None { (store.write)("purpose.md", content) }
  (store.write)("index.mbt.md", catalog)
  (store.write)(".corridor/last-valid.mbt.md", catalog)
  write_compile_receipt(store, catalog, @vault.fingerprint(entries))
  { "fingerprint": @vault.fingerprint(entries), "format": "corridor-catalog-v1" }
}

// The runtime parser intentionally reads only the closed catalog IR from the
// first checked block.  The compiler, however, owns every `mbt` block in the
// literate document.  Keep a content-addressed receipt so an auxiliary block
// cannot be changed around the parser and become active without a successful
// MoonBit check.  The receipt is cache state and is rebuilt when absent,
// corrupt, or based on different catalog text/IR.
fn write_compile_receipt(store : @vault.Storage, catalog : String, fingerprint : String) -> Unit raise @base.Fault {
  let receipt : Json = {
    "version": 1,
    "source_sha256": @base.hex_hash(catalog),
    "fingerprint": fingerprint,
    "compiled": true,
  }
  (store.write)(".corridor/catalog-compile.json", @base.canonical(receipt))
}

fn ensure_catalog_compiled(store : @vault.Storage, entries : Array[@core.Entry]) -> Unit raise @base.Fault {
  let catalog = @vault.required(store, "index.mbt.md")
  let fingerprint = @vault.fingerprint(entries)
  let receipt_ok = try {
    let value = @base.parse(@vault.required(store, ".corridor/catalog-compile.json"))
    @base.keys(value, ["version", "source_sha256", "fingerprint", "compiled"])
    @base.field(value, "version") == Json::number(1.0) &&
      @base.boolean(@base.field(value, "compiled")) &&
      @base.text(@base.field(value, "source_sha256")) == @base.hex_hash(catalog) &&
      @base.text(@base.field(value, "fingerprint")) == fingerprint
  } catch {
    _ => false
  }
  if receipt_ok { return }
  // Compile exactly the bytes whose hash will be recorded, then detect an
  // external edit that raced the compiler before publishing the receipt.
  (store.check)("index.mbt.md")
  if @vault.required(store, "index.mbt.md") != catalog { @base.fail("catalog_compile_race") }
  write_compile_receipt(store, catalog, fingerprint)
}

pub fn rebuild(store : @vault.Storage, entries : Array[@core.Entry]) -> @index.TextIndex raise @base.Fault {
  ensure_catalog_compiled(store, entries)
  @vault.verify(store, entries)
  let catalog = @decl.generate_preserving(@vault.required(store, "index.mbt.md"), entries)
  (store.write)(".corridor/last-valid.mbt.md", catalog)
  let documents : Array[@index.Document] = []
  for entry in entries {
    if @core.is_page(entry) && !entry.stale {
      documents.push(@index.document(entry, @vault.required(store, entry.path)))
    }
  }
  documents.sort_by((a,b) => @base.compare(a.id, b.id))
  let text_index = @index.build_index(documents)
  let payload : Json = { "version": 3, "algorithm": "text-index-v3", "fingerprint": @vault.fingerprint(entries), "index": text_index.to_json() }
  let canonical = @base.canonical(payload)
  let envelope : Json = { "sha256": @base.hex_hash(canonical), "payload": payload }
  (store.write)(".corridor/fts.json", @base.canonical(envelope))
  text_index
}

fn cached(store : @vault.Storage, entries : Array[@core.Entry]) -> @index.TextIndex raise @base.Fault {
  let text = @vault.required(store, ".corridor/fts.json")
  let value = @base.parse(text)
  let payload = @base.field(value, "payload")
  if @base.field(payload, "version") != Json::number(3.0) || @base.field(payload, "algorithm") != "text-index-v3".to_json() { @base.fail("index_algorithm_changed") }
  if @base.text(@base.field(value, "sha256")) != @base.hex_hash(@base.canonical(payload)) ||
    @base.text(@base.field(payload, "fingerprint")) != @vault.fingerprint(entries) {
    @base.fail("index_corrupt_or_stale")
  }
  let index_json = @base.field(payload, "index")
  let docs = @base.array(@base.field(index_json, "documents")).map(v => @index.from_json(v))
  let expected = entries.filter(e => @core.is_page(e) && !e.stale)
  if docs.length() != expected.length() { @base.fail("index_document_count_mismatch") }
  let seen : Map[String, Bool] = Map([])
  for doc in docs {
    if seen.contains(doc.id) { @base.fail("index_duplicate_document") }
    seen[doc.id] = true
    let entry = @core.find(expected, doc.id)
    let actual = @index.document(entry, @vault.required(store, entry.path))
    if doc.to_json() != actual.to_json() { @base.fail("index_document_corrupt: " + doc.id) }
  }
  let text_index = @index.build_index(docs)
  if text_index.to_json() != index_json { @base.fail("index_postings_corrupt") }
  text_index
}

fn status_result(store : @vault.Storage, entries : Array[@core.Entry], fingerprint : String) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let cache = try { ignore(cached(store, entries)); "valid" } catch { _ => "missing_or_invalid" }
  // This op already verified once; the aggregators below must not each re-hash
  // every file in the vault.
  let reviews = review_rows_unchecked(store, entries)
  let research = research_rows_unchecked(store, entries)
  let suggestions = suggestion_rows_unchecked(store, entries)
  let overview_state = overview_status_unchecked(store, entries)
  let evidence = evidence_stats_unchecked(store, entries)
  let providers = provider_entries_unchecked(store, entries)
  let provider_jobs = provider_job_rows_unchecked(store, entries)
  {
    "fingerprint": fingerprint,
    "validation": if cache == "valid" { "valid" } else { "cache_missing_or_invalid" },
    "index_cache": cache,
    "pages": entries.iter().filter(e => @core.is_page(e)).count(),
    "sources": entries.iter().filter(e => e.kind == "raw").count(),
    "active_sources": entries.iter().filter(e => e.kind == "raw" && !e.stale).count(),
    "stale_pages": entries.iter().filter(e => @core.is_page(e) && e.stale).count(),
    "pending_reviews": reviews.filter(r => optional(r, "status") == Some("pending".to_json())).length(),
    "review_debt": review_counts(reviews),
    "pending_research": research.filter(r => optional(r, "status") == Some("proposed".to_json())).length(),
    "pending_suggestions": suggestions.filter(r => optional(r, "status") == Some("proposed".to_json())).length(),
    "overview_status": overview_state,
    "evidence": evidence,
    "memory": memory_summary(store, entries),
    "impacts": impact_summary(store, entries),
    "providers": { "total": providers.length(), "active": providers.filter(r => optional(r, "status") == Some("active".to_json())).length(),
      "revoked": providers.filter(r => optional(r, "status") == Some("revoked".to_json())).length() },
    "provider_jobs": { "total": provider_jobs.length(), "pending": provider_jobs.filter(r => optional(r, "status") == Some("pending".to_json())).length(),
      "completed": provider_jobs.filter(r => optional(r, "status") == Some("completed".to_json())).length(),
      "cancelled": provider_jobs.filter(r => optional(r, "status") == Some("cancelled".to_json())).length(),
      "failed": provider_jobs.filter(r => optional(r, "status") == Some("failed".to_json())).length() },
    "orders": orders(store, entries).to_json(),
  }
}

pub fn dispatch(store : @vault.Storage, request : Json) -> Json raise @base.Fault {
  dispatch_with_catalog(store, request, None)
}

// A native process session may pass the exact catalog text it already parsed.
// Recovery still forces a fresh read; callers that cannot prove the text is
// current should pass None and retain the normal one-shot behavior.
pub fn dispatch_with_catalog(
  store : @vault.Storage, request : Json, cached_catalog : String?,
) -> Json raise @base.Fault {
  let op = @base.text(@base.field(request, "op"))
  let t = tool(op)
  // `progress` is a transport hint shared by every operation. It never
  // enters operation state or deterministic vault fingerprints.
  @base.keys(request, ["op", "vault", "request_id", "progress"] + t.fields)
  match request {
    Object(fields) => match fields.get("progress") {
      Some(value) => ignore(@base.boolean(value))
      None => ()
    }
    _ => ()
  }
  let arg = key => @base.field(request, key)
  let string = key => @base.text(arg(key))
  if op == "help" || op == "list-tools" { return describe_tools() }
  if op == "init" {
    let value = match request { Object(fields) => fields.get("purpose"); _ => None }
    let purpose = match value { None => "知识目标待填写"; Some(v) => @base.text(v) }
    return initialize(store, purpose)
  }
  let restored = @vault.recover_unpack(store)
  if op == "unpack" { return unpack_vault(store, request) }
  let recovered = @vault.recover(store) || restored
  if op == "recover" { return { "recovered": recovered } }
  if op == "read-last-valid" {
    let previous = @decl.parse(@vault.required(store, ".corridor/last-valid.mbt.md"))
    @vault.verify(store, previous)
    return { "catalog_status": "last_valid_snapshot", "read_only": true, "fingerprint": @vault.fingerprint(previous),
      "entries": previous.to_json(), "pages": previous.filter(e => @core.is_page(e)).map(e => {
        let value : Json = { "entry": e.to_json(), "text": @vault.required(store, e.path) }
        value
      }).to_json() }
  }
  // Lint is deliberately allowed to inspect a damaged catalog.  Do this
  // before the normal load/verify path so callers receive a stable report
  // instead of only the first parsing fault.
  if op == "lint" {
    let catalog = match cached_catalog {
      Some(value) if !recovered => Some(value)
      _ => (store.read)("index.mbt.md")
    }
    return lint_result(store, catalog)
  }
  let entries = match cached_catalog {
    Some(catalog) if !recovered => @decl.parse(catalog)
    _ => @vault.load(store)
  }
  ensure_catalog_compiled(store, entries)
  let fingerprint = @vault.fingerprint(entries)
  match op {
    "embedding-plan" => embedding_plan(store, entries, request)
    "import" => import_bundle(store, entries, request)
    "export" => export_vault(store, entries, request)
    "pack" => pack_vault(store, entries, request)
    "stats" | "fingerprints" | "read-log" | "review-list" | "review-resolve" | "quality-audit" | "research-list" | "research-topic" | "research-complete" | "research-cancel" | "purpose-suggest" | "purpose-apply" | "purpose-cancel" | "suggestion-list" | "overview-suggest" | "overview-apply" | "overview-cancel" | "overview-list" | "backfill" | "provider-register" | "provider-heartbeat" | "provider-unregister" | "provider-list" | "provider-job-open" | "provider-job-claim" | "provider-job-heartbeat" | "provider-job-complete" | "provider-job-cancel" | "provider-job-fail" | "provider-job-list" => maintenance(store, entries, request)
    "evidence-submit" => evidence_submit(store, entries, request)
    "evidence-replace" => evidence_replace(store, entries, request)
    "evidence-list" => evidence_list(store, entries, request)
    "memory-submit" => memory_submit(store, entries, request)
    "memory-supersede" => memory_supersede(store, entries, request)
    "memory-archive" => memory_archive(store, entries, request)
    "memory-restore" => memory_restore(store, entries, request)
    "memory-list" => memory_list(store, entries)
    "memory-read" => memory_read(store, entries, request)
    "memory-pin" => memory_protect(store, entries, request)
    "memory-use" => memory_use(store, entries, request)
    "memory-prefetch" => memory_prefetch(store, entries, request)
    "memory-conflicts" => memory_conflicts(store, entries)
    "memory-candidates" => memory_candidates(store, entries)
    "impact-audit" => impact_audit(store, entries, request)
    "impact-list" => impact_list(store, entries)
    "impact-resolve" => impact_resolve(store, entries, request)
    "inbox" => inbox(store, entries)
    "view-init" | "render-view" => visual(store, entries, request)
    "tree" | "graph" | "neighbors" | "path" | "weighted-path" | "insights" => explore(store, entries, request)
    "topics" => topics(store, entries)
    "scan" => scan(store, entries)
    "refresh" => {
      let result = scan(store, entries, adopt_pages=true)
      ignore(rebuild(store, @vault.load(store)))
      result
    }
    "plan" => {
      @vault.verify(store, entries)
      orders(store, entries).filter(o => o.phase != "committed" && o.phase != "cancelled").to_json()
    }
    "context" => { @vault.verify(store, entries); context(store, entries, string("order")) }
    "analysis-submit" => { @vault.verify(store, entries); guard_context(store, entries, request); submit_analysis(store, entries, string("order"), arg("analysis")) }
    "draft-submit" => submit_drafts(store, entries, request)
    "commit" => { guard_context(store, entries, request); commit_pages(store, entries, string("order"), arg("pages"), string("at")) }
    "cancel" => {
      @vault.verify(store, entries)
      let order = load_order(store, string("order"))
      if order.phase == "committed" { @base.fail("order_already_committed") }
      if order.phase != "cancelled" { save_order(store, entries, { ..order, phase: "cancelled" }) }
      { "order": order.id, "phase": "cancelled" }
    }
    "forget" => forget(store, entries, string("source"), string("at"))
    "archive-page" => archive_page(store, entries, request)
    "restore-page" => restore_page(store, entries, request)
    "embedding-submit" => submit_embeddings(store, entries, arg("space"), arg("items"), try arg("provider") catch { _ => Json::null() })
    "read-index" => @vault.required(store, "index.mbt.md").to_json()
    "read-purpose" => @vault.required(store, "purpose.md").to_json()
    "read-source" => read_source(store, entries, request)
    "status" => status_result(store, entries, fingerprint)
    "list-pages" => {
      // A derived read, not a raw byte reader: it must refuse a vault whose
      // state no longer matches the catalog, exactly like status/topics/tree.
      @vault.verify(store, entries)
      entries.filter(e => @core.is_page(e)).to_json()
    }
    "page-history" => page_history(store, entries, request)
    "read-page" => {
      @vault.verify(store, entries)
      let entry = @core.find(entries, string("id"))
      if !@core.is_page(entry) { @base.fail("not_a_page") }
      let text = @vault.required(store, entry.path)
      if @base.hex_hash(text) != entry.sha256 { @base.fail("page_changed") }
      { "entry": entry.to_json(), "text": text, "stale": entry.stale,
        "evidence": evidence_for_page_checked(store, entries, entry.id) }
    }
    "check-index" => {
      @vault.verify(store, entries)
      ensure_catalog_compiled(store, entries)
      { "fingerprint": fingerprint, "compiled": true }
    }
    "verify" => {
      @vault.verify(store, entries)
      let cache = try { ignore(cached(store, entries)); "valid" } catch { _ => "missing_or_invalid" }
      if cache == "missing_or_invalid" { @base.fail("index_missing_or_invalid: run rebuild") }
      { "fingerprint": fingerprint, "cache": cache, "violations": Json::array([]) }
    }
    "lint" => raise @base.Fault("internal_lint_dispatch")
    "rebuild" => { "documents": rebuild(store, entries).documents.length(), "fingerprint": fingerprint }
    "search" => {
      @vault.verify(store, entries)
      let mut rebuilt = false
      let docs = try cached(store, entries) catch {
        _ => { rebuilt = true; rebuild(store, entries) }
      }
      let limit = try {
        match arg("limit") {
          Number(n, ..) if n >= 1.0 && n <= 100.0 && n == n.to_int().to_double() => n.to_int()
          _ => raise @base.Fault("invalid_limit: integer 1..100")
        }
      } catch {
        @base.Fault(message) => if message.has_prefix("missing_field:") { 10 } else { raise @base.Fault(message) }
      }
      let query_vector = try arg("query_vector") catch { _ => Json::null() }
      let vector_candidates = try arg("vector_candidates") catch { _ => Json::null() }
      let provider = try arg("provider") catch { _ => Json::null() }
      let result = hybrid_search(store, entries, docs, string("query"), limit, query_vector, vector_candidates, provider)
      match result {
        Object(fields) => {
          fields["fingerprint"] = fingerprint.to_json()
          fields["cache_rebuilt"] = rebuilt.to_json()
          fields["context"] = assemble(store, entries, result, request)
          Json::object(fields)
        }
        _ => raise @base.Fault("internal_search_result")
      }
    }
    _ => raise @base.Fault("operation_not_implemented: " + op)
  }
}
