#!/usr/bin/env python3
"""Incremental embedding plans and publication races, using the real disk/compiler."""
import json
import base64
import hashlib
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

# ---- Optional multimodal routing (续二十六) ----------------------------------
# embed-multimodal flips embedding-plan for THAT provider+space to deterministic
# image items; providers without the capability keep the text recipe verbatim;
# unknown capabilities fail closed at registration. No model needed -- this is
# the engine protocol face only. `vault`/`call` rebind to a fresh directory.
with tempfile.TemporaryDirectory(prefix='corridor-mm-') as mmwork:
    vault = Path(mmwork)
    mm = {'id': 'clip-mm-v1:recipe-v1', 'dimensions': 2}
    call('init')
    call('provider-register', provider='mm-host', kind='embedding', space=mm,
         capabilities=['embed', 'embed-multimodal'], at='2026-11-04T00:00:00Z')
    call('provider-register', provider='txt-host', kind='embedding', space=mm,
         capabilities=['embed'], at='2026-11-04T00:00:00Z')
    call('provider-register', provider='bad-host', kind='embedding', space=mm,
         capabilities=['embed', 'frobnicate'], at='2026-11-04T00:00:00Z',
         error='provider_capability_unknown')
    call('provider-register', provider='mm-only', kind='embedding', space=mm,
         capabilities=['embed-multimodal'], at='2026-11-04T00:00:00Z',
         error='provider_embed_capability_required')
    png = b'\x89PNG\r\n\x1a\n' + b'memorycorridor deterministic image bytes'
    (vault/'raw/photo.png').write_bytes(png)
    (vault/'raw/input.md').write_text('Text evidence with no image source.\n')
    call('scan')
    o = next(order for order in call('plan') if order['source'] == 'raw/photo.png')['id']
    call('context', order=o)
    call('analysis-submit', order=o,
         analysis={'entities': [], 'concepts': [], 'conflicts': [], 'summary': 'mm'})
    staged = f'staging/{o}/0.md'
    (vault/staged).write_text('---\ntype: concept\ntitle: photo\nsources: ["raw/photo.png"]\n---\n青瓷照片页。\n')
    call('commit', order=o, pages=[{'id': 'concepts/photo', 'path': 'wiki/concepts/photo.md', 'staged': staged}], at='2026-11-04')
    o1 = next(order for order in call('plan') if order['source'] == 'raw/input.md')['id']
    call('context', order=o1)
    call('analysis-submit', order=o1,
         analysis={'entities': [], 'concepts': [], 'conflicts': [], 'summary': 'mm-prose'})
    staged1 = f'staging/{o1}/0.md'
    (vault/staged1).write_text('---\ntype: concept\ntitle: prose\nsources: ["raw/input.md"]\n---\n纯文字页。\n')
    call('commit', order=o1, pages=[{'id': 'concepts/prose', 'path': 'wiki/concepts/prose.md', 'staged': staged1}], at='2026-11-04')
    call('rebuild')

    mmplan = call('embedding-plan', space=mm, provider='mm-host')
    assert mmplan['image_recipe'] == 'first-image-source-v1' and mmplan['text_recipe'] is None
    assert mmplan['remaining'] == 0, mmplan
    # Every page whose source set contains an image participates -- including the
    # sources/ revision page, exactly as on the text face. prose never appears.
    planned = sorted(i['page'] for i in mmplan['items'])
    assert planned[0] == 'concepts/photo' and all(p != 'concepts/prose' for p in planned)
    assert len(planned) == 2
    item = next(i for i in mmplan['items'] if i['page'] == 'concepts/photo')
    assert set(item) == {'page', 'sha256', 'modality', 'image', 'image_sha256'}, item
    assert item['modality'] == 'image' and item['image'] == 'raw/photo.png'
    assert item['image_sha256'] == hashlib.sha256(png).hexdigest()
    assert call('embedding-plan', space=mm, provider='mm-host') == mmplan  # idempotent

    # The same space through a capability-less provider keeps the old text face.
    txtp = call('embedding-plan', space=mm, provider='txt-host')
    assert txtp['image_recipe'] is None and txtp['text_recipe'] == 'title-body-prefix16KiB-v1'
    assert 'concepts/prose' in [i['page'] for i in txtp['items']]  # prose included, not skipped
    assert all('image' not in i and 'text' in i for i in txtp['items'])
    assert len(txtp['items']) == 4 and txtp['remaining'] == 0  # 2 concepts + 2 sources pages

    # Vectors publish through the same validated channel...
    subs = [{'page': i['page'], 'sha256': i['sha256'], 'values': [1.0, 0.0]} for i in mmplan['items']]
    call('embedding-submit', space=mm, items=subs, provider='mm-host')
    assert call('embedding-plan', space=mm, provider='mm-host')['items'] == []

    # ...and the content-version lock follows IMAGE bytes, not page text.
    (vault/'raw/photo.png').write_bytes(png + b'-drifted')
    call('scan')
    assert call('embedding-plan', space=mm, provider='mm-host')['items'] == []  # stale pages
    call('embedding-submit', space=mm, items=[subs[0]], provider='mm-host',
         error='vector_page_not_active')
    o2 = next(order for order in call('plan') if order['source'] == 'raw/photo.png')['id']
    call('context', order=o2)
    call('analysis-submit', order=o2,
         analysis={'entities': [], 'concepts': [], 'conflicts': [], 'summary': 'mm2'})
    staged2 = f'staging/{o2}/0.md'
    (vault/staged2).write_text('---\ntype: concept\ntitle: photo2\nsources: ["raw/photo.png"]\n---\n青瓷照片页改。\n')
    call('commit', order=o2, pages=[{'id': 'concepts/photo', 'path': 'wiki/concepts/photo.md', 'staged': staged2}], at='2026-11-05')
    call('rebuild')
    item2 = call('embedding-plan', space=mm, provider='mm-host')['items'][0]
    assert item2['image_sha256'] == hashlib.sha256(png + b'-drifted').hexdigest()
    assert item2['sha256'] != item['sha256']

print('Multimodal plan routing: capability-gated image items, deterministic source pick, byte-version lock and closed capability vocabulary passed')
