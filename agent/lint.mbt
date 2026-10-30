// Lint is intentionally diagnostic: it never writes the vault and it does
// not turn the first failed check into an opaque transport error.

fn lint_issue(
  predicate : String,
  subject : String,
  path : String,
  detail : String,
  fix : String,
  severity : String,
) -> Json {
  {
    "predicate": predicate,
    "subject": subject,
    "path": path,
    "detail": detail,
    "fix": fix,
    "severity": severity,
  }
}

fn lint_add(
  issues : Array[Json],
  predicate : String,
  subject : String,
  path : String,
  detail : String,
  fix : String,
  severity : String,
) -> Unit {
  issues.push(lint_issue(predicate, subject, path, detail, fix, severity))
}

fn lint_sort(issues : Array[Json]) -> Unit {
  issues.sort_by((a, b) => {
    let key = value => {
      match value {
        Object(fields) => {
          let text = key => match fields.get(key) { Some(String(value)) => value; _ => "" }
          text("predicate") + "\u0000" + text("subject") + "\u0000" + text("path") + "\u0000" + text("detail")
        }
        _ => ""
      }
    }
    @base.compare(key(a), key(b))
  })
}

fn lint_entry_shape(entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  let ids : Map[String, Bool] = Map([])
  let paths : Map[String, Bool] = Map([])
  for entry in entries {
    if ids.contains(entry.id) {
      lint_add(issues, "duplicate_entry_id", entry.id, entry.path,
        "entry id appears more than once", "remove the duplicate catalog row", "error")
    }
    if paths.contains(entry.path) {
      lint_add(issues, "duplicate_entry_path", entry.id, entry.path,
        "entry path appears more than once", "remove the duplicate catalog row", "error")
    }
    ids[entry.id] = true
    paths[entry.path] = true
    let valid_id = try { @base.path(entry.id); true } catch {
      @base.Fault(message) => {
        lint_add(issues, "entry_id_invalid", entry.id, entry.path, message,
          "use a relative stable id without traversal or separators outside the vault", "error")
        false
      }
    }
    if !valid_id { () }
    let valid_path = try { @base.path(entry.path); true } catch {
      @base.Fault(message) => {
        lint_add(issues, "entry_path_invalid", entry.id, entry.path, message,
          "use a relative vault path without traversal, absolute prefixes, or backslashes", "error")
        false
      }
    }
    if !valid_path { () }
    if entry.format.is_empty() || entry.format.length() > 64 || entry.format.contains("\n") || entry.format.contains("\r") {
      lint_add(issues, "entry_format_invalid", entry.id, entry.path,
        "format must be a non-empty single-line value of at most 64 characters",
        "set format to the registered raw extension or json/markdown page format", "error")
    }
    if entry.sha256.length() != 64 || !entry.sha256.iter().all(c =>
      (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
      lint_add(issues, "entry_hash_invalid", entry.id, entry.path,
        "sha256 must be 64 lowercase hexadecimal characters", "recompute the content hash through scan or refresh", "error")
    }
    if @core.is_page(entry) {
      if !entry.path.has_prefix("wiki/") || !entry.path.has_suffix(".md") || entry.format != "markdown" || entry.sources.is_empty() {
        lint_add(issues, "page_entry_invalid", entry.id, entry.path,
          "page entries require wiki/*.md, format markdown, and at least one source",
          "repair the page catalog row and frontmatter together", "error")
      }
    } else if entry.kind == "purpose" {
      if entry.id != "purpose.md" || entry.path != "purpose.md" || entry.format != "markdown" || !entry.sources.is_empty() || entry.stale {
        lint_add(issues, "purpose_entry_invalid", entry.id, entry.path,
          "purpose must be purpose.md, markdown, source-free, and active", "restore the canonical purpose entry", "error")
      }
    } else if entry.kind == "raw" {
      if entry.id != entry.path {
        lint_add(issues, "raw_identity_mismatch", entry.id, entry.path,
          "raw source id must equal its vault path because page sources use the path as the stable reference",
          "set id to the exact raw/ path or re-register the source with scan", "error")
      }
      if !entry.path.has_prefix("raw/") || !entry.sources.is_empty() || entry.format != @core.expected_format(entry.kind, entry.path) {
        lint_add(issues, "raw_entry_invalid", entry.id, entry.path,
          "raw entries require a raw/ path, no sources, and the format implied by the extension",
          "run scan to register the source with its byte format", "error")
      }
    } else if entry.kind == "vector" {
      if !entry.path.has_prefix("vectors/") || entry.format != "json" || !entry.sources.is_empty() {
        lint_add(issues, "vector_entry_invalid", entry.id, entry.path,
          "vector entries require vectors/, json, and no sources", "recreate vectors through embedding-submit", "error")
      }
    } else if entry.kind == "state" {
      if !entry.path.has_prefix("state/") || entry.format != "json" || !entry.sources.is_empty() {
        lint_add(issues, "state_entry_invalid", entry.id, entry.path,
          "state entries require state/, json, and no sources", "recreate the record through its owning operation", "error")
      }
    } else {
      lint_add(issues, "entry_kind_unsupported", entry.id, entry.path,
        "entry kind is not supported by the engine: " + entry.kind,
        "use purpose, raw, vector, state, entity, concept, source-summary, synthesis, or query", "error")
    }
    let seen_sources : Map[String, Bool] = Map([])
    for source in entry.sources {
      let source_ok = try { @base.path(source); true } catch {
        @base.Fault(message) => {
          lint_add(issues, "source_path_invalid", entry.id, entry.path, message,
            "use a relative raw/ source path", "error")
          false
        }
      }
      if !source_ok { () }
      if seen_sources.contains(source) {
        lint_add(issues, "source_duplicate", entry.id, entry.path,
          "source is listed more than once: " + source, "remove duplicate sources from the page", "error")
      }
      seen_sources[source] = true
    }
  }
  for entry in entries {
    if !entry.stale {
      for source in entry.sources {
        if !entries.iter().any(candidate => candidate.id == source && candidate.kind == "raw" && !candidate.stale) {
          lint_add(issues, "source_unresolved", entry.id, entry.path,
            "active entry references an unknown or stale raw source: " + source,
            "register or restore the raw source before publishing the entry", "error")
        }
      }
    }
  }
  try { @core.validate_entries(entries) } catch {
    @base.Fault(_) => ()
  }
}

fn lint_file_entries(store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  for entry in entries {
    // Shape lint owns the diagnostic; this guard only prevents a damaged path
    // from reaching a storage adapter that may reject it as an unsafe access.
    let safe_path = try { @base.path(entry.path); true } catch { _ => false }
    if !safe_path { continue }
    if entry.stale {
      if entry.kind == "raw" {
        lint_add(issues, "stale_source", entry.id, entry.path,
          "raw source is revoked or no longer present", "run scan or restore the source before publishing dependent pages", "warning")
      } else if @core.is_page(entry) {
        lint_add(issues, "stale_page", entry.id, entry.path,
          "knowledge page is invalidated", "refresh its sources and submit a new page version", "warning")
      }
    }
    if entry.kind == "raw" {
      let digest : String? = try { (store.digest)(entry.path) } catch {
        @base.Fault(message) => {
          lint_add(issues, "source_unreadable", entry.id, entry.path, message,
            "restore readable source bytes and run scan", "error")
          None
        }
      }
      if !entry.stale && digest != Some(entry.sha256) {
        lint_add(issues, "source_hash_drift", entry.id, entry.path,
          "raw file is missing or its SHA-256 differs from the catalog", "run scan and review the resulting source version", "error")
      }
      continue
    }
    let text : String? = try { (store.read)(entry.path) } catch {
      @base.Fault(message) => {
        lint_add(issues, "content_unreadable", entry.id, entry.path, message,
          "restore readable content bytes before running verify", "error")
        None
      }
    }
    match text {
      None => lint_add(issues, "content_missing", entry.id, entry.path,
        "catalog content file is missing", "restore the file or remove the catalog entry through the engine", "error")
      Some(value) => {
        if @base.hex_hash(value) != entry.sha256 {
          lint_add(issues, "content_hash_drift", entry.id, entry.path,
            "content SHA-256 differs from the catalog", "run refresh for an explicit human edit or restore the registered bytes", "error")
        }
        if @core.is_page(entry) {
          let page = try { Some(@core.parse_page(value)) } catch {
            @base.Fault(message) => {
              lint_add(issues, "page_syntax", entry.id, entry.path, message,
                "repair the Markdown frontmatter and re-run lint", "error")
              None
            }
          }
          match page {
            None => ()
            Some(parsed) => {
              if parsed.kind != entry.kind || parsed.sources != entry.sources {
                lint_add(issues, "page_metadata_drift", entry.id, entry.path,
                  "frontmatter does not match the catalog entry", "submit the page through the engine so metadata and index are compiled together", "error")
              }
              for source in parsed.sources {
                let mut raw : @core.Entry? = None
                for candidate in entries {
                  if candidate.id == source && candidate.kind == "raw" { raw = Some(candidate) }
                }
                match raw {
                  None => lint_add(issues, "page_source_missing", entry.id, entry.path,
                    "page references an unknown raw source: " + source, "register the source with scan before publishing the page", "error")
                  Some(value) => if value.stale {
                    lint_add(issues, "page_source_stale", entry.id, entry.path,
                      "page references a stale raw source: " + source, "replace the source or regenerate the page", "warning")
                  }
                }
              }
              if !entry.stale {
                for link in parsed.links {
                  if !entries.iter().any(e => e.id == link && @core.is_page(e) && !e.stale) {
                    lint_add(issues, "wikilink_unresolved", entry.id, entry.path,
                      "wikilink target is missing or stale: " + link, "create or restore the target page, then recompile the page", "error")
                  }
                }
              }
            }
          }
        }
        if entry.kind == "state" || entry.kind == "vector" {
          try { @core.validate_record(entry, value) } catch {
            @base.Fault(message) => lint_add(issues, "record_invalid", entry.id, entry.path, message,
              "repair or recreate the state/vector record through its owning operation", "error")
          }
        }
        if entry.path.has_prefix("state/evidence/") {
          try { lint_evidence_record(store, entries, value, entry, issues) } catch { _ => () }
        }
      }
    }
  }
}

// A managed file the catalog does not know about is unreachable: nothing reads,
// verifies, searches or packs it. For state/ that also means the transaction
// that wrote it skipped its upsert, so durable history is silently lost. The
// directories that are intentionally not catalog-driven are excluded: views/
// and staging/ are discovered by listing, and raw/ is reported by the inbox as
// unscanned-source because pending material is work, not damage.
fn lint_unregistered_files(
  store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json],
) -> Unit {
  let registered : Map[String, Bool] = Map([])
  for entry in entries { registered[entry.path] = true }
  let excluded = [
    "state/transactions/pending.json",
    // Engine-maintained views of the catalog, rewritten on every publish.
    "wiki/index.md", "wiki/log.md",
  ]
  for directory in ["state", "wiki", "vectors"] {
    let paths = try { (store.files)(directory) } catch { _ => [] }
    paths.sort_by(@base.compare)
    for path in paths {
      if registered.contains(path) || excluded.contains(path) { continue }
      lint_add(issues, "file_unregistered", path, path,
        "file is not registered in the catalog, so it is neither read nor verified",
        "remove the orphan file or recreate the record through its owning operation", "error")
    }
  }
}

