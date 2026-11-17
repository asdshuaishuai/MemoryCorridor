#!/usr/bin/env python3
"""Offline real-path test for the LLM/HanLP provider surface (续五十四).

CI never touches the network. This e2e runs a local OpenAI-compatible server and
proves the real code paths that `--mock` normally bypasses:

  nlp_adapter affect/expand --provider llm  (JSON parse, bounds, request shape)
  rsi_agent_driver real mode                (prompt -> judgments -> complete)
  rsi_agent_driver model failure            (invalid JSON -> dream-work-fail)
  evo_agent_driver real mode + ack          (prompt -> text -> complete/ack)

HanLP itself stays a clean SKIP (no Java/package in CI); the provider selection
and fallback logic are what get pinned here.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def at(seconds: int) -> str:
    from datetime import datetime, timedelta, timezone
    base = datetime(2026, 11, 17, 0, 0, 0, tzinfo=timezone.utc)
    return (base + timedelta(seconds=seconds)).strftime("%Y-%m-%dT%H:%M:%SZ")
ADAPTER = ROOT / "scripts/nlp_adapter.py"
RSI_DRIVER = ROOT / "scripts/rsi_agent_driver.py"
EVO_DRIVER = ROOT / "scripts/evo_agent_driver.py"


class FakeOpenAI(BaseHTTPRequestHandler):
    responses = {}
    invalid = False
    seen = []

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {}
        last = (payload.get("messages") or [{}])[-1]
        FakeOpenAI.seen.append({
            "path": self.path, "model": payload.get("model"),
            "prompt": last.get("content", ""),
        })
        if FakeOpenAI.invalid:
            raw = b"not-json"
        else:
            content = FakeOpenAI.responses.get(self.path, "")
            raw = json.dumps(
                {"choices": [{"message": {"content": content}}]}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *args):
        pass


def run(server, script, *args, env_extra=None):
    env = dict(os.environ)
    env.update(env_extra or {})
    return subprocess.run([sys.executable, str(ROOT / "scripts" / script)] + list(args),
                          capture_output=True, text=True, timeout=120, env=env)


def main():
    server = HTTPServer(("127.0.0.1", 0), FakeOpenAI)
    port = server.server_address[1]
    endpoint = f"http://127.0.0.1:{port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        # 1. affect via the real LLM path.
        FakeOpenAI.responses = {"/chat/completions": json.dumps(
            {"valence": 0.5, "arousal": 0.4, "salience": 0.3,
             "topics": ["记忆"], "entities": []})}
        FakeOpenAI.invalid = False
        affect = run(server, "nlp_adapter.py", "affect", "--text", "今天很开心",
                     "--provider", "llm", "--endpoint", endpoint, "--model", "fake-model")
        assert affect.returncode == 0, (affect.stdout, affect.stderr)
        row = json.loads(affect.stdout)
        assert row["provider"] == "llm" and row["valence"] == 0.5, row
        assert FakeOpenAI.seen[-1]["model"] == "fake-model", FakeOpenAI.seen[-1]

        # 2. expand via the real LLM path.
        FakeOpenAI.responses = {"/chat/completions": json.dumps(
            {"queries": ["青瓷的来源", "青瓷 出处"]})}
        expand = run(server, "nlp_adapter.py", "expand", "--query", "青瓷的来源",
                     "--provider", "llm", "--endpoint", endpoint, "--model", "fake-model")
        assert expand.returncode == 0, (expand.stdout, expand.stderr)
        queries = json.loads(expand.stdout)
        assert queries["provider"] == "llm", queries
        assert queries["queries"] == ["青瓷的来源", "青瓷 出处"], queries

        # 3. invalid model JSON fails closed.
        FakeOpenAI.responses = {"/chat/completions": "not json at all"}
        bad = run(server, "nlp_adapter.py", "affect", "--text", "x",
                  "--provider", "llm", "--endpoint", endpoint, "--model", "fake-model")
        assert bad.returncode == 1, (bad.stdout, bad.stderr)
        assert "model did not return JSON" in bad.stderr, bad.stderr

        # 4. RSI driver real mode: prompt -> judgments -> complete -> retained.
        with tempfile.TemporaryDirectory(prefix="corridor-real-rsi-") as work:
            vault = Path(work)

            def call(op, **fields):
                result = subprocess.run([str(EXE)],
                                        input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                        text=True, capture_output=True, check=True, timeout=120)
                response = json.loads(result.stdout)
                assert response["ok"], response
                return response["result"]

            call("init", purpose="真实路径 RSI")
            (vault / "raw").mkdir(exist_ok=True)
            (vault / "raw/a.md").write_text("青瓷证据甲。\n", encoding="utf-8")
            (vault / "raw/b.md").write_text("未引用证据乙。\n", encoding="utf-8")
            call("scan")
            call("rebuild")
            call("dream-policy", due_after_seconds=0, min_opportunities=0,
                 max_open_rounds=1, at="2026-11-17T00:00:00Z")
            FakeOpenAI.responses = {"/chat/completions": json.dumps(
                {"judgments": {"task": "local-ok"}, "proposals": []})}
            rsi = run(server, "rsi_agent_driver.py", "--vault", str(vault),
                      "--cli", str(EXE), "--once", "--driver", "rsi-llm",
                      "--limit", "1",
                      env_extra={"RSI_LLM_ENDPOINT": endpoint, "RSI_LLM_MODEL": "fake-model"})
            assert rsi.returncode == 0, (rsi.stdout, rsi.stderr)
            summary = json.loads(rsi.stdout.strip().splitlines()[-1])
            assert summary["closed"] == "retained", summary
            work = call("dream-work-list")["work"]
            assert work and work[0]["result"]["judgments"] == {"task": "local-ok"}, work
            assert any("任务类型" in row["prompt"] for row in FakeOpenAI.seen), FakeOpenAI.seen[-1]

            # 5. model failure is recorded, not crashed.
            FakeOpenAI.responses = {"/chat/completions": "not json"}
            again = run(server, "rsi_agent_driver.py", "--vault", str(vault),
                        "--cli", str(EXE), "--once", "--driver", "rsi-llm",
                        "--limit", "1",
                        env_extra={"RSI_LLM_ENDPOINT": endpoint, "RSI_LLM_MODEL": "fake-model"})
            assert again.returncode == 0, (again.stdout, again.stderr)
            failed = call("dream-work-list")["work"]
            assert any(item["status"] == "failed" for item in failed), failed

        # 6. evo driver real mode: prompt -> text -> complete -> ack.
        with tempfile.TemporaryDirectory(prefix="corridor-real-evo-") as work:
            vault = Path(work)

            def call(op, **fields):
                result = subprocess.run([str(EXE)],
                                        input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                        text=True, capture_output=True, check=True, timeout=120)
                response = json.loads(result.stdout)
                assert response["ok"], response
                return response["result"]

            call("init", purpose="真实路径主动应答")
            call("evo-policy", enabled=True, at="2026-11-17T00:00:00Z")
            call("evo-init", seed=7, at="2026-11-17T00:00:01Z")
            step = 0
            for _ in range(160):
                step += 1
                call("evo-observe", step=step, kind="social", salience=1.0, valence=1.0,
                     subject="user", body={"cpu": 0.1, "memory": 0.1, "latency": 0.1, "budget": 0.1},
                     at=at(10 + step))
                if call("evo-proactive-due", at=at(1000 + step))["due"]:
                    break
            FakeOpenAI.responses = {"/chat/completions": "（本地端点主动应答）"}
            evo = run(server, "evo_agent_driver.py", "--vault", str(vault),
                      "--cli", str(EXE), "--once", "--ack", "--driver", "evo-llm",
                      env_extra={"EVO_LLM_ENDPOINT": endpoint, "EVO_LLM_MODEL": "fake-model"})
            assert evo.returncode == 0, (evo.stdout, evo.stderr)
            assert "（本地端点主动应答）" in evo.stdout, (evo.stdout, evo.stderr)
            counts = call("evo-proactive-list")["counts"]
            assert counts["done"] == 1 and counts["delivered"] == 1, counts
            assert any("情绪" in row["prompt"] for row in FakeOpenAI.seen), FakeOpenAI.seen[-1]

    finally:
        server.shutdown()
        server.server_close()

    print("nlp/llm real-path e2e: local OpenAI-compatible server drives affect/expand, "
          "RSI judgments + failure recording, evo proactive reply + ack passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())