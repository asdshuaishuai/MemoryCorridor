#!/usr/bin/env python3
"""Host-side NLP adapter end-to-end (续四十五).

NLP stays outside the MoonBit core: the adapter maps user text to structured
affect (and queries to expansions), and the daemon feeds the affect into
`evo-observe`. Tests pin the deterministic lexicon provider, bounded values,
query expansion, message-file cursor semantics and the no-knowledge-write rule.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"
ADAPTER = ROOT / "scripts/nlp_adapter.py"
DAEMON = ROOT / "scripts/evo_daemon.py"


def adapter(*args):
    run = subprocess.run([sys.executable, str(ADAPTER)] + list(args),
                         capture_output=True, text=True, timeout=60)
    return run


def main():
    # 1. deterministic affect: sign, bounds, determinism.
    positive = json.loads(adapter("affect", "--text", "今天很开心，谢谢你！").stdout)
    negative = json.loads(adapter("affect", "--text", "今天压力很大，很难过。").stdout)
    neutral = json.loads(adapter("affect", "--text", "今天读了一份资料。").stdout)
    assert positive["valence"] > 0.3, positive
    assert negative["valence"] < -0.3, negative
    assert -1.0 <= neutral["valence"] <= 1.0, neutral
    for row in (positive, negative, neutral):
        assert 0.0 <= row["arousal"] <= 1.0 and 0.0 <= row["salience"] <= 1.0, row
        assert len(row["text_sha256"]) == 64 and row["provider"] == "lexicon", row
    assert positive == json.loads(adapter("affect", "--text", "今天很开心，谢谢你！").stdout)

    # 2. query expansion keeps the original first and adds deterministic terms.
    expanded = json.loads(adapter("expand", "--query", "青瓷的来源").stdout)
    assert expanded["queries"][0] == "青瓷的来源", expanded
    assert any("出处" in query for query in expanded["queries"]), expanded
    assert 2 <= len(expanded["queries"]) <= 8, expanded
    assert len(expanded["query_sha256"]) == 64

    # 3. daemon integration: user messages -> evo observations, cursor-deduped.
    with tempfile.TemporaryDirectory(prefix="corridor-nlp-") as work:
        vault = Path(work)
        messages = vault / "messages.txt"

        def call(op, **fields):
            run = subprocess.run([str(EXE)],
                                 input=json.dumps(dict(fields, op=op, vault=str(vault))) + "\n",
                                 text=True, capture_output=True, check=True, timeout=120)
            response = json.loads(run.stdout)
            assert response["ok"], response
            return response["result"]

        def daemon():
            run = subprocess.run([sys.executable, str(DAEMON), "--vault", str(vault),
                                  "--cli", str(EXE), "--mock", "--once",
                                  "--driver", "nlp-a", "--message-file", str(messages),
                                  "--affect-provider", "lexicon",
                                  "--quiet-start", "0", "--quiet-end", "24",
                                  "--reflect-every", "0", "--consolidate-every", "0"],
                                 capture_output=True, text=True, timeout=120)
            assert run.returncode == 0, (run.stdout, run.stderr)
            return json.loads(run.stdout.strip().splitlines()[-1])

        call("init", purpose="NLP 感知端到端")
        call("evo-policy", enabled=True, at="2026-11-13T00:00:00Z")
        call("evo-init", seed=7, at="2026-11-13T00:00:01Z")
        before = call("status")

        messages.write_text("今天很开心，谢谢你！\n", encoding="utf-8")
        first = daemon()
        assert len(first["messages"]) == 1 and first["messages"][0]["valence"] > 0.3, first
        assert first["messages"][0]["provider"] == "lexicon", first
        assert call("evo-status")["window"]["steps"] >= 1

        second = daemon()
        assert second["messages"] == [], second

        with messages.open("a", encoding="utf-8") as handle:
            handle.write("今天压力很大，很难过。\n")
        third = daemon()
        assert len(third["messages"]) == 1 and third["messages"][0]["valence"] < -0.3, third

        after = call("status")
        assert after["pages"] == before["pages"] and after["sources"] == before["sources"], (before, after)

    print("nlp adapter e2e: lexicon affect bounds/determinism, query expansion, daemon "
          "message cursor, no knowledge writes passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())