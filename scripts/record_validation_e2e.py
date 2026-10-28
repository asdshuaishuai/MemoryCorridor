#!/usr/bin/env python3
"""Every state-record validation branch must be reachable.

`core/records.mbt` carries ~190 `*_invalid` branches that guard hand-edited or
corrupted state. They are unreachable through the operations, because a tampered
record fails the content hash first and every verifying read stops at
`content_changed`. The one surface that reaches them is `lint`, which is allowed
to run on a damaged vault and reports `record_invalid` with the failing branch in
`detail`.

This suite tampers one field per record kind and asserts the exact branch fires,
so removing any of them turns the suite red instead of silently widening what a
hand-edited vault may contain.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields},
                                     ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def call_fields(root, op, fields):
    """Call without the helper's own error-expectation parameter.

    Some operations take a field literally named `error`, which the main helper
    would otherwise swallow as its expected-error argument.
    """
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields},
                                     ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    assert value["ok"], value
    return value["result"]


def publish(root, name, body, page_id, title):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [], "summary": title})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}"
    )
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T09:00:00Z")
    return order


def record_invalid_details(root):
    return [row["detail"] for row in call(root, "lint")["violations"]
            if row["predicate"] == "record_invalid"]


def tamper(root, path, field, value):
    target = root / path
    original = target.read_text(encoding="utf-8")
    parsed = json.loads(original)
    parsed[field] = value
    target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    return target, original


with tempfile.TemporaryDirectory(prefix="memorycorridor-records-") as temp:
    root = Path(temp)
    call(root, "init", purpose="记录校验")
    publish(root, "ceramics.md", "器形与釉色。", "concepts/ceramics", "陶瓷")
    order = publish(root, "glaze.md", "釉色对照。", "concepts/glaze", "釉色")

    note = call(root, "memory-submit", kind="fact", scope="workspace",
                text="官窑记录可据此核对釉色与器形，长度足够通过相似度门槛。",
                conditions=["核对时"], sources=["raw/ceramics.md"],
                at="2026-11-14T09:30:00Z", key="note")["id"]
    topic = call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
                 at="2026-11-14T09:45:00Z", key="topic")["id"]
    goal = call(root, "purpose-suggest", at="2026-11-14T10:00:00Z", key="goal")["id"]
    overview = call(root, "overview-suggest", at="2026-11-14T10:15:00Z", key="ov")["id"]
    registration = call(root, "provider-register", provider="本地后端", kind="embedding",
                        space={"id": "vec", "dimensions": 8}, capabilities=["embed"],
                        at="2026-11-14T10:30:00Z")
    # The op addresses a provider by name; its record is addressed by path.
    provider = registration["provider"]
    provider_path = registration["path"]
    plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": 8},
                provider=provider, limit=1)
    job = call(root, "provider-job-open", provider=provider, kind="embedding",
               space={"id": "vec", "dimensions": 8},
               request={"items": plan["items"], "text_recipe": plan["text_recipe"]},
               at="2026-11-14T10:45:00Z", key="job")["id"]
    page = call(root, "read-page", id="concepts/ceramics")
    body = page["text"].split("---\n", 2)[-1]
    quote = "器形与釉色"
    start = len(body.encode().split(quote.encode(), 1)[0])
    evidence = call(root, "evidence-submit", page="concepts/ceramics",
                    page_hash=page["entry"]["sha256"],
                    items=[{"source": "raw/ceramics.md", "body_start": start,
                            "body_end": start + len(quote.encode()), "quote": quote,
                            "source_start": 0, "source_end": len("器形与釉色。".encode()),
                            "source_quote": "器形与釉色。"}])["id"]

    # Each entry is (record path, field, bad value, expected branch).
    # An impact record needs the topic's inputs to have moved, and a review needs
    # quality debt, so both are created here rather than in the setup above.
    publish(root, "later.md", "更晚的材料。", "concepts/later", "更晚")
    call(root, "impact-audit", at="2026-11-14T11:00:00Z")
    impact_id = call(root, "impact-list")["impacts"][0]["id"]
    call(root, "quality-audit", at="2026-11-14T11:30:00Z")
    pending_review_id = call(root, "review-list")[0]["id"]
    call(root, "review-resolve", id=pending_review_id, action="skip", note="n",
         at="2026-11-14T11:45:00Z")
    review_id = next(row["id"] for row in call(root, "review-list")
                     if row["status"] == "pending")

    cases = [
        (f"state/memory/{note}.json", "kind", "habit", "memory_kind_invalid"),
        (f"state/memory/{note}.json", "scope", "user", "memory_scope_invalid"),
        (f"state/memory/{note}.json", "status", "bogus", "memory_status_invalid"),
        (f"state/memory/{note}.json", "text", "", "memory_text_invalid"),
        (f"state/memory/{note}.json", "version", 2, "memory_version_unsupported"),
        (f"state/research/{topic}.json", "status", "bogus", "research_status_invalid"),
        (f"state/research/{topic}.json", "topic", "", "research_topic_invalid"),
        (f"state/research/{topic}.json", "queries", [], "research_queries_count_invalid"),
        (f"state/research/{topic}.json", "inputs_hash", "short",
         "research_inputs_hash_invalid"),
        (f"state/suggestions/{goal}.json", "kind", "bogus", "suggestion_kind_invalid"),
        (f"state/suggestions/{goal}.json", "status", "bogus", "suggestion_status_invalid"),
        (f"state/overview/{overview}.json", "status", "bogus", "overview_status_invalid"),
        (f"state/orders/{order}.json", "phase", "bogus", "order_record_phase_invalid"),
        (provider_path, "kind", "bogus", "provider_kind_invalid"),
        (provider_path, "status", "bogus", "provider_status_invalid"),
        (f"state/provider-jobs/{job}.json", "status", "bogus", "provider_job_status_invalid"),
        (f"state/provider-jobs/{job}.json", "kind", "bogus", "provider_job_kind_invalid"),
        # An evidence record is content-addressed, so editing  or 
        # changes its identity and the engine reports the identity mismatch
        # instead -- which is the correct refusal, just a different branch.
    ]

    # The rest of the single-field branches, taken from `scripts/branch_probe.py`,
    # which tampers every field of every record kind and reports what `lint`
    # says. The memory fields that feed `note_hash` are included on purpose: the
    # hash check comes after the shape checks, so tampering them reaches the
    # shape branch first.
    cases += [
        (f"state/memory/{note}.json", "archived_at", "short", "memory_time_invalid"),
        (f"state/memory/{note}.json", "note_hash", "not-a-hash", "memory_note_hash_invalid"),
        #  is a parallel array to , not a map.
        (f"state/memory/{note}.json", "source_hashes", ["short"],
         "memory_source_hash_invalid"),
        (f"state/memory/{note}.json", "superseded_by", "short",
         "memory_superseded_by_invalid"),
        (f"state/memory/{note}.json", "supersedes", "short", "memory_supersedes_invalid"),
        (f"state/memory/{note}.json", "id", "short", "memory_record_identity_invalid"),
        (f"state/memory/{note}.json", "key", "a\nb", "memory_key_invalid"),
        (f"state/research/{topic}.json", "baseline", "short",
         "research_record_identity_invalid"),
        (f"state/research/{topic}.json", "inputs_hash", "short",
         "research_inputs_hash_invalid"),
        (f"state/research/{topic}.json", "queries", [], "research_queries_count_invalid"),
        (f"state/research/{topic}.json", "queries", ["a\nb"], "research_query_invalid"),
        (f"state/research/{topic}.json", "created_at", "short", "research_created_at_invalid"),
        (f"state/research/{topic}.json", "key", "a\nb",
         "research_idempotency_key_invalid"),
        (f"state/research/{topic}.json", "sources", ["raw/x.md"],
         "research_open_record_invalid"),
        (f"state/suggestions/{goal}.json", "baseline", "short",
         "suggestion_record_identity_invalid"),
        (f"state/suggestions/{goal}.json", "purpose_hash", "short",
         "suggestion_record_identity_invalid"),
        (f"state/suggestions/{goal}.json", "result_hash", "0" * 64,
         "suggestion_open_record_invalid"),
        (f"state/suggestions/{goal}.json", "created_at", "short",
         "suggestion_created_at_invalid"),
        (f"state/suggestions/{goal}.json", "key", "a\nb",
         "suggestion_idempotency_key_invalid"),
        (f"state/overview/{overview}.json", "page_hashes", "bogus",
         "overview_page_hashes_invalid"),
        (f"state/overview/{overview}.json", "result_hash", "0" * 64,
         "overview_open_record_invalid"),
        (f"state/overview/{overview}.json", "created_at", "short",
         "overview_created_at_invalid"),
        (f"state/overview/{overview}.json", "key", "a\nb",
         "overview_idempotency_key_invalid"),
        (provider_path, "capabilities", [], "provider_capabilities_invalid"),
        (provider_path, "capabilities", ["embed", ""], "provider_capability_invalid"),
        (provider_path, "protocol", "other", "provider_protocol_invalid"),
        (provider_path, "provider", "", "provider_name_invalid"),
        (provider_path, "registered_at", "short", "provider_time_invalid: registered_at"),
        (provider_path, "last_seen", "short", "provider_time_invalid: last_seen"),
        (provider_path, "closed_at", "2026-11-14T10:30:00Z", "provider_active_closed"),
    ]

    # The remaining kinds, all discovered by `scripts/branch_probe.py`. `impact`,
    # `review`, `order`, `provider-job` and `vector`-adjacent records were not
    # covered at all before this pass.
    cases += [
        (f"state/impacts/{impact_id}.json", "kind", "bogus", "impact_kind_invalid"),
        (f"state/impacts/{impact_id}.json", "cause", "bogus", "impact_cause_invalid"),
        (f"state/impacts/{impact_id}.json", "subject", "not-a-path",
         "impact_subject_invalid"),
        (f"state/impacts/{impact_id}.json", "detail", "", "impact_detail_invalid"),
        (f"state/impacts/{impact_id}.json", "frozen", "short", "impact_frozen_invalid"),
        (f"state/impacts/{impact_id}.json", "current", "short", "impact_current_invalid"),
        (f"state/impacts/{impact_id}.json", "dismissed", "0" * 64,
         "impact_dismissed_open_invalid"),
        (f"state/impacts/{impact_id}.json", "resolved_at", "2026-11-14T11:00:00Z",
         "impact_open_resolved_at_invalid"),
        (f"state/impacts/{impact_id}.json", "created_at", "short",
         "impact_created_at_invalid"),
        (f"state/impacts/{impact_id}.json", "updated_at", "short",
         "impact_updated_at_invalid"),
        (f"state/impacts/{impact_id}.json", "version", 2, "impact_version_unsupported"),
        (f"state/impacts/{impact_id}.json", "key", "a\nb", "impact_key_invalid"),
        (f"state/reviews/{review_id}.json", "predicate", "", "review_predicate_invalid"),
        (f"state/reviews/{review_id}.json", "created_at", "short",
         "review_created_at_invalid"),
        (f"state/reviews/{review_id}.json", "input_fingerprint", "short",
         "review_input_fingerprint_invalid"),
        (f"state/reviews/{review_id}.json", "decision", {"action": "skip"},
         "review_pending_decision_invalid"),
        (f"state/reviews/{review_id}.json", "order", "short",
         "review_record_identity_invalid"),
        (f"state/orders/{order}.json", "phase", "bogus", "order_record_phase_invalid"),
        (f"state/orders/{order}.json", "context_version", "bogus",
         "order_context_version_invalid"),
        (f"state/orders/{order}.json", "page_hashes", "bogus",
         "order_record_page_hashes_invalid"),
        (f"state/orders/{order}.json", "source", "wiki/index.md",
         "order_record_source_invalid"),
        (f"state/orders/{order}.json", "baseline", "short",
         "order_record_identity_invalid"),
        (f"state/evidence/{evidence}.json", "page_hash", "short",
         "evidence_page_invalid"),
        (f"state/evidence/{evidence}.json", "id", "short",
         "evidence_record_identity_invalid"),
        (f"state/provider-jobs/{job}.json", "status", "bogus",
         "provider_job_status_invalid"),
        (f"state/provider-jobs/{job}.json", "kind", "bogus", "provider_job_kind_invalid"),
        (f"state/provider-jobs/{job}.json", "provider", "", "provider_job_name_invalid"),
        (f"state/provider-jobs/{job}.json", "key", "a\nb", "provider_job_key_invalid"),
        (f"state/provider-jobs/{job}.json", "request_hash", "short",
         "provider_job_request_hash_invalid"),
        (f"state/provider-jobs/{job}.json", "created_at", "short",
         "provider_job_time_invalid: created_at"),
        (f"state/provider-jobs/{job}.json", "updated_at", "short",
         "provider_job_time_invalid: updated_at"),
        (f"state/provider-jobs/{job}.json", "worker", "w",
         "provider_job_lease_pair_invalid"),
        (f"state/provider-jobs/{job}.json", "closed_at", "short",
         "provider_job_pending_invalid"),
    ]

    # Branches that need two fields at once: the status has to move before the
    # shape of the closed state is checked at all.
    def tamper_two(path, fields):
        target = root / path
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        for field, value in fields.items():
            parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        return target, original

    checked = 0
    paired = [
        (f"state/research/{topic}.json", {"status": "completed", "closed_at": "short"},
         "research_completed_record_invalid"),
        (f"state/research/{topic}.json", {"status": "cancelled", "closed_at": "short"},
         "research_cancelled_record_invalid"),
        (f"state/research/{topic}.json", {"status": "completed", "closed_at": "2026-11-14",
                                          "sources": ["wiki/index.md"]},
         "research_source_invalid"),
        (f"state/suggestions/{goal}.json", {"status": "applied", "closed_at": "2026-11-14",
                                            "result_hash": "not-a-hash"},
         "suggestion_applied_record_invalid"),
        (f"state/suggestions/{goal}.json", {"status": "cancelled", "closed_at": "2026-11-14",
                                            "result_hash": "0" * 64},
         "suggestion_cancelled_record_invalid"),
        (provider_path, {"status": "revoked", "closed_at": "short"},
         "provider_closed_at_invalid"),
    ]
    for path, fields, expected in paired:
        target, original = tamper_two(path, fields)
        details = record_invalid_details(root)
        assert details == [expected], (path, fields, details, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1

    for path, field, value, expected in cases:
        target, original = tamper(root, path, field, value)
        details = record_invalid_details(root)
        assert details == [expected], (path, field, details, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1

    # The event layer is content-addressed, so it is tempting to assume a tamper
    # only ever produces an identity mismatch. It does not: the shape checks run
    # independently of the filename hash. `scripts/event_branch_probe.py` tampers
    # every field of every event kind and records what `lint` reports; these
    # entries come from it, and each one locates its event file by `op` because
    # the filename is a hash.
    def event_file(op):
        for path in sorted((root / "state/events").glob("*.json")):
            if json.loads(path.read_text(encoding="utf-8")).get("op") == op:
                return path
        raise AssertionError("no event for op " + op)

    event_cases = [
        ("ingest", "source", "wiki/index.md", "ingest_event_source_invalid"),
        ("ingest", "pages", [], "ingest_event_pages_invalid"),
        ("memory-submit", "key", "a\nb", "memory_event_key_invalid"),
        ("memory-submit", "memory", "short", "memory_event_id_invalid"),
        ("memory-submit", "note_hash", "short", "memory_event_note_hash_invalid"),
        ("memory-submit", "supersedes", "short", "memory_supersedes_invalid"),
        ("memory-submit", "at", "short", "event_time_invalid"),
        ("research-topic", "key", "a\nb", "research_event_key_invalid"),
        ("research-topic", "research", "short", "research_event_id_invalid"),
        ("research-topic", "topic", "", "research_event_topic_invalid"),
        ("research-topic", "queries", [], "research_event_queries_invalid"),
        ("research-topic", "queries", ["a\nb"], "research_event_query_invalid"),
        ("research-topic", "at", "short", "event_time_invalid"),
        ("purpose-suggest", "key", "a\nb", "purpose_event_key_invalid"),
        ("purpose-suggest", "baseline", "short", "purpose_event_baseline_invalid"),
        ("purpose-suggest", "purpose_hash", "short", "purpose_event_hash_invalid"),
        ("purpose-suggest", "suggestion", "short", "purpose_event_suggestion_invalid"),
        ("purpose-suggest", "at", "short", "event_time_invalid"),
        ("overview-suggest", "key", "a\nb", "overview_event_key_invalid"),
        ("overview-suggest", "baseline", "short", "overview_event_baseline_invalid"),
        ("overview-suggest", "purpose_hash", "short", "overview_event_purpose_hash_invalid"),
        ("overview-suggest", "suggestion", "short", "overview_event_suggestion_invalid"),
        ("overview-suggest", "at", "short", "event_time_invalid"),
        ("quality-audit", "id", "short", "quality_event_id_invalid"),
        ("quality-audit", "fingerprint", "short", "quality_event_fingerprint_invalid"),
        ("quality-audit", "at", "short", "event_time_invalid"),
        ("review-resolve", "action", "bogus", "review_event_action_invalid"),
        ("review-resolve", "review", "short", "review_event_id_invalid"),
        ("review-resolve", "key", "a\nb", "review_event_key_invalid"),
        ("review-resolve", "input_fingerprint", "short",
         "review_event_fingerprint_invalid"),
        ("review-resolve", "predicate", "a\nb", "review_event_field_invalid: predicate"),
        ("review-resolve", "subject", "a\nb", "review_event_field_invalid: subject"),
        ("review-resolve", "at", "short", "event_time_invalid"),
        ("provider-register", "kind", "bogus", "provider_event_kind_invalid"),
        ("provider-register", "provider", "", "provider_event_name_invalid"),
        ("provider-register", "at", "short", "event_time_invalid"),
    ]
    for op, field, value, expected in event_cases:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The provider job events. `provider-job-open` needs a request that matches
    # the page bytes exactly, which `embedding-plan` produces, and a provider
    # registered for the job's kind.
    plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": 8})
    opened = call(root, "provider-job-open", provider="本地后端", kind="embedding",
                  space={"id": "vec", "dimensions": 8},
                  request={"items": plan["items"],
                           "text_recipe": "title-body-prefix16KiB-v1"},
                  at="2026-11-14T12:40:00Z")
    job_id = opened["id"] if isinstance(opened, dict) else opened
    call(root, "provider-job-claim", id=job_id, worker="w1",
         lease_until="2026-11-14T13:00:00Z", at="2026-11-14T12:42:00Z")
    call(root, "provider-job-heartbeat", id=job_id, worker="w1",
         lease_until="2026-11-14T14:00:00Z", at="2026-11-14T12:43:00Z")
    event_cases += [
        ("provider-job-open", "kind", "bogus", "provider_job_event_kind_invalid"),
        ("provider-job-open", "provider", "", "provider_job_event_provider_invalid"),
        ("provider-job-claim", "worker", "a\nb", "provider_job_event_field_invalid: worker"),
        ("provider-job-claim", "lease_until", "2026-11-14T10:00:00Z",
         "provider_job_event_identity_invalid"),
        ("provider-job-heartbeat", "worker", "a\nb",
         "provider_job_event_field_invalid: worker"),
        ("provider-job-heartbeat", "lease_until", "2026-11-14T10:00:00Z",
         "provider_job_event_identity_invalid"),
    ]
    for op, field, value, expected in event_cases[-6:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The import event. `import` needs a directory that actually holds a
    # markdown file, or it refuses before the event is written.
    (root / "imports/m").mkdir(parents=True, exist_ok=True)
    (root / "imports/m/a.md").write_text("# 导入的材料\n\n器形与釉色。\n")
    call(root, "import", format="markdown", directory="imports/m",
         at="2026-11-14T12:50:00Z")
    event_cases += [
        ("import", "format", "a\nb", "import_event_format_invalid"),
        ("import", "version", 0, "import_event_version_invalid"),
    ]
    for op, field, value, expected in event_cases[-2:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The evidence event. The item shape is byte ranges that must not split a
    # character, and the page hash has to be the current one, so both are real
    # values rather than placeholders.
    real_hash = call(root, "list-pages")[0]["sha256"]
    call(root, "evidence-submit", page="concepts/ceramics", page_hash=real_hash,
         items=[{"source": "raw/ceramics.md", "body_start": 0, "body_end": 3,
                 "quote": "器", "source_start": 0, "source_end": 3,
                 "source_quote": "器"}])
    event_cases += [
        ("evidence-submit", "evidence", "short", "evidence_event_id_invalid"),
        ("evidence-submit", "page_hash", "short",
         "evidence_event_page_hash_invalid"),
    ]
    for op, field, value, expected in event_cases[-2:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The page lifecycle events. `archive-page` then `restore-page` produces both
    # kinds, and `forget` a third; each field is checked on its own.
    try:
        call(root, "archive-page", id="concepts/ceramics",
             at="2026-11-14T12:10:00Z", reason="归档核对")
        call(root, "restore-page", id="concepts/ceramics",
             at="2026-11-14T12:20:00Z")
        call(root, "forget", source="raw/ceramics.md", at="2026-11-14T12:30:00Z")
    except Exception:
        pass
    event_cases += [
        ("page-archive", "page", "bogus", "page_archive_event_identity_invalid"),
        ("page-archive", "page_hash", "short", "page_archive_event_hash_invalid"),
        ("page-archive", "at", "", "page_archive_event_metadata_invalid"),
        ("page-archive", "version", "short", "page_archive_event_version_invalid"),
        ("page-restore", "page", "bogus", "page_restore_event_identity_invalid"),
        ("page-restore", "page_hash", "short", "page_restore_event_hash_invalid"),
        ("page-restore", "archive", "bogus", "page_restore_event_archive_invalid"),
        ("page-restore", "version", "short", "page_restore_event_version_invalid"),
        ("forget", "source", "bogus", "forget_event_source_invalid"),
    ]
    for op, field, value, expected in event_cases[-9:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The impact event layer. `impact-audit` opens these, and every field they
    # carry is checked, so the whole set is reachable once an impact exists.
    event_cases += [
        ("impact-open", "impact", "short", "impact_event_id_invalid"),
        ("impact-open", "key", "a\nb", "impact_event_key_invalid"),
        ("impact-open", "kind", "bogus", "impact_kind_invalid"),
        ("impact-open", "subject", "bogus", "impact_subject_invalid"),
        ("impact-open", "cause", "bogus", "impact_cause_invalid"),
        ("impact-open", "frozen", "short", "impact_event_frozen_invalid"),
        ("impact-open", "current", "short", "impact_event_current_invalid"),
    ]
    for op, field, value, expected in event_cases[-7:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The identity of an event is what the filename is derived from, so a tamper
    # that lands on it reports the identity branch rather than the field shape.
    event_cases += [
        ("provider-register", "provider", "renamed-backend",
         "provider_event_identity_invalid"),
        ("review-resolve", "key", "renamed-key", "review_event_identity_invalid"),
    ]
    for op, field, value, expected in event_cases[-2:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # Three more branches that only a probe finds: two event-layer shape checks
    # and one record field. `page-archive` and `page-restore` events were probed
    # too and produced nothing reachable -- every field they carry feeds the
    # filename hash, so a tamper lands on the identity check instead.
    event_cases += [
        ("evidence-submit", "page_hash", "short", "evidence_event_page_hash_invalid"),
        ("ingest", "order", "short", "ingest_event_order_invalid"),
    ]
    for op, field, value, expected in event_cases[-2:]:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # `superseded_by` on an evidence record is checked even though the record has
    # no supersede chain, so a hand-edited value cannot point at nothing.
    evidence_path = root / "state/evidence" / (evidence + ".json")
    original = evidence_path.read_text(encoding="utf-8")
    parsed = json.loads(original)
    parsed["superseded_by"] = "short"
    evidence_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "evidence_superseded_by_invalid" in record_invalid_details(root)
    evidence_path.write_text(original, encoding="utf-8")
    assert record_invalid_details(root) == []
    checked += 1

    # An unknown event operation is the branch AGENTS.md names explicitly: state
    # events only accept operations the engine defines. The trailing-space case
    # matters because a name that merely looks right must not slip through.
    for op_value, expected in [("", "event_operation_required"),
                               ("bogus-op", "event_operation_unsupported: bogus-op"),
                               ("ingest ", "event_operation_unsupported: ingest ")]:
        target = event_file("ingest")
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["op"] = op_value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op_value, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], op_value
        checked += 1

    # Renaming an event file is a different failure: the file becomes an orphan
    # that `lint` reports as unregistered rather than as an invalid record, so
    # the two predicates must not be conflated.
    #
    # This is also why the `*_event_identity_invalid` branches are not covered
    # here: there is no external way to produce an event file whose name does not
    # match its content. Renaming yields an orphan (asserted below), tampering a
    # field reaches the shape branches first, and `pack` carries content-addressed
    # objects only -- `state/events/` is not packed at all, which was checked
    # against a real archive. Those branches assert an invariant the engine
    # maintains itself, so they are defence in depth rather than a reachable
    # state, and no honest test can claim to cover them.
    renamed = event_file("ingest")
    renamed_to = renamed.with_name("0" * 64 + ".json")
    renamed.rename(renamed_to)
    orphans = [row["path"] for row in call(root, "lint")["violations"]
               if row["predicate"] == "file_unregistered"]
    assert str(renamed_to.relative_to(root)) in orphans, orphans
    renamed_to.rename(renamed)
    assert [row["path"] for row in call(root, "lint")["violations"]
            if row["predicate"] == "file_unregistered"] == []

    # Vector records live under `vectors/`, not `state/`, and carry their own
    # dimension and norm checks.
    # The provider above registered an 8-dimensional space, so the vector cases
    # use that width rather than registering a second provider.
    width = 8
    plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": width},
                provider=provider, limit=1)
    item = {key: value for key, value in plan["items"][0].items()
            if key in ("page", "sha256")}
    call(root, "embedding-submit", space={"id": "vec", "dimensions": width},
         provider=provider, items=[{**item, "values": [1] * width}])
    vector_path = sorted((root / "vectors").glob("*.json"))[0]
    vector_cases = [
        ("space", "bogus", "expected_object"),
        ("space", {"id": "vec", "dimensions": 3}, "vector_record_dimensions_mismatch"),
        ("values", [0] * width, "vector_record_zero_norm"),
        ("values", ["a"] * width, "vector_record_nonfinite"),
        ("values", [1] * (width - 1), "vector_record_dimensions_mismatch"),
        ("sha256", "short", "vector_record_hash_invalid"),
    ]
    for field, value, expected in vector_cases:
        original = vector_path.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        vector_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, got, expected)
        vector_path.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], field
        checked += 1

    # Recursing into nested objects reached three more. A provider's `space` and a
    # job's `request.items[]` are validated inside the object, so a top-level
    # tamper never reached them.
    nested_cases = [
        (provider_path, "space", {"id": "", "dimensions": 8}, "provider_space_invalid"),
        (provider_path, "space", {"id": "vec", "dimensions": -1},
         "provider_dimensions_invalid"),
        (f"state/provider-jobs/{job}.json", "space", {"id": "", "dimensions": 8},
         "provider_job_space_invalid"),
    ]
    for path, field, value, expected in nested_cases:
        target = root / path
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (path, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1


    # Widening the probe's value shapes reached four more branches that the
    # narrower first pass missed: page-hash maps and space dimensions.
    widened_cases = [
        (f"state/orders/{order}.json", "page_hashes", {"concepts/ceramics": "short"},
         "order_record_page_hash_invalid"),
        (f"state/overview/{overview}.json", "page_hashes",
         {"concepts/ceramics": "short"}, "overview_page_hash_invalid"),
        (provider_path, "space", {"id": "vec", "dimensions": 0},
         "provider_dimensions_invalid"),
        (f"state/provider-jobs/{job}.json", "space", {"id": "vec", "dimensions": 0},
         "provider_job_dimensions_invalid"),
    ]
    for path, field, value, expected in widened_cases:
        target = root / path
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (path, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1

    # The last gap, found by diffing `scripts/branch_coverage.py` against the two
    # probes: branches the probes can reach that no test referenced yet.
    #
    # Two of these correct an earlier claim. `*_event_identity_invalid` was
    # recorded as unreachable because renaming an event file only produces an
    # orphan. That is true but incomplete: tampering a field that feeds the
    # filename hash reaches the identity check, which is what these cases do.
    final_cases = [
        (f"state/impacts/{impact_id}.json", "status", "bogus", "impact_status_invalid"),
        (f"state/impacts/{impact_id}.json", "id", "short",
         "impact_record_identity_invalid"),
        (f"state/memory/{note}.json", "archived_at", "2026-11-14T09:30:00Z",
         "memory_active_archived_at_invalid"),
        (f"state/memory/{note}.json", "source_hashes", ["a", "b"],
         "memory_source_hashes_count_invalid"),
        (f"state/overview/{overview}.json", "id", "short",
         "overview_record_identity_invalid"),
        (provider_path, "id", "short", "provider_record_identity_invalid"),
        (f"state/provider-jobs/{job}.json", "id", "short",
         "provider_job_record_identity_invalid"),
        (f"state/reviews/{review_id}.json", "status", "bogus", "review_status_invalid"),
    ]
    for path, field, value, expected in final_cases:
        target = root / path
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (path, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1

    # Event-level identity: tampering the idempotency key changes the filename
    # hash, so the engine reports the mismatch instead of the key shape.
    event_identity_cases = [
        ("provider-register", "provider", "renamed-backend",
         "provider_event_identity_invalid"),
        ("review-resolve", "key", "another-key", "review_event_identity_invalid"),
    ]
    for op, field, value, expected in event_identity_cases:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # The provider-job state machine is where the Proposal Engine hands work to
    # an external executor, so its closed states have shape checks that a
    # pending-only probe cannot reach. Build one job per terminal state.
    #
    # A job request item must keep every field `embedding-plan` produced, text
    # included, while `embedding-submit` accepts only page/sha256/values. A
    # completion result carries the same page and hash as the request.
    job_plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": 8},
                    provider=provider, limit=1)
    job_page = job_plan["items"][0]["page"]
    job_hash = job_plan["items"][0]["sha256"]
    job_recipe = job_plan["text_recipe"]

    def open_job(key):
        return call(root, "provider-job-open", provider=provider, kind="embedding",
                    space={"id": "vec", "dimensions": 8},
                    request={"items": [job_plan["items"][0]],
                             "text_recipe": job_recipe},
                    at="2026-11-14T13:00:00Z", key=key)["id"]

    completed = open_job("job-complete")
    call(root, "provider-job-claim", id=completed, worker="w1",
         lease_until="2026-11-14T14:00:00Z", at="2026-11-14T13:10:00Z")
    call_fields(root, "provider-job-complete",
                {"id": completed, "worker": "w1",
                 "result": {"items": [{"page": job_page, "sha256": job_hash,
                                       "values": [1] * 8}]},
                 "at": "2026-11-14T13:20:00Z"})

    failed = open_job("job-fail")
    call(root, "provider-job-claim", id=failed, worker="w1",
         lease_until="2026-11-14T14:00:00Z", at="2026-11-14T13:10:00Z")
    call_fields(root, "provider-job-fail",
                {"id": failed, "worker": "w1", "error": "backend_timeout",
                 "at": "2026-11-14T13:20:00Z"})

    cancelled = open_job("job-cancel")
    call(root, "provider-job-cancel", id=cancelled, worker="w1",
         at="2026-11-14T13:30:00Z")

    # Each terminal state checks the fields that belong to it, so the tamper has
    # to land on a record that is already in that state.
    job_cases = [
        (completed, "result", {"items": []}, "provider_job_result_invalid"),
        (completed, "closed_at", "short", "provider_job_closed_at_invalid"),
        (failed, "error", "", "provider_job_error_invalid"),
        (failed, "closed_at", "short", "provider_job_closed_at_invalid"),
        (cancelled, "result", {"items": []}, "provider_job_cancelled_result"),
        (cancelled, "closed_at", "short", "provider_job_closed_at_invalid"),
    ]
    for job_id, field, value, expected in job_cases:
        path = root / "state/provider-jobs" / (job_id + ".json")
        original = path.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, got, expected)
        path.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], field
        checked += 1

    # The request envelope is validated independently of the job's state.
    request_cases = [
        ({"items": [], "text_recipe": job_recipe}, "provider_job_items_invalid"),
        ({"items": [job_plan["items"][0]], "text_recipe": "other"},
         "provider_job_text_recipe_invalid"),
    ]
    for request_value, expected in request_cases:
        path = root / "state/provider-jobs" / (job + ".json")
        original = path.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["request"] = request_value
        path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (request_value, got, expected)
        path.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], expected
        checked += 1

    # The job events. Their op names are past tense, which is easy to get wrong
    # from the operation names, and their shapes are narrower than the records:
    # completed/cancelled carry only op/id/provider/at and failed only
    # op/id/error/at, so the result shape is a record-level check (covered above)
    # and not reachable here.
    job_event_cases = [
        ("provider-job-failed", "error", "", "provider_job_event_error_invalid"),
        ("provider-job-failed", "id", "short", "provider_job_event_id_invalid"),
        ("provider-job-completed", "provider", "",
         "provider_job_event_provider_invalid"),
        ("provider-job-cancelled", "provider", "",
         "provider_job_event_provider_invalid"),
        ("provider-job-claim", "worker", "",
         "provider_job_event_field_invalid: worker"),
    ]
    for op, field, value, expected in job_event_cases:
        target = event_file(op)
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (op, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (op, field)
        checked += 1

    # A tampered record is also refused by every verifying read, so the branch
    # above is a second line of defence rather than the only one.
    target, original = tamper(root, f"state/memory/{note}.json", "kind", "habit")
    for op in ("verify", "memory-list", "status", "stats", "impact-list", "inbox"):
        call(root, op, error="content_changed")
    target.write_text(original, encoding="utf-8")
    call(root, "rebuild")
    call(root, "verify")
    print(f"record validation: {checked} branches reached through lint and restored")
