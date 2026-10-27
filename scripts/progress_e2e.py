#!/usr/bin/env python3
"""Verify opt-in structured progress for the CLI and MCP transports."""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "_build/native/debug/build/cli/cli.exe"
MCP = ROOT / "_build/native/debug/build/mcp/mcp.exe"


def read_line(stream, label):
    data = bytearray()
    while True:
        assert select.select([stream], [], [], 20)[0], label
        chunk = os.read(stream.fileno(), 1)
        assert chunk, label
        if chunk == b"\n":
            return json.loads(data.decode())
        data.extend(chunk)


with tempfile.TemporaryDirectory(prefix="corridor-progress-") as work:
    cli = subprocess.Popen([str(CLI)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, bufsize=0)

    def cli_send(value):
        cli.stdin.write((json.dumps(value) + "\n").encode())
        cli.stdin.flush()

    cli_send({"op": "init", "vault": work, "purpose": "progress", "progress": True, "request_id": 1})
    started = read_line(cli.stdout, "CLI started event")
    completed = read_line(cli.stdout, "CLI completed event")
    terminal = read_line(cli.stdout, "CLI terminal response")
    assert started == {"event": "progress", "op": "init", "phase": "started", "request_id": 1}
    assert completed["event"] == "progress" and completed["phase"] == "completed"
    assert terminal["ok"] and terminal["request_id"] == 1

    cli_send({"op": "status", "vault": work, "progress": "yes", "request_id": 2})
    invalid = read_line(cli.stdout, "CLI invalid progress response")
    assert not invalid["ok"] and invalid["error_code"] == "expected_boolean"
    cli.stdin.close()
    assert cli.wait(timeout=10) == 0

    mcp = subprocess.Popen([str(MCP)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, bufsize=0)

    def mcp_send(value):
        mcp.stdin.write((json.dumps(value) + "\n").encode())
        mcp.stdin.flush()

    mcp_send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {}}})
    assert read_line(mcp.stdout, "MCP initialize")["id"] == 1
    mcp_send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    mcp_send({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
              "params": {"name": "corridor_status", "arguments": {"vault": work},
                         "_meta": {"progressToken": "progress-1"}}})
    mcp_started = read_line(mcp.stdout, "MCP started event")
    mcp_completed = read_line(mcp.stdout, "MCP completed event")
    mcp_terminal = read_line(mcp.stdout, "MCP terminal response")
    assert mcp_started["method"] == "notifications/progress"
    assert mcp_started["params"]["progress"] == 0
    assert mcp_completed["params"]["progress"] == 1
    assert mcp_terminal["id"] == 2 and not mcp_terminal["result"]["isError"]
    mcp.stdin.close()
    assert mcp.wait(timeout=10) == 0

print("Structured progress: CLI opt-in events, MCP progress notifications and failure typing passed")
