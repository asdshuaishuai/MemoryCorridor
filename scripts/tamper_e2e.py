#!/usr/bin/env python3
"""Every read op must refuse externally edited state.

`@vault.verify` hashes every catalog entry, so tampering with any state file must
break every verifying op -- not just the four that happened to have a probe. The
`_unchecked` row helpers trust their caller, and this is what keeps that trust
honest across the whole read surface.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"

# Raw byte readers are deliberately exempt: they exist so a host can inspect a
# damaged vault, the same reason `lint` is allowed to run on one. Everything
# else is a derived read and must refuse state that no longer matches the
# catalog. `list-pages` was exempt until this probe was written, which made it
# report success while `status` on the same vault refused.
RAW_READERS = {"read-index", "read-purpose"}

# Read ops reached directly from dispatch, plus the parameterised readers.
READ_OPS = [
    ("status", {}),
    ("stats", {}),
    ("fingerprints", {}),
    ("list-pages", {}),
    ("read-index", {}),
    ("read-purpose", {}),
    ("topics", {}),
    ("tree", {}),
    ("insights", {}),
    ("research-list", {}),
    ("suggestion-list", {}),
    ("overview-list", {}),
    ("memory-list", {}),
    ("memory-conflicts", {}),
    ("impact-list", {}),
    ("inbox", {}),
    ("review-list", {}),
    ("provider-list", {}),
    ("provider-job-list", {}),
]


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def publish(root, name, title, page_id, body):
    (root / "raw" / name).write_text(body)
    order = call(root, "scan")["orders"][0]
    context = call(root, "context", order=order)
    call(root, "analysis-submit", order=order, context_token=context["context_token"],
         analysis={"entities": [], "concepts": [title], "conflicts": [], "summary": title})
    staging = root / "staging" / order
    staging.mkdir(parents=True, exist_ok=True)
    (staging / "page.md").write_text(
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}"
    )
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T09:00:00Z")


with tempfile.TemporaryDirectory(prefix="memorycorridor-tamper-") as temp:
    root = Path(temp)
    call(root, "init", purpose="篡改探测")
    publish(root, "ceramics.md", "陶瓷", "concepts/ceramics", "器形与釉色。")
    call(root, "memory-submit", kind="fact", scope="workspace", text="可据此核对",
         conditions=["核对时"], sources=["raw/ceramics.md"],
         at="2026-11-14T09:30:00Z", key="note")
    call(root, "research-topic", topic="陶瓷釉色", queries=["釉色"],
         at="2026-11-14T09:45:00Z", key="topic")
    call(root, "impact-audit", at="2026-11-14T10:00:00Z")
    # Parameterised readers that need an id or a query.
    note_id = call(root, "memory-list")["notes"][0]["id"]
    topic_id = call(root, "research-list")[0]["id"]
    READ_OPS += [("memory-read", {"id": note_id}),
                 ("page-history", {"id": "concepts/ceramics"})]

    # Baseline: every read op succeeds on an untouched vault.
    for op, fields in READ_OPS:
        call(root, op, **fields)

    # Tamper with one state record. Every verifying read must refuse it.
    note_path = root / "state/memory" / (note_id + ".json")
    tampered = json.loads(note_path.read_text(encoding="utf-8"))
    tampered["text"] = "被外部编辑过的正文"
    note_path.write_text(json.dumps(tampered, ensure_ascii=False), encoding="utf-8")

    refused, leaked = [], []
    for op, fields in READ_OPS:
        value = json.loads(subprocess.run(
            [str(EXE)],
            input=json.dumps({"op": op, "vault": str(root), **fields}) + "\n",
            capture_output=True, text=True, check=True, timeout=60).stdout)
        if value["ok"]:
            (refused if op in RAW_READERS else leaked).append(op)
        elif "content_changed" in value["error"]:
            refused.append(op)
        else:
            leaked.append("%s (%s)" % (op, value["error"][:40]))
    derived = [op for op, _ in READ_OPS if op not in RAW_READERS]
    print("  refused: %d/%d derived reads" % (len(refused) - len(RAW_READERS), len(derived)))
    assert not leaked, "these read ops served tampered state: %s" % leaked
    # The raw readers must still work, or a damaged vault could not be inspected.
    for op in sorted(RAW_READERS):
        raw = json.loads(subprocess.run(
            [str(EXE)], input=json.dumps({"op": op, "vault": str(root)}) + "\n",
            capture_output=True, text=True, check=True, timeout=60).stdout)
        print("   raw reader %s ok=%s %s" % (op, raw["ok"], raw.get("error", "")[:40]))

    # `lint` is the diagnostic path: it reports instead of refusing.
    assert call(root, "lint")["errors"] >= 1
    # The vault is deliberately left damaged: `rebuild` correctly refuses it too,
    # because the catalog still records the pre-edit hash of the state record.
    print("tamper probe: every derived read refuses externally edited state")
