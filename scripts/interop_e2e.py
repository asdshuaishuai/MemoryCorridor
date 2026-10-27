#!/usr/bin/env python3
"""Actual native import/export, preservation, conflicts and compiler-boundary tests."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / '_build/native/debug/build/cli/cli.exe'
CHECKS = []


def call(root, op, error=None, env=None, **fields):
    process = subprocess.run([str(EXE)], input=json.dumps({'op': op, 'vault': str(root), **fields})+'\n',
                             capture_output=True, text=True, check=True, timeout=30, env=env)
    value = json.loads(process.stdout)
    assert 'Panic' not in process.stderr and 'Warning:' not in process.stderr, process.stderr
    if error:
        assert not value['ok'] and error in value['error'], value
    else:
        assert value['ok'], value
    return value.get('result', value)


def write_files(directory, files):
    for path, data in files.items():
        target = directory / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)


def snapshot(directory):
    return {str(p.relative_to(directory)): p.read_bytes() for p in directory.rglob('*') if p.is_file()}


with tempfile.TemporaryDirectory(prefix='corridor-interop-') as work:
    work = Path(work)
    root = work / 'vault'
    root.mkdir()
    call(root, 'init')
    inputs = {
        'index.md': b'---\nokf_version: "0.2"\n---\n# Catalog\n',
        'log.md': b'reserved, no type required\n',
        'nested/index.md': b'# Reserved at every level\n',
        'nested/a.md': ('---\r\ntype: UnknownExtension\r\ntitle: Extended record\r\ncustom:\r\n  nested: [1, true, null]\r\n  details: |\r\n    preserve this\r\nverified: {by: "human:reviewer", at: "2026-10-01T00:00:00Z"}\r\ngenerated: {by: "upstream/1", at: "2026-10-01T00:00:00Z"}\r\nsources:\r\n  - resource: /assets/data.bin\r\n    title: Original\r\n---\r\n[B](../b.md) [Broken](/absent.md) [[missing]]\r\n').encode(),
        'b.md': b'---\ntype: Table\n---\n| x | y |\n|---|---|\n|1|2|\n',
        'assets/data.bin': b'\x00\xff\x80original',
        'references/script.py': b'raise RuntimeError("must never execute")\n',
    }
    write_files(root / 'imports/first', inputs)
    result = call(root, 'import', format='okf', directory='imports/first', at='2026-10-16')
    bundle = result['bundle']
    assert len(result['pages']) == 2 and len(result['broken']) == 2
    assert len(call(root, 'list-pages')) == 2
    assert len(call(root, 'review-list')) == 2
    assert call(root, 'plan') == []
    assert call(root, 'import', format='okf', directory='imports/first', at='2026-10-17')['replayed']
    assert len(call(root, 'read-log')) == 1
    call(root, 'rebuild')
    call(root, 'verify')
    assert call(root, 'search', query='Extended')['hits']
    call(root, 'export', format='okf', directory='exports/exact', bundle=bundle)
    assert snapshot(root / 'exports/exact') == inputs
    assert (root / 'exports/exact.receipt.json').exists()
    shutil.copytree(root / 'exports/exact', root / 'imports/again')
    assert call(root, 'import', format='okf', directory='imports/again', at='2026-10-17')['bundle'] == bundle
    CHECKS.append('OKF 0.2 unknown types/nested fields, reserved names, broken-link reviews, binary resources, byte-exact idempotent roundtrip')

    pid = next(row['id'] for row in result['pages'] if row['path'] == 'nested/a.md')
    page = root / ('wiki/'+pid+'.md')
    page.write_text(page.read_text()+'\nHuman edit: new content.\n')
    call(root, 'refresh')
    call(root, 'export', format='okf', directory='exports/edited', bundle=bundle)
    edited = (root / 'exports/edited/nested/a.md').read_text()
    assert 'Human edit: new content.' in edited and '[B](/b.md)' in edited
    assert 'custom:' in edited and 'preserve this' in edited
    assert not re.search(r'^(verified|generated):', edited, re.M)
    assert 'x_memorycorridor_original_verified:' in edited and 'human:reviewer' in edited
    assert (root / 'exports/edited/assets/data.bin').read_bytes() == inputs['assets/data.bin']
    assert (root / 'exports/edited/b.md').read_bytes() == inputs['b.md']
    CHECKS.append('edited body keeps unknown metadata/resources and moves old trust/producer claims into origin fields')

    projected = call(root, 'export', format='okf', directory='exports/all')
    documents = list((root / 'exports/all/pages').glob('*/page.md'))
    assert len(documents) == 2
    for doc in documents:
        text = doc.read_text()
        assert re.search(r'^sources:\n\s+-\s+(id|resource):', text, re.M) and 'resource: /references/' in text, text
        assert 'verified:' not in text
    assert 'okf_version:' in (root / 'exports/all/index.md').read_text()
    second = work / 'second'
    second.mkdir()
    call(second, 'init')
    shutil.copytree(root / 'exports/all', second / 'imports/projected')
    assert len(call(second, 'import', format='okf', directory='imports/projected', at='2026-10-16')['pages']) == 2
    partial = root / 'exports/partial'
    rows = snapshot(root / 'exports/all')
    write_files(partial, dict(list(rows.items())[:2]))
    call(root, 'export', format='okf', directory='exports/partial')
    assert snapshot(partial) == rows
    call(root, 'export', format='okf', directory='exports/all')  # Identical replay.
    (root / 'exports/all/index.md').write_text('external edit')
    call(root, 'export', format='okf', directory='exports/all', error='export_file_conflict')
    assert (root / 'exports/all/index.md').read_text() == 'external edit'
    CHECKS.append('conformant source objects/native projection reimport, partial export retry and external edit refusal')

    write_files(root / 'imports/plain', {'note.md': b'Plain **Markdown** with [missing](lost.md)', 'assets/code.js': b'console.log("never run");'})
    plain = call(root, 'import', format='markdown', directory='imports/plain', at='2026-10-16')
    call(root, 'export', format='markdown', directory='exports/plain', bundle=plain['bundle'])
    assert snapshot(root / 'exports/plain') == snapshot(root / 'imports/plain')
    call(root, 'export', format='okf', directory='exports/plain-okf', bundle=plain['bundle'])
    assert 'type: Reference' in (root / 'exports/plain-okf/note.md').read_text()
    call(root, 'forget', source='raw/imports/'+plain['bundle']+'/note.md', at='2026-10-16')
    call(root, 'export', format='markdown', directory='exports/forgotten', bundle=plain['bundle'], error='interop_original_changed_or_forgotten')
    CHECKS.append('plain Markdown and OKF conversion; independent namespaces and forgotten-source export refusal')

    before = (root / 'index.mbt.md').read_bytes()
    invalids = [b'no frontmatter', b'---\ntype: A\ntype: B\n---\n', b'---\n- value\n---\n', b'---\ntype: 3\n---\n', b'---\ntype: Good\n---\n\xff']
    for i, data in enumerate(invalids):
        write_files(root / ('imports/invalid-'+str(i)), {'page.md': data})
        value = call(root, 'import', format='okf', directory='imports/invalid-'+str(i), at='2026-10-16', error='interop_' if i == 4 else ('okf_' if i in [0,3] else 'interop_'))
        assert (root / 'index.mbt.md').read_bytes() == before
        assert not (root / 'state/transactions/pending.json').exists()
    (root / 'imports/link').mkdir()
    (root / 'imports/link/escape.md').symlink_to(work / 'outside')
    call(root, 'import', format='markdown', directory='imports/link', at='2026-10-16', error='symlink')
    call(root, 'import', format='markdown', directory='raw', at='2026-10-16', error='interop_directory_required')
    CHECKS.append('malformed YAML/type/UTF8 and unsafe input paths rejected before knowledge publication')

    # Fail the actual compiler boundary, then retry the same immutable uploads.
    bin_dir = work / 'bin'
    bin_dir.mkdir()
    compiler = bin_dir / 'moon'
    compiler.write_text('#!/bin/sh\nexit 1\n')
    compiler.chmod(0o755)
    env = {**os.environ, 'PATH': str(bin_dir)+os.pathsep+os.environ['PATH']}
    write_files(root / 'imports/failure', {'page.md': b'---\ntype: Test\n---\ncompiler failure test'})
    call(root, 'import', format='okf', directory='imports/failure', at='2026-10-16', error='moon_check_failed', env=env)
    assert (root / 'index.mbt.md').read_bytes() == before
    assert not (root / 'state/transactions/pending.json').exists()
    assert call(root, 'import', format='okf', directory='imports/failure', at='2026-10-16')['pages']
    before = (root / 'index.mbt.md').read_bytes()
    write_files(root / 'imports/race', {'page.md': b'---\ntype: Test\n---\nchanged during compile'})
    compiler.write_text('#!/usr/bin/env python3\nimport subprocess,sys\nfrom pathlib import Path\n'
                        'subprocess.run(['+repr(shutil.which('moon'))+',*sys.argv[1:]],check=True)\n'
                        'Path("imports/race/added.bin").write_bytes(b"external addition")\n')
    call(root, 'import', format='okf', directory='imports/race', at='2026-10-16', error='interop_input_changed', env=env)
    assert (root / 'index.mbt.md').read_bytes() == before
    CHECKS.append('real compiler failure/retry and input inventory race leave no partially published catalog')

print(json.dumps({'passed':len(CHECKS),'checks':CHECKS},ensure_ascii=False,indent=2))
