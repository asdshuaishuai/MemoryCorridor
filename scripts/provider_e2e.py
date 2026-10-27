#!/usr/bin/env python3
"""Provider lifecycle, space binding and revocation on the real native CLI."""
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"

with tempfile.TemporaryDirectory(prefix="corridor-provider-") as work:
    vault = Path(work)

    def call(op, error=None, **fields):
        request = dict(fields, op=op, vault=str(vault))
        run = subprocess.run([str(EXE)], input=json.dumps(request) + "\n", text=True,
                             capture_output=True, check=True, timeout=30)
        response = json.loads(run.stdout)
        if error:
            assert not response["ok"] and error in response["error"], response
            return response
        assert response["ok"], response
        return response["result"]

    space = {"id": "external-v1", "dimensions": 2}
    call("init")
    embedding = call("provider-register", provider="embedder", kind="embedding", space=space,
                     capabilities=["embed"], at="2026-10-17T10:00:00Z")
    assert embedding["status"] == "active" and not embedding["replayed"]
    assert call("provider-register", provider="embedder", kind="embedding", space=space,
                capabilities=["embed"], at="2026-10-17T10:00:00Z")["replayed"]
    call("provider-register", provider="embedder", kind="embedding", space=space,
         capabilities=["embed"], at="2026-10-18T10:00:00Z", error="provider_registration_conflict")
    listed = call("provider-list")
    assert len(listed) == 1 and listed[0]["provider"] == "embedder"
    assert call("embedding-plan", space=space, provider="embedder")["items"] == []
    call("embedding-plan", space={"id": "wrong", "dimensions": 2}, provider="embedder",
         error="provider_space_mismatch")
    assert call("provider-heartbeat", provider="embedder", at="2026-10-17T11:00:00Z")["last_seen"] == "2026-10-17T11:00:00Z"
    assert call("provider-heartbeat", provider="embedder", at="2026-10-17T11:00:00Z")["replayed"]

    search = call("provider-register", provider="ranker", kind="search", space=space,
                  capabilities=["search"], at="2026-10-17T10:01:00Z")
    assert search["status"] == "active"
    call("search", query="", provider="ranker", vector_candidates={
        "space": space, "hits": []
    })
    call("provider-unregister", provider="ranker", at="2026-10-17T12:00:00Z")
    call("search", query="", provider="ranker", vector_candidates={
        "space": space, "hits": []
    }, error="provider_not_active")
    assert call("provider-unregister", provider="ranker", at="2026-10-17T12:00:00Z")["replayed"]
    call("verify")
    rows = call("provider-list")
    assert [row["status"] for row in rows] == ["active", "revoked"]

print("Provider lifecycle, space binding, replay, conflict and revocation: passed")
