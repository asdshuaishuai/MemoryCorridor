#!/usr/bin/env python3
"""Lint predicates reached by editing files the engine did not write.

`lint` is the one surface allowed to run on a damaged vault, and it reports each
problem with a named predicate. A predicate no test references fails silently:
removing it leaves every suite green, exactly like the `record_invalid` branches
were before `record_validation_e2e.py`.

This tampers with page frontmatter and raw sources -- the shapes a human editor
or an external tool actually produces -- and asserts the predicate that fires.
"""
import json
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "_build/native/debug/build/cli/cli.exe"


def call(root, op, error=None, **fields):
    value = json.loads(subprocess.run(
        [str(EXE)], input=json.dumps({"op": op, "vault": str(root), **fields},
                                     ensure_ascii=False) + "\n",
        capture_output=True, text=True, check=True, timeout=60).stdout)
    if error is None:
        assert value["ok"], value
        return value["result"]
    assert not value["ok"] and error in value["error"], value
    return value


def predicates(root):
    return {row["predicate"] for row in call(root, "lint")["violations"]}


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
        f"---\ntype: concept\ntitle: {title}\nsources: [\"raw/{name}\"]\n---\n{body}"
    )
    call(root, "commit", order=order,
         pages=[{"id": page_id, "path": f"wiki/{page_id}.md",
                 "staged": f"staging/{order}/page.md"}], at="2026-11-14T09:00:00Z")
    return root / "wiki" / f"{page_id}.md"


