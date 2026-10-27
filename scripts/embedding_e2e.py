#!/usr/bin/env python3
"""Incremental embedding plans and publication races, using the real disk/compiler."""
import json
import base64
import os
import struct
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / '_build/native/debug/build/cli/cli.exe'

with tempfile.TemporaryDirectory(prefix='corridor-embedding-') as work:
    vault = Path(work)

    def call(op, error=None, env=None, **fields):
        run = subprocess.run([str(EXE)], input=json.dumps(dict(fields, op=op, vault=str(vault)))+'\n',
                             text=True, capture_output=True, check=True, timeout=30, env=env)
        response = json.loads(run.stdout)
        if error:
            assert not response['ok'] and error in response['error'], response
            return response
        assert response['ok'], response
        return response['result']

    space = {'id': 'model-content-v1:recipe-v1', 'dimensions': 2}
    call('init')
    empty = call('embedding-plan', space=space)
    assert empty['items'] == [] and empty['remaining'] == 0
    (vault/'raw/input.md').write_text('Evidence for all pages.\n')
    call('scan')
    order = call('plan')[0]['id']
    call('context', order=order)
    call('analysis-submit', order=order, analysis={'entities': [], 'concepts': [], 'conflicts': [], 'summary': 'evidence'})
    pages = []
    for name, body in [('z', 'Short document.'), ('a', '界🌙' * 5000)]:
        staged = f'staging/{order}/{name}.md'
        (vault/staged).write_text('---\ntype: concept\ntitle: '+name+'\nsources: ["raw/input.md"]\n---\n'+body+'\n')
        pages.append({'id': f'concepts/{name}', 'path': f'wiki/concepts/{name}.md', 'staged': staged})
    call('commit', order=order, pages=pages, at='2026-10-16')
    before = (vault/'index.mbt.md').read_bytes()
    plan = call('embedding-plan', space=space, limit=1)
    assert plan == call('embedding-plan', space=space, limit=1)
    assert (vault/'index.mbt.md').read_bytes() == before
    assert plan['text_recipe'] == 'title-body-prefix16KiB-v1'
    first = plan['items'][0]
    assert first['page'] == 'concepts/a' and plan['remaining'] == 2
    assert first['truncated'] and len(first['text'].encode()) <= 16384
    assert '\ufffd' not in first['text'] and first['text'].startswith('a\n\n')
    short = next(p for p in call('embedding-plan', space=space)['items'] if p['page'] == 'concepts/z')
    assert not short['truncated'] and 'Short document.' in short['text']
    for limit in [0, 129, 1.5]:
        call('embedding-plan', space=space, limit=limit, error='invalid_integer: limit')
    call('embedding-plan', space=space, unexpected=True, error='unknown_field')
    item = {k: first[k] for k in ['page', 'sha256']}
    item['values'] = [1, 0]
    compiler_dir = vault/'test-bin'
    compiler_dir.mkdir()
    compiler = compiler_dir/'moon'
    compiler.write_text('#!/bin/sh\nexit 1\n')
    compiler.chmod(0o755)
    failed_env = {**os.environ, 'PATH': str(compiler_dir)+os.pathsep+os.environ['PATH']}
    call('embedding-submit', space=space, items=[item], error='moon_check_failed', env=failed_env)
    assert (vault/'index.mbt.md').read_bytes() == before
    assert not list((vault/'vectors').glob('*.json'))
    assert not (vault/'state/transactions/pending.json').exists()
    call('embedding-submit', space=space, items=[item])
    missing = call('embedding-plan', space=space)
    assert first['page'] not in [p['page'] for p in missing['items']]
    assert len(missing['items']) == 2
    wire = base64.b64encode(struct.pack('<ff', 0.0, 1.0)).decode()
    wire_item = {'page': 'concepts/z', 'sha256': short['sha256'], 'values_b64': wire}
    call('embedding-submit', space=space, items=[wire_item])
    wire_search = call('search', query='', query_vector={'space': space, 'values_b64': wire})
    assert wire_search['vector_status'] == 'brute_force' and wire_search['hits'][0]['id'] == 'concepts/z'
    call('search', query='', query_vector={'space': space, 'values': [1, 0], 'values_b64': wire}, error='vector_values_encoding_exclusive')
    external = call('search', query='', vector_candidates={
        'space': space, 'hits': [{'id': 'concepts/z', 'score': 0.99}]})
    assert external['vector_status'] == 'external' and external['hits'][0]['id'] == 'concepts/z'
    call('search', query='', vector_candidates={
        'space': space, 'hits': [{'id': 'concepts/missing', 'score': 0.99}]},
         error='backend_invalid_candidate')
    call('search', query='', query_vector={'space': space, 'values': [1, 0]},
         vector_candidates={'space': space, 'hits': []}, error='vector_inputs_exclusive')
    other = dict(space, id='model-content-v2:recipe-v1')
    assert len(call('embedding-plan', space=other)['items']) == 3
    assert len(call('embedding-plan', space=dict(space, dimensions=3))['items']) == 3

    # Human body adoption makes the previous vector version unusable.
    page = vault/'wiki/concepts/a.md'
    page.write_text(page.read_text()+'\nNew edition.\n')
    call('embedding-plan', space=space, error='content_changed')
    call('refresh')
    updated = call('embedding-plan', space=space)['items'][0]
    assert updated['page'] == first['page'] and updated['sha256'] != first['sha256']
    baseline = (vault/'index.mbt.md').read_bytes()
    call('embedding-submit', space=space, items=[item], error='vector_content_version_mismatch')
    assert (vault/'index.mbt.md').read_bytes() == baseline

    # Source drift during external inference must prevent publication before scan.
    item['sha256'] = updated['sha256']
    (vault/'raw/input.md').write_text('Changed evidence.\n')
    call('embedding-submit', space=space, items=[item], error='source_missing_or_changed')
    assert (vault/'index.mbt.md').read_bytes() == baseline
    call('scan')
    assert call('embedding-plan', space=space)['items'] == []
    call('embedding-submit', space=space, items=[item], error='vector_page_not_active')
    call('rebuild')
    assert call('search', query='', query_vector={'space': space, 'values': [1, 0]})['hits'] == []

print('Embedding plans: deterministic batches, Unicode bounds, model/version isolation, compiler failure/retry and source-race rejection passed')
