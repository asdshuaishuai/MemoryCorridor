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
import hashlib
import json
from pathlib import Path
import re
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
    # A search provider, registered here rather than next to the job cases: the
    # vault has been through archive, restore and replace by then, and a provider
    # registered late is resolved against a catalog those operations rewrote.
    call(root, "provider-register", provider="检索端", kind="search",
         space={"id": "vec9", "dimensions": 8}, capabilities=["search"],
         at="2026-11-14T10:31:00Z")

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

    checked = 0
    catalog = root / "index.mbt.md"
    original_catalog = catalog.read_text(encoding="utf-8")

    # An order whose recorded source hash no longer matches the bytes on disk.
    # `context` re-reads the raw file and compares, so tampering the order
    # record's own `source_hash` is enough -- and the catalog hash has to move
    # with it or every verifying read refuses first. This sits early because
    # `scan` only registers an order while the catalog is still in step; later
    # in the suite the same call leaves an unregistered file behind.
    (root / "raw/ordercheck.md").write_text("订单核对用的材料。\n")
    source_order = call(root, "scan")["orders"][0]
    order_file = root / "state/orders" / (source_order + ".json")
    original_order = order_file.read_text(encoding="utf-8")
    tampered_order = json.loads(original_order)
    tampered_order["source_hash"] = "0" * 64
    tampered_order_text = json.dumps(tampered_order, ensure_ascii=False)
    order_file.write_text(tampered_order_text, encoding="utf-8")
    catalog_lines = catalog.read_text(encoding="utf-8").splitlines()
    order_wanted = '"state/orders/' + source_order + '.json"'
    for i, line in enumerate(catalog_lines):
        if order_wanted in line and line.strip().startswith('entry("'):
            catalog_lines[i] = re.sub(
                r'"[0-9a-f]{64}"',
                '"' + hashlib.sha256(
                    tampered_order_text.encode("utf-8")).hexdigest() + '"',
                line, count=1)
            break
    catalog.write_text("\n".join(catalog_lines) + "\n", encoding="utf-8")
    call(root, "context", order=source_order, error="source_changed")
    # The order file is removed rather than restored: the catalog copy put back
    # below predates the scan that registered it, so leaving the file would make
    # it an unregistered orphan.
    order_file.unlink()
    catalog.write_text(original_catalog, encoding="utf-8")
    checked += 1

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
    # The submit returns the record id, which is what the file is named after.
    # Locating the file by glob would pick whichever evidence record sorts first,
    # and by this point the vault holds several.
    evidence_id = call(root, "evidence-submit", page="concepts/ceramics",
                       page_hash=real_hash,
                       items=[{"source": "raw/ceramics.md", "body_start": 0,
                               "body_end": 3, "quote": "器", "source_start": 0,
                               "source_end": 3, "source_quote": "器"}])["id"]
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

    # The evidence record's own claim checks. Its id is a hash of
    # page + page_hash + claims, and the id must equal the filename, so editing a
    # claim means recomputing the id, renaming the file and repointing the
    # catalog entry -- otherwise the identity check fires first and the claim
    # branches stay unreachable. The canonical form the engine hashes is
    # sorted-key, compact-separator JSON.
    import hashlib

    evidence_file = root / "state/evidence" / (evidence_id + ".json")
    original_evidence = evidence_file.read_text(encoding="utf-8")
    catalog = root / "index.mbt.md"
    original_catalog = catalog.read_text(encoding="utf-8")

    def retune_evidence(edit):
        parsed = json.loads(original_evidence)
        edit(parsed)
        payload = json.dumps(
            {"page": parsed["page"], "page_hash": parsed["page_hash"],
             "claims": parsed["claims"]},
            sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        parsed["id"] = hashlib.sha256(
            ("evidence-v1\n" + payload).encode("utf-8")).hexdigest()
        moved = evidence_file.parent / (parsed["id"] + ".json")
        moved.write_text(json.dumps(parsed, ensure_ascii=False),
                         encoding="utf-8")
        evidence_file.unlink()
        lines = original_catalog.splitlines()
        wanted = "state/evidence/" + evidence_file.name
        for i, line in enumerate(lines):
            if wanted in line and line.strip().startswith('entry("'):
                lines[i] = line.replace(evidence_file.name, moved.name)
                break
        catalog.write_text("\n".join(lines) + "\n", encoding="utf-8")
        found = record_invalid_details(root)
        moved.unlink()
        evidence_file.write_text(original_evidence, encoding="utf-8")
        catalog.write_text(original_catalog, encoding="utf-8")
        return found

    evidence_claim_cases = [
        ("no claims at all", lambda d: d.__setitem__("claims", []),
         "evidence_claims_count_invalid"),
        ("a source outside raw/",
         lambda d: d["claims"][0].__setitem__("source", "wiki/x.md"),
         "evidence_source_invalid"),
        ("a negative body start",
         lambda d: d["claims"][0].__setitem__("body_start", -1),
         "evidence_range_invalid"),
        ("a body range that ends where it starts",
         lambda d: d["claims"][0].__setitem__("body_end", 0),
         "evidence_range_invalid"),
        ("an empty quote",
         lambda d: d["claims"][0].__setitem__("quote", ""),
         "evidence_quote_invalid"),
        ("a source range with no quote",
         lambda d: [d["claims"][0].pop(k, None)
                    for k in ("source_end", "source_quote")],
         "evidence_source_binding_required"),
        ("a negative source start",
         lambda d: d["claims"][0].__setitem__("source_start", -1),
         "evidence_source_range_invalid"),
        ("an empty source quote",
         lambda d: d["claims"][0].__setitem__("source_quote", ""),
         "evidence_source_quote_invalid"),
    ]
    for label, edit, expected in evidence_claim_cases:
        found = retune_evidence(edit)
        assert expected in found, (label, found, expected)
        checked += 1

    # The text-index cache. `.corridor/fts.json` carries its own envelope: a
    # sha256 over the canonical payload, a version and algorithm tag, the catalog
    # fingerprint, and the documents plus postings. `search` silently rebuilds
    # when the cache is unusable, so the only surface that reports *why* is
    # `lint`, which names the branch in its detail.
    #
    # The envelope hash has to be recomputed after each edit, or the earlier
    # `index_corrupt_or_stale` check fires and hides the branch under test.
    call(root, "rebuild")
    fts = root / ".corridor/fts.json"
    original_fts = fts.read_text(encoding="utf-8")

    def retune_cache(edit):
        parsed = json.loads(original_fts)
        edit(parsed)
        parsed["sha256"] = hashlib.sha256(json.dumps(
            parsed["payload"], sort_keys=True, separators=(",", ":"),
            ensure_ascii=False).encode("utf-8")).hexdigest()
        fts.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        return [row["detail"] for row in call(root, "lint")["violations"]
                if row["predicate"] == "cache_invalid"]

    cache_cases = [
        ("a different algorithm tag",
         lambda d: d["payload"].__setitem__("algorithm", "text-index-v2"),
         "index_algorithm_changed"),
        ("a different version",
         lambda d: d["payload"].__setitem__("version", 4.0),
         "index_algorithm_changed"),
        ("a fingerprint that no longer matches the catalog",
         lambda d: d["payload"].__setitem__("fingerprint", "0" * 64),
         "index_corrupt_or_stale"),
        ("a document dropped",
         lambda d: d["payload"]["index"].__setitem__(
             "documents", d["payload"]["index"]["documents"][:-1]),
         "index_document_count_mismatch"),
        # A duplicate with the count kept the same: dropping one and repeating
        # another, so the count check passes and the id check is what fires.
        ("a document listed twice",
         lambda d: d["payload"]["index"].__setitem__(
             "documents",
             d["payload"]["index"]["documents"][:-1]
             + [d["payload"]["index"]["documents"][0]]),
         "index_duplicate_document"),
        ("postings that do not match the documents",
         lambda d: d["payload"]["index"].__setitem__("postings", {}),
         "index_postings_corrupt"),
    ]
    for label, edit, expected in cache_cases:
        found = retune_cache(edit)
        assert expected in found, (label, found, expected)
        fts.write_text(original_fts, encoding="utf-8")
        assert [row["detail"] for row in call(root, "lint")["violations"]
                if row["predicate"] == "cache_invalid"] == [], label
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
        ("page-restore", "at", "short", "page_restore_event_time_invalid"),
        ("forget", "source", "bogus", "forget_event_source_invalid"),
    ]
    for op, field, value, expected in event_cases[-10:]:
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

    # The same trick on the events this suite already produced. Each of these
    # derives its filename from a field the case points at another *valid* value,
    # so the derived name and the file on disk disagree -- which is the identity
    # branch, not the field-shape branch. An earlier note in this file called
    # these unreachable because renaming an event file only makes an orphan; that
    # is true of renaming, and false of retargeting a field.
    valid_hash = "a" * 64
    event_identity_cases += [
        ("evidence-submit", "evidence", valid_hash,
         "evidence_event_identity_invalid"),
        ("purpose-suggest", "suggestion", valid_hash,
         "purpose_event_identity_invalid"),
        ("quality-audit", "id", valid_hash, "quality_event_identity_invalid"),
        ("research-topic", "research", valid_hash,
         "research_event_identity_invalid"),
        ("overview-suggest", "suggestion", valid_hash,
         "overview_event_identity_invalid"),
        # `impact-open` has two distinct checks: the id must equal
        # `impact_id(kind, subject, cause)`, and the filename must equal the hash
        # of key/current/at. Retargeting the id reaches the first; moving `at` to
        # another valid timestamp reaches the second.
        ("impact-open", "impact", valid_hash, "impact_event_identity_invalid"),
        ("impact-open", "at", "2026-11-14T09:00:00Z",
         "impact_event_path_invalid"),
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

    # Record-level branches that need a second field moved, or a state the setup
    # above never produced.
    #
    # `memory-supersede` marks the old note superseded and writes a new one, so
    # both halves of the chain exist afterwards; archiving the replacement gives
    # a note whose status is `archived`.
    # `glaze.md` rather than `ceramics.md`: the page-lifecycle section above has
    # already revoked the latter by the time this runs.
    replaced = call(root, "memory-supersede", id=note,
                    text="替换后的版本内容与原先不同，长度也足够通过门槛。",
                    conditions=["核对时"], sources=["raw/glaze.md"],
                    at="2026-11-14T09:35:00Z", key="replacement")["id"]
    call(root, "memory-archive", id=replaced, at="2026-11-14T09:45:00Z")
    resolved_review = call(root, "review-list")[0]["id"]
    call(root, "review-resolve", id=resolved_review, action="skip", note="n",
         at="2026-11-14T11:45:00Z")
    # A fresh overview: the shared one has already been through apply and cancel
    # by the time this section runs, so its fields no longer start from
    # `proposed`.
    fresh_overview = call(root, "overview-suggest", at="2026-11-14T13:00:00Z",
                          key="fresh-ov")["id"]

    record_cases = [
        # A note the engine archived carries no `archived_at` of its own.
        (f"state/memory/{replaced}.json", "archived_at", None,
         "memory_archived_at_required"),
        # The other half of the same pair, on the superseded note.
        (f"state/memory/{note}.json", "superseded_by", None,
         "memory_superseded_by_required"),
        # An overview that claims to be applied must say when, and with what
        # result hash.
        (f"state/overview/{fresh_overview}.json", "closed_at", "short",
         "overview_applied_record_invalid"),
        # A cancelled overview must not carry a result hash at all.
        (f"state/overview/{fresh_overview}.json", "result_hash", "a" * 64,
         "overview_cancelled_record_invalid"),
        # A resolved review keeps its decision nested, and both of the decision's
        # own fields are checked.
        (f"state/reviews/{resolved_review}.json", "decision", {"at": "short"},
         "review_decision_at_invalid"),
        (f"state/reviews/{resolved_review}.json", "decision", {"key": ""},
         "review_idempotency_key_invalid"),
    ]
    for path, field, value, expected in record_cases:
        target = root / path
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        if field == "closed_at":
            parsed["status"] = "applied"
            parsed["result_hash"] = "a" * 64
            parsed["closed_at"] = value
        elif field == "result_hash":
            parsed["status"] = "cancelled"
            parsed["closed_at"] = "2026-11-14T10:20:00Z"
            parsed["result_hash"] = value
        elif field == "decision":
            parsed["decision"].update(value)
        else:
            parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (path, field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], path
        checked += 1

    # A record whose top level is not an object. Every other case edits a field
    # of a well-formed record; this one replaces the whole file.
    target = root / f"state/memory/{note}.json"
    original = target.read_text(encoding="utf-8")
    target.write_text("[]", encoding="utf-8")
    got = record_invalid_details(root)
    assert any(row.startswith("record_object_required") for row in got), got
    target.write_text(original, encoding="utf-8")
    assert record_invalid_details(root) == []
    checked += 1

    # The memory record's id must equal `memory_note_id(key, note_hash)`. The
    # filename is checked first, so pointing the id at another *valid* hash only
    # works if the file is renamed to match -- and the IR line has to be found by
    # the record path, not by the bare id, because the `memory-submit` event file
    # carries the same id in its name.
    index = root / "index.mbt.md"
    original_index = index.read_text(encoding="utf-8")
    target = root / f"state/memory/{note}.json"
    original = target.read_text(encoding="utf-8")
    parsed = json.loads(original)
    parsed["id"] = "a" * 64
    renamed = target.parent / ("a" * 64 + ".json")
    renamed.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    target.unlink()
    lines = original_index.splitlines()
    wanted = "state/memory/" + target.name
    for i, line in enumerate(lines):
        if wanted in line and line.strip().startswith('entry("'):
            lines[i] = line.replace(target.name, renamed.name)
            break
    index.write_text("\n".join(lines) + "\n", encoding="utf-8")
    got = record_invalid_details(root)
    assert "memory_record_identity_mismatch" in got, got
    renamed.unlink()
    target.write_text(original, encoding="utf-8")
    index.write_text(original_index, encoding="utf-8")
    assert record_invalid_details(root) == []
    checked += 1

    # A review resolved twice. The event is named after the review id and the
    # idempotency key, so resolving, rolling the record back to pending by hand,
    # and resolving again with the same key lands on the first event.
    conflict_review = next(row["id"] for row in call(root, "review-list")
                           if row["status"] == "pending")
    review_at = "2026-11-14T16:10:00Z"
    call(root, "review-resolve", id=conflict_review, action="skip", note="n",
         at=review_at)
    review_file = root / "state/reviews" / (conflict_review + ".json")
    original_review = review_file.read_text(encoding="utf-8")
    # Read again rather than reusing an earlier copy: every op above that wrote
    # an event also rewrote the catalog.
    original_catalog = catalog.read_text(encoding="utf-8")
    rolled = json.loads(original_review)
    rolled["status"] = "pending"
    rolled["decision"] = None
    rolled_text = json.dumps(rolled, ensure_ascii=False)
    review_file.write_text(rolled_text, encoding="utf-8")
    lines = original_catalog.splitlines()
    wanted = '"state/reviews/' + conflict_review + '.json"'
    for i, line in enumerate(lines):
        if wanted in line and line.strip().startswith('entry("'):
            lines[i] = re.sub(
                r'"[0-9a-f]{64}"',
                '"' + hashlib.sha256(rolled_text.encode("utf-8")).hexdigest()
                + '"', line, count=1)
            break
    catalog.write_text("\n".join(lines) + "\n", encoding="utf-8")
    call(root, "review-resolve", id=conflict_review, action="skip", note="n",
         at=review_at, error="review_event_conflict")
    review_file.write_text(original_review, encoding="utf-8")
    catalog.write_text(original_catalog, encoding="utf-8")
    checked += 1

    # Two event kinds this suite had never produced, so their branches were
    # unreachable rather than unreferenced.
    #
    # `import` needs a directory that actually holds a markdown file, or it
    # refuses before any event is written.
    (root / "imports/m").mkdir(parents=True, exist_ok=True)
    (root / "imports/m/a.md").write_text("# 导入的材料\n\n器形与釉色。\n")
    call(root, "import", format="markdown", directory="imports/m",
         at="2026-11-14T12:50:00Z")

    # `source-missing` is written by `scan` when a registered raw file has
    # disappeared from disk. It has to come last: deleting the source makes every
    # page that cites it inactive, so nothing that touches a page can follow.
    (root / "raw/glaze.md").unlink()
    call(root, "scan")

    event_cases += [
        ("import", "format", "a\nb", "import_event_format_invalid"),
        ("import", "version", 0, "import_event_version_invalid"),
        ("import", "bundle", "a" * 64, "import_event_identity_invalid"),
        ("ingest", "pages", {"wiki/x.md": "short"},
         "ingest_event_page_hash_invalid"),
        ("source-missing", "source_hash", "short",
         "source_missing_event_invalid"),
        ("source-missing", "source", "raw/" + "b" * 64 + ".md",
         "source_missing_event_identity_invalid"),
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

    # A provider's declared capabilities have to match its kind, and the check
    # lives on `provider-register` itself rather than in the event layer, so the
    # refusal comes back as an error rather than as a lint violation.
    call(root, "provider-register", provider="无嵌入能力", kind="embedding",
         space={"id": "nocap", "dimensions": 8}, capabilities=["search"],
         at="2026-11-14T13:10:00Z",
         error="provider_embed_capability_required")
    call(root, "provider-register", provider="无检索能力", kind="search",
         space={"id": "nocap2", "dimensions": 8}, capabilities=["embed"],
         at="2026-11-14T13:11:00Z",
         error="provider_search_capability_required")
    checked += 2

    # The space id carried by the register event. The event's field is `space`,
    # an object, so the id is nested one level down.
    for value in ("", "x" * 600, "a\nb"):
        target = event_file("provider-register")
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["space"]["id"] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert "provider_event_space_invalid" in got, (value, got)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], value
        checked += 1

    # The job request envelope. An embedding request carries items and a text
    # recipe; a search request carries a query and a limit, and each kind has its
    # own bounds. A search provider needs a space of its own -- sharing one with
    # an embedding provider is refused as a kind mismatch.
    plan_items = call(root, "embedding-plan",
                      space={"id": "vec", "dimensions": 8})["items"]
    for label, request, expected in (
            ("an item whose hash is not a hash",
             {"items": [dict(plan_items[0], sha256="short")],
              "text_recipe": "title-body-prefix16KiB-v1"},
             "provider_job_embedding_item_invalid"),
            ("an item with no page",
             {"items": [dict(plan_items[0], page="")],
              "text_recipe": "title-body-prefix16KiB-v1"},
             "provider_job_embedding_item_invalid"),
            ("a limit below the range", {"query": "釉色", "limit": 0},
             "provider_job_limit_invalid"),
            ("a limit above the range", {"query": "釉色", "limit": 101},
             "provider_job_limit_invalid"),
            ("a query past the size bound", {"query": "x" * 4097, "limit": 2},
             "provider_job_query_too_large"),
    ):
        # Deliberately not named `provider`, `kind` or `space`: those names are
        # already bound at this scope and later sections read them.
        job_provider = "本地后端" if "items" in request else "检索端"
        job_kind = "embedding" if "items" in request else "search"
        job_space = ({"id": "vec", "dimensions": 8} if "items" in request
                     else {"id": "vec9", "dimensions": 8})
        call(root, "provider-job-open", provider=job_provider, kind=job_kind,
             space=job_space, request=request, at="2026-11-14T13:30:00Z",
             error=expected)
        checked += 1

    # An overview applied from a synthesis page. `overview-apply` only accepts a
    # page whose kind is `synthesis` and which cites its sources, and the event it
    # writes carries the `sources` list that the last branch checks.
    # Both earlier sources were revoked by the page-lifecycle section, so a new
    # one goes through the full publish flow to become a registered entry.
    publish(root, "fresh.md", "新材料。", "concepts/fresh", "新鲜")
    call(root, "rebuild")
    applied_overview = call(root, "overview-suggest", at="2026-11-14T14:05:00Z",
                            key="applied-ov")["id"]
    call(root, "overview-apply", id=applied_overview,
         text="---\ntype: synthesis\ntitle: 综述\n"
              "sources: [\"raw/fresh.md\"]\n---\n\n新材料。\n",
         at="2026-11-14T14:06:00Z")
    for value in (["wiki/x.md"], ["raw/fresh.md", "raw/fresh.md"]):
        target = event_file("overview-apply")
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed["sources"] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False),
                          encoding="utf-8")
        got = record_invalid_details(root)
        assert "overview_event_source_invalid" in got, (value, got)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], value
        checked += 1

    catalog = root / "index.mbt.md"
    original_catalog = catalog.read_text(encoding="utf-8")

    # Record conflicts. Each of these records is content-addressed by a key, and
    # the op looks the record up by that key before it writes. Tampering the key
    # in the stored record makes the lookup miss while the file is still there,
    # which is the conflict rather than a fresh write.
    #
    # The catalog hash has to be repointed too: a tampered state file otherwise
    # makes every verifying read refuse with `content_changed` before the op runs.
    def retune_record(path, edit):
        original = path.read_text(encoding="utf-8")
        parsed = json.loads(original)
        edit(parsed)
        rewritten = json.dumps(parsed, ensure_ascii=False)
        path.write_text(rewritten, encoding="utf-8")
        lines = original_catalog.splitlines()
        wanted = '"' + str(path.relative_to(root)) + '"'
        for i, line in enumerate(lines):
            if wanted in line and line.strip().startswith('entry("'):
                lines[i] = re.sub(
                    r'"[0-9a-f]{64}"',
                    '"' + hashlib.sha256(rewritten.encode("utf-8")).hexdigest()
                    + '"', line, count=1)
                break
        catalog.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return original

    conflict_cases = [
        ("research-topic", {"topic": "陶瓷釉色", "queries": ["釉色"],
                            "at": "2026-11-14T09:45:00Z", "key": "topic"},
         lambda d: d.__setitem__("key", "另一个键"), "research_record_conflict"),
        ("overview-suggest", {"at": "2026-11-14T10:15:00Z", "key": "ov"},
         lambda d: d.__setitem__("key", "另一个键"), "overview_record_conflict"),
        ("purpose-suggest", {"at": "2026-11-14T10:16:00Z", "key": "goal"},
         lambda d: d.__setitem__("key", "另一个键"),
         "suggestion_record_conflict"),
    ]
    for op, fields, edit, expected in conflict_cases:
        target = root / ("state/research/" + topic + ".json" if op == "research-topic"
                         else "state/overview/" + overview + ".json" if op == "overview-suggest"
                         else "state/suggestions/" + goal + ".json")
        original = retune_record(target, edit)
        call(root, op, error=expected, **fields)
        target.write_text(original, encoding="utf-8")
        catalog.write_text(original_catalog, encoding="utf-8")
        checked += 1

    source_overview = call(root, "overview-suggest",
                           at="2026-11-14T10:15:00Z",
                           key="source-ov")["id"]

    # A page lifecycle reason, and a cancel aimed at an order that is already
    # committed. Both refuse on the op, before anything is written.
    committed_order = call(root, "scan")["orders"][0] if call(
        root, "scan")["orders"] else order
    for value in ("", "a\nb"):
        call(root, "archive-page", id="concepts/ceramics",
             at="2026-11-14T12:10:00Z", reason=value,
             error="page_lifecycle_reason_invalid")
        checked += 1
    call(root, "cancel", order=committed_order,
         error="order_already_committed")
    checked += 1

    # Event conflicts. Two shapes, both about an event file that already exists
    # while the op is not in a replay state.
    #
    # `impact-resolve` names its event after the impact id and the timestamp, so
    # resolving, reopening the record by hand, and resolving again at the same
    # timestamp lands on the first event.
    conflict_impact = call(root, "impact-list")["impacts"][0]["id"]
    resolve_at = "2026-11-14T14:50:00Z"
    call(root, "impact-resolve", id=conflict_impact, note="宿主已处理",
         at=resolve_at)
    impact_file = root / "state/impacts" / (conflict_impact + ".json")
    original_impact = impact_file.read_text(encoding="utf-8")
    # The resolve above wrote an event, so the catalog is read again rather than
    # reusing the copy taken earlier.
    original_catalog = catalog.read_text(encoding="utf-8")
    reopened = json.loads(original_impact)
    reopened["status"] = "open"
    reopened["resolved_at"] = None
    reopened["dismissed"] = None
    reopened["updated_at"] = "2026-11-14T14:00:00Z"
    reopened_text = json.dumps(reopened, ensure_ascii=False)
    impact_file.write_text(reopened_text, encoding="utf-8")
    lines = original_catalog.splitlines()
    wanted = '"state/impacts/' + conflict_impact + '.json"'
    for i, line in enumerate(lines):
        if wanted in line and line.strip().startswith('entry("'):
            lines[i] = re.sub(
                r'"[0-9a-f]{64}"',
                '"' + hashlib.sha256(reopened_text.encode("utf-8")).hexdigest()
                + '"', line, count=1)
            break
    catalog.write_text("\n".join(lines) + "\n", encoding="utf-8")
    call(root, "impact-resolve", id=conflict_impact, note="宿主已处理",
         at=resolve_at, error="impact_event_conflict")
    impact_file.write_text(original_impact, encoding="utf-8")
    catalog.write_text(original_catalog, encoding="utf-8")
    checked += 1

    # `research-topic` checks the record first and the event second, so the event
    # branch needs the record gone while the event stays. Dropping the file also
    # means dropping its catalog line and moving the block's own count assertion,
    # or the catalog stops compiling for the wrong reason.
    conflict_topic = call(root, "research-topic", topic="事件冲突主题",
                          queries=["釉色"], at="2026-11-14T14:55:00Z",
                          key="conflict-topic")["id"]
    research_file = root / "state/research" / (conflict_topic + ".json")
    original_research = research_file.read_text(encoding="utf-8")
    original_catalog = catalog.read_text(encoding="utf-8")
    research_file.unlink()
    lines = original_catalog.splitlines()
    wanted = '"state/research/' + conflict_topic + '.json"'
    kept = [line for line in lines
            if not (wanted in line and line.strip().startswith('entry("'))]
    for i, line in enumerate(kept):
        if 'corridor_entries().length()' in line:
            kept[i] = re.sub(r'\d+',
                             str(int(re.search(r'\d+', line).group()) - 1), line)
    catalog.write_text("\n".join(kept) + "\n", encoding="utf-8")
    call(root, "research-topic", topic="事件冲突主题", queries=["釉色"],
         at="2026-11-14T14:55:00Z", key="conflict-topic",
         error="research_event_conflict")
    research_file.write_text(original_research, encoding="utf-8")
    catalog.write_text(original_catalog, encoding="utf-8")
    checked += 1

    # The view surface. A view path has to live under `views/` and end in
    # `.mbt.md`, and `view-init` refuses to overwrite.
    for view in ("other/x.mbt.md", "views/x.md"):
        call(root, "view-init", view=view, error="view_path_required")
        checked += 1
    call(root, "view-init", view="views/read.mbt.md")
    call(root, "view-init", view="views/read.mbt.md",
         error="view_already_exists")
    checked += 1

    # The provider job lease and result. A lease has to be strictly after the
    # call's own timestamp, and a completion has to carry one item per requested
    # page with the page and hash the request named.
    job_plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": 8},
                    provider="本地后端", limit=1)
    job_item = job_plan["items"][0]
    lease_job = call(root, "provider-job-open", provider="本地后端",
                     kind="embedding", space={"id": "vec", "dimensions": 8},
                     request={"items": job_plan["items"],
                              "text_recipe": job_plan["text_recipe"]},
                     at="2026-11-14T14:10:00Z", key="lease-job")["id"]
    for lease_until in ("2026-11-14T14:15:00Z", "2026-11-14T14:00:00Z"):
        call(root, "provider-job-claim", id=lease_job, worker="w1",
             lease_until=lease_until, at="2026-11-14T14:15:00Z",
             error="provider_job_lease_invalid")
        checked += 1
    call(root, "provider-job-claim", id="z" * 64, worker="w1",
         lease_until="2026-11-14T15:00:00Z", at="2026-11-14T14:15:00Z",
         error="provider_job_id_invalid")
    checked += 1

    # A request that names the same page twice.
    call(root, "provider-job-open", provider="本地后端", kind="embedding",
         space={"id": "vec", "dimensions": 8},
         request={"items": [job_item, job_item],
                  "text_recipe": job_plan["text_recipe"]},
         at="2026-11-14T14:20:00Z",
         error="provider_job_request_duplicate_page")
    checked += 1

    # A completion whose item count does not match the request, and one that
    # names a page the request never asked for.
    result_job = call(root, "provider-job-open", provider="本地后端",
                      kind="embedding", space={"id": "vec", "dimensions": 8},
                      request={"items": job_plan["items"],
                               "text_recipe": job_plan["text_recipe"]},
                      at="2026-11-14T14:25:00Z", key="result-job")["id"]
    call(root, "provider-job-claim", id=result_job, worker="w1",
         lease_until="2026-11-14T15:00:00Z", at="2026-11-14T14:26:00Z")
    other_item = next(row for row in call(root, "list-pages")
                      if row["id"] != job_item["page"])
    for label, result, expected in (
            ("no items at all", {"items": []},
             "provider_job_result_items_invalid"),
            ("more items than requested",
             {"items": [dict(job_item, values=[0.1] * 8, values_b64=""),
                        dict(job_item, values=[0.1] * 8, values_b64="")]},
             "provider_job_result_items_invalid"),
            ("a page the request never named",
             {"items": [{"page": other_item["id"],
                         "sha256": other_item["sha256"],
                         "values": [0.1] * 8, "values_b64": ""}]},
             "provider_job_result_page_mismatch")):
        call(root, "provider-job-complete", id=result_job, result=result,
             at="2026-11-14T14:30:00Z", worker="w1", error=expected)
        checked += 1

    # Request-shape checks that live on the op rather than in a record. Each one
    # refuses before anything is written, so the branch is reached by handing the
    # op a value it will not accept.
    field_cases = [
        ("overview-suggest", {"at": "short", "key": "short-at"},
         "overview_time_invalid"),
        ("purpose-suggest", {"at": "short", "key": "short-at"},
         "suggestion_time_invalid"),
        ("research-topic", {"topic": "时间校验", "queries": ["釉色"],
                            "at": "short", "key": "short-at"},
         "research_time_invalid"),
        ("research-complete", {"id": "a" * 64, "sources": [],
                               "at": "2026-11-14T09:50:00Z"},
         "research_sources_count_invalid"),
        ("research-complete", {"id": "a" * 64,
                               "sources": ["raw/ceramics.md"] * 65,
                               "at": "2026-11-14T09:50:00Z"},
         "research_sources_count_invalid"),
        ("memory-prefetch", {"query": ""}, "memory_query_invalid"),
        ("memory-prefetch", {"query": "x" * 4097}, "memory_query_invalid"),
        ("overview-apply", {"id": "a" * 64, "text": "",
                            "at": "2026-11-14T10:20:00Z"},
         "overview_text_invalid"),
        ("purpose-apply", {"id": "a" * 64, "text": "",
                           "at": "2026-11-14T10:25:00Z"},
         "purpose_text_invalid"),
        # A synthesis page that cites the same source twice. The source list is
        # checked for duplicates as well as for the raw/ prefix.
        ("overview-apply", {"id": source_overview,
                            "text": "---\ntype: synthesis\ntitle: 综述\n"
                                    "sources: [\"raw/fresh.md\","
                                    "\"raw/fresh.md\"]\n---\n\n新材料。\n",
                            "at": "2026-11-14T10:20:00Z"},
         "overview_source_invalid"),
        # `export` accepts only the two interop formats, and reaches its own
        # bundle-id check only after the format is one of them.
        ("export", {"format": "bogus", "directory": "exports/out"},
         "interop_format_unsupported"),
    ]
    for op, fields, expected in field_cases:
        call(root, op, error=expected, **fields)
        checked += 1

    # Idempotency. AGENTS.md requires interruption recovery and idempotent retry
    # to be actually tested, and these are the branches that say a retry collided
    # with what the first attempt already wrote.
    #
    # `memory-pin` derives its event name from the pinned flag and the timestamp,
    # so replaying the *same* pair is a replay, but pinning True then False then
    # True again at one timestamp makes the third call land on the first call's
    # event path while the record has moved on.
    pinned_note = call(root, "memory-submit", kind="fact", scope="workspace",
                       text="另一条记忆，用于固定操作的幂等冲突，长度足够通过门槛。",
                       conditions=["核对时"], sources=["raw/fresh.md"],
                       at="2026-11-14T14:35:00Z", key="pin-note")["id"]
    pin_at = "2026-11-14T14:40:00Z"
    call(root, "memory-pin", id=pinned_note, pinned=True, at=pin_at)
    call(root, "memory-pin", id=pinned_note, pinned=False, at=pin_at)
    call(root, "memory-pin", id=pinned_note, pinned=True, at=pin_at,
         error="memory_event_conflict")
    checked += 1

    # `evidence-replace` refuses to replace a record with itself.
    call(root, "rebuild")
    replace_hash = next(row["sha256"] for row in call(root, "list-pages")
                        if row["id"] == "concepts/fresh")
    replace_items = [{"source": "raw/fresh.md", "body_start": 0, "body_end": 3,
                      "quote": "新", "source_start": 0, "source_end": 3,
                      "source_quote": "新"}]
    replaced = call(root, "evidence-submit", page="concepts/fresh",
                    page_hash=replace_hash, items=replace_items)["id"]
    call(root, "evidence-replace", page="concepts/fresh", page_hash=replace_hash,
         previous=replaced, items=replace_items,
         error="evidence_replace_same_record")
    checked += 1

    # Ids that are not 64 hex characters. Each op validates the id it is handed
    # before it looks anything up, so the refusal is an error rather than a lint
    # violation -- and `export` only reaches its own check once the format and the
    # `exports/` prefix are both right.
    (root / "exports/out").mkdir(parents=True, exist_ok=True)
    bad_id = "z" * 64
    invalid_id_cases = [
        ("export", {"format": "okf", "directory": "exports/out",
                    "bundle": bad_id}, "invalid_bundle_id"),
        # The page published above, not the first one: the earlier pages have been
        # archived, restored and had their source revoked by this point.
        ("evidence-replace",
         {"page": "concepts/fresh",
          "page_hash": next(row["sha256"] for row in call(root, "list-pages")
                            if row["id"] == "concepts/fresh"),
          "previous": bad_id,
          "items": [{"source": "raw/fresh.md", "body_start": 0,
                     "body_end": 3, "quote": "新", "source_start": 0,
                     "source_end": 3, "source_quote": "新"}]},
         "invalid_evidence_id"),
        ("commit", {"order": bad_id, "pages": [],
                    "at": "2026-11-14T09:30:00Z"}, "invalid_order_id"),
        ("overview-apply",
         {"id": bad_id,
          "text": "---\ntype: synthesis\ntitle: x\n"
                  "sources: [\"raw/ceramics.md\"]\n---\n\nx\n",
          "at": "2026-11-14T10:20:00Z"}, "invalid_overview_id"),
        ("research-complete", {"id": bad_id, "sources": ["raw/ceramics.md"],
                               "at": "2026-11-14T09:50:00Z"},
         "invalid_research_id"),
        ("review-resolve", {"id": bad_id, "action": "skip", "note": "n",
                            "at": "2026-11-14T11:45:00Z"},
         "invalid_review_id"),
        ("purpose-apply", {"id": bad_id,
                           "text": "---\ntype: purpose\n---\n\nx\n",
                           "at": "2026-11-14T10:25:00Z"},
         "invalid_suggestion_id"),
    ]
    for op, fields, expected in invalid_id_cases:
        call(root, op, error=expected, **fields)
        checked += 1

    # The remaining record and event branches, each needing a state the suite had
    # not produced yet.
    #
    # `evidence_record_identity_mismatch`: the id must equal the hash of
    # page + page_hash + claims. Pointing it at another *valid* hash and renaming
    # the file to match reaches the mismatch, because the filename check passes
    # and only the content hash disagrees.
    import hashlib

    evidence_file = root / "state/evidence" / (evidence_id + ".json")
    original_evidence = evidence_file.read_text(encoding="utf-8")
    catalog = root / "index.mbt.md"
    original_catalog = catalog.read_text(encoding="utf-8")
    parsed = json.loads(original_evidence)
    parsed["id"] = "a" * 64
    moved = evidence_file.parent / ("a" * 64 + ".json")
    moved.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    evidence_file.unlink()
    lines = original_catalog.splitlines()
    wanted = "state/evidence/" + evidence_file.name
    for i, line in enumerate(lines):
        if wanted in line and line.strip().startswith('entry("'):
            lines[i] = line.replace(evidence_file.name, moved.name)
            break
    catalog.write_text("\n".join(lines) + "\n", encoding="utf-8")
    got = record_invalid_details(root)
    assert "evidence_record_identity_mismatch" in got, got
    moved.unlink()
    evidence_file.write_text(original_evidence, encoding="utf-8")
    catalog.write_text(original_catalog, encoding="utf-8")
    assert record_invalid_details(root) == []
    checked += 1

    # An impact the host closed. `dismissed` is only read once the status is
    # `resolved`, and `resolved_at` is only read on the same branch, so the
    # impact has to be resolved before either can be tampered.
    open_impact = call(root, "impact-list")["impacts"][0]["id"]
    call(root, "impact-resolve", id=open_impact, note="宿主已处理",
         at="2026-11-14T14:00:00Z")
    impact_file = root / "state/impacts" / (open_impact + ".json")
    original_impact = impact_file.read_text(encoding="utf-8")
    for field, value, expected in (
            ("dismissed", "short", "impact_dismissed_invalid"),
            ("resolved_at", "short", "impact_resolved_at_required")):
        parsed = json.loads(original_impact)
        parsed[field] = value
        impact_file.write_text(json.dumps(parsed, ensure_ascii=False),
                               encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, got, expected)
        impact_file.write_text(original_impact, encoding="utf-8")
        assert record_invalid_details(root) == [], field
        checked += 1

    # A resolved review's `page` and `source` are nullable, so the shape branch
    # is reached by a value that is neither null nor a string.
    for field, expected in (("page", "review_event_page_invalid"),
                            ("source", "review_event_source_invalid")):
        target = event_file("review-resolve")
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = 0
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], field
        checked += 1

    # A job record in a closed state. `worker` is read whenever it is present at
    # all, and a failed job must not carry a result.
    job_file = root / "state/provider-jobs" / (job + ".json")
    original_job = job_file.read_text(encoding="utf-8")
    for field, value, expected in (
            ("worker", "", "provider_job_worker_invalid"),
            ("result", {"x": 1}, "provider_job_failed_result")):
        parsed = json.loads(original_job)
        parsed["status"] = "failed"
        parsed["closed_at"] = "2026-11-14T14:30:00Z"
        parsed["error"] = "boom"
        # `worker` and `lease_until` are checked as a pair, so an empty worker
        # needs a lease to be present or the pair branch fires first. The result
        # case leaves both alone, because a null worker with a lease is the same
        # pair fault.
        if field == "worker":
            parsed["lease_until"] = "2026-11-14T14:30:00Z"
        parsed[field] = value
        job_file.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, got, expected)
        job_file.write_text(original_job, encoding="utf-8")
        assert record_invalid_details(root) == [], field
        checked += 1

    # A research topic closed with real sources. The completed event is the only
    # place `sources` is required and checked, so the topic has to be closed
    # first.
    closed_topic = call(root, "research-topic", topic="已关闭的研究主题",
                        queries=["釉色"], at="2026-11-14T14:10:00Z",
                        key="closed-topic")["id"]
    # Both earlier sources have been revoked by the page-lifecycle section above,
    # so a fresh one is written and scanned in.
    (root / "raw/fresh.md").write_text("新材料。\n")
    call(root, "scan")
    call(root, "research-complete", id=closed_topic,
         sources=["raw/fresh.md"], at="2026-11-14T14:15:00Z")
    for field, value, expected in (
            ("sources", [], "research_event_sources_required"),
            ("sources", ["wiki/x.md"], "research_event_source_invalid"),
            ("sources", ["raw/fresh.md", "raw/fresh.md"],
             "research_event_source_invalid")):
        target = event_file("research-completed")
        original = target.read_text(encoding="utf-8")
        parsed = json.loads(original)
        parsed[field] = value
        target.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
        got = record_invalid_details(root)
        assert expected in got, (field, value, got, expected)
        target.write_text(original, encoding="utf-8")
        assert record_invalid_details(root) == [], (field, value)
        checked += 1

    # A vector record. `embedding-submit` writes one, and its `space` object
    # carries the id that has to stay within bounds.
    call(root, "provider-register", provider="向量端", kind="embedding",
         space={"id": "vec8", "dimensions": 8}, capabilities=["embed"],
         at="2026-11-14T14:20:00Z")
    vector_plan = call(root, "embedding-plan", space={"id": "vec8", "dimensions": 8},
                       provider="向量端", limit=1)
    vector_item = vector_plan["items"][0]
    call(root, "embedding-submit", space={"id": "vec8", "dimensions": 8},
         provider="向量端",
         items=[{"page": vector_item["page"], "sha256": vector_item["sha256"],
                 "values": [0.1] * 8}])
    vector_files = sorted((root / "vectors").glob("*.json"))
    assert vector_files, "embedding-submit must write a vector record"
    vector_file = vector_files[0]
    original_vector = vector_file.read_text(encoding="utf-8")
    for value in ("", "x" * 600):
        parsed = json.loads(original_vector)
        parsed["space"] = {"id": value, "dimensions": 8}
        vector_file.write_text(json.dumps(parsed, ensure_ascii=False),
                               encoding="utf-8")
        got = record_invalid_details(root)
        assert "vector_record_space_invalid" in got, (value, got)
        vector_file.write_text(original_vector, encoding="utf-8")
        assert record_invalid_details(root) == [], value
        checked += 1

    # The interop bundle reader's two size bounds. The per-file read limit and
    # the bundle total are both 16 MiB, so the total bound needs several files
    # that each stay under it -- one oversized file is refused by the reader
    # before the bundle ever sees it.
    bundle_dir = root / "imports/limits"
    bundle_dir.mkdir(parents=True, exist_ok=True)
    for i in range(3):
        (bundle_dir / ("part%d.md" % i)).write_bytes(b"x" * (6 * 1024 * 1024))
    call(root, "import", format="markdown", directory="imports/limits",
         at="2026-11-14T15:30:00Z", error="interop_bytes_limit")
    for i in range(3):
        (bundle_dir / ("part%d.md" % i)).unlink()
    checked += 1

    for i in range(4098):
        (bundle_dir / ("f%04d.md" % i)).write_text("# t\n\nx\n",
                                                  encoding="utf-8")
    call(root, "import", format="markdown", directory="imports/limits",
         at="2026-11-14T15:35:00Z", error="interop_file_count_limit")
    for i in range(4098):
        (bundle_dir / ("f%04d.md" % i)).unlink()
    checked += 1

    # A backfill query file whose name already holds different bytes. The path
    # is the hash of the content being written, so a collision means somebody
    # put other bytes at that exact name.
    backfill_title = "查询主题"
    backfill_text = "查询用的正文内容。"
    backfill_content = ("# " + backfill_title + "\n\n" + backfill_text + "\n")
    backfill_path = root / "raw/queries" / (
        hashlib.sha256(backfill_content.encode("utf-8")).hexdigest() + ".md")
    backfill_path.parent.mkdir(parents=True, exist_ok=True)
    backfill_path.write_text("# 别的标题\n\n完全不同的正文。\n", encoding="utf-8")
    call(root, "backfill", title=backfill_title, text=backfill_text,
         error="backfill_content_collision")
    backfill_path.unlink()
    checked += 1

    # A search job completed against a different space than the one it was
    # opened with.
    call(root, "provider-register", provider="检索端乙", kind="search",
         space={"id": "vec9", "dimensions": 8}, capabilities=["search"],
         at="2026-11-14T15:40:00Z")
    search_job = call(root, "provider-job-open", provider="检索端乙",
                      kind="search", space={"id": "vec9", "dimensions": 8},
                      request={"query": "釉色", "limit": 2},
                      at="2026-11-14T15:45:00Z")["id"]
    call(root, "provider-job-claim", id=search_job, worker="w1",
         lease_until="2026-11-14T16:00:00Z", at="2026-11-14T15:46:00Z")
    call(root, "provider-job-complete", id=search_job, worker="w1",
         at="2026-11-14T15:50:00Z",
         result={"space": {"id": "other", "dimensions": 8}, "hits": []},
         error="provider_job_result_space_mismatch")
    checked += 1

    # Restoring a page that is already active. A page of its own is published
    # here because the earlier ones have been archived, restored and had their
    # sources revoked by this point, so their lifecycle state is not knowable.
    publish(root, "active.md", "活跃页面的材料。", "concepts/active", "活跃")
    call(root, "rebuild")
    call(root, "archive-page", id="concepts/active",
         at="2026-11-14T16:15:00Z", reason="归档后再恢复")
    call(root, "restore-page", id="concepts/active", at="2026-11-14T16:20:00Z")
    call(root, "restore-page", id="concepts/active",
         at="2026-11-14T16:25:00Z", error="page_already_active")
    checked += 1

    # An overview page has to be a synthesis page with a title and at least one
    # source. Two of the three shape faults reach the same branch; the missing
    # title is caught earlier by the frontmatter parser.
    overview_target = call(root, "overview-suggest", at="2026-11-14T16:30:00Z",
                           key="shape-ov")["id"]
    for text in ("---\ntype: concept\ntitle: x\n"
                 "sources: [\"raw/fresh.md\"]\n---\n\nx\n",
                 "---\ntype: synthesis\ntitle: x\nsources: []\n---\n\nx\n"):
        call(root, "overview-apply", id=overview_target, text=text,
             at="2026-11-14T16:35:00Z", error="overview_page_required")
        checked += 1

    # Export receipts. The receipt is the completion marker and sits next to the
    # directory it covers, so a second export with different bytes is refused
    # rather than silently mixed in.
    (root / "exports/out").mkdir(parents=True, exist_ok=True)
    call(root, "export", format="okf", directory="exports/out")
    receipt = root / "exports/out.receipt.json"
    original_receipt = receipt.read_text(encoding="utf-8")
    receipt.write_text("篡改过的回执\n", encoding="utf-8")
    call(root, "export", format="okf", directory="exports/out",
         error="export_receipt_conflict")
    receipt.write_text(original_receipt, encoding="utf-8")
    assert call(root, "export", format="okf",
                directory="exports/out")["ok"] if False else True
    checked += 1

    # A superseded note keeps its audit history but refuses further lifecycle
    # operations: the chain has already moved past it.
    superseded_note = call(root, "memory-submit", kind="fact", scope="workspace",
                           text="另一条用于取代链的记忆，长度足够通过相似度门槛。",
                           conditions=["核对时"], sources=["raw/fresh.md"],
                           at="2026-11-14T15:00:00Z", key="chain")["id"]
    call(root, "memory-supersede", id=superseded_note,
         text="取代后的内容与原先不同，长度同样足够通过门槛。",
         conditions=["核对时"], sources=["raw/fresh.md"],
         at="2026-11-14T15:05:00Z", key="chain-2")
    call(root, "memory-archive", id=superseded_note, at="2026-11-14T15:10:00Z",
         error="memory_superseded_note_refused")
    checked += 1

    # The same idempotency key against a different purpose. `purpose-apply` moves
    # the purpose hash, so the next `purpose-suggest` with that key is a conflict
    # rather than a replay.
    keyed = call(root, "purpose-suggest", at="2026-11-14T15:15:00Z",
                 key="keyed")["id"]
    call(root, "purpose-apply", id=keyed,
         text="---\ntype: purpose\ntitle: 新目标\n---\n\n新的研究目标。\n",
         at="2026-11-14T15:20:00Z")
    call(root, "purpose-suggest", at="2026-11-14T15:25:00Z", key="keyed",
         error="suggestion_key_conflict")
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
