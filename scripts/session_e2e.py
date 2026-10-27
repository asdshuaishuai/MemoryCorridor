#!/usr/bin/env python3
"""Verify the process-scoped native vault session contract."""
import json
import hashlib
from pathlib import Path
import select
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"


class Process:
    def __init__(self):
        self.proc = subprocess.Popen([str(EXE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)

    def call(self, value, ok=True, error=None):
        self.proc.stdin.write(json.dumps(value, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()
        assert select.select([self.proc.stdout], [], [], 20)[0], value
        result = json.loads(self.proc.stdout.readline())
        assert result.get("request_id") == value.get("request_id"), result
        assert result.get("ok") is ok, result
        if error:
            assert error in result["error"], result
        return result

    def close(self):
        self.proc.stdin.close()
        assert self.proc.wait(timeout=10) == 0
        assert b"Panic" not in self.proc.stderr.read().encode()


with tempfile.TemporaryDirectory(prefix="corridor-session-") as work:
    root = Path(work) / "vault"
    other = Path(work) / "other"
    root.mkdir()
    other.mkdir()

    first = Process()
    first.call({"op": "session-close", "request_id": 1}, ok=False, error="session_not_open")
    first.call({"op": "session-open", "vault": str(root), "request_id": 2})
    first.call({"op": "session-open", "vault": str(root), "request_id": 3})
    first.call({"op": "init", "purpose": "session contract", "request_id": 4})
    first.call({"op": "status", "request_id": 5})
    catalog_path = root / "index.mbt.md"
    original_catalog = catalog_path.read_text()
    purpose_hash = hashlib.sha256((root / "purpose.md").read_bytes()).hexdigest()
    catalog_path.write_text(original_catalog.replace(purpose_hash, "0" * 64))
    first.call({"op": "status", "request_id": 51}, ok=False, error="content_changed")
    catalog_path.write_text(original_catalog)
    first.call({"op": "status", "request_id": 52})
    first.call({"op": "status", "vault": str(other), "request_id": 6}, ok=False,
               error="session_vault_mismatch")
    first.call({"op": "session-close", "request_id": 7})
    first.call({"op": "session-close", "request_id": 8}, ok=False, error="session_not_open")
    first.close()

    second = Process()
    second.call({"op": "session-open", "vault": str(root), "request_id": 9})
    second.call({"op": "status", "request_id": 10})
    second.call({"op": "session-close", "request_id": 11})
    second.close()

    legacy = Process()
    legacy.call({"op": "status", "vault": str(root), "request_id": 12})
    legacy.call({"op": "status", "vault": str(other), "request_id": 13}, ok=False,
                error="session_vault_mismatch")
    legacy.call({"op": "status", "request_id": 14}, ok=False, error="vault_required")
    legacy.close()

# `session-close` must release the OS lock itself, not leave it to process exit.
# The block above closes a session and then exits, so it cannot tell the two
# apart; this holds the process open and lets another writer in.
    # `session-close` must release the OS lock itself, not leave it to process
    # exit. The block above closes a session and then exits, so it cannot tell
    # the two apart; this holds the process open and lets another writer in.
    holder = Process()
    holder.call({"op": "session-open", "vault": str(root), "request_id": 15})
    holder.call({"op": "session-close", "request_id": 16})
    assert holder.proc.poll() is None, "the holder must still be alive"
    (root / "raw").mkdir(exist_ok=True)
    (root / "raw/locked.md").write_text("锁释放后写入。\n")
    outside = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": "scan", "vault": str(root),
                                      "request_id": 17}) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    assert outside["ok"], outside
    assert outside["result"]["orders"], outside
    holder.call({"op": "session-open", "vault": str(root), "request_id": 18})
    holder.call({"op": "session-close", "request_id": 19})
    holder.close()

print("Native session: open/close binding, vault isolation, lock release and legacy compatibility: passed")
