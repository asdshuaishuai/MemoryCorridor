#!/usr/bin/env python3
"""Exercise the actual native process, compiler, and temporary on-disk vaults."""
import fcntl
import hashlib
import json
from pathlib import Path
import select
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"
CHECKS = []


class Session:
    def __init__(self, root):
        self.root = root
        self.log = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen(
            [str(EXE)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, text=True, bufsize=1,
        )

    def call(self, op, *, error=None, **args):
        request = {"op": op, "vault": str(self.root), "request_id": len(CHECKS), **args}
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 20)[0]:
            raise AssertionError(f"response timed out: {op}")
        line = self.process.stdout.readline()
        assert line, f"process exited on {op}"
        value = json.loads(line)
        assert value["request_id"] == request["request_id"]
        if error:
            assert not value["ok"] and error in value["error"], value
            return value
        assert value["ok"], value
        return value["result"]

    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=10) == 0
        self.log.seek(0)
        log = self.log.read()
        assert "Panic" not in log, log
        assert "Warning:" not in log, log
        self.log.close()


def check(name):
    CHECKS.append(name)


def prepare(session, order):
    context = session.call("context", order=order)
    session.call("analysis-submit", order=order, analysis={
        "entities": [], "concepts": ["能量", "共享"], "conflicts": [], "summary": "资料分析",
    })
    return context


def commit(session, order, pages):
    directory = session.root / "staging" / order
    directory.mkdir(parents=True, exist_ok=True)
    declarations = []
    for i, (pid, title, sources, body) in enumerate(pages):
        staged = directory / f"{i}.md"
        staged.write_text(
            "---\ntype: concept\ntitle: " + title + "\nsources: " +
            json.dumps(sources, ensure_ascii=False) + "\n---\n" + body + "\n"
        )
        declarations.append({"id": pid, "path": f"wiki/{pid}.md", "staged": str(staged.relative_to(session.root))})
    return session.call("commit", order=order, pages=declarations, at="2026-10-16")


