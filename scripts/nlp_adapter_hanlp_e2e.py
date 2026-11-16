#!/usr/bin/env python3
"""Optional HanLP provider end-to-end (续四十六).

HanLP is an OPTIONAL provider of the host-side NLP adapter, never a bundled
dependency and never used by the MoonBit core. This e2e SKIPs cleanly when the
`hanlp` package is not installed; when it is present it downloads the small
default token model on first use and proves the provider contract for affect
and expand. Model licenses must be checked by the operator before enabling
(see docs/nlp-adapter.md).
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / "scripts/nlp_adapter.py"


def main():
    try:
        import hanlp  # noqa: F401
    except ImportError:
        print("SKIP nlp_adapter_hanlp_e2e: hanlp not installed "
              "(optional provider; pip install hanlp; see docs/nlp-adapter.md)")
        return 0

    affect = subprocess.run([sys.executable, str(ADAPTER), "affect",
                             "--text", "今天很开心，谢谢你！", "--provider", "hanlp"],
                            capture_output=True, text=True, timeout=600)
    assert affect.returncode == 0, (affect.stdout, affect.stderr)
    row = json.loads(affect.stdout)
    assert row["provider"] == "hanlp" and row["valence"] > 0.0, row
    assert 0.0 <= row["arousal"] <= 1.0 and 0.0 <= row["salience"] <= 1.0, row
    assert len(row["text_sha256"]) == 64, row

    expanded = subprocess.run([sys.executable, str(ADAPTER), "expand",
                               "--query", "青瓷的来源", "--provider", "hanlp"],
                              capture_output=True, text=True, timeout=600)
    assert expanded.returncode == 0, (expanded.stdout, expanded.stderr)
    queries = json.loads(expanded.stdout)
    assert queries["provider"] == "hanlp", queries
    assert queries["queries"][0] == "青瓷的来源", queries
    assert 1 <= len(queries["queries"]) <= 8, queries

    print("nlp adapter hanlp e2e: provider contract for affect/expand passed "
          "(optional; model licenses are the operator's responsibility)")
    return 0


if __name__ == "__main__":
    sys.exit(main())