#!/usr/bin/env python3
"""Probe which event-layer validation branches are reachable.

Event files are content-addressed, so tampering a field that feeds the filename
hash changes the identity and the engine reports an identity mismatch instead of
the shape branch. This probe tampers every field of every event kind and records
what `lint` says, so the reachable branches can be told apart from the shadowed
ones before any assertion claims to cover them.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"

BAD_STRINGS = ["", "x" * 300, "a\nb", "bogus", "not-a-hash", "0" * 63, "0" * 65,
               "2026-11-14T10:00:00Z"]
BAD_ARRAYS = [[], ["x"] * 40, ["a\nb"], ["not-a-hash"], [""]]
BAD_VALUES = [0, 2, -1, True, None, {}, []]


def call(root, op, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields},
                                     ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    assert value["ok"], value
    return value["result"]


def details(root):
    return [row["detail"] for row in call(root, "lint")["violations"]
            if row["predicate"] == "record_invalid"]


def publish(root, name, body, page_id, title):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order,
         context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [],
                   "summary": title})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}")
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T09:00:00Z")


with tempfile.TemporaryDirectory(prefix="memorycorridor-eventprobe-") as temp:
    root = Path(temp)
    call(root, "init", purpose="事件层可达性")
    publish(root, "ceramics.md", "器形与釉色。", "concepts/ceramics", "陶瓷")
    call(root, "memory-submit", kind="fact", scope="workspace",
         text="官窑记录可据此核对釉色与器形，长度足够通过相似度门槛。",
         conditions=["核对时"], sources=["raw/ceramics.md"],
         at="2026-11-14T09:30:00Z", key="note")
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
         at="2026-11-14T09:45:00Z", key="topic")
    call(root, "purpose-suggest", at="2026-11-14T10:00:00Z", key="goal")
    call(root, "overview-suggest", at="2026-11-14T10:15:00Z", key="ov")
    registration = call(root, "provider-register", provider="本地后端",
                        kind="embedding", space={"id": "vec", "dimensions": 8},
                        capabilities=["embed"], at="2026-11-14T10:30:00Z")
    publish(root, "later.md", "更晚的材料。", "concepts/later", "更晚")
    call(root, "impact-audit", at="2026-11-14T11:00:00Z")
    call(root, "quality-audit", at="2026-11-14T11:30:00Z")
    call(root, "review-resolve", id=call(root, "review-list")[0]["id"],
         action="skip", note="n", at="2026-11-14T11:45:00Z")

    events = sorted((root / "state/events").glob("*.json"))
    print("event files:", len(events))
    seen = {}
    for path in events:
        original = path.read_text(encoding="utf-8")
        parsed = json.loads(original)
        op = parsed.get("op", "?")
        for field, value in list(parsed.items()):
            if field == "op":
                continue
            candidates = BAD_STRINGS if isinstance(value, str) else (
                BAD_ARRAYS if isinstance(value, list) else BAD_VALUES + BAD_STRINGS)
            for bad in candidates:
                tampered = dict(parsed)
                tampered[field] = bad
                path.write_text(json.dumps(tampered, ensure_ascii=False),
                                encoding="utf-8")
                got = details(root)
                if got:
                    seen.setdefault((op, field), set()).update(got)
                path.write_text(original, encoding="utf-8")
    for (op, field) in sorted(seen):
        print("  %-18s %-16s %s" % (op, field, sorted(seen[(op, field)])))
    print("distinct (op, field) pairs that reach a branch:", len(seen))
    branches = set()
    for values in seen.values():
        branches |= values
    print("distinct branches reached:", len(branches))