with tempfile.TemporaryDirectory(prefix="memorycorridor-e2e-") as work:
    root = Path(work) / "vault"
    root.mkdir()
    s = Session(root)
    initial = s.call("init", purpose="植物能量知识")
    s.call("search", query="空库")
    assert s.call("verify")["violations"] == []
    assert s.call("status")["index_cache"] == "valid"
    lint = s.call("lint")
    assert lint["status"] == "clean" and lint["errors"] == 0 and lint["violations"] == []
    s.call("init", error="vault_already_initialized")
    check("empty vault, explicit init refusal and clean verify/lint")

    (root / "raw/甲.md").write_text("# 光合作用\n叶绿体转换光能。\n")
    (root / "raw/乙.txt").write_text("共享能源研究：保存来源证据。\n")
    assert len(s.call("scan")["orders"]) == 2
    planned = {o["source"]: o["id"] for o in s.call("plan")}
    first, second = planned["raw/甲.md"], planned["raw/乙.txt"]
    prepare(s, first)
    s.call("context", order=second, error="another_order_active")
    commit(s, first, [("concepts/能量", "光合作用能量", ["raw/甲.md"], "叶绿体通过光合作用转换能量。")])
    prepare(s, second)
    commit(s, second, [("concepts/共享", "共享能源", ["raw/甲.md", "raw/乙.txt"], "跨资料的共享能源知识。[[concepts/能量]]")])
    pages = s.call("list-pages")
    assert len(pages) == 4  # Two concepts and two fallback source pages.
    assert s.call("search", query="光合作用")["hits"][0]["id"] == "concepts/能量"
    s.call("check-index")
    s.call("verify")
    index_source = (root / "index.mbt.md").read_text()
    (root / "index.mbt.md").write_text(index_source + "\n```mbt check\nfn literate_helper() -> Int { corridor_entries().length() }\ntest \"literate helper block\" { assert_eq(literate_helper(), 9) }\n```\n")
    s.call("check-index")
    assert s.call("status")["index_cache"] == "valid"
    # Runtime loading must honor every checked literate block, even though the
    # closed catalog IR is parsed from the first block. A broken helper cannot
    # become active merely because the entry rows are unchanged.
    (root / "index.mbt.md").write_text(index_source + "\n```mbt check\nfn broken_helper() -> Int { missing_symbol() }\n```\n")
    s.call("search", query="光合作用", error="moon_check_failed")
    (root / "index.mbt.md").write_text(index_source)
    # A malformed document (text glued to the closing fence) is refused at load
    # time by the same runtime parser the compiler-independent paths use.
    (root / "index.mbt.md").write_text(index_source + "Glued remark")
    rejected = s.call("status", error="catalog_literate_tail")
    assert any(v["predicate"] == "catalog_literate_tail" for v in rejected["violations"])
    (root / "index.mbt.md").write_text(index_source)
    check("two sources, serialized work orders, fallback summaries and Chinese retrieval")

    shared = s.call("read-page", id="concepts/共享")
    body = shared["text"].split("---\n", 2)[-1]
    quote = "跨资料的共享能源知识。"
    start = len(body.encode("utf-8").split(quote.encode("utf-8"), 1)[0])
    end = start + len(quote.encode("utf-8"))
    second_quote = "共享"
    second_start = len(body.encode("utf-8").split(second_quote.encode("utf-8"), 1)[0])
    second_end = second_start + len(second_quote.encode("utf-8"))
    evidence = s.call("evidence-submit", page="concepts/共享", page_hash=shared["entry"]["sha256"], items=[
        {"source": "raw/甲.md", "body_start": start, "body_end": end, "quote": quote},
        {"source": "raw/甲.md", "body_start": second_start, "body_end": second_end, "quote": second_quote},
    ])
    assert not evidence["replayed"] and evidence["record"]["valid"] and len(evidence["record"]["claims"]) == 2
    replay = s.call("evidence-submit", page="concepts/共享", page_hash=shared["entry"]["sha256"], items=[
        {"source": "raw/甲.md", "body_start": start, "body_end": end, "quote": quote},
        {"source": "raw/甲.md", "body_start": second_start, "body_end": second_end, "quote": second_quote},
    ])
    assert replay["replayed"]
    s.call("evidence-submit", page="concepts/共享", page_hash=shared["entry"]["sha256"], items=[
        {"source": "raw/甲.md", "body_start": start, "body_end": end, "quote": quote},
        {"source": "raw/甲.md", "body_start": start, "body_end": end, "quote": quote},
    ], error="evidence_duplicate_claim")
    page_evidence = s.call("read-page", id="concepts/共享")["evidence"]
    assert len(page_evidence[0]["claims"]) == 2 and all(claim["valid"] for claim in page_evidence[0]["claims"]) and s.call("evidence-list", page="concepts/共享")[0]["id"] == evidence["id"]
    assert s.call("search", query="共享")["context"]["blocks"][0]["evidence"][0]["id"] == evidence["id"]
    s.call("evidence-submit", page="concepts/共享", page_hash=shared["entry"]["sha256"], items=[
        {"source": "raw/甲.md", "body_start": start, "body_end": end + 1, "quote": quote},
    ], error="evidence_quote_mismatch")
    s.call("evidence-submit", page="concepts/共享", page_hash=shared["entry"]["sha256"], items=[
        {"source": "raw/甲.md", "body_start": start + 1, "body_end": end, "quote": quote},
    ], error="utf8_range_boundary_invalid")
    s.call("evidence-submit", page="concepts/共享", page_hash="0" * 64, items=[
        {"source": "raw/甲.md", "body_start": start, "body_end": end, "quote": quote},
    ], error="evidence_page_version_mismatch")
    check("page evidence sidecars enforce UTF-8 ranges, page versions and idempotent replay")

    before = s.call("status")["fingerprint"]
    assert s.call("commit", order=second, pages=[], at="2026-10-16")["replayed"]
    assert s.call("status")["fingerprint"] == before
    check("committed order retry is idempotent")

    by_id = {p["id"]: p for p in pages}
    space = {"id": "test-embedding-v1", "dimensions": 2}
    items = [{"page": pid, "sha256": by_id[pid]["sha256"], "values": values}
             for pid, values in [("concepts/能量", [1, 0]), ("concepts/共享", [0, 1])]]
    s.call("embedding-submit", space=space, items=items)
    qv = {"space": space, "values": [0, 1]}
    vector = s.call("search", query="", query_vector=qv)
    assert vector["vector_status"] == "brute_force"
    assert vector["hits"][0]["id"] == "concepts/共享"
    foreign = {"space": {"id": "different-model", "dimensions": 2}, "values": [0, 1]}
    assert s.call("search", query="", query_vector=foreign)["hits"] == []
    invalid = [{**items[0], "values": [0, 0]}]
    s.call("embedding-submit", space=space, items=invalid, error="vector_zero_norm")
    invalid = [{**items[0], "sha256": "0" * 64}]
    s.call("embedding-submit", space=space, items=invalid, error="vector_content_version_mismatch")
    check("exact vector ranking, model isolation, zero-norm and version rejection")

    fingerprint = s.call("status")["fingerprint"]
    order_bytes = {p: p.read_bytes() for p in (root / "state/orders").glob("*.json")}
    shutil.rmtree(root / ".corridor")
    assert s.call("search", query="共享")["cache_rebuilt"]
    assert all(p.read_bytes() == data for p, data in order_bytes.items())
    assert s.call("status")["fingerprint"] == fingerprint
    cache = root / ".corridor/fts.json"
    cache.write_text("corrupted")
    s.call("verify", error="index_missing_or_invalid")
    assert s.call("status")["index_cache"] == "missing_or_invalid"
    assert s.call("search", query="共享")["cache_rebuilt"]
    s.call("verify")
    check("cache deletion and real corruption rebuild without losing orders")

    original = (root / "wiki/concepts/能量.md").read_text()
    (root / "wiki/concepts/能量.md").write_text(original + "外部改动")
    s.call("verify", error="content_changed")
    drift_lint = s.call("lint")
    assert drift_lint["errors"] >= 1 and any(v["predicate"] == "content_hash_drift" for v in drift_lint["violations"])
    s.call("search", query="能量", error="content_changed")
    (root / "wiki/concepts/能量.md").write_text(original)
    (root / "raw/符号链接.md").symlink_to(root / "raw/甲.md")
    s.call("scan", error="list_failed_or_symlink")
    (root / "raw/符号链接.md").unlink()
    unknown = s.call("status", unexpected=True, error="unknown_field")
    assert unknown["error_code"] == "unknown_field" and "list-tools" in unknown["hint"]
    s.call("read-page", id="../outside", error="entry_not_found")
    with (root / ".corridor-lock").open("r+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        s.call("status", error="vault_locked")
    check("external drift, symlinks, unknown fields and process lock")

    forgotten = s.call("forget", source="raw/甲.md", at="2026-10-16")
    assert "concepts/共享" in forgotten["invalidated"]
    assert s.call("forget", source="raw/甲.md", at="2026-10-16")["replayed"]
    assert s.call("status")["fingerprint"] == forgotten["fingerprint"]
    assert s.call("read-page", id="concepts/共享")["stale"]
    assert not s.call("read-page", id="concepts/共享")["evidence"][0]["valid"]
    assert s.call("status")["evidence"]["invalid"] == 1
    assert s.call("search", query="共享", query_vector=qv)["hits"] == []
    assert s.call("scan")["orders"] == []  # Unchanged forgotten raw is not reintroduced.
    check("shared-page invalidation, vector exclusion and persistent forget tombstone")

    # Source changes enqueue a new version and invalidate obsolete work orders.
    (root / "raw/乙.txt").write_text("共享能源研究修订版：只保留乙来源证据。\n")
    new_order = s.call("scan")["orders"][0]
    assert new_order != second
    context = prepare(s, new_order)
    assert any(p["entry"]["id"] == "concepts/共享" for p in context["pages"])
    commit(s, new_order, [("concepts/共享", "共享能源修订", ["raw/乙.txt"], "仅由乙支持的新版共享知识。")])
    assert not s.call("read-page", id="concepts/共享")["stale"]
    assert s.call("search", query="共享")["hits"]
    # Old embedding must not survive a body version change.
    assert s.call("search", query="", query_vector=qv)["hits"] == []
    s.call("verify")
    check("incremental context includes old text, recompilation and stale-vector exclusion")

    # Real file recovery, both sides of the catalog publication point.
    for published in [False, True]:
        old_index = (root / "index.mbt.md").read_text()
        recovered_event = json.dumps({"op": "refresh", "before": "0" * 64, "changes": []}, separators=(",", ":"))
        digest = hashlib.sha256(recovered_event.encode()).hexdigest()
        row = f'    entry("state/events/recovery.json", "state/events/recovery.json", "state", "json", "{digest}", [], false),\n'
        # Canonical order requires all entries sorted by id.
        split = old_index.split("  [\n", 1)
        body, tail = split[1].split("  ]\n", 1)
        rows = body.splitlines(keepends=True) + [row]
        rows.sort()
        import re
        tail = re.sub(r'length\(\), \d+', f'length(), {len(rows)}', tail)
        new_index = split[0] + "  [\n" + "".join(rows) + "  ]\n" + tail
        event_path = "state/events/recovery.json"
        journal = {"version": 1, "old_index": old_index, "new_index": new_index,
                   "changes": [{"path": event_path, "before": None, "after": recovered_event}]}
        (root / "state/transactions/pending.json").write_text(json.dumps(journal))
        (root / event_path).write_text(recovered_event)
        if published:
            (root / "index.mbt.md").write_text(new_index)
        assert s.call("recover")["recovered"]
        assert (root / event_path).exists() == published
        assert not (root / "state/transactions/pending.json").exists()
        direction = "forward" if published else "rollback"
        history = {"version": 1, "direction": direction, "journal": journal}
        history_bytes = json.dumps(history, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        history_path = root / "state/transactions/history" / (hashlib.sha256(history_bytes).hexdigest() + ".json")
        assert history_path.read_bytes() == history_bytes
    s.call("rebuild")
    s.call("check-index")
    s.call("verify")
    check("on-disk transaction recovery before and after publication")
    # Explicit human edit adoption must be all-or-nothing and invalidate embeddings.
    page = root / "wiki/concepts/共享.md"
    text = page.read_text()
    baseline = (root / "index.mbt.md").read_bytes()
    page.write_text(text + "\n[[concepts/missing]]")
    s.call("refresh", error="wikilink_unresolved")
    assert (root / "index.mbt.md").read_bytes() == baseline
    page.write_text(text + "\n人工修订术语：叶绿素。<script>window.pwned=1</script>\n")
    s.call("refresh")
    assert s.call("search", query="叶绿素")["hits"][0]["id"] == "concepts/共享"
    assert s.call("search", query="", query_vector=qv)["hits"] == []
    check("invalid refresh preserves catalog; valid human edit refreshes search and vector versions")

    binary = b"%PDF-1.7\x00\xff\x80test"
    (root / "raw/document.pdf").write_bytes(binary)
    order = s.call("scan")["orders"][0]
    ctx = s.call("context", order=order)
    assert ctx["source_text"] is None and ctx["extraction_required"]
    assert ctx["order"]["source_hash"] == hashlib.sha256(binary).hexdigest()
    s.call("cancel", order=order)
    check("binary original digest is byte-accurate and extraction stays explicit")

    (root / "raw/context.html").write_text("<article><h1>HTML source</h1><p>可直接交给 Agent 分析。</p></article>")
    html_order = s.call("scan")["orders"][0]
    html_context = s.call("context", order=html_order)
    assert html_context["source_text"] == "<article><h1>HTML source</h1><p>可直接交给 Agent 分析。</p></article>"
    assert not html_context["extraction_required"]
    s.call("cancel", order=html_order)
    check("catalog format exposes HTML source text to context without external extraction")

    g = s.call("graph")
    assert any(n["id"] == "concepts/共享" for n in g["nodes"])
    assert all(n["id"] != "concepts/能量" for n in g["nodes"])
    tree = s.call("tree")
    def check_tree(node):
        assert set(node) == {"name", "dirs", "pages"}
        assert [directory["name"] for directory in node["dirs"]] == sorted(directory["name"] for directory in node["dirs"])
        assert [page["name"] for page in node["pages"]] == sorted(
            [page["name"] for page in node["pages"]], key=lambda name: (name != "index", name)
        )
        for page in node["pages"]:
            assert set(page) == {"id", "kind", "name", "path", "stale", "title"}
        for directory in node["dirs"]:
            check_tree(directory)
    assert tree["name"] == "wiki"
    check_tree(tree)
    s.call("insights")
    assert s.call("path", **{"from": "concepts/共享", "to": "concepts/共享"})["path"] == ["concepts/共享"]
    assert s.call("weighted-path", **{"from": "concepts/共享", "to": "concepts/共享"})["path"] == ["concepts/共享"]
    research = s.call("research-topic", topic="共享能源的证据缺口", queries=["共享能源 证据", "能源协同机制"], at="2026-10-16", key="research-gap-1")
    assert research["status"] == "proposed" and research["execution"] == "host_required"
    assert s.call("research-list")[0]["id"] == research["id"]
    assert s.call("research-topic", topic="共享能源的证据缺口", queries=["共享能源 证据", "能源协同机制"], at="2026-10-16", key="research-gap-1")["replayed"]
    s.call("research-topic", topic="另一个主题", queries=["不同问题"], at="2026-10-16", key="research-gap-1", error="research_key_conflict")
    assert s.call("stats")["pending_research"] == 1
    (root / "raw/research").mkdir(parents=True, exist_ok=True)
    (root / "raw/research/gap.md").write_text("研究结果需要纳入来源登记。\n")
    s.call("scan")
    completed = s.call("research-complete", id=research["id"], sources=["raw/research/gap.md"], at="2026-10-17")
    assert completed["status"] == "completed" and not completed["replayed"]
    assert s.call("research-complete", id=research["id"], sources=["raw/research/gap.md"], at="2026-10-17")["replayed"]
    s.call("research-cancel", id=research["id"], at="2026-10-18", error="research_terminal")
    assert s.call("stats")["pending_research"] == 0
    check("persistent research-topic handoff, key replay and conflict refusal")
    catalog_before_suggest = (root / "index.mbt.md").read_text()
    literate_tail = ("\nHuman-maintained catalog notes.\n\n"+
                     "```mbt check\nfn purpose_helper() -> Int { 1 }\n"+
                     "test \"purpose helper\" { assert_eq(purpose_helper(), 1) }\n```\n")
    (root / "index.mbt.md").write_text(catalog_before_suggest + literate_tail)
    s.call("check-index")
    suggestion = s.call("purpose-suggest", at="2026-10-18", key="purpose-cycle-1")
    assert suggestion["status"] == "proposed" and suggestion["context"]["purpose_hash"]
    assert s.call("purpose-suggest", at="2026-10-18", key="purpose-cycle-1")["replayed"]
    applied = s.call("purpose-apply", id=suggestion["id"], text="聚焦共享能源证据与来源维护", at="2026-10-19")
    assert applied["status"] == "applied" and not applied["replayed"]
    assert literate_tail in (root / "index.mbt.md").read_text()
    assert "共享能源证据" in s.call("read-purpose")
    assert s.call("purpose-apply", id=suggestion["id"], text="聚焦共享能源证据与来源维护", at="2026-10-19")["replayed"]
    s.call("purpose-apply", id=suggestion["id"], text="另一个目标", at="2026-10-20", error="suggestion_terminal")
    assert s.call("stats")["pending_suggestions"] == 0
    check("purpose suggestion context, atomic human apply and terminal replay")
    stale_suggestion = s.call("purpose-suggest", at="2026-10-19", key="purpose-cycle-2")
    purpose_path = root / "purpose.md"
    purpose_path.write_text(purpose_path.read_text() + "外部目标修订。\n")
    s.call("refresh")
    s.call("purpose-apply", id=stale_suggestion["id"], text="过期建议不能覆盖", at="2026-10-20", error="purpose_suggestion_stale")
    check("purpose suggestion rejects external target drift")
    assert s.call("stats")["overview_status"] == "missing"
    overview = s.call("overview-suggest", at="2026-10-20", key="overview-cycle-1")
    assert overview["status"] == "proposed" and overview["context"]["page_hashes"]
    overview_text = "---\ntype: synthesis\ntitle: 全局综述\nsources: [\"raw/乙.txt\", \"raw/research/gap.md\"]\n---\n当前知识库围绕共享能源证据组织。\n"
    applied_overview = s.call("overview-apply", id=overview["id"], text=overview_text, at="2026-10-21")
    assert applied_overview["status"] == "applied" and s.call("stats")["overview_status"] == "current"
    assert s.call("read-page", id="overview")["entry"]["kind"] == "synthesis"
    assert s.call("overview-apply", id=overview["id"], text=overview_text, at="2026-10-21")["replayed"]
    s.call("overview-apply", id=overview["id"], text=overview_text + "改动", at="2026-10-22", error="overview_terminal")
    check("overview suggestion context, synthesis publication and status")
    assembled = s.call("search", query="共享", budget=150)["context"]
    assert assembled["used"] <= 150 and assembled["blocks"]
    assert all(b["sha256"] and b["sources"] for b in assembled["blocks"])
    s.call("search", query="共享", budget=0, error="invalid_integer")
    check("graph, insights and bounded retrieval with versioned citations")

    s.call("view-init")
    view = root / "views/library.mbt.md"
    original_view = view.read_text()
    rendered = s.call("render-view")
    html = root / rendered["output"]
    assert html.exists() and "&lt;script&gt;window.pwned=1" in html.read_text()
    previous_html = html.read_bytes()
    view.write_text(original_view + "Glued remark")
    s.call("render-view", error="view_literate_tail")
    assert html.read_bytes() == previous_html
    view.write_text(original_view)
    view.write_text(original_view.replace("#315B47", "badcolor"))
    s.call("render-view", error="view_color_hex_required")
    assert html.read_bytes() == previous_html
    assert s.call("read-page", id="concepts/共享")["text"]
    view.write_text(original_view)
    view.write_text(original_view.replace('"MemoryCorridor"', '"测试阅读室"').replace('["catalog","page","sources"]', '["page","catalog","sources"]'))
    s.call("render-view")
    changed_html = html.read_text()
    assert "<title>测试阅读室</title>" in changed_html
    assert changed_html.index("<main") < changed_html.index("<nav")
    dynamic_view = original_view.replace('["catalog","page","sources"]', '["catalog","page","graph","insights","sources"]')
    view.write_text(dynamic_view)
    s.call("render-view")
    dynamic_html = html.read_text()
    assert "GRAPH / 知识关系" in dynamic_html and "INSIGHTS / 快照洞察" in dynamic_html
    view.write_text(original_view + "\n\n这是可编辑的文学化说明，不参与视觉 IR。\n")
    s.call("render-view")
    view.write_text(original_view)
    s.call("render-view")
    check("actual literate visual compile, dynamic data panels and isolated failed view preserving last rendered snapshot")

    watcher = subprocess.run(["python3", str(REPO / "scripts/watch.py"), str(root), "--once"], capture_output=True, text=True, timeout=30)
    assert watcher.returncode == 0, watcher.stderr + watcher.stdout
    assert json.loads(watcher.stdout)["ok"]
    previous_html = html.read_bytes()
    view.write_text(original_view.replace("#315B47", "badcolor"))
    failed_watcher = subprocess.run(["python3", str(REPO / "scripts/watch.py"), str(root), "--once"], capture_output=True, text=True, timeout=30)
    assert failed_watcher.returncode != 0, failed_watcher.stdout
    failed_value = json.loads(failed_watcher.stdout)
    assert not failed_value["ok"]
    assert not failed_value["result"]["visual"]["ok"]
    assert html.read_bytes() == previous_html
    view.write_text(original_view)
    check("watcher propagates visual compile failures and preserves the last HTML")
    custom_view = root / "views/custom.mbt.md"
    custom_view.write_text(original_view.replace('"MemoryCorridor"', '"自定义阅读室"'))
    custom_watcher = subprocess.run(
        ["python3", str(REPO / "scripts/watch.py"), str(root), "--view", "views/custom.mbt.md", "--once"],
        capture_output=True, text=True, timeout=30,
    )
    assert custom_watcher.returncode == 0, custom_watcher.stderr + custom_watcher.stdout
    assert json.loads(custom_watcher.stdout)["ok"]
    assert "<title>自定义阅读室</title>" in html.read_text()
    custom_view.unlink()
    s.call("render-view")
    check("watcher explicitly compiles a selected custom mbt.md view")
    # A persistent watcher observes a real external content edit.
    watch = subprocess.Popen(["python3", str(REPO / "scripts/watch.py"), str(root), "--interval", "0.1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([watch.stdout], [], [], 30)[0]
        assert json.loads(watch.stdout.readline())["ok"]
        page.write_text(page.read_text() + "\n实时刷新标记。\n")
        assert select.select([watch.stdout], [], [], 30)[0]
        assert json.loads(watch.stdout.readline())["ok"]
        assert s.call("search", query="实时刷新标记")["hits"]
    finally:
        watch.terminate()
        watch.communicate(timeout=10)
    check("one-shot and persistent file watcher adopt actual external edits")
    archived = s.call("backfill", title="查询研究记录", text="检索结论需要进一步核对。")
    backfill_order = archived["scan"]["orders"][0]
    assert s.call("backfill", title="查询研究记录", text="检索结论需要进一步核对。")["scan"]["orders"] == []
    s.call("context", order=backfill_order)
    analysis = {"entities": [], "concepts": [], "conflicts": ["结论与既有资料存在矛盾"], "summary": "需要人工复核"}
    s.call("analysis-submit", order=backfill_order, analysis=analysis)
    # Purpose is authoritative, and a changed goal must invalidate old analysis.
    purpose = root / "purpose.md"
    purpose.write_text(purpose.read_text() + "\n新的研究目标。\n")
    s.call("refresh")
    s.call("commit", order=backfill_order, pages=[], at="2026-10-16", error="purpose_conflict")
    context = s.call("context", order=backfill_order)
    assert context["order"]["phase"] == "context-ready" and context["order"]["analysis"] is None
    s.call("analysis-submit", order=backfill_order, analysis=analysis)
    commit(s, backfill_order, [])
    reviews = s.call("review-list")
    assert len(reviews) == 1 and reviews[0]["status"] == "pending"
    decision = {"id": reviews[0]["id"], "action": "research", "note": "补充证据后由宿主继续", "at": "2026-10-16"}
    s.call("review-resolve", **decision)
    assert s.call("review-resolve", **decision)["replayed"]
    s.call("review-resolve", **{**decision, "action": "skip"}, error="review_already_resolved")
    review_event = s.call("read-log")
    assert any(event.get("op") == "review-resolve" and event.get("review") == decision["id"] for event in review_event)
    bounded_log = s.call("read-log", limit=1)
    assert len(bounded_log) == 1 and bounded_log[0].get("op") == "review-resolve"
    shutil.rmtree(root / ".corridor")
    s.call("rebuild")
    assert s.call("review-list")[0]["status"] == "resolved"
    assert s.call("stats")["pending_reviews"] == 0
    assert s.call("stats")["review_debt"] == {"pending": 0, "resolved": 1, "total": 1}
    assert s.call("fingerprints")["vault"] == s.call("status")["fingerprint"]
    review_path = root / "state/reviews" / f"{decision['id']}.json"
    review_bytes = review_path.read_bytes()
    review = json.loads(review_bytes)
    del review["decision"]["key"]
    review_path.write_text(json.dumps(review, ensure_ascii=False, separators=(",", ":")))
    s.call("status", error="content_changed")
    review_path.write_bytes(review_bytes)
    s.call("status")
    assert s.call("read-log")
    check("explicit backfill, purpose version conflict, persistent review and idempotent human decision")
    catalog = root / "index.mbt.md"
    last = catalog.read_text()
    catalog.write_text(last.replace("    entry(", "    invalid(),\n    entry(", 1))
    fallback = s.call("read-last-valid")
    assert fallback["read_only"] and fallback["pages"]
    s.call("search", query="共享", error="catalog_non_")
    target = root / "wiki/concepts/共享.md"
    before = target.read_text()
    target.write_text(before + "\n未登记的修改")
    s.call("read-last-valid", error="content_changed")
    target.write_text(before)
    catalog.write_text(last)
    s.call("verify")
    check("invalid declaration keeps explicit read-only fallback, which still rejects content drift")
    # Every dictionary entry shares the unknown-field guard, before mutation.
    fingerprint = s.call("status")["fingerprint"]
    for tool in s.call("list-tools"):
        s.call(tool["name"], __unknown=True, error="unknown_field")
    assert s.call("status")["fingerprint"] == fingerprint
    check("all advertised CLI operations reject unknown fields before changing state")
    s.close()

print(json.dumps({"passed": len(CHECKS), "checks": CHECKS}, ensure_ascii=False, indent=2))
