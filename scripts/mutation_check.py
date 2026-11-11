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
     '  let textual =\n    entry.format != "binary" && entry.format != "image" && !@office.is_office_format(entry.format)',
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

    # 续十八: wasipure boundary mutation validation -- the lease-lock
    # arithmetic guards, the takeover retry, and the MCP handshake gates.
    # Each is driven by scripts/wasipure_e2e.py against the rebuilt module.
    ("a forged negative lease must not authorize instant takeover",
     "wasipure/storage.mbt",
     '  if value < 0.0 { return false }',
     '  if value < 0.0 { return true }',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("a lease beyond the u64 domain must not saturate into takability",
     "wasipure/storage.mbt",
     '  if value >= 18446744073709551616.0 { return false }',
     '  if value >= 18446744073709551616.0 { return true }',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("an unexpired or unreadable lease must never be preempted",
     "wasipure/storage.mbt",
     '        if !lease_lock_expired() { @base.fail("vault_locked: another writer is active") }',
     '        if false { @base.fail("vault_locked: another writer is active") }',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("a takeover must re-create the lock in a second EXCL round",
     "wasipure/storage.mbt",
     '  for _ in 0..<2 {',
     '  for _ in 0..<1 {',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("tools/list must refuse before the initialized notification arrives",
     "wasipure/mcp.mbt",
     '      "tools/list" => {\n        if !ready { raise @base.Fault("initialization_required") }',
     '      "tools/list" => {\n        if false { raise @base.Fault("initialization_required") }',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    ("the MCP handshake may only be completed once per connection",
     "wasipure/mcp.mbt",
     '        if initialized { raise @base.Fault("already_initialized") }',
     '        if false { raise @base.Fault("already_initialized") }',
     "wasipure direct-run e2e:",
     "wasipure_e2e.py"),

    # 续二十三 semantic page-redundancy: every decision that turns a raw
    # signal into a proposal is guarded so a paraphrase-only nomination, the
    # content-version lock, the byte gate, the cosine floor, the priority, and
    # the lint wiring each have a test/e2e that fails when the guard is dropped.
    ("page-redundancy must lock a vector to the page's current content version",
     "agent/redundancy.mbt",
     '      pages.iter().any(p => p.id == record.page && p.sha256 == record.sha256) {',
     '      pages.iter().any(p => p.id == record.page) {',
     "redundancy e2e:",
     "redundancy_e2e.py"),

    ("near-duplicate token merge must respect the byte gate",
     "agent/redundancy.mbt",
     '  if @index.similar_eligible(bodies[page.id]) && @index.similar_eligible(bodies[kept.id]) {',
     '  if true {',
     "short bodies never merge on a coincidental token sequence"),

    ("vector cosine must clear the (now declarable) redundancy floor",
     "agent/redundancy.mbt",
     '        if cos >= cosine_floor {',
     '        if cos >= 0.0 {',
     "orthogonal vectors nominate nothing without a structural signal"),

    ("the deterministic token signal must outrank vector cosine",
     "agent/redundancy.mbt",
     '          if primary is None { primary = Some(("vector_cosine", cos)) }',
     '          primary = Some(("vector_cosine", cos))',
     "similar_text takes priority over vector_cosine"),

    ("shared-source nomination needs real term overlap, not just a shared cite",
     "agent/redundancy.mbt",
     '    if term_overlap(bodies[page.id], bodies[kept.id]) >= REDUNDANCY_SHARED_OVERLAP_FLOOR {',
     '    if term_overlap(bodies[page.id], bodies[kept.id]) >= 0.0 {',
     "shared source with low term overlap does not nominate"),

    ("lint must run the deterministic redundant-page pass",
     "agent/lint.mbt",
     '          lint_redundant_pages(store, value, issues)\n',
     '',
     "lint flags formatting-only near-duplicate pages (redundant_page)"),

    # 续二十六 optional multimodal routing: the capability vocabulary is
    # closed, the routing reads the ACTUAL provider row, the image pick is
    # deterministic, unembeddable pages are skipped rather than gap-counted,
    # and image items pin the exact bytes. Each guard is caught by the always-
    # in-CI embedding protocol e2e or the selector wbtest.
    ("provider capability vocabulary must stay closed",
     "agent/providers.mbt",
     '  if !["embed", "search", "embed-multimodal"].contains(value) {\n    @base.fail("provider_capability_unknown: " + value)\n  }',
     '  if false { @base.fail("provider_capability_unknown: " + value) }',
     "Multimodal plan routing:",
     "embedding_e2e.py"),

    ("multimodal routing must fire for a declaring provider",
     "agent/vectors.mbt",
     '  let multimodal = provider_declares(store, entries, request, "embedding", space, "embed-multimodal")',
     '  let multimodal = false',
     "Multimodal plan routing:",
     "embedding_e2e.py"),

    ("multimodal routing must read the actual provider row, not assume",
     "agent/providers.mbt",
     '      let row = provider_for(store, entries, provider, kind, space)\n      @base.strings(@base.field(row, "capabilities")).contains(capability)',
     '      ignore(provider_for(store, entries, provider, kind, space))\n      true',
     "Multimodal plan routing:",
     "embedding_e2e.py"),

    ("the image source pick must be sorted-deterministic",
     "agent/vectors.mbt",
     '  let sorted = page.sources.copy()\n  sorted.sort()',
     '  let sorted = page.sources.copy()',
     "first image source picks the sorted-first active image"),

    ("pages without an image source must be skipped, never planned",
     "agent/vectors.mbt",
     '  let targets = if multimodal { pages.filter(p => first_image_source(entries, p) != None) } else { pages }',
     '  let targets = pages',
     "Multimodal plan routing:",
     "embedding_e2e.py"),

    ("image items must pin the exact image bytes version",
     "agent/vectors.mbt",
     '      items.push({ "page": entry.id, "sha256": entry.sha256, "modality": "image",\n        "image": source.id, "image_sha256": source.sha256 })',
     '      items.push({ "page": entry.id, "sha256": entry.sha256, "modality": "image", "image": source.id })',
     "Multimodal plan routing:",
     "embedding_e2e.py"),

    # 续二十七 explicit cosine tier: the declared floor must reach the
    # nomination decision, must default to the text tier, and must bounds-
    # check finiteness; each guard is caught by redundancy_e2e's tier section.
    ("the declared cosine tier must reach the nomination decision",
     "agent/redundancy.mbt",
     '        if cos >= cosine_floor {',
     '        if cos >= REDUNDANCY_COSINE_FLOOR {',
     "redundancy e2e:",
     "redundancy_e2e.py"),

    ("the cosine tier default must stay the documented text floor",
     "agent/redundancy.mbt",
     '  let cosine_floor = bounded_double(request, "cosine_floor", REDUNDANCY_COSINE_FLOOR, 0.0, 1.0)',
     '  let cosine_floor = bounded_double(request, "cosine_floor", 0.0, 0.0, 1.0)',
     "redundancy e2e:",
     "redundancy_e2e.py"),

    ("the cosine tier bound must refuse values above 1",
     "agent/explore.mbt",
     '    Some(Number(n, ..)) if !n.is_nan() && !n.is_inf() && n >= low && n <= high => n',
     '    Some(Number(n, ..)) if !n.is_nan() && !n.is_inf() && n >= low => n',
     "redundancy e2e:",
     "redundancy_e2e.py"),

    # 续二十八 dream round ledger: the baseline binding, replay precedence,
    # the two compatibility gates and the event dictionary each have a dream
    # e2e assertion that fails when the guard is dropped.
    ("a dream round must bind the exact baseline fingerprint",
     "agent/dream.mbt",
     '  if baseline != @vault.fingerprint(entries) { @base.fail("dream_stale_baseline") }',
     '  if false { @base.fail("dream_stale_baseline") }',
     "dream e2e:",
     "dream_e2e.py"),

    ("an existing dream round must replay before the baseline check",
     "agent/dream.mbt",
     '      let old = @base.parse(existing)\n      return { "id": id, "status": @base.text(@base.field(old, "status")), "replayed": true, "path": path }',
     '      ignore(@base.parse(existing))',
     "dream e2e:",
     "dream_e2e.py"),

    ("retained rounds may not regress lint errors",
     "agent/dream.mbt",
     '    if current.lint_errors > dream_json_int(base_metrics, "lint_errors") { @base.fail("dream_compat_lint_regression") }',
     '    if false { @base.fail("dream_compat_lint_regression") }',
     "dream e2e:",
     "dream_e2e.py"),

    ("retained rounds may not lose evidence coverage",
     "agent/dream.mbt",
     '    if current.uncovered_sources > dream_json_int(base_metrics, "uncovered_sources") {\n      @base.fail("dream_compat_evidence_loss")\n    }',
     '    if false {\n      @base.fail("dream_compat_evidence_loss")\n    }',
     "dream e2e:",
     "dream_e2e.py"),

    ("dream events must be registered in the event dictionary",
     "core/records.mbt",
     '      "dream-open", "dream-close",',
     '      "dream-open",',
     "dream e2e:",
     "dream_e2e.py"),

    # The literate compilation surface: the catalog block is read as the
    # closed MoonBit literal subset. Each guard below is what keeps that
    # grammar closed; dropping one must make the literate-surface tests fail.
    ("catalog scaffolding must match the v1 declarations token for token",
     "decl/catalog.mbt",
     '  if !@base.literal_prefix_matches(tokens, header) {\n    @base.fail("catalog_header_invalid: require v1 literal DSL")\n  }',
     '  if false { @base.fail("catalog_header_invalid: require v1 literal DSL") }',
     "catalog still refuses smuggled code, wrong scaffolding and count drift"),

    ("catalog footer must declare the parsed row count and nothing else",
     "decl/catalog.mbt",
     '  if !@base.literal_tail_matches(tokens, pos, footer) {',
     '  if false {',
     "catalog still refuses smuggled code, wrong scaffolding and count drift"),

    ("context must run office extraction for OOXML formats",
     "agent/orders.mbt",
     '  let office_text = if @office.is_office_format(source_entry.format) {',
     '  let office_text = if false {',
     "office e2e:",
     "office_e2e.py"),

    # 续十六 fourth-round hunt (office/xml parse surface): whitelist capture
    # replaced the skip/instrText blacklists that latched forever on
    # self-closing tags; entities refuse outright; decimals are bounded;
    # slides enforce the `slide<N>.xml` pattern and a:t-only text.
    ("word text must be captured only inside w:t leaves",
     "office/office.mbt",
     '        } else if name == "w:t" && !self_closing {\n          capturing = true',
     '        } else if false {\n          capturing = true',
     "whitelist capture: self-closing skip tags hide nothing downstream"),

    ("w:t capture must close on End so excluded runs stay excluded",
     "office/office.mbt",
     '      End(name) => if name == "w:t" { capturing = false }',
     '      End(name) => ()',
     "whitelist capture: self-closing skip tags hide nothing downstream"),

    ("whitespace-only text nodes must survive verbatim (word space runs)",
     "office/xml.mbt",
     '      if text.length() > 0 { events.push(Text(decode_entities(text))) }',
     '      if !text.trim().is_empty() { events.push(Text(decode_entities(text))) }',
     "whitelist capture: self-closing skip tags hide nothing downstream"),

    ("a self-closing shared string must keep its index slot",
     "office/office.mbt",
     '          if self_closing {\n            items.push("")\n            current = None\n          } else {\n            current = Some(StringBuilder())\n          }',
     '          current = Some(StringBuilder())',
     "excel latches and index integrity: f-is-si self-closing and bounded indices"),

    ("complete entity syntax that does not decode must refuse, not leak markup",
     "office/xml.mbt",
     '      _ => raise @base.Fault("xml_entity_unknown: " + body)',
     '      _ => return None',
     "xml scanner refuses markup the deterministic contract excludes"),

    ("illegal entity codepoints must refuse instead of emitting control bytes",
     "office/xml.mbt",
     '  if !legal { @base.fail("xml_entity_codepoint_invalid: " + body) }',
     '  if !legal { return None }',
     "xml scanner refuses markup the deterministic contract excludes"),

    # The length check is the primary bound; the per-step accumulator cap is
    # registered as defense-in-depth (deleting it alone keeps the exact refusal
    # via the range check -- same observable behavior, so no mutation binds).
    ("decimal parsing must refuse overflow instead of wrapping back into range",
     "office/office.mbt",
     '  if value.length() > 18 {\n    return None\n  }\n',
     '',
     "excel latches and index integrity: f-is-si self-closing and bounded indices"),

    ("slide parts outside the slide<N>.xml pattern must refuse the package",
     "office/office.mbt",
     '        @base.fail("office_slide_unnamed: " + file.path)',
     '        ()',
     "slides: named-pattern enforcement and a:t-only text"),

    ("duplicate slide numbers must refuse, not reorder ambiguously",
     "office/office.mbt",
     '            @base.fail("office_slide_duplicate: " + file.path)',
     '            ()',
     "slides: named-pattern enforcement and a:t-only text"),

    ("slide text is only what renders: a:t leaves and nothing else",
     "office/office.mbt",
     '      Text(value) => if capturing { out.write_string(value) }\n    }\n  }\n  out.to_string()\n}\n\n// ---------------------------------------------------------------- Entry',
     '      Text(value) => out.write_string(value)\n    }\n  }\n  out.to_string()\n}\n\n// ---------------------------------------------------------------- Entry',
     "slides: named-pattern enforcement and a:t-only text"),

    # 续十六 second-round corrections (sidecar): replay echoes the booked
    # path, and the lint stale predicate follows the digest like context does.
    ("a replayed sidecar must echo the booked source, not the requesting path",
     "agent/extraction.mbt",
     '      return { "source": @base.text(@base.field(stored, "source")), "path": path,',
     '      return { "source": source, "path": path,',
     "twin sources: replay echoes the booked path; the stale predicate follows the digest"),

    ("the stale predicate must follow the digest across twin sources",
     "agent/extraction.mbt",
     '      if e.kind == "raw" && !e.stale && (store.digest)(e.path) == Some(source_sha256) {\n        twin = true\n      }',
     '      if false { twin = true }',
     "twin sources: replay echoes the booked path; the stale predicate follows the digest"),

    # Extraction sidecar (extraction-submit). Review corrections: the submit-side
    # `(store.digest)(source) != entry.sha256` check is shadowed by `verify`
    # (active raws are digest-checked there first), so no mutation binds to it.
    # These bind to the checks that actually decide: the catalog gate on the
    # context lookup, the per-digest key, the OOXML override refusal, the
    # filename/content digest lock in validate_record, and the never-overwrite
    # conflict rule. Each is guarded by extraction_wbtest.mbt AND extraction_e2e.py.
    ("the context sidecar lookup must go through the catalog, not a bare path",
     "agent/extraction.mbt",
     '''  match entries.iter().find_first(e => e.path == path) {
    None => None
    Some(entry) => Some(@base.parse(@vault.required(store, entry.path)))
  }''',
     '''  match (store.read)(path) {
    None => None
    Some(text) => Some(@base.parse(text))
  }''',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("context must bind the sidecar to the current digest, not any registered one",
     "agent/extraction.mbt",
     '  match entries.iter().find_first(e => e.path == path) {',
     '  match entries.iter().find_first(e => e.path.has_prefix("state/extractions/")) {',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("office/html sources must refuse external extraction (extraction_override)",
     "agent/extraction.mbt",
     '  if @office.is_office_format(raw.format) || @htdoc.is_html_format(raw.format) {\n    // office 原件与 HTML 都有引擎自抽通道（续十一 / 续十七），外部结果不可遮蔽\n    @base.fail("extraction_override")\n  }',
     '',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("context must project HTML originals through the engine channel",
     "agent/orders.mbt",
     '  } else if @htdoc.is_html_format(source_entry.format) {',
     '  } else if false {',
     "context supplies the html body"),

    ("the engine channel must name itself per format (corridor-html-v1)",
     "agent/orders.mbt",
     '        "extractor": if @htdoc.is_html_format(source_entry.format) {\n          "corridor-html-v1"',
     '        "extractor": if false {\n          "corridor-html-v1"',
     "context supplies the html body"),

    ("unclosed script/style regions must refuse, never truncate the body",
     "htdoc/html.mbt",
     '        if !closed { @base.fail("html_unterminated_" + region) }',
     '        if false { @base.fail("html_unterminated_" + region) }',
     "unclosed script refuses instead of swallowing the tail"),

    ("numeric entities with illegal codepoints must refuse, not leak bytes",
     "htdoc/html.mbt",
     '  if !legal { @base.fail("html_entity_codepoint_invalid: &" + body + ";") }',
     '  if !legal { out.write_string(code_point_string(32)) }',
     "entities: numeric must decode, unknown names stay literal"),

    ("the sidecar filename digest must lock the content source digest",
     "core/records.mbt",
     '''    if entry.path != "state/extractions/" + source_sha256 + ".json" {
      @base.fail("extraction_record_identity_invalid")
    }''',
     '    if false { @base.fail("extraction_record_identity_invalid") }',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("a textual source must keep its own bytes when a sidecar shares the digest",
     "agent/orders.mbt",
     '  let sidecar = if office_text is None && !textual && !source_entry.stale {',
     '  let sidecar = if office_text is None && !source_entry.stale {',
     "a shared-digest sidecar never overrides a textual source's own bytes"),

    ("a replayed channel must conflict on different text, never overwrite",
     "agent/extraction.mbt",
     '''      if @base.text(@base.field(stored, "text")) != submitted {
        @base.fail("extraction_conflict")
      }''',
     '      if false { @base.fail("extraction_conflict") }',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    # Lifecycle honesty (review findings 3/4/5): the gates behind the rewritten
    # hints and the one-way lifecycle must actually fire, or the documented
    # recovery path is a lie the next host learns the hard way.
    ("a second extractor must not silently inherit an active sidecar (exists gate)",
     "agent/extraction.mbt",
     '''      if stored_extractor != extractor || stored_version != version {
        @base.fail("extraction_exists: " + stored_extractor + ":" + stored_version)
      }''',
     '      if false { @base.fail("extraction_exists") }',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("a revoked source must not reopen its sidecar channel (stale gate)",
     "agent/extraction.mbt",
     '  if raw.stale { @base.fail("extraction_source_stale") }\n',
     '',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("an orphan event without its registered sidecar must be refused, not absorbed",
     "agent/extraction.mbt",
     '  if (store.read)(event_path) is Some(_) { @base.fail("extraction_event_conflict") }\n',
     '',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("the text cap must count UTF-8 bytes, not characters (transport's unit)",
     "core/records.mbt",
     '  if value.is_empty() || @base.utf8_size(value) > EXTRACTION_TEXT_LIMIT || value.contains("\\r") {',
     '  if value.is_empty() || value.length() > EXTRACTION_TEXT_LIMIT || value.contains("\\r") {',
     "extraction sidecar e2e:",
     "extraction_e2e.py"),

    ("literal reader must skip line comments like moon does",
     "base/literal.mbt",
     "    if unit == b'/'.to_uint16() && i + 1 < code.length() && code[i+1] == b'/'.to_uint16() {",
     "    if false {",
     "catalog accepts moon-equivalent formatting, comments and escapes"),
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
