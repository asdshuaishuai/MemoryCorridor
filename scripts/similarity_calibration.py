#!/usr/bin/env python3
"""Calibration for index/context.mbt similar-dedup gates.

Mirrors the MoonBit tokenizer. The shipped rule for near-duplicate paragraphs
in "similar" dedup mode:

  merge  <=> both sides >= GATE bytes
          AND token sequences are identical (the tokenizer already folds case
              and drops whitespace/punctuation, so only formatting-level
              differences qualify)

Token sequence identity makes reordering, swapped words, changed digits and
changed CJK characters unmergeable, while wrapped / re-punctuated / re-cased
copies of the same text merge. Paragraphs below the gate never merge: short
text carries too little signal, and identical short paragraphs are already
covered by exact dedup.
"""
import sys

GATE = 64


def tokens(text):
    out = []
    word = ""
    previous = ""
    for c in text.lower():
        code = ord(c)
        if (0x3400 <= code <= 0x9FFF) or (0xF900 <= code <= 0xFAFF) or (0x20000 <= code <= 0x323AF) or \
           (0x3040 <= code <= 0x309F) or (0x30A0 <= code <= 0x30FF) or (0x31F0 <= code <= 0x31FF) or \
           (0xFF66 <= code <= 0xFF9D) or (0xAC00 <= code <= 0xD7A3):
            if word:
                out.append(word)
                word = ""
            current = c
            out.append(current)
            if previous:
                out.append(previous + current)
            previous = current
        else:
            previous = ""
            letter = (0x00C0 <= code <= 0x02AF and code not in (0x00D7, 0x00F7)) or \
                     (0x0370 <= code <= 0x052F)
            if code < 128 and c.isalnum():
                word += c
            elif letter:
                word += c
            elif word:
                out.append(word)
                word = ""
    if word:
        out.append(word)
    return out


def dice(a, b):
    ta, tb = tokens(a), tokens(b)
    if not ta or not tb:
        return 0.0
    from collections import Counter
    ca, cb = Counter(ta), Counter(tb)
    inter = sum((ca & cb).values())
    return 2.0 * inter / (len(ta) + len(tb))


def byte_len(s):
    return len(s.encode())


def merges(a, b):
    if byte_len(a) < GATE or byte_len(b) < GATE:
        return False
    return tokens(a) == tokens(b)


MUST_MERGE = {
    "exact copy": ("the quick brown fox jumps over the lazy dog and rests near the river tonight",
                   "the quick brown fox jumps over the lazy dog and rests near the river tonight"),
    "whitespace run": ("shared paragraph for testing purposes here with enough words to pass the gate",
                       "shared  paragraph  for testing purposes here with enough words to pass the gate"),
    "newline rewrap": ("实验组在第三天显示出标记物的显著上升，对照组保持基线，结论需要复核。",
                       "实验组在第三天显示出标记物的显著上升，\n对照组保持基线，结论需要复核。"),
    "case only": ("Shared Paragraph For Testing With Enough Words To Pass The Gate And Merge.",
                  "shared paragraph for testing with enough words to pass the gate and merge."),
    "trailing punctuation": ("the quick brown fox jumps over the lazy dog near the river bank tonight",
                             "the quick brown fox jumps over the lazy dog near the river bank tonight."),
    "chinese punctuation": ("该药物在三期实验中有效率为百分之六十二，副作用发生率为百分之五，需要复核。",
                            "该药物在三期实验中有效率为百分之六十二，副作用发生率为百分之五，需要复核。"),
    "list punctuation": ("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda river shore",
                         "alpha, beta, gamma, delta, epsilon, zeta, eta, theta, iota, kappa, lambda, river, shore"),
    "markdown markers": ("- alpha evidence line with enough words to pass the gate for merging purposes",
                         "* alpha evidence line with enough words to pass the gate for merging purposes"),
    "full width digits": ("该药物在三期实验中有效率为百分之六十二，副作用发生率为百分之五，需要复核。",
                          "该药物在三期实验中有效率为百分之六十二，副作用发生率为百分之五， 需要复核。"),
}

MUST_NOT_MERGE = {
    "needle bodies": ("needle alpha " * 200, "needle beta " * 200),
    "evidence A/B": ("Needle alpha evidence A.", "Needle beta evidence B."),
    "one-char evidence": ("根据资料，实验组在第三天显示出标记物的显著上升，对照组保持基线，需要复核。",
                          "根据资料，实验组在第三天显示出标记物的显著下降，对照组保持基线，需要复核。"),
    "one-digit evidence": ("该药物在 3 期实验中有效率为 62%，副作用发生率为 5%，覆盖多中心样本。",
                           "该药物在 3 期实验中有效率为 63%，副作用发生率为 5%，覆盖多中心样本。"),
    "chinese near": ("关键证据𠀀abc" * 20, "关键证据😀 xyz " * 30),
    "extra clause": ("the quick brown fox jumps over the lazy dog near the river bank tonight",
                     "the quick brown fox jumps over the lazy dog near the river bank tonight and swims"),
    "short formatting pair": ("shared paragraph for testing.", "shared  paragraph for testing."),
    "word reorder": ("the quick brown fox jumps over the lazy dog near the river bank tonight",
                     "the lazy dog near the river bank tonight the quick brown fox jumps over"),
}

failures = []
print(f"=== MUST MERGE (token sequence equal, gate {GATE} bytes) ===")
for name, (a, b) in MUST_MERGE.items():
    ok = merges(a, b)
    print(f"  {'ok ' if ok else 'FAIL'} {name:24s} dice={dice(a,b):.4f} bytes={byte_len(a)}/{byte_len(b)}")
    if not ok:
        failures.append(name)

print("=== MUST NOT MERGE ===")
for name, (a, b) in MUST_NOT_MERGE.items():
    ok = not merges(a, b)
    print(f"  {'ok ' if ok else 'FAIL'} {name:24s} dice={dice(a,b):.4f} bytes={byte_len(a)}/{byte_len(b)}")
    if not ok:
        failures.append(name)

if failures:
    print("FAILED:", ", ".join(failures))
    sys.exit(1)
print(f"calibration passed: token-sequence identity, gate {GATE} bytes")
