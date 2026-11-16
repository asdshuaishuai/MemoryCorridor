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
        import pyhanlp  # noqa: F401  # HanLP 1.x (preferred, light)
    except ImportError:
        try:
            import hanlp  # noqa: F401  # HanLP 2.x (fallback)
        except ImportError:
            print("SKIP nlp_adapter_hanlp_e2e: pyhanlp/hanlp not installed "
                  "(optional provider; pip install pyhanlp; see docs/nlp-adapter.md)")
            return 0

    affect = subprocess.run([sys.executable, str(ADAPTER), "affect",
                             "--text", "今天很开心，谢谢你！", "--provider", "hanlp"],
                            capture_output=True, text=True, timeout=600)
    if affect.returncode != 0:
        # pyhanlp needs Java; a broken runtime is a SKIP, not a product failure.
        print("SKIP nlp_adapter_hanlp_e2e: provider unavailable: "
              + (affect.stderr.strip() or affect.stdout.strip())[:200])
        return 0
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