with tempfile.TemporaryDirectory(prefix="memorycorridor-lint-") as temp:
    root = Path(temp)
    call(root, "init", purpose="lint 谓词")
    page = publish(root, "ceramics.md", "器形与釉色。", "concepts/ceramics", "陶瓷")
    original = page.read_text(encoding="utf-8")
    call(root, "rebuild")

    checked = 0

    # Each case edits one thing and asserts the predicate that names it. The
    # catalog hash drift that accompanies every edit is not the point, so only
    # the specific predicate is asserted.
    cases = [
        ("a page whose kind is not one the engine knows",
         original.replace("type: concept", "type: bogus"), "page_metadata_drift"),
        ("a page whose frontmatter lost a required field",
         original.replace("title: 陶瓷\n", ""), "page_syntax"),
        ("a page that no longer cites its source",
         original.replace('sources: ["raw/ceramics.md"]', "sources: []"),
         "page_metadata_drift"),
    ]
    for label, text, expected in cases:
        page.write_text(text, encoding="utf-8")
        found = predicates(root)
        assert expected in found, (label, sorted(found))
        page.write_text(original, encoding="utf-8")
        checked += 1

    # A raw source that disappears is reported by name, not as a generic error.
    (root / "raw/ceramics.md").unlink()
    assert "source_hash_drift" in predicates(root), sorted(predicates(root))
    (root / "raw/ceramics.md").write_text("器形与釉色。", encoding="utf-8")
    checked += 1

    # Cross-record invariants: a supersede chain that points at a record which
    # does not exist, and two live notes claiming the same idempotency key. Both
    # need a second record, so they are constructed rather than tampered with in
    # isolation.
    first = call(root, "memory-submit", kind="fact", scope="workspace",
                 text="第一条判断，长度足够通过门槛。", conditions=["判断甲"],
                 sources=[], at="2026-11-14T10:00:00Z", key="chain-a")
    call(root, "memory-supersede", id=first["id"],
         text="第二条判断，长度足够通过门槛。", conditions=["判断甲"],
         sources=[], at="2026-11-14T10:10:00Z")
    first_path = root / "state/memory" / (first["id"] + ".json")
    original_first = first_path.read_text(encoding="utf-8")
    parsed = json.loads(original_first)
    parsed["supersedes"] = "f" * 64
    first_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "memory_supersede_origin_missing" in predicates(root), sorted(predicates(root))
    first_path.write_text(original_first, encoding="utf-8")
    checked += 1

    third = call(root, "memory-submit", kind="fact", scope="workspace",
                 text="第三条判断，长度足够通过门槛。", conditions=["判断乙"],
                 sources=[], at="2026-11-14T10:20:00Z", key="chain-c")
    third_path = root / "state/memory" / (third["id"] + ".json")
    original_third = third_path.read_text(encoding="utf-8")
    parsed = json.loads(original_third)
    parsed["key"] = "chain-a"
    third_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "memory_key_ambiguous" in predicates(root), sorted(predicates(root))
    third_path.write_text(original_third, encoding="utf-8")
    checked += 1

    # Evidence anchors are the "check the original text" path, so a rewritten
    # source has to invalidate them by name rather than silently passing.
    (root / "raw/anchor.md").write_text("器形与釉色。\n")
    publish(root, "anchor.md", "器形与釉色。", "concepts/anchor", "锚点")
    page = call(root, "read-page", id="concepts/anchor")
    page_body = page["text"].split("---\n", 2)[-1]
    quote = "器形与釉色"
    quote_start = len(page_body.encode().split(quote.encode(), 1)[0])
    call(root, "evidence-submit", page="concepts/anchor",
         page_hash=page["entry"]["sha256"],
         items=[{"source": "raw/anchor.md", "body_start": quote_start,
                 "body_end": quote_start + len(quote.encode()), "quote": quote,
                 "source_start": 0, "source_end": len("器形与釉色。".encode()),
                 "source_quote": "器形与釉色。"}])
    assert "evidence_source_anchor_invalid" not in predicates(root)
    (root / "raw/anchor.md").write_text("完全不同的内容。", encoding="utf-8")
    call(root, "scan")
    found = predicates(root)
    assert "evidence_source_anchor_invalid" in found, sorted(found)
    assert "evidence_page_stale" in found, sorted(found)
    # Restoring identical bytes does not un-invalidate the page -- revocation is
    # durable by design -- so the documented recovery is to republish it.
    publish(root, "anchor.md", "器形与釉色。", "concepts/anchor", "锚点")
    call(root, "rebuild")
    checked += 1

    # The same pair of faults on a raw source rather than a page: an unreadable
    # source is reported separately from a missing one, and pages citing it keep
    # their history while the source is marked stale.
    source_path = root / "raw" / "ceramics.md"
    original_mode = source_path.stat().st_mode
    source_path.chmod(0)
    assert "source_unreadable" in predicates(root), sorted(predicates(root))
    source_path.chmod(original_mode)
    checked += 1

    # A page body that is gone and one that cannot be read are different faults,
    # and both are reported by name. Restoring the permissions is not enough for
    # the engine to trust the file again, so the cache is rebuilt explicitly.
    body_path = root / "wiki" / "concepts" / "ceramics.md"
    original_mode = body_path.stat().st_mode
    body_path.chmod(0)
    found = predicates(root)
    assert "content_unreadable" in found, sorted(found)
    body_path.chmod(original_mode)
    checked += 1

    original_body = body_path.read_text(encoding="utf-8")
    body_path.unlink()
    assert "content_missing" in predicates(root), sorted(predicates(root))
    # Writing the exact bytes back satisfies the catalog hash again, so the vault
    # recovers without a republish -- a deleted body is not a revoked source.
    body_path.write_text(original_body, encoding="utf-8")
    checked += 1

    # The two remaining supersede-chain invariants. `target_missing` is a record
    # pointing at a replacement that does not exist; `link_asymmetric` is a real
    # chain whose back-pointer was redirected, so the two halves disagree.
    head = call(root, "memory-submit", kind="fact", scope="workspace",
                text="链首判断，长度足够通过门槛。", conditions=["链条"],
                sources=[], at="2026-11-14T12:00:00Z", key="link-head")
    tail = call(root, "memory-supersede", id=head["id"],
                text="链尾判断，长度足够通过门槛。", conditions=["链条"],
                sources=[], at="2026-11-14T12:10:00Z")
    head_path = root / "state/memory" / (head["id"] + ".json")
    tail_path = root / "state/memory" / (tail["id"] + ".json")
    original_head = head_path.read_text(encoding="utf-8")
    original_tail = tail_path.read_text(encoding="utf-8")

    parsed = json.loads(original_head)
    parsed["superseded_by"] = "e" * 64
    head_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "memory_supersede_target_missing" in predicates(root), sorted(predicates(root))
    head_path.write_text(original_head, encoding="utf-8")
    checked += 1

    parsed = json.loads(original_tail)
    parsed["supersedes"] = "e" * 64
    tail_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "memory_supersede_link_asymmetric" in predicates(root), sorted(predicates(root))
    tail_path.write_text(original_tail, encoding="utf-8")
    checked += 1

    # The catalog IR is read once here because the impact cases below also edit
    # it: an impact is only linted when its file is registered.
    index = root / "index.mbt.md"
    original_index = index.read_text(encoding="utf-8")
    index_lines = original_index.splitlines()

    # Impact records must point at a subject that exists and describe drift that
    # is still there. Both need an open impact, so material has to arrive after
    # the topic was frozen for one to exist at all.
    (root / "raw/early.md").write_text("早先的材料。\n")
    publish(root, "early.md", "早先的材料。", "concepts/early", "早先")
    call(root, "research-topic", topic="影响记录主体", queries=["影响"],
         at="2026-11-14T11:00:00Z", key="impact-topic")
    (root / "raw/late.md").write_text("后来的材料。\n")
    publish(root, "late.md", "后来的材料。", "concepts/late", "后来")
    call(root, "impact-audit", at="2026-11-14T11:30:00Z")
    records = call(root, "impact-list")["impacts"]
    assert records, "material after the freeze must open an impact"
    impact_path = root / "state/impacts" / (records[0]["id"] + ".json")
    original_impact = impact_path.read_text(encoding="utf-8")
    # The impact registered itself while the section ran, so the catalog is read
    # again before anything edits it.
    original_index = index.read_text(encoding="utf-8")
    index_lines = original_index.splitlines()

    parsed = json.loads(original_impact)
    parsed["subject"] = "state/research/" + "f" * 64 + ".json"
    impact_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "impact_subject_missing" in predicates(root), sorted(predicates(root))
    impact_path.write_text(original_impact, encoding="utf-8")
    checked += 1

    # The same impact identity recorded twice. An unregistered second file is a
    # different fault, so the twin is registered in the catalog as well, with the
    # block's count assertion moved to match.
    twin = impact_path.parent / ("twin-" + impact_path.name)
    twin.write_text(original_impact, encoding="utf-8")
    impact_line = next(i for i, l in enumerate(index_lines)
                       if impact_path.name in l and l.strip().startswith('entry("'))
    count_line = next(i for i, l in enumerate(index_lines)
                      if 'corridor_entries().length()' in l)
    saved_lines = list(index_lines)
    index_lines[count_line] = re.sub(
        r'\d+', str(int(re.search(r'\d+', index_lines[count_line]).group()) + 1),
        index_lines[count_line])
    index_lines.insert(impact_line + 1, index_lines[impact_line])
    index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    assert "impact_duplicate" in predicates(root), sorted(predicates(root))
    index_lines[:] = saved_lines
    index.write_text(original_index, encoding="utf-8")
    twin.unlink()
    checked += 1

    parsed = json.loads(original_impact)
    parsed["frozen"] = parsed["current"]
    impact_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    assert "impact_no_drift" in predicates(root), sorted(predicates(root))
    impact_path.write_text(original_impact, encoding="utf-8")
    checked += 1

    # Catalog IR entries: one field at a time, no duplicate needed. This is the
    # part of the surface that a hand-edited `index.mbt.md` reaches, and each
    # field has its own predicate, so they are pinned separately.
    index = root / "index.mbt.md"

    def retune(transform):
        target = next(i for i, l in enumerate(index_lines)
                      if l.strip().startswith('entry("') and '"concepts/ceramics"' in l)
        saved = index_lines[target]
        index_lines[target] = transform(index_lines[target])
        index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
        found = predicates(root)
        index_lines[target] = saved
        index.write_text(original_index, encoding="utf-8")
        return found

    def corrupt_hash(line):
        # The digest may not start with a zero, so it is located by shape.
        found = re.search(r'"([0-9a-f]{64})"', line)
        if found is None:
            return line
        digest = found.group(1)
        return line.replace('"' + digest + '"', '"z' + digest[1:] + '"', 1)

    assert "entry_kind_unsupported" in retune(
        lambda line: line.replace('"concept"', '"bogus"', 1)), "kind"
    assert "page_entry_invalid" in retune(
        lambda line: line.replace('"markdown"', '"bogus"', 1)), "format"
    assert "page_entry_invalid" in retune(
        lambda line: re.sub(r'"wiki/[^"]+"', '"nowhere/x.md"', line, count=1)), "path"
    assert "entry_hash_invalid" in retune(corrupt_hash), "hash"
    assert "entry_id_invalid" in retune(
        lambda line: line.replace('entry("concepts/', 'entry("../escape', 1)), "id"
    assert "entry_path_invalid" in retune(
        lambda line: re.sub(r'"wiki/[^"]+"', '"/absolute/x.md"', line, count=1)), "path shape"
    assert "entry_format_invalid" in retune(
        lambda line: re.sub(r'"markdown"', '""', line, count=1)), "empty format"
    assert "entry_format_invalid" in retune(
        lambda line: re.sub(r'"markdown"', '"' + 'a' * 65 + '"', line, count=1)), "long format"
    checked += 1

    # The purpose entry has its own shape check.
    purpose_line = next(i for i, l in enumerate(index_lines)
                        if l.strip().startswith('entry("') and '"purpose.md"' in l)
    saved_purpose = index_lines[purpose_line]
    index_lines[purpose_line] = index_lines[purpose_line].replace(
        '"markdown"', '"json"', 1)
    index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    assert "purpose_entry_invalid" in predicates(root), sorted(predicates(root))
    index_lines[purpose_line] = saved_purpose
    index.write_text(original_index, encoding="utf-8")
    checked += 1

    # A page citing a source the catalog does not describe, and a page whose
    # source list holds a path the engine refuses. The distinction matters: an
    # unregistered source is `page_source_missing`, while a malformed path never
    # reaches the lookup at all.
    raw_line = next(i for i, l in enumerate(index_lines)
                    if l.strip().startswith('entry("raw/'))
    saved_raw = index_lines[raw_line]
    index_lines[raw_line] = re.sub(r'entry\("raw/[^"]+", "raw/[^"]+"',
                                   'entry("nowhere/x.md", "nowhere/x.md"',
                                   index_lines[raw_line])
    index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    assert "page_source_missing" in predicates(root), sorted(predicates(root))
    index_lines[raw_line] = saved_raw
    index.write_text(original_index, encoding="utf-8")
    checked += 1

    assert "source_path_invalid" in retune(
        lambda line: re.sub(r'\["[^"]*"\]', '["../escape"]', line, count=1)), "source path"
    checked += 1

    # A block that is still a check block but no longer compiles is a different
    # fault from a fence that is not a check block at all.
    broken_block = original_index.splitlines()
    insert_at = next(i for i, l in enumerate(broken_block)
                     if l.strip().startswith('entry("'))
    broken_block.insert(insert_at, '  this is not valid moonbit syntax !!!')
    index.write_text("\n".join(broken_block) + "\n", encoding="utf-8")
    assert "catalog_compile" in predicates(root), sorted(predicates(root))
    index.write_text(original_index, encoding="utf-8")
    checked += 1

    # State entries have their own shape check: wrong format, or a source list
    # they must not carry. Both are one field away from a valid line.
    state_line = next(i for i, l in enumerate(index_lines)
                      if '"state/' in l and l.strip().startswith('entry("'))
    saved_state = index_lines[state_line]
    for label, edited in (
            ("format", index_lines[state_line].replace('"json"', '"markdown"', 1)),
            ("sources", re.sub(r'\[\]', '["raw/ceramics.md"]',
                              index_lines[state_line], count=1))):
        index_lines[state_line] = edited
        index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
        found = predicates(root)
        assert "state_entry_invalid" in found, (label, sorted(found))
        index_lines[state_line] = saved_state
        index.write_text(original_index, encoding="utf-8")
    checked += 1

    # A vector entry needs a vectors/ path, json format and no sources. The test
    # vault has none, so the kind is what is edited.
    saved_kind = index_lines[state_line]
    index_lines[state_line] = index_lines[state_line].replace(
        '"state"', '"vector"', 1)
    index.write_text("\n".join(index_lines) + "\n", encoding="utf-8")
    assert "vector_entry_invalid" in predicates(root), sorted(predicates(root))
    index_lines[state_line] = saved_kind
    index.write_text(original_index, encoding="utf-8")
    checked += 1

    # A duplicated entry. The block carries its own count assertion, so the count
    # has to move with the copy or the block fails to compile for the wrong
    # reason and reports a syntax fault instead of the repetition.
    insert_at = next(i for i, l in enumerate(index_lines)
                     if l.strip().startswith('entry("'))
    count_line = next(i for i, l in enumerate(index_lines)
                      if 'corridor_entries().length()' in l)
    duplicated = list(index_lines)
    duplicated[count_line] = re.sub(
        r'\d+', str(int(re.search(r'\d+', duplicated[count_line]).group()) + 1),
        duplicated[count_line])
    duplicated.insert(insert_at + 1, duplicated[insert_at])
    index.write_text("\n".join(duplicated) + "\n", encoding="utf-8")
    found = predicates(root)
    assert "duplicate_entry_id" in found, sorted(found)
    assert "duplicate_entry_path" in found, sorted(found)
    index.write_text(original_index, encoding="utf-8")
    checked += 1

    # A catalog whose literate fence is no longer a check block is a syntax
    # fault, reported by name rather than as a generic parse failure.
    index.write_text(original_index.replace("```mbt check", "```mbt"), encoding="utf-8")
    assert "catalog_syntax" in predicates(root), sorted(predicates(root))
    index.write_text(original_index, encoding="utf-8")
    checked += 1


    # Restoring the exact bytes clears every predicate again, so the tampering
    # probe leaves the vault healthy.
    call(root, "rebuild")
    assert predicates(root) == set(), sorted(predicates(root))
    call(root, "verify")
    print(f"lint predicates: {checked} reached by editing files and restored")