fn lint_cache(store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json]) -> Unit {
  try { ignore(cached(store, entries)) } catch {
    @base.Fault(message) => {
      let predicate = if message == "file_missing: .corridor/fts.json" {
        "cache_missing"
      } else {
        "cache_invalid"
      }
      lint_add(issues, predicate, "", ".corridor/fts.json", message,
        "run rebuild after the catalog and content pass lint", "warning")
    }
  }
}

fn lint_evidence_record(
  store : @vault.Storage, entries : Array[@core.Entry], value : String,
  entry : @core.Entry, issues : Array[Json],
) -> Unit raise @base.Fault {
  let row = try { @base.parse(value) } catch { _ => return }
  // Superseded records remain durable history, but are not current evidence.
  match row {
    Object(fields) if fields.contains("superseded_by") => return
    _ => ()
  }
  // The record already passed validate_record, so a fault here is a
  // cross-record one: the evidence points at a page the vault can no longer
  // resolve. Swallowing it would keep durable history whose subject is gone.
  let view = try { evidence_row_view(store, entries, row) } catch {
    @base.Fault(message) => {
      lint_add(issues, "evidence_reference_unresolvable", entry.id, entry.path, message,
        "restore the referenced page and its catalog entry, or replace the evidence through the engine", "error")
      return
    }
  }
  for claim in @base.array(@base.field(view, "claims")) {
    let source = @base.text(@base.field(claim, "source"))
    let page_stale = @base.boolean(@base.field(claim, "page_stale"))
    let source_stale = @base.boolean(@base.field(claim, "source_stale"))
    if !@base.boolean(@base.field(claim, "body_quote_verified")) {
      lint_add(issues, "evidence_body_anchor_invalid", entry.id, entry.path,
        "evidence quote no longer matches the recorded UTF-8 body range",
        "submit a new evidence record for the current page version", "error")
    }
    match @base.field(claim, "source_quote_verified") {
      False => lint_add(issues, "evidence_source_anchor_invalid", entry.id, entry.path,
        "exact raw quote no longer matches the recorded UTF-8 source range: " + source,
        "replace the evidence with a current raw range or omit the exact binding", "error")
      _ => ()
    }
    if page_stale {
      lint_add(issues, "evidence_page_stale", entry.id, entry.path,
        "evidence belongs to a stale knowledge page", "regenerate the page and submit evidence for its new hash", "warning")
    }
    if source_stale {
      lint_add(issues, "evidence_source_stale", entry.id, entry.path,
        "evidence references a revoked, missing, or changed raw source: " + source,
        "restore or re-register the source, then replace the evidence", "warning")
    }
  }
}

