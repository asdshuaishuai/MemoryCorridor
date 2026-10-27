#!/usr/bin/env python3
"""Durable provider execution handoff, completion, cancellation and replay."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"

with tempfile.TemporaryDirectory(prefix="corridor-provider-job-") as work:
    vault = Path(work)

    def call(op, expected_error=None, **fields):
        request = dict(fields, op=op, vault=str(vault))
        run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n", text=True,
                             capture_output=True, check=True, timeout=30)
        response = json.loads(run.stdout)
        if expected_error:
            assert not response["ok"] and expected_error in response["error"], response
            return response
        assert response["ok"], response
        return response["result"]

    space = {"id": "job-v1", "dimensions": 2}
    call("init")
    (vault / "raw").mkdir(parents=True, exist_ok=True)
    (vault / "raw/input.md").write_text("# Input\nProvider job source.\n")
    order = call("scan")["orders"][0]
    call("context", order=order)
    call("analysis-submit", order=order, analysis={
        "entities": [], "concepts": ["Provider job"], "conflicts": [], "summary": "provider job test",
    })
    staging = vault / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    draft = staging / "draft.md"
    draft.write_text("---\ntype: concept\ntitle: Provider job\nsources: [raw/input.md]\n---\nProvider task body.\n")
    call("commit", order=order, at="2026-10-17T10:00:30Z", pages=[
        {"id": "concepts/provider-job", "path": "wiki/concepts/provider-job.md",
         "staged": str(draft.relative_to(vault))}
    ])
    page = next(row for row in call("list-pages") if row["id"] == "concepts/provider-job")
    call("provider-register", provider="embedder", kind="embedding", space=space,
         capabilities=["embed"], at="2026-10-17T10:00:00Z")
    embedding_plan = call("embedding-plan", space=space, provider="embedder", limit=1)
    payload = {"items": embedding_plan["items"], "text_recipe": embedding_plan["text_recipe"]}
    call("provider-job-open", provider="embedder", kind="embedding", space=space,
         request={**payload, "items": [{**payload["items"][0], "sha256": "0" * 64}]}, key="stale",
         at="2026-10-17T10:00:45Z", expected_error="provider_job_page_version_mismatch")
    call("provider-job-open", provider="embedder", kind="embedding", space=space,
         request={**payload, "items": [{**payload["items"][0], "text": "tampered"}]}, key="tampered",
         at="2026-10-17T10:00:50Z", expected_error="provider_job_embedding_text_mismatch")
    opened = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                  request=payload, key="job-1", at="2026-10-17T10:01:00Z")
    assert opened["status"] == "pending" and not opened["replayed"]
    job_id = opened["id"]
    leased = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                  request=payload, key="lease-1", at="2026-10-17T10:01:10Z")
    leased_id = leased["id"]
    call("provider-job-heartbeat", id=leased_id, worker="worker-a",
         lease_until="2026-10-17T10:20:00Z", at="2026-10-17T10:01:30Z",
         expected_error="provider_job_worker_required")
    assert call("provider-job-claim", id=leased_id, worker="worker-a",
                lease_until="2026-10-17T10:20:00Z", at="2026-10-17T10:02:00Z")["worker"] == "worker-a"
    call("provider-job-claim", id=leased_id, worker="worker-b",
         lease_until="2026-10-17T10:21:00Z", at="2026-10-17T10:03:00Z",
         expected_error="provider_job_already_claimed")
    call("provider-job-heartbeat", id=leased_id, worker="worker-b",
         lease_until="2026-10-17T10:30:00Z", at="2026-10-17T10:04:00Z",
         expected_error="provider_job_worker_mismatch")
    assert call("provider-job-heartbeat", id=leased_id, worker="worker-a",
                lease_until="2026-10-17T10:30:00Z", at="2026-10-17T10:04:00Z")["lease_until"] == "2026-10-17T10:30:00Z"
    call("provider-job-complete", id=leased_id, worker="worker-b", result={"items": []},
         at="2026-10-17T10:05:00Z", expected_error="provider_job_worker_mismatch")
    call("provider-job-complete", id=leased_id, worker="worker-a",
         result={"items": [{"page": page["id"], "sha256": page["sha256"], "values": [1.0, 0.0]}]},
         at="2026-10-17T10:31:00Z", expected_error="provider_job_lease_expired")
    assert call("provider-job-fail", id=leased_id, worker="worker-a", error="provider_timeout",
                at="2026-10-17T10:31:00Z")["status"] == "failed"

    reclaimed = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                     request=payload, key="lease-reclaim", at="2026-10-17T10:32:00Z")
    assert call("provider-job-claim", id=reclaimed["id"], worker="worker-a",
                lease_until="2026-10-17T10:33:00Z", at="2026-10-17T10:32:10Z")["worker"] == "worker-a"
    assert call("provider-job-claim", id=reclaimed["id"], worker="worker-b",
                lease_until="2026-10-17T10:40:00Z", at="2026-10-17T10:34:00Z")["worker"] == "worker-b"
    assert call("provider-job-complete", id=reclaimed["id"], worker="worker-b",
                result={"items": [{"page": page["id"], "sha256": page["sha256"], "values": [1.0, 0.0]}]},
                at="2026-10-17T10:35:00Z")["status"] == "completed"
    replay = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                  request=payload, key="job-1", at="2026-10-17T10:01:00Z")
    assert replay["replayed"] and replay["id"] == job_id
    call("provider-job-open", provider="embedder", kind="embedding", space=space,
         request=payload, key="job-1", at="2026-10-17T10:01:01Z",
         expected_error="provider_job_key_conflict")
    call("provider-job-complete", id=job_id, result={"items": [{"page": page["id"], "sha256": page["sha256"], "values": [1.0]}]},
         at="2026-10-17T10:01:30Z", expected_error="vector_dimension_mismatch")
    assert next(row for row in call("provider-job-list") if row["id"] == job_id)["status"] == "pending"
    completed = call("provider-job-complete", id=job_id, result={"items": [{"page": page["id"], "sha256": page["sha256"], "values": [1.0, 0.0]}]},
                     at="2026-10-17T10:02:00Z")
    assert completed["status"] == "completed" and completed["applied_vectors"] == 1
    assert len(call("search", query="Provider job", query_vector={"space": space, "values": [1.0, 0.0]}, provider="embedder")["hits"]) == 1
    result = {"items": [{"page": page["id"], "sha256": page["sha256"], "values": [1.0, 0.0]}]}
    call("provider-job-complete", id=job_id, result=result,
         at="2026-10-17T10:02:00Z")
    call("provider-job-complete", id=job_id, result={"items": [{"page": page["id"], "sha256": page["sha256"], "values": [0.0, 1.0]}]},
         at="2026-10-17T10:03:00Z", expected_error="provider_job_terminal")

    cancelled = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                     request=payload, key="job-2", at="2026-10-17T10:04:00Z")
    assert call("provider-job-cancel", id=cancelled["id"], at="2026-10-17T10:05:00Z")["status"] == "cancelled"
    call("provider-job-complete", id=cancelled["id"], result=result,
         at="2026-10-17T10:06:00Z", expected_error="provider_job_terminal")
    failed = call("provider-job-open", provider="embedder", kind="embedding", space=space,
                  request=payload, key="job-fail", at="2026-10-17T10:06:30Z")
    failed_result = call("provider-job-fail", id=failed["id"], error="provider_timeout", at="2026-10-17T10:07:00Z")
    assert failed_result["status"] == "failed"
    assert call("provider-job-fail", id=failed["id"], error="provider_timeout", at="2026-10-17T10:07:00Z")["replayed"]
    call("provider-job-complete", id=failed["id"], result=result,
         at="2026-10-17T10:07:01Z", expected_error="provider_job_terminal")
    call("provider-register", provider="ranker", kind="search", space=space,
         capabilities=["search"], at="2026-10-17T10:07:30Z")
    search_job = call("provider-job-open", provider="ranker", kind="search", space=space,
                      request={"query": "Provider job", "limit": 5}, key="search-1",
                      at="2026-10-17T10:08:00Z")
    search_done = call("provider-job-complete", id=search_job["id"], result={
        "space": space, "hits": [{"id": page["id"], "score": 1.0}]
    }, at="2026-10-17T10:08:30Z")
    assert search_done["status"] == "completed" and search_done["applied_vectors"] == 0
    rows = call("provider-job-list")
    assert len(rows) == 6 and {row["status"] for row in rows} == {"completed", "cancelled", "failed"}
    status = call("status")
    assert status["provider_jobs"] == {"total": 6, "pending": 0, "completed": 3, "cancelled": 1, "failed": 2}
    call("rebuild")
    call("verify")

print("Provider durable job open/complete/cancel, replay, conflict and stats: passed")
