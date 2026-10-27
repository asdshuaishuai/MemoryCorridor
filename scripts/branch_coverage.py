#!/usr/bin/env python3
"""Report which record/event validation branches no test references.

`core/records.mbt` carries ~190 `*_invalid` branches. They sat at 1/191 coverage
for most of this project's life because nothing counted them, and a branch no
test references fails silently: removing it leaves every suite green.

This is a report, not a gate. The exemption list it once carried drifted out of
contact with reality within one round, which is the same failure the tool exists
to prevent, so it now prints the facts and leaves the judgement to whoever runs
it. To act on a branch, either add a case to
`scripts/record_validation_e2e.py` or record in `specs/engine/tasks.md` why the
branch cannot be reached from outside the engine.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RECORDS = ROOT / "core/records.mbt"


def test_text():
    chunks = []
    for pattern in ("scripts/*.py", "scripts/*.mjs", "sdk/*.mjs",
                    "*_wbtest.mbt", "core/*_wbtest.mbt", "vault/*_wbtest.mbt",
                    "agent/*_wbtest.mbt"):
        for path in sorted(ROOT.glob(pattern)):
            chunks.append(path.read_text(encoding="utf-8", errors="replace"))
    return "\n".join(chunks)


def main():
    source = RECORDS.read_text(encoding="utf-8")
    branches = sorted(set(re.findall(r'@base\.fail\("([a-z_]+)', source)))
    text = test_text()
    covered = [b for b in branches if b in text]
    uncovered = [b for b in branches if b not in text]

    print("record/event validation branches in core/records.mbt: %d" % len(branches))
    print("  referenced by a test: %d" % len(covered))
    print("  not referenced:       %d" % len(uncovered))
    for branch in uncovered:
        print("    " + branch)
    print("Run scripts/branch_probe.py or scripts/event_branch_probe.py to find "
          "which of these a tamper can actually reach.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