fn lint_compile(store : @vault.Storage, issues : Array[Json]) -> Unit {
  try { (store.check)("index.mbt.md") } catch {
    @base.Fault(message) => lint_add(issues, "catalog_compile", "", "index.mbt.md", message,
      "repair the literate MoonBit block and run check-index", "error")
  }
}

pub fn lint_result(store : @vault.Storage, catalog : String?) -> Json raise @base.Fault {
  let issues : Array[Json] = []
  match catalog {
    None => lint_add(issues, "catalog_missing", "", "index.mbt.md", "file_missing: index.mbt.md",
      "initialize or restore the vault catalog", "error")
    Some(text) => {
      let entries = try { Some(@decl.parse_unchecked(text)) } catch {
        @base.Fault(message) => {
          lint_add(issues, "catalog_syntax", "", "index.mbt.md", message,
            "repair the canonical literate catalog rows", "error")
          None
        }
      }
      match entries {
        None => ()
        Some(value) => {
          lint_entry_shape(value, issues)
          lint_file_entries(store, value, issues)
          lint_memory_notes(store, value, issues)
          lint_impact_notes(store, value, issues)
          lint_unregistered_files(store, value, issues)
          lint_cache(store, value, issues)
        }
      }
      lint_compile(store, issues)
    }
  }
  lint_sort(issues)
  let stale = match catalog {
    None => Json::array([])
    Some(text) => try { @decl.parse_unchecked(text).filter(e => e.stale).to_json() } catch { _ => Json::array([]) }
  }
  let errors = issues.filter(v => @base.text(@base.field(v, "severity")) == "error").length()
  let fingerprint = match catalog {
    None => ""
    Some(text) => try { @vault.fingerprint(@decl.parse(text)) } catch { _ => "" }
  }
  {
    "status": if issues.is_empty() { "clean" } else { "issues" },
    "fingerprint": fingerprint,
    "errors": errors,
    "warnings": issues.length() - errors,
    "violations": issues.to_json(),
    "stale": stale,
  }
}
