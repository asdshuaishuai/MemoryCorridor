#!/usr/bin/env python3
"""Discover which record-validation branches are reachable through `lint`.

For every state record kind, tamper each field with a value of the wrong shape
and record what `lint` reports. A branch that never appears is either shadowed by
an earlier check in the same validator or unreachable by construction; both are
worth knowing before writing assertions that claim to cover it.
"""
import json
import re
from pathlib import Path
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


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


BAD_STRINGS = ["", "x" * 300, "a\nb", "bogus", "not-a-hash", "0" * 63,
               "0" * 65, "2026-11-14T10:00:00Z", "0" * 64, "f" * 64,
               "-1", "1.5", "true", "null", "[]", "{}", "../escape",
               "/absolute", "concepts/../x", "wiki/index.md", "raw/",
               "state/memory/x.json", "a" * 513]
BAD_ARRAYS = [[], ["x"] * 20, ["a\nb"], ["not-a-hash"], [""], ["0" * 64],
              ["a", "b"], [None], [1], [{}], ["../escape"]]
BAD_VALUES = [0, 2, -1, True, False, None, {}, [], 1.5, 999999999999,
              {"id": "x"}, {"id": "x", "dimensions": 0}]

def nested_targets(value, prefix=""):
    """Yield (dotted path, current value) for every nested field."""
    if isinstance(value, dict):
        for key, item in value.items():
            path = prefix + "." + key if prefix else key
            yield path, item
            for nested in nested_targets(item, path):
                yield nested
    elif isinstance(value, list):
        for index, item in enumerate(value):
            path = "%s[%d]" % (prefix, index)
            yield path, item
            for nested in nested_targets(item, path):
                yield nested


def dig(container, dotted):
    """Return the parent container and final key for a dotted path.

    Array steps arrive as `name[0]`, so an index has to be split off before it
    is used as a key.
    """
    parts = dotted.split(".")
    current = container
    for part in parts[:-1]:
        match = re.match(r"^(.*)\[(\d+)\]$", part)
        if match:
            current = current[match.group(1)][int(match.group(2))]
        else:
            current = current[part]
    last = parts[-1]
    match = re.match(r"^(.*)\[(\d+)\]$", last)
    if match:
        return current[match.group(1)], int(match.group(2))
    return current, last


# State combinations are deliberately not enumerated here. A branch guarded
# by `status` needs the status changed first, which multiplies the work by the
# number of states; with twelve candidate states the probe stopped finishing
# (timeout). `scripts/record_validation_e2e.py` covers those cases by hand for
# the records that need them (research, suggestion, provider-job), which is
# the practical trade-off.


def probe(root, path, label):
    target = root / path
    original = target.read_text(encoding="utf-8")
    parsed = json.loads(original)
    found = {}
    targets = [(f, v) for f, v in parsed.items() if f != "op"]
    targets += [(d, v) for d, v in nested_targets(parsed)
                if "." in d or "[" in d]
    for field, value in targets:
        candidates = []
        if isinstance(value, str):
            candidates = BAD_STRINGS
        elif isinstance(value, list):
            candidates = BAD_ARRAYS
        else:
            candidates = BAD_VALUES + BAD_STRINGS
        for bad in candidates:
            tampered = json.loads(original)
            parent, key = dig(tampered, field)
            parent[key] = bad
            target.write_text(json.dumps(tampered, ensure_ascii=False), encoding="utf-8")
            got = details(root)
            if got:
                found.setdefault(field, set()).update(got)
            target.write_text(original, encoding="utf-8")
    print("== %s (%s)" % (label, path.split("/")[-2]))
    for field in sorted(found):
        print("   %-18s %s" % (field, sorted(found[field])))
    return found


with tempfile.TemporaryDirectory(prefix="memorycorridor-probe-") as temp:
    root = Path(temp)
    call(root, "init", purpose="分支可达性")
    publish(root, "ceramics.md", "器形与釉色。", "concepts/ceramics", "陶瓷")
    note = call(root, "memory-submit", kind="fact", scope="workspace",
                text="官窑记录可据此核对釉色与器形，长度足够通过相似度门槛。",
                conditions=["核对时"], sources=["raw/ceramics.md"],
                at="2026-11-14T09:30:00Z", key="note")["id"]
    topic = call(root, "research-topic", topic="陶瓷釉色", queries=["釉色 对照"],
                 at="2026-11-14T09:45:00Z", key="topic")["id"]
    goal = call(root, "purpose-suggest", at="2026-11-14T10:00:00Z", key="goal")["id"]
    overview = call(root, "overview-suggest", at="2026-11-14T10:15:00Z", key="ov")["id"]
    registration = call(root, "provider-register", provider="本地后端",
                        kind="embedding", space={"id": "vec", "dimensions": 8},
                        capabilities=["embed"], at="2026-11-14T10:30:00Z")
    (root / "raw/fresh.md").write_text("新来源。\n")
    order = call(root, "scan")["orders"]
    publish(root, "later.md", "更晚的材料。", "concepts/later", "更晚")
    call(root, "impact-audit", at="2026-11-14T11:00:00Z")
    impact_id = call(root, "impact-list")["impacts"][0]["id"]
    call(root, "quality-audit", at="2026-11-14T11:30:00Z")
    review_id = call(root, "review-list")[0]["id"]
    page = call(root, "read-page", id="concepts/ceramics")
    body = page["text"].split("---\n", 2)[-1]
    quote = "器形与釉色"
    start = len(body.encode().split(quote.encode(), 1)[0])
    evidence = call(root, "evidence-submit", page="concepts/ceramics",
                    page_hash=page["entry"]["sha256"],
                    items=[{"source": "raw/ceramics.md", "body_start": start,
                            "body_end": start + len(quote.encode()), "quote": quote,
                            "source_start": 0,
                            "source_end": len("器形与釉色。".encode()),
                            "source_quote": "器形与釉色。"}])["id"]
    plan = call(root, "embedding-plan", space={"id": "vec", "dimensions": 8},
                provider=registration["provider"], limit=1)
    job = call(root, "provider-job-open", provider=registration["provider"],
               kind="embedding", space={"id": "vec", "dimensions": 8},
               request={"items": plan["items"], "text_recipe": plan["text_recipe"]},
               at="2026-11-14T12:00:00Z", key="job")["id"]
    probe(root, f"state/memory/{note}.json", "memory")
    probe(root, f"state/research/{topic}.json", "research")
    probe(root, f"state/suggestions/{goal}.json", "suggestion")
    probe(root, f"state/overview/{overview}.json", "overview")
    probe(root, registration["path"], "provider")
    probe(root, f"state/orders/{order[0]}.json", "order")
    probe(root, f"state/impacts/{impact_id}.json", "impact")
    probe(root, f"state/reviews/{review_id}.json", "review")
    probe(root, f"state/evidence/{evidence}.json", "evidence")
    probe(root, f"state/provider-jobs/{job}.json", "provider-job")
