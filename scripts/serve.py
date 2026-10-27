#!/usr/bin/env python3
"""Loopback HTTP transport for the native engine and compiled mbt.md reader."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
from urllib.parse import parse_qs, urlsplit

parser = argparse.ArgumentParser(description="Serve a MemoryCorridor vault on localhost")
parser.add_argument("vault", type=Path)
parser.add_argument("--port", type=int, default=8768)
parser.add_argument("--cli", type=Path, default=Path(__file__).resolve().parents[1] / "_build/native/debug/build/cli/cli.exe")
args = parser.parse_args()
if not 0 <= args.port <= 65535:
    parser.error("--port must be between 0 and 65535")
root, exe = args.vault.resolve(strict=True), args.cli.resolve(strict=True)


def invoke(op, **fields):
    process = subprocess.run([str(exe)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
                             capture_output=True, text=True, check=True, timeout=30)
    return json.loads(process.stdout)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def respond(self, status, value, mime="application/json; charset=utf-8"):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        try:
            port = self.server.server_port
            if self.headers.get("Host") not in {f"127.0.0.1:{port}", f"localhost:{port}"}:
                self.respond(403, {"ok": False, "error": "invalid_host"})
                return
            url = urlsplit(self.path)
            if url.scheme or url.netloc or len(self.path.encode()) > 16384:
                raise ValueError("invalid_request_target")
            query = parse_qs(url.query, keep_blank_values=True, strict_parsing=True, max_num_fields=12)
            routes = {"/": ("render-view", None), "/api/status": ("status", None),
                      "/api/pages": ("list-pages", None), "/api/page": ("read-page", "id"),
                      "/api/search": ("search", "q"), "/api/tree": ("tree", None),
                      "/api/topics": ("topics", None),
                      "/api/lint": ("lint", None)}
            if url.path not in routes:
                self.respond(404, {"ok": False, "error": "not_found"})
                return
            op, parameter = routes[url.path]
            if url.path == "/api/search":
                allowed = {"q", "limit", "budget", "hops", "query_vector", "vector_candidates", "dedup", "spread", "provider"}
                if set(query) - allowed or "q" not in query or any(len(v) != 1 for v in query.values()):
                    raise ValueError("invalid_query_parameters")
                if not query["q"][0] and "query_vector" not in query and "vector_candidates" not in query:
                    raise ValueError("invalid_query_parameters")
                fields = {"query": query["q"][0]}
                for name in ("limit", "budget", "hops"):
                    if name in query:
                        try:
                            fields[name] = int(query[name][0])
                        except ValueError:
                            raise ValueError("invalid_" + name)
                for name in ("dedup", "spread", "provider"):
                    if name in query:
                        fields[name] = query[name][0]
                if "query_vector" in query:
                    try:
                        vector = json.loads(query["query_vector"][0])
                    except json.JSONDecodeError:
                        raise ValueError("invalid_query_vector")
                    if not isinstance(vector, dict):
                        raise ValueError("invalid_query_vector")
                    fields["query_vector"] = vector
                if "vector_candidates" in query:
                    try:
                        candidates = json.loads(query["vector_candidates"][0])
                    except json.JSONDecodeError:
                        raise ValueError("invalid_vector_candidates")
                    if not isinstance(candidates, dict):
                        raise ValueError("invalid_vector_candidates")
                    fields["vector_candidates"] = candidates
            else:
                if set(query) != ({parameter} if parameter else set()) or any(len(v) != 1 or not v[0] for v in query.values()):
                    raise ValueError("invalid_query_parameters")
                fields = {} if parameter is None else {"query" if parameter == "q" else parameter: query[parameter][0]}
            # lint is the recovery-facing read operation: it must be able to
            # describe the drift that would make verify reject the vault.
            if op != "lint":
                verified = invoke("verify")
                if not verified["ok"]:
                    self.respond(409, verified)
                    return
            result = invoke(op, **fields)
            if not result["ok"]:
                self.respond(409, result)
            elif url.path == "/":
                self.respond(200, (root / ".corridor/viewer.html").read_bytes(), "text/html; charset=utf-8")
            else:
                self.respond(200, result)
        except ValueError as error:
            self.respond(400, {"ok": False, "error": str(error)})
        except subprocess.TimeoutExpired:
            self.respond(504, {"ok": False, "error": "engine_timeout"})
        except (OSError, subprocess.SubprocessError, KeyError):
            self.respond(502, {"ok": False, "error": "engine_unavailable_or_invalid_response"})

    do_HEAD = do_GET

    def do_POST(self):
        self.close_connection = True
        self.respond(405, {"ok": False, "error": "read_only_service"})


for operation in ["verify"] + ([] if (root / "views/library.mbt.md").exists() else ["view-init"]) + ["render-view"]:
    result = invoke(operation)
    if not result["ok"]:
        raise SystemExit(json.dumps(result, ensure_ascii=False))
with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
    server.daemon_threads = False
    print(json.dumps({"url": f"http://127.0.0.1:{server.server_port}", "vault": str(root), "mode": "read-only"}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
