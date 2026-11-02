// Host-side extraction sidecars.
//
// OCR and PDF text extraction are model abilities that live outside the engine
// (AGENTS.md: MoonBit core must not call a model or the network). This module is
// the intake channel for those results: the host runs its own extractor, then
// submits the text here. A sidecar is bound to the exact registered bytes it was
// extracted from, so it stops applying the moment those bytes change or the
// source is revoked. Nothing in this file calls out to a model.

// The sidecar for a given source digest, but only through the catalog: a
// host-dropped file at that path is not a registered entry and must never be
// read as text. Returns the parsed record, or None when no sidecar is registered.
pub fn sidecar_for(
  store : @vault.Storage, entries : Array[@core.Entry], source_sha256 : String,
) -> Json? raise @base.Fault {
  let path = "state/extractions/" + source_sha256 + ".json"
  match entries.iter().find_first(e => e.path == path) {
    None => None
    Some(entry) => Some(@base.parse(@vault.required(store, entry.path)))
  }
}

pub fn extraction_submit(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  let source = @base.text(@base.field(request, "source"))
  @base.path(source)
  let kind = @base.text(@base.field(request, "kind"))
  let extractor = @base.text(@base.field(request, "extractor"))
  let version = @base.text(@base.field(request, "version"))
  let submitted = @base.text(@base.field(request, "text"))
  let at = @base.text(@base.field(request, "at"))

  // Only an active, non-textual raw source can carry a sidecar. A registered
  // raw entry's id is its `raw/...` path (`validate_entries`), so the kind
  // check subsumes the prefix test; `expected_raw_source` reads like the
  // sibling byte-channel guard in `read_source`. Textual sources already serve
  // their own bytes through `context`, and OOXML originals get the engine's own
  // deterministic extraction (续十一) -- that channel cannot be overridden by
  // an external result, hence the distinct `extraction_override`.
  let raw = @core.find(entries, source)
  if raw.kind != "raw" { @base.fail("expected_raw_source") }
  if raw.stale { @base.fail("extraction_source_stale") }
  if @office.is_office_format(raw.format) { @base.fail("extraction_override") }
  if raw.format != "binary" && raw.format != "image" { @base.fail("extraction_source_textual") }

  // Defense in depth: `verify` already refuses a drifted active raw with
  // `source_missing_or_changed` before this line, so this branch only fires if
  // that earlier gate were ever bypassed. The decisive bindings are the record's
  // filename/content mutual lock (validate_record) and the context lookup by the
  // current digest -- `mutation_check.py` targets those, not this shadowed line.
  if (store.digest)(source) != Some(raw.sha256) { @base.fail("source_changed") }

  // The source digest is the sidecar's identity: the filename hash and the
  // content `source_sha256` are both this value, so the record cannot be renamed
  // onto different bytes and a retried submission replays instead of forking.
  let source_sha256 = raw.sha256
  let path = "state/extractions/" + source_sha256 + ".json"
  let record : Json = { "source": source, "source_sha256": source_sha256, "kind": kind,
    "extractor": extractor, "version": version, "text": submitted, "submitted_at": at }
  let content = @base.canonical(record)
  let record_entry : @core.Entry = { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }
  // Reject a malformed submission through the single-source-of-truth validator
  // before any event is built, so the stable `extraction_*` codes come from the
  // same table that verifies the record on every later read.
  @core.validate_record(record_entry, content)

  match entries.iter().find_first(e => e.path == path) {
    Some(existing) => {
      let stored = @base.parse(@vault.required(store, existing.path))
      let stored_extractor = @base.text(@base.field(stored, "extractor"))
      let stored_version = @base.text(@base.field(stored, "version"))
      // A different extractor or version is not a replay and must not overwrite
      // the current one. The lifecycle is deliberately one-way per digest: the
      // only recovery is replacing the source bytes (scan refuses to re-register
      // identical bytes over a revoked entry -- orders.mbt's tombstone rule), so
      // forget + rescan of the same bytes stays refused here, and the host books
      // against the new digest instead.
      if stored_extractor != extractor || stored_version != version {
        @base.fail("extraction_exists: " + stored_extractor + ":" + stored_version)
      }
      // Same (source_sha256, extractor, version): verbatim text replays,
      // anything else is a conflict -- never a silent replacement.
      if @base.text(@base.field(stored, "text")) != submitted {
        @base.fail("extraction_conflict")
      }
      // Echo the *record's* source, not the requesting path: under twin
      // sources the replay key matches by digest, and misattributing the
      // sidecar to this path would contradict what the record books (续十六 B-C).
      return { "source": @base.text(@base.field(stored, "source")), "path": path,
        "source_sha256": source_sha256,
        "kind": @base.text(@base.field(stored, "kind")), "extractor": extractor,
        "version": version, "replayed": true, "event": Json::null(),
        "fingerprint": @vault.fingerprint(entries) }
    }
    None => ()
  }

  // A real submission records one event bound to the same source digest, so a
  // replayed submission above never writes a second event.
  let event_path = "state/events/extraction-submit-" + source_sha256 + ".json"
  if (store.read)(event_path) is Some(_) { @base.fail("extraction_event_conflict") }
  let event : Json = { "op": "extraction-submit", "source": source,
    "source_sha256": source_sha256, "extractor": extractor, "version": version, "at": at }
  let event_content = @base.canonical(event)
  let event_entry : @core.Entry = { id: event_path, path: event_path, kind: "state",
    format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false }
  let next = upsert(upsert(entries, record_entry), event_entry)
  @vault.commit(store, @vault.fingerprint(entries), next, [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "source": source, "path": path, "source_sha256": source_sha256, "kind": kind,
    "extractor": extractor, "version": version, "replayed": false,
    "event": event_path.to_json(), "fingerprint": @vault.fingerprint(next) }
}

// Schema faults are `validate_record`'s job (reached by `verify` and lint); this
// pass adds the cross-record invariant a single sidecar cannot express: the
// source it pins to must still be an active raw whose current bytes match.
// Judged by digest, not by the booked path: under twin sources `context`
// legally serves this sidecar to any active raw with matching bytes, so the
// warning must not fire while supply is correct (续十六 B-B -- the old
// path-based verdict made an unactionable warning stick to a serving record).
fn extraction_source_state(
  store : @vault.Storage, entries : Array[@core.Entry], row : Json,
) -> String raise @base.Fault {
  let source = @base.text(@base.field(row, "source"))
  let source_sha256 = @base.text(@base.field(row, "source_sha256"))
  let by_path = entries.iter().find_first(e => e.id == source && e.kind == "raw")
  let verdict = match by_path {
    None => "missing"
    Some(entry) => if entry.stale {
      "revoked"
    } else if (store.digest)(source) != Some(source_sha256) {
      "drifted"
    } else {
      "current"
    }
  }
  if verdict == "current" {
    "current"
  } else {
    // Some active raw may still carry exactly these bytes: the sidecar serves.
    let mut twin = false
    for e in entries {
      if e.kind == "raw" && !e.stale && (store.digest)(e.path) == Some(source_sha256) {
        twin = true
      }
    }
    if twin { "current" } else { verdict }
  }
}

pub fn lint_extractions(
  store : @vault.Storage, entries : Array[@core.Entry], issues : Array[Json],
) -> Unit {
  for entry in entries {
    if entry.kind != "state" || !entry.path.has_prefix("state/extractions/") { continue }
    let text = try { (store.read)(entry.path) } catch { _ => None }
    match text {
      None => ()
      Some(value) => {
        let row = try { Some(@base.parse(value)) } catch { _ => None }
        match row {
          None => ()
          Some(record) => {
            // A registered sidecar passed validate_record, so the field reads
            // below normally cannot fault. Guard anyway: lint runs against a
            // catalog a human may have edited, and one damaged record must not
            // abort the whole diagnostic pass (record_invalid already reports it).
            let state = try { extraction_source_state(store, entries, record) } catch {
              _ => "current"
            }
            match state {
              "revoked" | "missing" => lint_add(issues, "extraction_source_stale", entry.id,
                entry.path,
                "extraction sidecar pins a raw source that is revoked or no longer registered",
                "restore the source and rescan, or re-extract against the current bytes",
                "warning")
              "drifted" => lint_add(issues, "extraction_source_drift", entry.id, entry.path,
                "the source's current bytes no longer match the digest this sidecar pins",
                "run scan and have the host re-extract against the new source version",
                "warning")
              _ => ()
            }
          }
        }
      }
    }
  }
}
