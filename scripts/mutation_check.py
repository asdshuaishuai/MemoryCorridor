#!/usr/bin/env python3
"""Mutation-check the guards added for the A5-derived layers.

Each entry injects one targeted defect into production code and asserts that the
test claiming to guard that behaviour actually fails. A mutation that survives
means the test is decorative.
"""
import re
import shutil
from urllib.parse import quote, unquote
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
BACKUP = Path("/tmp/mutation-backup")

MUTATIONS = [
    ("memory note hash must bind conditions and sources",
     "core/records.mbt",
     '''  if note_hash != memory_note_hash(kind, scope, text, conditions, sources, source_hashes) {
    @base.fail("memory_note_hash_mismatch")
  }''',
     '''  if false { @base.fail("memory_note_hash_mismatch") }''',
     "memory record validation rejects drift"),

    ("impact identity must derive from kind/subject/cause",
     "core/records.mbt",
     '''  if id != impact_id(kind, subject, cause) { @base.fail("impact_record_identity_mismatch") }''',
     '''  if false { @base.fail("impact_record_identity_mismatch") }''',
     "impact record validation rejects"),

    ("memory pin event path must bind the flag and time",
     "core/records.mbt",
     '''      let expected = "state/events/memory-pin-" + memory + "-" +
        @base.hex_hash(pinned.to_string() + "\\n" + string("at")) + ".json"
      if entry.path != expected { @base.fail("memory_event_identity_invalid") }''',
     '''      if false { @base.fail("memory_event_identity_invalid") }''',
     "memory pin event path binds"),

    ("conflict grouping needs two distinct judgments",
     "agent/memory.mbt",
     '''    if distinct.length() < 2 { continue }''',
     '''    if distinct.length() < 1 { continue }''',
     "memory conflict grouping needs"),

    ("source drift must be detected",
     "agent/memory.mbt",
     '''fn drifted_memory_sources(note : MemoryNote, entries : Array[@core.Entry]) -> Array[String] {''',
     '''fn drifted_memory_sources(note : MemoryNote, entries : Array[@core.Entry]) -> Array[String] {
  return []''',
     "memory source hashes pin"),

    ("duplicate detection must ignore the source binding",
     "agent/memory.mbt",
     """    if @core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions) == judgment &&""",
     """    if @core.memory_note_hash(note.kind, note.scope, note.text, note.conditions,
      note.sources, note.source_hashes) == judgment &&""",
     "duplicate and conflict detection ignore"),

    ("ingest event path must bind the order",
     "core/records.mbt",
     '''      let expected = "state/events/" + order + ".json"
      if entry.path != expected { @base.fail("ingest_event_identity_invalid") }''',
     '''      if false { @base.fail("ingest_event_identity_invalid") }''',
     "ingest event accepts a missing pages field"),

    ("memory use must record the reported timestamp",
     "agent/memory.mbt",
     """        let record : MemoryNote = { ..note, last_used_at: Some(at) }""",
     """        let record : MemoryNote = { ..note, last_used_at: note.last_used_at }""",
     "memory use records foreground usage"),

    ("memory use batch must be atomic",
     "agent/memory.mbt",
     """  if changes.is_empty() {
    return { "used": 0, "replayed": true, "fingerprint": @vault.fingerprint(entries),
      "committed": false }
  }""",
     """  if false {
    return { "used": 0, "replayed": true, "fingerprint": @vault.fingerprint(entries),
      "committed": false }
  }""",
     "memory use recovers from a crash"),

    ("inbox by_kind counts must be deterministically ordered",
     "agent/inbox.mbt",
     '  let kinds = by_kind.keys().to_array()\n  kinds.sort_by(@base.compare)',
     '  let kinds = by_kind.keys().to_array()',
     "inbox by_kind counts are deterministically ordered"),

    ("prefetch must report truncation when the budget drops a candidate",
     "agent/memory.mbt",
     '        if !notes.is_empty() && used + estimate > 4096 { truncated = true; continue }',
     '        if !notes.is_empty() && used + estimate > 4096 { continue }',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("prefetch must honour the kinds filter",
     "agent/memory.mbt",
     '    (kinds.is_empty() || kinds.contains(n.kind)))',
     '    true)',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("conflict grouping must normalise condition order",
     "agent/memory.mbt",
     '  conditions.sort_by(@base.compare)',
     '',
     "memory conflict grouping needs"),

    ("read source must not claim a binary source is textual",
     "agent/sources.mbt",
     '  let textual = entry.format != "binary" && entry.format != "image"',
     '  let textual = true',
     "read-source: metadata, verification",
     "read_source_e2e.py"),

    ("page history must order versions by time",
     "agent/page_history.mbt",
     '    let key = (row : PageVersion) => row.at + "\\u0000" + row.op + "\\u0000" + row.event',
     '    let key = (row : PageVersion) => row.op + "\\u0000" + row.at + "\\u0000" + row.event',
     "page history: commits, lifecycle",
     "page_history_e2e.py"),

    ("a host decision must suppress re-reporting the same drift",
     "agent/impact.mbt",
     '        let suppressed = match existing.dismissed {\n          None => false\n          Some(value) => value == f.current\n        }',
     '        let suppressed = false',
     "change impact: drift detection",
     "impact_e2e.py"),

    ("lint must report an unregistered state file",
     "agent/lint.mbt",
     '  for directory in ["state", "wiki", "vectors"] {',
     '  for directory in ["wiki", "vectors"] {',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("lint must report a memory note whose source bytes changed",
     "agent/memory.mbt",
     '            for source in drifted_memory_sources(parsed, entries) {',
     '            for source in [] {',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("lint must report competing memory judgments",
     "agent/memory.mbt",
     '  for group in memory_conflict_groups(rows) {',
     '  for group in memory_conflict_groups(rows).filter(g => false) {',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("the inbox must surface a memory note with a stale source",
     "agent/inbox.mbt",
     '    if invalid.is_empty() && drifted.is_empty() { continue }',
     '    if true { continue }',
     "inbox: aggregation, determinism",
     "inbox_e2e.py"),

    ("the inbox must surface competing memory judgments",
     "agent/inbox.mbt",
     '  for group in memory_conflict_groups(memory_rows_unchecked(store, entries)) {',
     '  for group in memory_conflict_groups(memory_rows_unchecked(store, entries).filter(n => false)) {',
     "inbox: aggregation, determinism",
     "inbox_e2e.py"),

    ("lint must not report drift on a superseded note",
     "agent/memory.mbt",
     '            if parsed.status != "superseded" {',
     '            if true {',
     "cross-layer lifecycle",
     "lifecycle_e2e.py"),

    ("the inbox must fold drift into the item that already covers the subject",
     "agent/inbox.mbt",
     '    if covered.get(row.subject).unwrap_or(false) { continue }',
     '    if false { continue }',
     "inbox: aggregation, determinism",
     "inbox_e2e.py"),

    ("a revoked source must make a note invalid, not drifted",
     "agent/memory.mbt",
     '  note.sources.filter(s => !entries.iter().any(e => e.id == s && e.kind == "raw" && !e.stale))',
     '  note.sources.filter(s => !entries.iter().any(e => e.id == s && e.kind == "raw"))',
     "cross-layer revocation",
     "revocation_lifecycle_e2e.py"),

    ("a note is valid only when its sources are present and unchanged",
     "agent/memory.mbt",
     '      fields["valid"] = (invalid.is_empty() && drifted.is_empty()).to_json()',
     '      fields["valid"] = invalid.is_empty().to_json()',
     "cross-layer revocation",
     "revocation_lifecycle_e2e.py"),

    ("stats must verify before aggregating, because graph_unchecked trusts the caller",
     "agent/maintenance.mbt",
     'fn maintenance(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {\n  @vault.verify(store, entries)',
     'fn maintenance(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {\n  ignore(entries)',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("recovery must refuse a journal whose catalog was edited outside it",
     "vault/storage.mbt",
     '  if current != old_index && current != new_index {',
     '  if false {',
     "concurrent writers",
     "concurrent_e2e.py"),

    ("recovery must retain the journal instead of discarding it",
     "vault/storage.mbt",
     '    @base.fail("recovery_conflict: catalog edited outside transaction; journal retained")',
     '    (store.remove)("state/transactions/pending.json"); @base.fail("recovery_conflict")',
     "concurrent writers",
     "concurrent_e2e.py"),

    ("session-close must release the vault OS lock itself",
     "nativehost/host.mbt",
     '    if session.held.val { @platform.unlock() }\n    session.root.val = None',
     '    session.root.val = None',
     "Native session:",
     "session_e2e.py"),

    ("list-pages is a derived read and must refuse a damaged vault",
     "agent/session.mbt",
     '    "list-pages" => {\n      // A derived read, not a raw byte reader: it must refuse a vault whose\n      // state no longer matches the catalog, exactly like status/topics/tree.\n      @vault.verify(store, entries)\n      entries.filter(e => @core.is_page(e)).to_json()\n    }',
     '    "list-pages" => entries.filter(e => @core.is_page(e)).to_json()',
     "tamper probe",
     "tamper_e2e.py"),

    ("a commit event must be registered in the catalog, not just written",
     "agent/commit.mbt",
     '  changes.push({ path: event_path, before: None, after: Some(event_content) })\n  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false })',
     '  changes.push({ path: event_path, before: None, after: Some(event_content) })',
     "page commit recovers from a crash at any publish point"),
    ("research topic event must be registered in the catalog",
     "agent/research.mbt",
     '  let next = upsert(upsert(entries, record_entry), event_entry)',
     '  let next = upsert(entries, record_entry)',
     "research topic recovers from a crash at any publish point"),

    ("purpose suggestion event must be registered in the catalog",
     "agent/purpose.mbt",
     '  let next = upsert(upsert(entries, entry), event_entry)',
     '  let next = upsert(entries, entry)',
     "purpose suggestion recovers from a crash at any publish point"),

    ("overview suggestion event must be registered in the catalog",
     "agent/overview.mbt",
     '  let next = upsert(upsert(entries, entry), event_entry)',
     '  let next = upsert(entries, entry)',
     "overview suggestion recovers from a crash at any publish point"),

    ("provider registration event must be registered in the catalog",
     "agent/providers.mbt",
     '  @vault.commit(store, @vault.fingerprint(entries), upsert(upsert(entries, entry), event_entry),',
     '  @vault.commit(store, @vault.fingerprint(entries), upsert(entries, entry),',
     "provider registration recovers from a crash at any publish point"),
    ("quality audit event must be registered in the catalog",
     "agent/quality.mbt",
     '  changes.push({ path: event_path, before: None, after: Some(event_content) })\n  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false })',
     '  changes.push({ path: event_path, before: None, after: Some(event_content) })',
     "quality audit recovers from a crash at any publish point"),

    ("page archive event must be registered in the catalog",
     "agent/pages.mbt",
     '  next = upsert(next, event_entry)\n  let changes : Array[@vault.Change] = [{ path, before: None, after: Some(content) }]',
     '  let changes : Array[@vault.Change] = [{ path, before: None, after: Some(content) }]',
     "page archive recovers from a crash at any publish point"),

    ("research completion event must be registered in the catalog",
     "agent/research.mbt",
     '  let next_entries = upsert(upsert(entries, { ..entry, sha256: @base.hex_hash(content) }), event_entry)',
     '  let next_entries = upsert(entries, { ..entry, sha256: @base.hex_hash(content) })',
     "research completion recovers from a crash at any publish point"),

    ("source revocation event must be registered in the catalog",
     "agent/commit.mbt",
     '  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })',
     '  ignore(event_path)',
     "source revocation recovers from a crash at any publish point"),
    ("lint must stay runnable on a damaged vault",
     "agent/lint.mbt",
     'pub fn lint_result(store : @vault.Storage, catalog : String?) -> Json raise @base.Fault {\n  let issues : Array[Json] = []',
     'pub fn lint_result(store : @vault.Storage, catalog : String?) -> Json raise @base.Fault {\n  if catalog is None { @base.fail("lint_refuses_missing_catalog") }\n  let issues : Array[Json] = []',
     "MCP lifecycle, dictionary/schema parity",
     "mcp_e2e.py"),
    ("a conflicted note must never be proposed for merging",
     "agent/memory.mbt",
     '  let live = active.filter(n => !conflicted.get(n.id).unwrap_or(false))',
     '  let live = active',
     "memory candidates excludes conflicted notes from merging and pruning",
     "memory_e2e.py"),

    ("a conflicted note must never be proposed for pruning",
     "agent/memory.mbt",
     '    if conflicted.get(note.id).unwrap_or(false) { continue }',
     '    if false { continue }',
     "memory candidates excludes conflicted notes from merging and pruning",
     "memory_e2e.py"),

    ("a pinned note must never be proposed for pruning",
     "agent/memory.mbt",
     '    if note.pinned { continue }\n    if note.last_used_at is Some(_) { continue }',
     '    if note.last_used_at is Some(_) { continue }',
     "memory candidates never proposes a pinned or already-settled note",
     "memory_e2e.py"),

    ("a used note must never be proposed for pruning",
     "agent/memory.mbt",
     '    if note.last_used_at is Some(_) { continue }',
     '    if false { continue }',
     "memory candidates never proposes a pinned or already-settled note",
     "memory_e2e.py"),

    ("merge participants must not also be proposed for pruning",
     "agent/memory.mbt",
     '    if in_merge.get(note.id).unwrap_or(false) { continue }',
     '    if false { continue }',
     "memory notes, supersede chain",
     "memory_e2e.py"),
    ("candidates must not merge notes of different kinds",
     "agent/memory.mbt",
     '      if kept.2 == note.kind && kept.3 == note.scope &&\n        @index.similar_merge(tokens, kept.1) { keeper = kept.0 }',
     '      if @index.similar_merge(tokens, kept.1) { keeper = kept.0 }',
     "memory candidates never merges across kinds or scopes"),

    ("prefetch must not collapse notes of different kinds",
     "agent/memory.mbt",
     '            if kept.2 == note.kind && kept.3 == note.scope &&\n              @index.similar_merge(tokens, kept.1) { keeper = kept.0 }',
     '            if @index.similar_merge(tokens, kept.1) { keeper = kept.0 }',
     "memory candidates never merges across kinds or scopes"),
    ("an impact with no dedicated item must surface on its own",
     "agent/inbox.mbt",
     '  let covered : Map[String, Bool] = Map([])\n  for item in items { covered[item.subject] = true }',
     '  let covered : Map[String, Bool] = Map([])\n  for item in items { covered[item.subject] = true }\n  covered["wiki/overview.md"] = true',
     "inbox: aggregation, determinism",
     "inbox_e2e.py"),
    ("a byte range that splits a character must be refused, not silently emptied",
     "base/json.mbt",
     '  try @utf8.decode(bytes[start:end]) catch { _ => raise Fault("utf8_range_boundary_invalid") }',
     '  @utf8.decode(bytes[start:end]) catch { _ => "" }',
     "read-source: metadata, verification",
     "read_source_e2e.py"),
    ("an anchor must be verified at its offsets, not by searching the text",
     "agent/evidence.mbt",
     '        let verified : Bool = try { @base.utf8_slice(@vault.required(store, source), source_start, source_end) == source_quote } catch { _ => false }',
     '        let whole = @vault.required(store, source)\n        let verified : Bool = whole.contains(source_quote)',
     "evidence source e2e: exact raw anchors",
     "evidence_source_e2e.py"),
    ("recorded body anchors must stay relative to the parsed body",
     "agent/evidence.mbt",
     '  { "source": source, "body_start": start, "body_end": end, "quote": quote,',
     '  { "source": source, "body_start": start + 66, "body_end": end + 66, "quote": quote,',
     "evidence source e2e: exact raw anchors",
     "evidence_source_e2e.py"),
    ("every duplicate must point at one keeper, never at another duplicate",
     "agent/memory.mbt",
     '        "reason": "similar_text" })\n      continue\n    }\n    keepers.push((note.id, tokens, note.kind, note.scope))',
     '        "reason": "similar_text" })\n    }\n    keepers.push((note.id, tokens, note.kind, note.scope))',
     "memory candidates groups every duplicate under one keeper"),
    ("prefetch must honour the requested candidate limit",
     "agent/memory.mbt",
     '  let hits = @index.search_index(@index.build_index(documents), query, limit~)',
     '  let hits = @index.search_index(@index.build_index(documents), query, limit=50)',
     "memory notes, supersede chain",
     "memory_e2e.py"),
    ("graph expansion must default to and allow the documented two hops",
     "agent/explore.mbt",
     '  let hops = integer(request, "hops", 2, 0, 2)',
     '  let hops = integer(request, "hops", 1, 0, 2)',
     "Retrieval context: late evidence",
     "retrieval_e2e.py"),
    ("search must refuse a budget above its advertised maximum",
     "agent/explore.mbt",
     '  let budget = integer(request, "budget", 4096, 1, 65536)',
     '  let budget = integer(request, "budget", 4096, 1, 2147483647)',
     "Adversarial native corpus:",
     "adversarial_e2e.py"),

    ("read-source must refuse a byte offset above its advertised maximum",
     "agent/sources.mbt",
     '    Number(n, ..) if n >= 0.0 && n <= 16777216.0 && n == n.to_int().to_double() => n.to_int()',
     '    Number(n, ..) if n >= 0.0 && n <= 2147483647.0 && n == n.to_int().to_double() => n.to_int()',
     "Adversarial native corpus:",
     "adversarial_e2e.py"),
    ("the memory text bound counts characters, not bytes",
     "agent/memory.mbt",
     '  if value.is_empty() || value.length() > 4096 || value.contains("\\r") { @base.fail("memory_text_invalid") }',
     '  if value.is_empty() || @base.utf8_size(value) > 4096 || value.contains("\\r") { @base.fail("memory_text_invalid") }',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("the conditions count bound is the documented sixteen",
     "agent/memory.mbt",
     '  if value.length() > 16 { @base.fail("memory_conditions_count_invalid") }',
     '  if value.length() > 8 { @base.fail("memory_conditions_count_invalid") }',
     "memory notes, supersede chain",
     "memory_e2e.py"),

    ("the sources count bound is the documented thirty-two",
     "agent/memory.mbt",
     '  if value.length() > 32 { @base.fail("memory_sources_count_invalid") }',
     '  if value.length() > 16 { @base.fail("memory_sources_count_invalid") }',
     "memory notes, supersede chain",
     "memory_e2e.py"),
    ("a resolved review must refuse an unsupported decision action",
     "core/records.mbt",
     '      if !["research", "create-page", "skip"].contains(@base.text(@base.field(decision, "action"))) { @base.fail("review_action_invalid") }',
     '      ignore(@base.text(@base.field(decision, "action")))',
     "HumanGate quality-audit: orphan/sparse debt",
     "quality_gate_e2e.py"),
    ("an evidence record must refuse a bogus supersede link",
     "core/records.mbt",
     '      Some(value) => if !valid_hash(@base.text(value)) || @base.text(value) == id {\n        @base.fail("evidence_superseded_by_invalid")\n      }',
     '      Some(value) => ignore(@base.text(value))',
     "record validation:",
     "record_validation_e2e.py"),
    ("a completed job must refuse a result that is absent or unhashed",
     "core/records.mbt",
     'if result == Json::null() || error != Json::null() || !valid_hash(@base.text(result_hash)) || @base.text(result_hash) != @base.hex_hash(@base.canonical(result)) { @base.fail("provider_job_result_invalid") }',
     'ignore(result_hash)',
     "record validation:",
     "record_validation_e2e.py"),

    ("a cancelled job must refuse any result",
     "core/records.mbt",
     'if result != Json::null() || result_hash != Json::null() || error != Json::null() { @base.fail("provider_job_cancelled_result") }',
     'ignore(result)',
     "record validation:",
     "record_validation_e2e.py"),
    ("a failed job event must refuse an invalid error field",
     "core/records.mbt",
     'if error.is_empty() || error.length() > 4096 || error.contains("\\n") || error.contains("\\r") { @base.fail("provider_job_event_error_invalid") }',
     'ignore(error)',
     "record validation:",
     "record_validation_e2e.py"),
    ("a memory event must refuse an invalid idempotency key",
     "core/records.mbt",
     '      let key = string("key")\n      if key.is_empty() || key.length() > 256 || key.contains("\\n") || key.contains("\\r") {\n        @base.fail("memory_event_key_invalid")\n      }',
     '      ignore(string("key"))',
     "record validation:",
     "record_validation_e2e.py"),

    ("an impact record must refuse an unsupported kind",
     "core/records.mbt",
     '  if !["research", "overview-suggestion", "overview-synthesis"].contains(value) {\n    @base.fail("impact_kind_invalid")\n  }',
     '  ignore(value)',
     "record validation:",
     "record_validation_e2e.py"),

    ("a memory record must refuse an unsupported kind",
     "core/records.mbt",
     '  if !["preference", "decision", "constraint", "fact", "goal"].contains(kind) {\n    @base.fail("memory_kind_invalid")\n  }',
     '  ignore(kind)',
     "record validation:",
     "record_validation_e2e.py"),
    ("lint must name a page whose frontmatter lost a required field",
     "agent/lint.mbt",
     'lint_add(issues, "page_syntax", entry.id, entry.path,',
     'ignore(entry.id)',
     "lint predicates:",
     "lint_predicates_e2e.py"),
    ("a dispatch entry point must verify before reading records",
     "agent/impact.mbt",
     'pub fn impact_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {\n  @vault.verify(store, entries)\n  let rows = impact_rows_unchecked(store, entries)',
     'pub fn impact_list(store : @vault.Storage, entries : Array[@core.Entry]) -> Json raise @base.Fault {\n  let rows = impact_rows_unchecked(store, entries)',
     "change impact: drift detection",
     "impact_e2e.py"),

    ("archived notes must not block the same judgment",     "agent/memory.mbt",
     '''    if note.status != "active" { continue }
    if @core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions) == judgment &&''',
     '''    if note.status == "superseded" { continue }
    if @core.memory_judgment_hash(note.kind, note.scope, note.text, note.conditions) == judgment &&''',
     "an archived note does not block"),

    # The modules below have no MoonBit behavioural test, so their guard lives
    # in an end-to-end script. Naming it here is what makes the mutation
    # meaningful; without it `moon test` would pass and the defect would hide.
    ("topics must exclude material pages from the semantic layer",
     "agent/topics.mbt",
     '  let rows = entries.filter(e => @core.is_page(e) && e.kind == "synthesis")',
     '  let rows = entries.filter(e => @core.is_page(e))',
     "topics: semantic layer, material exclusion",
     "topics_e2e.py"),

    ("topics must report a revoked source instead of dropping it",
     "agent/topics.mbt",
     '  let sources = entry.sources.filter(s => entries.iter().any(e => e.id == s && e.kind == "raw" && !e.stale))',
     '  let sources = entry.sources',
     "topics: semantic layer, material exclusion",
     "topics_e2e.py"),

    ("page history must assemble the commit events",
     "agent/page_history.mbt",
     '      match optional(row, "pages") {\n        Some(Object(hashes)) => match hashes.get(id) {',
     '      match optional(row, "pages") {\n        Some(Object(hashes)) => match None {',
     "page history: commits, lifecycle",
     "page_history_e2e.py"),

    ("page history must record a revoked source",
     "agent/page_history.mbt",
     '      let invalidated = @base.strings(@base.field(row, "invalidated"))\n      if invalidated.contains(id) {',
     '      let invalidated = @base.strings(@base.field(row, "invalidated"))\n      if false && invalidated.contains(id) {',
     "page history: commits, lifecycle",
     "page_history_e2e.py"),

    ("read source must reject an inverted range",
     "agent/sources.mbt",
     '    if stop <= start || stop > total { @base.fail("source_range_invalid: 0 <= start < end <= " + total.to_string()) }',
     '    if stop > total { @base.fail("source_range_invalid: 0 <= start < end <= " + total.to_string()) }',
     "read-source: metadata, verification, ranges",
     "read_source_e2e.py"),

    # The wasm service boundary (wasm/host.mbt + wasm/service.mbt) is guarded
    # by scripts/wasm_service_e2e.py driving a rebuilt wasm module; there is no
    # MoonBit behavioural test for it.
    ("a missing file must read as absent over the wasm host boundary",
     "wasm/host.mbt",
     '    if status == -3 { return None }',
     '    if status == -1 { return None }',
     "wasm service e2e:",
     "wasm_service_e2e.py"),

    ("a refused read must stay refused over the wasm host boundary",
     "wasm/host.mbt",
     '    if status == -1 { raise @base.Fault(refused) }',
     '    if status == -1 { return None }',
     "wasm service e2e:",
     "wasm_service_e2e.py"),

    ("the host read retry must grow the buffer to the exact size",
     "wasm/host.mbt",
     '      if needed <= cap { raise @base.Fault("host_protocol_invalid: " + path) }\n      cap = needed\n      continue',
     '      if needed <= cap { raise @base.Fault("host_protocol_invalid: " + path) }\n      cap = 2097152\n      continue',
     "wasm service e2e:",
     "wasm_service_e2e.py"),

    ("closing the wasm session must release the vault lock",
     "wasm/service.mbt",
     '    if session.held.val { host_unlock() }\n    session.root.val = None',
     '    session.root.val = None',
     "wasm service e2e:",
     "wasm_service_e2e.py"),

    ("lint must name an evidence record whose page reference is unresolvable",
     "agent/lint.mbt",
     '''  let view = try { evidence_row_view(store, entries, row) } catch {
    @base.Fault(message) => {
      lint_add(issues, "evidence_reference_unresolvable", entry.id, entry.path, message,
        "restore the referenced page and its catalog entry, or replace the evidence through the engine", "error")
      return
    }
  }''',
     '''  let view = try { evidence_row_view(store, entries, row) } catch { _ => return }''',
     "lint predicates:",
     "lint_predicates_e2e.py"),

    # The wasipure boundary (pure-WASI storage + receipt protocol) is guarded
    # by scripts/wasipure_e2e.py driving the rebuilt wasipure module.
    ("a wasi receipt must match the current bytes, not just the path",
     "wasipure/storage.mbt",
     '    if @base.text(@base.field(receipt, "path")) == path && @base.text(@base.field(receipt, "sha256")) == sha {',
     '    if @base.text(@base.field(receipt, "path")) == path {',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("a wasi receipt with ok false must fail compile verification",
     "wasipure/storage.mbt",
     '      if @base.boolean(@base.field(receipt, "ok")) { return }',
     '      return',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("wasi readdir stride must follow the wasmtime dirent emission",
     "wasipure/storage.mbt",
     '          offset += 24 + namlen',
     '          offset += 21 + namlen',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("wasi write must create the parent chain before the temp file",
     "wasipure/storage.mbt",
     '  match path.rev_split_once("/") {\n    Some((parent, _)) => wasi_mkdirs(parent.to_owned())\n    None => ()\n  }',
     '  None => ()',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),
]


PRINT_RE = re.compile('print\\("([^"]*)"\\)')


def e2e_success_messages():
    """Map each end-to-end script to the message it prints when it passes.

    A mutation whose expected-test string is one of these is guarded only by
    that script. Forgetting to name it makes `moon test` pass while the defect
    hides, which happened twice, so the checker now refuses the entry outright.
    """
    messages = {}
    for script in sorted((REPO / "scripts").glob("*_e2e.py")):
        for line in script.read_text().splitlines():
            match = PRINT_RE.search(line)
            if match and "passed" in match.group(1):
                messages[match.group(1)] = script.name
    return messages


def check_e2e_names():
    messages = e2e_success_messages()
    problems = []
    for entry in MUTATIONS:
        expected = entry[4]
        named = entry[5] if len(entry) > 5 else None
        if named is not None:
            continue
        for message, script in messages.items():
            if message.startswith(expected):
                problems.append(f"  {entry[0]}: guarded only by {script}, add it as the e2e name")
                break
    if problems:
        print("MUTATION ENTRIES MISSING AN E2E SCRIPT:")
        for problem in problems:
            print(problem)
        sys.exit(2)


def run_tests():
    """Run the MoonBit tests and report whether any test actually failed."""
    result = subprocess.run(["moon", "test", "--target", "native"], cwd=REPO,
                            capture_output=True, text=True, timeout=900)
    output = result.stdout + result.stderr
    failed = re.search(r"Total tests: \d+, passed: \d+, failed: (\d+)", output)
    return output, bool(failed) and int(failed.group(1)) > 0


def run_e2e(script):
    """Rebuild, then run an end-to-end script against the fresh binaries.

    Skipping the rebuild silently tests the previous binary, which makes every
    e2e-based mutation look caught when nothing was caught at all. The wasm
    service module is rebuilt too: scripts/wasm_service_e2e.py instantiates it,
    so a wasm-boundary mutation would otherwise hide behind a stale module.
    """
    build = subprocess.run(["moon", "build", "--target", "native", "cli", "mcp", "web"], cwd=REPO,
                           capture_output=True, text=True, timeout=900)
    if build.returncode != 0:
        return build.stdout + build.stderr, True
    wasm = subprocess.run(["moon", "build", "--target", "wasm", "wasm"], cwd=REPO,
                          capture_output=True, text=True, timeout=900)
    if wasm.returncode != 0:
        return wasm.stdout + wasm.stderr, True
    wasipure = subprocess.run(["moon", "build", "--target", "wasm", "wasipure"], cwd=REPO,
                              capture_output=True, text=True, timeout=900)
    if wasipure.returncode != 0:
        return wasipure.stdout + wasipure.stderr, True
    result = subprocess.run([sys.executable, str(REPO / "scripts" / script)], cwd=REPO,
                            capture_output=True, text=True, timeout=900)
    return result.stdout + result.stderr, result.returncode != 0


def rebuild_clean():
    """Rebuild cli/mcp and the test driver, failing loudly if either fails.

    Both runs are quiet, so a failure would otherwise be invisible: the sources
    are pristine but the binaries still carry the last mutation, and the next
    `moon test` reports a failure that does not exist.
    """
    for args in (["moon", "build", "--target", "native", "cli", "mcp", "web"],
                 ["moon", "build", "--target", "wasm", "wasm"],
                 ["moon", "build", "--target", "wasm", "wasipure"],
                 ["moon", "test", "--target", "native", "--build-only"]):
        result = subprocess.run(args, cwd=REPO, capture_output=True, text=True, timeout=900)
        if result.returncode != 0:
            print("FATAL: " + " ".join(args) + " failed after restoring the sources;")
            print("       the binaries may still carry a mutation. Output:")
            print((result.stdout + result.stderr)[-2000:])
            sys.exit(2)


def restore_from_backup():
    """Undo an interrupted run.

    The backup is written before the first mutation, so it always holds the
    pristine sources. A run killed by a signal or a timeout never reaches its
    `finally`, which used to leave production code mutated and the next run
    deleted the only copy that could undo it.
    """
    restored = []
    for backup in sorted(BACKUP.iterdir()):
        path = unquote(backup.name)
        target = REPO / path
        if not target.exists():
            continue
        text = backup.read_text()
        if target.read_text() != text:
            target.write_text(text)
            restored.append(path)
    return restored


def main():
    check_e2e_names()
    if BACKUP.exists() and any(BACKUP.iterdir()):
        restored = restore_from_backup()
        shutil.rmtree(BACKUP)
        print("A previous mutation run was interrupted. Restored %d file(s):" % len(restored))
        for path in restored:
            print("  " + path)
        rebuild_clean()
        print("Sources and binaries are clean again. Re-run to start a fresh check.")
        sys.exit(3)
    if BACKUP.exists():
        shutil.rmtree(BACKUP)
    BACKUP.mkdir(parents=True)
    originals = {}
    for entry in MUTATIONS:
        path = entry[1]
        if path not in originals:
            originals[path] = (REPO / path).read_text()
            shutil.copy2(REPO / path, BACKUP / quote(path, safe=""))

    survivors = []
    try:
        for index, entry in enumerate(MUTATIONS, 1):
            name, path, old, new, expected_test = entry[:5]
            e2e = entry[5] if len(entry) > 5 else None
            source = (REPO / path).read_text()
            if old not in source:
                print(f"[{index}] PATTERN MISS  {name}")
                survivors.append((name, "pattern did not match"))
                continue
            (REPO / path).write_text(source.replace(old, new, 1))
            # A behaviour covered only by an end-to-end script cannot be caught
            # by `moon test`, so run the named script too and accept either.
            output, tests_failed = run_tests()
            if "Error: [" in output and "Total tests" not in output:
                print(f"[{index}] COMPILE   {name} (caught by the compiler, not a test)")
                (REPO / path).write_text(originals[path])
                continue
            e2e_failed = False
            if e2e is not None:
                e2e_output, e2e_failed = run_e2e(e2e)
                output += e2e_output
            # `moon test` prints "failed: 0" on success, so the count has to be
            # parsed rather than matched as a substring. An end-to-end script
            # only prints its own name when it succeeds, so a non-zero exit is
            # itself the evidence that the behaviour is guarded.
            if e2e is not None:
                caught = e2e_failed or (tests_failed and expected_test in output)
            else:
                caught = tests_failed and expected_test in output
            status = "CAUGHT " if caught else "SURVIVED"
            print(f"[{index}] {status}  {name}"
                  + (f"  (via {e2e})" if e2e_failed and not tests_failed else ""))
            if not caught:
                survivors.append((name, "no failing test mentions " + expected_test))
            (REPO / path).write_text(originals[path])
    finally:
        for path, text in originals.items():
            (REPO / path).write_text(text)
        shutil.rmtree(BACKUP, ignore_errors=True)
        # A killed run must never leave production code mutated, and the
        # binaries must not be left carrying the last mutation either.
        for path, text in originals.items():
            if (REPO / path).read_text() != text:
                print(f"FATAL: {path} was not restored; refusing to continue")
                sys.exit(2)
        # The test driver is a separate binary from cli/mcp, and MoonBit will not
        # rebuild it from restored sources alone. Without this, the next
        # `moon test` runs against the last mutation and reports a phantom failure.
        rebuild_clean()

    print()
    if survivors:
        print("SURVIVING MUTATIONS (decorative tests):")
        for name, why in survivors:
            print(f"  - {name}: {why}")
        sys.exit(1)
    print("all mutations caught")


if __name__ == "__main__":
    main()
