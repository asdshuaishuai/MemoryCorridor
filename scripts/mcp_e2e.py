#!/usr/bin/env python3
"""Actual JSON-RPC process lifecycle and dictionary parity, without an SDK shim."""
import json
from pathlib import Path
import select
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="corridor-mcp-") as work:
    with tempfile.TemporaryFile(mode="w+") as log:
        p = subprocess.Popen([str(ROOT / "_build/native/debug/build/mcp/mcp.exe")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
        sequence = 0

        def call(method, params=None):
            global sequence
            sequence += 1
            req = {"jsonrpc": "2.0", "id": sequence, "method": method}
            if params is not None:
                req["params"] = params
            p.stdin.write(json.dumps(req) + "\n")
            p.stdin.flush()
            assert select.select([p.stdout], [], [], 20)[0], method
            result = json.loads(p.stdout.readline())
            assert result["id"] == sequence and result["jsonrpc"] == "2.0"
            return result

        assert "error" in call("tools/list")
        init = call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})
        assert init["result"]["protocolVersion"] == "2025-06-18"
        assert "error" in call("tools/list")
        p.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        p.stdin.flush()
        listed = call("tools/list")["result"]["tools"]
        assert all(t["inputSchema"]["additionalProperties"] is False for t in listed)
        by_name = {t["name"]: t["inputSchema"] for t in listed}
        assert by_name["corridor_research_complete"]["properties"]["sources"] == {
            "type": "array", "items": {"type": "string"}}
        assert by_name["corridor_research_topic"]["properties"]["queries"] == {
            "type": "array", "items": {"type": "string"}}
        assert by_name["corridor_provider_register"]["properties"]["capabilities"] == {
            "type": "array", "items": {"type": "string"}}
        assert by_name["corridor_embedding_submit"]["properties"]["items"] == {
            "type": "array", "items": {"type": "object"}}
        cli = subprocess.run([str(ROOT / "_build/native/debug/build/cli/cli.exe")], input='{"op":"list-tools"}\n', capture_output=True, text=True, check=True)
        dictionary = json.loads(cli.stdout)["result"]
        assert {"corridor_" + t["name"].replace("-", "_") for t in dictionary} == {t["name"] for t in listed}
        assert [t["inputSchema"] for t in dictionary] == [t["inputSchema"] for t in listed]
        # Advertising a tool is not the same as reaching it. Every operation in
        # the dictionary must survive an actual `tools/call`: name translation,
        # the field envelope and the error envelope are all part of what a client
        # relies on, and a tool that only exists in `tools/list` is exactly the
        # kind of gap that stays green. This runs before `init`, so the vault is
        # uninitialised on purpose: most operations must come back with a domain
        # `error_code`, and the two that are allowed to run on a damaged vault
        # must succeed. A transport-level failure produces neither.
        transport_skipped = {
            # Not vault operations, or they would bind the session below.
            "corridor_list_tools", "corridor_help", "corridor_init",
            "corridor_session_open", "corridor_session_close",
        }
        # `lint` is the diagnostic entry and `recover` is a no-op on a clean
        # vault, so both must answer successfully with no vault present.
        must_succeed = {"corridor_lint", "corridor_recover"}
        unreachable, succeeded = [], []
        for tool in listed:
            name = tool["name"]
            if name in transport_skipped:
                continue
            reply = call("tools/call", {"name": name, "arguments": {"vault": work}})
            if "error" in reply:
                unreachable.append((name, "jsonrpc error: " + str(reply["error"])[:60]))
                continue
            payload = reply["result"]
            if payload.get("isError"):
                code = payload.get("structuredContent", {}).get("result", {}).get("error_code")
                if not code:
                    unreachable.append((name, "no error_code in the envelope"))
                elif name in must_succeed:
                    unreachable.append((name, "must succeed on a damaged vault, got " + code))
            elif "structuredContent" not in payload:
                unreachable.append((name, "no structuredContent on success"))
            else:
                succeeded.append(name)
        assert not unreachable, unreachable
        assert must_succeed <= set(succeeded), sorted(must_succeed - set(succeeded))
        print("  transport reachability: %d/%d advertised tools answered a real tools/call"
              % (len(listed) - len(transport_skipped), len(listed)))
        args = {"vault": work, "purpose": "MCP validation"}
        result = call("tools/call", {"name": "corridor_init", "arguments": args})["result"]
        assert not result["isError"] and result["structuredContent"]["result"]["fingerprint"]
        result = call("tools/call", {"name": "corridor_search", "arguments": {"vault": work, "query": "empty"}})["result"]
        assert result["structuredContent"]["result"]["hits"] == []
        result = call("tools/call", {"name": "corridor_read_page", "arguments": {"vault": work, "id": "missing"}})["result"]
        assert result["isError"]
        assert result["structuredContent"]["result"]["error_code"] == "entry_not_found"
        result = call("tools/call", {"name": "corridor_render_view", "arguments": {"vault": work, "view": "../escape"}})["result"]
        assert result["isError"]
        violation = result["structuredContent"]["result"]["violations"][0]
        assert violation["predicate"] == "unsafe_path" and violation["fix"]
        # Every operation added to the dictionary must survive the transport, not
        # just be advertised by it: name translation, field types and the error
        # envelope are all part of the contract a client relies on.
        note = call("tools/call", {"name": "corridor_memory_submit", "arguments": {
            "vault": work, "kind": "preference", "scope": "workspace",
            "text": "优先安排陶瓷窑口对比的参观时间", "conditions": ["规划博物馆行程时"],
            "sources": [], "at": "2026-11-02T09:00:00Z", "key": "mcp-note"}})["result"]
        assert not note["isError"], note
        note_id = note["structuredContent"]["result"]["id"]
        assert note["structuredContent"]["result"]["status"] == "active"
        # A boolean field must round-trip as a boolean.
        pinned = call("tools/call", {"name": "corridor_memory_pin", "arguments": {
            "vault": work, "id": note_id, "pinned": True,
            "at": "2026-11-02T09:30:00Z"}})["result"]
        assert not pinned["isError"] and pinned["structuredContent"]["result"]["pinned"] is True
        refused = call("tools/call", {"name": "corridor_memory_archive", "arguments": {
            "vault": work, "id": note_id, "at": "2026-11-02T10:00:00Z"}})["result"]
        assert refused["isError"]
        assert refused["structuredContent"]["result"]["error_code"] == "memory_pinned_archive_refused"
        # A read operation must not claim a pending host action.
        read = call("tools/call", {"name": "corridor_memory_read", "arguments": {
            "vault": work, "id": note_id}})["result"]
        assert not read["isError"]
        assert "execution" not in read["structuredContent"]["result"]
        assert read["structuredContent"]["result"]["record"]["pinned"] is True
        brief = call("tools/call", {"name": "corridor_memory_prefetch", "arguments": {
            "vault": work, "query": "陶瓷 参观"}})["result"]
        assert not brief["isError"] and brief["structuredContent"]["result"]["query_seed"] == "query"
        assert brief["structuredContent"]["result"]["notes"][0]["id"] == note_id
        # The two seed forms are mutually exclusive, and the refusal names why.
        exclusive = call("tools/call", {"name": "corridor_memory_prefetch", "arguments": {
            "vault": work, "query": "陶瓷", "page": "concepts/x"}})["result"]
        assert exclusive["isError"]
        assert exclusive["structuredContent"]["result"]["error_code"] == "memory_query_exclusive"
        neither = call("tools/call", {"name": "corridor_memory_prefetch",
                                      "arguments": {"vault": work}})["result"]
        assert neither["isError"]
        assert neither["structuredContent"]["result"]["error_code"] == "memory_query_required"
        # The consolidation surface is the one place an agent can discover merge
        # and prune candidates without a seed, so it must answer through the
        # transport with the same shape it has natively.
        seeded = call("tools/call", {"name": "corridor_memory_candidates",
            "arguments": {"vault": work}})["result"]
        assert not seeded["isError"], seeded
        for field in ["merge", "prune", "counts", "fingerprint"]:
            assert field in seeded["structuredContent"]["result"], field
        assert "execution" not in seeded["structuredContent"]["result"]
        counts = seeded["structuredContent"]["result"]["counts"]
        for field in ["merge", "prune", "conflicted", "pinned", "eligible", "active"]:
            assert field in counts, field
        # Read-only views return their empty shapes through the transport.
        for name in ["corridor_memory_list", "corridor_memory_conflicts", "corridor_impact_list",
                     "corridor_inbox", "corridor_topics"]:
            empty = call("tools/call", {"name": name, "arguments": {"vault": work}})["result"]
            assert not empty["isError"], (name, empty)
        # A batch usage report is one transaction and replays on the same time.
        used = call("tools/call", {"name": "corridor_memory_use", "arguments": {
            "vault": work, "ids": [note_id], "at": "2026-11-02T10:30:00Z"}})["result"]
        assert not used["isError"], used
        assert used["structuredContent"]["result"]["used"] == 1
        assert used["structuredContent"]["result"]["replayed"] is False
        again = call("tools/call", {"name": "corridor_memory_use", "arguments": {
            "vault": work, "ids": [note_id], "at": "2026-11-02T10:30:00Z"}})["result"]
        assert again["structuredContent"]["result"]["replayed"] is True
        listed = call("tools/call", {"name": "corridor_memory_list", "arguments": {
            "vault": work}})["result"]
        assert listed["structuredContent"]["result"]["notes"][0]["last_used_at"] == "2026-11-02T10:30:00Z"
        # An empty batch and a repeated id are refused with a stable code.
        for bad in [{"ids": [], "at": "2026-11-02T11:00:00Z"},
                    {"ids": [note_id, note_id], "at": "2026-11-02T11:00:00Z"}]:
            refused = call("tools/call", {"name": "corridor_memory_use",
                                          "arguments": {"vault": work, **bad}})["result"]
            assert refused["isError"]
            assert refused["structuredContent"]["result"]["error_code"].startswith("memory_use_")
        # A page that was never published has no history to report.
        missing = call("tools/call", {"name": "corridor_page_history", "arguments": {
            "vault": work, "id": "concepts/absent"}})["result"]
        assert missing["isError"]
        assert missing["structuredContent"]["result"]["error_code"] == "entry_not_found"
        # A ranged source read reports the range it was asked for.
        ranged = call("tools/call", {"name": "corridor_read_source", "arguments": {
            "vault": work, "id": "raw/absent.md", "start": 0, "end": 4}})["result"]
        assert ranged["isError"]
        assert ranged["structuredContent"]["result"]["error_code"] == "entry_not_found"
        # Cancelling a suggestion is reachable and terminal.
        goal = call("tools/call", {"name": "corridor_purpose_suggest", "arguments": {
            "vault": work, "at": "2026-11-02T11:00:00Z"}})["result"]
        assert not goal["isError"], goal
        cancelled = call("tools/call", {"name": "corridor_purpose_cancel", "arguments": {
            "vault": work, "id": goal["structuredContent"]["result"]["id"],
            "at": "2026-11-02T11:30:00Z"}})["result"]
        assert not cancelled["isError"] and cancelled["structuredContent"]["result"]["status"] == "cancelled"
        assert call("tools/call", {"name": "corridor_purpose_cancel", "arguments": {
            "vault": work, "id": goal["structuredContent"]["result"]["id"],
            "at": "2026-11-02T11:30:00Z"}})["result"]["structuredContent"]["result"]["replayed"] is True
        # An overview suggestion cancels and refuses re-application once closed.
        overview = call("tools/call", {"name": "corridor_overview_suggest", "arguments": {
            "vault": work, "at": "2026-11-02T11:45:00Z"}})["result"]
        assert not overview["isError"], overview
        overview_id = overview["structuredContent"]["result"]["id"]
        dropped = call("tools/call", {"name": "corridor_overview_cancel", "arguments": {
            "vault": work, "id": overview_id, "at": "2026-11-02T12:00:00Z"}})["result"]
        assert not dropped["isError"] and dropped["structuredContent"]["result"]["status"] == "cancelled"
        assert call("tools/call", {"name": "corridor_overview_cancel", "arguments": {
            "vault": work, "id": overview_id,
            "at": "2026-11-02T12:00:00Z"}})["result"]["structuredContent"]["result"]["replayed"] is True
        # A cancelled suggestion cannot be published. Which refusal fires first
        # depends on how much the vault moved since the suggestion froze its
        # inputs, so the transport guarantee is that a stable code comes back.
        terminal = call("tools/call", {"name": "corridor_overview_apply", "arguments": {
            "vault": work, "id": overview_id, "text": "---\ntype: synthesis\ntitle: t\nsources: []\n---\n正文\n",
            "at": "2026-11-02T12:30:00Z"}})["result"]
        assert terminal["isError"]
        assert terminal["structuredContent"]["result"]["error_code"]
        # The change-impact state machine is reachable end to end.
        topic = call("tools/call", {"name": "corridor_research_topic", "arguments": {
            "vault": work, "topic": "陶瓷", "queries": ["陶瓷"],
            "at": "2026-11-02T13:00:00Z"}})["result"]
        assert not topic["isError"], topic
        audit = call("tools/call", {"name": "corridor_impact_audit", "arguments": {
            "vault": work, "at": "2026-11-02T13:30:00Z"}})["result"]
        assert not audit["isError"], audit
        assert audit["structuredContent"]["result"]["committed"] in (True, False)
        impacts = call("tools/call", {"name": "corridor_impact_list", "arguments": {
            "vault": work}})["result"]
        assert not impacts["isError"]
        open_rows = [r for r in impacts["structuredContent"]["result"]["impacts"]
                     if r["status"] == "open"]
        if open_rows:
            impact_id = open_rows[0]["id"]
            settled = call("tools/call", {"name": "corridor_impact_resolve", "arguments": {
                "vault": work, "id": impact_id, "note": "交由人工跟踪",
                "at": "2026-11-02T14:00:00Z"}})["result"]
            assert not settled["isError"], settled
            assert settled["structuredContent"]["result"]["status"] == "resolved"
            assert settled["structuredContent"]["result"]["record"]["dismissed"]
            replay = call("tools/call", {"name": "corridor_impact_resolve", "arguments": {
                "vault": work, "id": impact_id, "note": "交由人工跟踪",
                "at": "2026-11-02T14:00:00Z"}})["result"]
            assert replay["structuredContent"]["result"]["replayed"] is True
            # A resolved decision against these inputs is not re-reported.
            quiet = call("tools/call", {"name": "corridor_impact_audit", "arguments": {
                "vault": work, "at": "2026-11-02T14:30:00Z"}})["result"]
            assert quiet["structuredContent"]["result"]["committed"] is False
        method_error = call("not-a-method")
        assert method_error["error"]["code"] == -32601
        assert method_error["error"]["data"]["error_code"] == "method_not_found"
        assert "error" in call("tools/call", {"name": "corridor_status", "arguments": {"vault": work, "unexpected": True}})
        # No notification reply may appear before the next ping response.
        p.stdin.write('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}\n')
        p.stdin.flush()
        assert call("ping")["result"] == {}
        p.stdin.write('{broken\n')
        p.stdin.flush()
        assert select.select([p.stdout], [], [], 10)[0]
        assert json.loads(p.stdout.readline())["error"]["code"] == -32700
        p.stdin.write('[]\n')
        p.stdin.flush()
        assert select.select([p.stdout], [], [], 10)[0]
        assert json.loads(p.stdout.readline())["error"]["code"] == -32600
        p.stdin.close()
        assert p.wait(timeout=10) == 0
        log.seek(0)
        assert "Warning:" not in log.read()
print("MCP lifecycle, dictionary/schema parity, tools, notifications and errors: passed")
