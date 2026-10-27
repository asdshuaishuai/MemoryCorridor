#!/usr/bin/env python3
"""Concurrent writers on one vault.

AGENTS.md requires interruption recovery, idempotent retry and external edit
conflict to be tested for real. The crashing-store unit tests cover
interruption mid-transaction; this covers N live processes racing on the same
vault, which is the path only an OS lock and the optimistic baseline checks
protect.

The CLI takes `flock(.corridor-lock, LOCK_EX|LOCK_NB)` per invocation, so a race
must be resolved by serialization or refusal -- never by a lost write.
"""
import json
from pathlib import Path
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
WRITERS = 6
REFUSALS = ("vault_locked", "catalog_conflict", "recovery_required",
            "write_conflict", "another_order_active")


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=120).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def stage(root, name):
    (root / "raw" / name).write_text("来源正文。陶瓷与釉色。\n")
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["陶瓷"], "conflicts": [], "summary": "陶瓷"})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: 陶瓷\nsources: [\"raw/{name}\"]\n---\n正文。\n"
    )
    return order, {"id": "concepts/ceramics", "path": "wiki/concepts/ceramics.md",
                   "staged": f"staging/{order}/page.md"}


def commit(root, order, page, at):
    value = json.loads(subprocess.run(
        [str(EXE)],
        input=json.dumps({"op": "commit", "vault": str(root), "order": order,
                          "pages": [page], "at": at}) + "\n",
        capture_output=True, text=True, check=True, timeout=120).stdout)
    return value["ok"], value.get("error", "")


with tempfile.TemporaryDirectory(prefix="memorycorridor-race-") as temp:
    root = Path(temp)
    call(root, "init", purpose="并发竞争")
    order, page = stage(root, "source.md")

    # A journal left behind by an interrupted writer blocks every other writer
    # until it is recovered, and the schema is validated rather than guessed.
    pending = root / "state/transactions/pending.json"
    pending.parent.mkdir(parents=True, exist_ok=True)
    pending.write_text(json.dumps({"version": 1, "old_index": "i", "new_index": "j",
                                   "changes": []}), encoding="utf-8")
    with ThreadPoolExecutor(max_workers=WRITERS) as pool:
        blocked = list(pool.map(lambda _: commit(root, order, page, "2026-11-14T09:00:00Z"),
                                range(WRITERS)))
    assert [ok for ok, _ in blocked] == [False] * WRITERS, blocked
    # A journal whose old_index disagrees with the live catalog is an external
    # edit conflict: it is refused and RETAINED, never silently applied or dropped.
    # Writers that never reached the journal are stopped by the lock instead.
    assert all(m.startswith(("recovery_conflict", "vault_locked")) for _, m in blocked), blocked
    assert any(m.startswith("recovery_conflict") for _, m in blocked), blocked
    assert pending.exists(), "the journal must be retained for a human to inspect"
    assert not (root / "wiki/concepts/ceramics.md").exists()
    # An unknown journal version is refused too.
    pending.write_text(json.dumps({"version": 2, "old_index": "i", "new_index": "j",
                                   "changes": []}), encoding="utf-8")
    assert call(root, "commit", order=order, pages=[page], at="2026-11-14T09:05:00Z",
                error="journal_version_unsupported")
    # A journal that matches the live catalog is not a block: `dispatch` rolls it
    # forward on every invocation, so the first writer to take the lock finishes
    # the interrupted transaction and then proceeds with its own.
    pending.write_text(json.dumps({"version": 1,
                                   "old_index": (root / "index.mbt.md").read_text(encoding="utf-8"),
                                   "new_index": "unused", "changes": []}),
                       encoding="utf-8")
    with ThreadPoolExecutor(max_workers=WRITERS) as pool:
        rolled = list(pool.map(lambda _: commit(root, order, page, "2026-11-14T09:06:00Z"),
                               range(WRITERS)))
    assert any(ok for ok, _ in rolled), rolled
    for ok, message in rolled:
        if not ok:
            assert message.startswith(("vault_locked", "catalog_conflict",
                                       "another_order_active")), message
    # Recovery consumed the journal rather than leaving it to block forever.
    assert not pending.exists(), "a matching journal must be rolled forward and cleared"

    # The real race: every writer holds the same pre-write catalog and the same
    # content-addressed write. The lock serializes them, so at most one lands
    # and the rest are refused by name or replayed idempotently.
    with ThreadPoolExecutor(max_workers=WRITERS) as pool:
        outcomes = list(pool.map(lambda _: commit(root, order, page, "2026-11-14T09:10:00Z"),
                                 range(WRITERS)))
    landed = sum(1 for ok, _ in outcomes if ok)
    print("  race: %d landed, %d refused (%s)" % (
        landed, WRITERS - landed, sorted({m for _, m in outcomes if m})))
    assert landed >= 1, outcomes
    for ok, message in outcomes:
        if not ok:
            assert message.startswith(REFUSALS), message

    # The vault is exactly as consistent as the winners made it.
    call(root, "rebuild")
    call(root, "verify")
    pages = [e["id"] for e in call(root, "list-pages")]
    assert "concepts/ceramics" in pages, pages
    assert len(pages) == len(set(pages)), "a race must not duplicate a page"
    assert sum(1 for p in pages if p == "concepts/ceramics") == 1
    body = (root / "wiki/concepts/ceramics.md").read_text(encoding="utf-8")
    assert body.startswith("---\n") and "sources:" in body
    # One page, one version: a race must not duplicate the record, even though
    # the earlier roll-forward section already published it. `commit` records the
    # page in the catalog's commit history rather than a separate event file.
    history = call(root, "page-history", id="concepts/ceramics")
    assert history["counts"]["versions"] == 1, history["counts"]
    assert [o["phase"] for o in call(root, "status")["orders"]] == ["committed"]

    # The lock is released, so the next single writer is not blocked by ghosts.
    (root / "raw/second.md").write_text("第二个来源。\n")
    order_two = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order_two)
    call(root, "analysis-submit", order=order_two,
         context_token=context["context_token"],
         analysis={"entities": [], "concepts": ["二"], "conflicts": [], "summary": "二"})
    staging = root / "staging" / order_two
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        "---\ntype: concept\ntitle: 二\nsources: [\"raw/second.md\"]\n---\n二。\n"
    )
    call(root, "commit", order=order_two,
         pages=[{"id": "concepts/two", "path": "wiki/concepts/two.md",
                 "staged": f"staging/{order_two}/page.md"}], at="2026-11-14T09:20:00Z")
    call(root, "rebuild")
    call(root, "verify")
    print("concurrent writers: lock, journal guard, race and release passed")
