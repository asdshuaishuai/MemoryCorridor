#!/usr/bin/env python3
"""Real HTTP/native checks; no mock engine or application-specific dependency."""
import http.client
import json
from pathlib import Path
import select
import subprocess
import tempfile
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
from urllib.error import HTTPError

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"
SERVER = REPO / "_build/native/debug/build/web/web.exe"

with tempfile.TemporaryDirectory(prefix="corridor-web-") as work:
    root = Path(work)
    subprocess.run(["python3", str(REPO / "scripts/reading_fixture.py"), work], capture_output=True, text=True, check=True)

    def native(op, **fields):
        run = subprocess.run([str(EXE)], input=json.dumps({"op": op, "vault": work, **fields}) + "\n",
                             capture_output=True, text=True, check=True, timeout=30)
        result = json.loads(run.stdout)
        assert result["ok"], result
        return result

    server = subprocess.Popen([str(SERVER), work, "--port", "0"],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        assert select.select([server.stdout], [], [], 30)[0], "HTTP startup timed out"
        ready = json.loads(server.stdout.readline())
        origin = ready["url"]
        assert ready["mode"] == "read-only"

        def request(path, method="GET", headers=None):
            req = Request(origin + path, method=method, headers=headers or {})
            try:
                result = urlopen(req, timeout=30)
            except HTTPError as error:
                result = error
            with result:
                body = result.read()
                return result.status, result.headers, body

        def api(path):
            status, headers, body = request(path)
            assert status == 200, body
            assert headers["Cache-Control"] == "no-store"
            assert headers["Content-Type"].startswith("application/json")
            return json.loads(body)

        assert api("/api/status") == native("status")
        assert api("/api/pages") == native("list-pages")
        assert api("/api/tree") == native("tree")
        assert api("/api/topics") == native("topics")
        assert api("/api/lint") == native("lint")
        assert api("/api/page?" + urlencode({"id": "concepts/rich"})) == native("read-page", id="concepts/rich")
        assert api("/api/search?" + urlencode({"q": "渲染"})) == native("search", query="渲染")
        strategy_args = {"q": "渲染", "limit": 2, "budget": 128, "hops": 0, "dedup": "similar", "spread": "even"}
        assert api("/api/search?" + urlencode(strategy_args)) == native(
            "search", query="渲染", limit=2, budget=128, hops=0, dedup="similar", spread="even")
        vector = {"space": {"id": "web-test", "dimensions": 2}, "values": [1, 0]}
        search_args = {"q": "渲染", "limit": 2, "budget": 128, "hops": 0,
                       "query_vector": json.dumps(vector, ensure_ascii=False, separators=(",", ":"))}
        assert api("/api/search?" + urlencode(search_args)) == native(
            "search", query="渲染", limit=2, budget=128, hops=0, query_vector=vector)
        assert api("/api/search?" + urlencode({"q": "", "query_vector": json.dumps(vector)})) == native(
            "search", query="", query_vector=vector)
        space = {"id": "web-test", "dimensions": 2}
        native("provider-register", provider="web-provider", kind="embedding", space=space,
               capabilities=["embed"], at="2026-10-16")
        native("rebuild")
        provider_args = {"q": "", "provider": "web-provider",
                         "query_vector": json.dumps({"space": space, "values": [1, 0]}, ensure_ascii=False, separators=(",", ":"))}
        assert api("/api/search?" + urlencode(provider_args)) == native(
            "search", query="", provider="web-provider", query_vector={"space": space, "values": [1, 0]})
        candidates = {"space": {"id": "web-external-v1", "dimensions": 2},
                      "hits": [{"id": "concepts/rich", "score": 0.99}]}
        external_args = {"q": "", "vector_candidates": json.dumps(candidates, ensure_ascii=False, separators=(",", ":"))}
        assert api("/api/search?" + urlencode(external_args)) == native(
            "search", query="", vector_candidates=candidates)
        status, headers, html = request("/")
        assert status == 200 and headers["Content-Type"].startswith("text/html")
        assert html == (root / ".corridor/viewer.html").read_bytes()
        assert b"Content-Security-Policy" in html and "富文本与代码".encode() in html
        status, headers, body = request("/", method="HEAD")
        assert status == 200 and not body and int(headers["Content-Length"]) == len(html)
        for path in ["/api/page", "/api/page?id=", "/api/search", "/api/search?q=", "/api/search?q=a&q=b",
                     "/api/search?q=a&limit=nope", "/api/search?q=a&unknown=1",
                     "/api/search?q=a&query_vector=not-json", "/api/search?q=&vector_candidates=not-json",
                     "/api/status?vault=/tmp", "/api/lint?extra=1", "/api/topics?id=x",
                     "/?view=other"]:
            assert request(path)[0] == 400, path
        for path in ["/raw/article.md", "/.corridor/viewer.html", "/../purpose.md", "/api/commit",
                     "/api/topics/extra", "/api/memory-list", "/api/inbox", "/api/page-history"]:
            assert request(path)[0] == 404, path
        assert request("/api/search?q=a&hops=3")[0] == 409
        assert request("/api/search?q=a&dedup=unknown")[0] == 409
        assert request("/api/search?q=a&spread=unknown")[0] == 409
        assert request("/", method="POST")[0] == 405
        assert request("/api/status", headers={"Host": "attacker.example"})[0] == 403
        connection = http.client.HTTPConnection(urlsplit(origin).netloc, timeout=30)
        connection.request("GET", "http://attacker.example/api/status")
        assert connection.getresponse().status == 403
        connection.close()

        # Raw-socket probes for the request reader itself: the terminator
        # \r\n\r\n begins at the last header line's own \r, so a parser that
        # stops splitting at the terminator start would swallow that line
        # whole — historically producing 403 invalid_host whenever Host came
        # last, as minimal pipelined clients write it.
        import socket
        origin_parts = urlsplit(origin)

        def raw(payload):
            with socket.create_connection((origin_parts.hostname, origin_parts.port), timeout=30) as probe:
                probe.sendall(payload)
                probe.shutdown(socket.SHUT_WR)  # request fully sent; server may drain to EOF
                chunks = []
                while True:
                    piece = probe.recv(65536)
                    if not piece:
                        break
                    chunks.append(piece)
                return b"".join(chunks)

        host_header = ("Host: %s:%d" % (origin_parts.hostname, origin_parts.port)).encode()
        minimal = raw(b"GET /api/status HTTP/1.1\r\n" + host_header + b"\r\n\r\n")
        assert minimal.startswith(b"HTTP/1.1 200 OK"), minimal[:120]
        assert b'"ok":true' in minimal and b'"op":"status"' in minimal
        # The byte ceiling covers every accumulated block: an oversized header
        # block whose terminator arrives with it is 431, not an accepted 200.
        oversized = raw(b"GET /api/status HTTP/1.1\r\n" + host_header +
                        b"\r\nX-Pad: " + b"a" * 140000 + b"\r\n\r\n")
        assert oversized.startswith(b"HTTP/1.1 431 "), oversized[:120]
        # And the response must actually reach the client: a bounded drain
        # follows the 431 so the kernel cannot answer the peer's unread bytes
        # with an RST that swallows the response head+body.
        assert oversized.rstrip().endswith(b'{"error":"headers_too_large","ok":false}'), oversized[-120:]
        # HEAD keeps RFC semantics on the raw path: headers only.
        head_only = raw(b"HEAD /api/status HTTP/1.1\r\n" + host_header + b"\r\n\r\n")
        assert head_only.startswith(b"HTTP/1.1 200 OK"), head_only[:120]
        assert head_only.endswith(b"Connection: close\r\n\r\n"), head_only[-120:]

        page = root / "wiki/concepts/rich.md"
        text = page.read_text()
        previous = (root / ".corridor/viewer.html").read_bytes()
        page.write_text(text + "\n外部编辑尚未登记。\n")
        assert request("/api/status")[0] == 409
        lint = api("/api/lint")
        assert lint["result"]["errors"] >= 1 and any(v["predicate"] == "content_hash_drift" for v in lint["result"]["violations"])
        assert request("/api/page?id=concepts/rich")[0] == 409
        assert request("/")[0] == 409
        assert (root / ".corridor/viewer.html").read_bytes() == previous
        native("refresh")
        assert "外部编辑尚未登记" in api("/api/page?id=concepts/rich")["result"]["text"]
        assert "外部编辑尚未登记".encode() in request("/")[2]
        view = root / "views/library.mbt.md"
        original = view.read_text()
        previous = (root / ".corridor/viewer.html").read_bytes()
        view.write_text("not a valid declaration")
        assert request("/")[0] == 409
        assert (root / ".corridor/viewer.html").read_bytes() == previous
        view.write_text(original)
        assert request("/")[0] == 200
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=10)

print("Loopback Web: native read/search parity, compiled mbt.md, routing confinement, drift/compiler rejection: passed")
