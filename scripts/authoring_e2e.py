#!/usr/bin/env python3
"""Native structured drafts and versioned external-model publication boundaries."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT/'_build/native/debug/build/cli/cli.exe'
ANALYSIS = {'entities': [], 'concepts': ['energy'], 'conflicts': ['Evidence needs review'], 'summary': 'Observed evidence.'}

with tempfile.TemporaryDirectory(prefix='corridor-authoring-') as work:
    vault = Path(work)

    def call(op, error=None, env=None, **fields):
        run = subprocess.run([str(EXE)], input=json.dumps(dict(fields, op=op, vault=str(vault)))+'\n',
                             text=True, capture_output=True, check=True, timeout=30, env=env)
        result = json.loads(run.stdout)
        if error:
            assert not result['ok'] and error in result['error'], result
            return result
        assert result['ok'], result
        return result['result']

    def proposal(pid, source, body, kind='concept'):
        return {'id': pid, 'kind': kind, 'title': '引号 " / # 与换行\n标题',
                'sources': [source], 'tags': ['中文'], 'body': body}

    def drafts():
        return {p.relative_to(vault): p.read_bytes() for p in (vault/'staging').rglob('*.md')}

    call('init')
    (vault/'raw/a.md').write_text('Plants convert sunlight into energy.\n')
    call('scan')
    first = call('plan')[0]['id']
    context = call('context', order=first)
    token = context['context_token']
    assert len(token) == 64 and token == call('context', order=first)['context_token']
    call('analysis-submit', order=first, context_token='0'*64, analysis=ANALYSIS, error='context_stale')
    call('analysis-submit', order=first, context_token=token, analysis=ANALYSIS)
    assert call('analysis-submit', order=first, context_token=token, analysis=ANALYSIS)['phase'] == 'analysis-done'
    assert token == call('context', order=first)['context_token']
    summary = proposal(context['source_summary_id'], 'raw/a.md', 'Source observes conversion. [[concepts/energy]]', 'source-summary')
    page = proposal('concepts/energy', 'raw/a.md', 'Energy conversion is supported by the source.')
    baseline = (vault/'index.mbt.md').read_bytes()
    initial = drafts()
    invalid = [
        ([], 'draft_batch_size'),
        ([page, page], 'duplicate_draft'),
        ([page, dict(page, id='concepts/bad', body='[[concepts/missing]]')], 'wikilink_unresolved'),
        ([dict(page, id='../escape')], 'unsafe_path'),
        ([dict(page, path='index.mbt.md')], 'unknown_field'),
        ([dict(page, kind='raw')], 'draft_page_kind_required'),
        ([dict(page, sources=['raw/missing.md'])], 'order_source_missing'),
        ([dict(page, body='')], 'draft_content_required'),
        ([dict(page, body='x'*1048577)], 'draft_text_limit'),
    ]
    for pages, error in invalid:
        failure = call('draft-submit', order=first, context_token=token, pages=pages, error=error)
        if error == 'wikilink_unresolved':
            assert failure['violations'][0]['predicate'] == error
            assert failure['violations'][0]['page'] == 'concepts/bad'
            assert failure['violations'][0]['fix']
        assert drafts() == initial and (vault/'index.mbt.md').read_bytes() == baseline
    staged = call('draft-submit', order=first, context_token=token, pages=[summary, page])
    assert staged['published'] is False
    assert call('draft-submit', order=first, context_token=token, pages=[summary, page]) == staged
    assert (vault/'index.mbt.md').read_bytes() == baseline and call('list-pages') == []
    assert all(item['staged'].startswith(f'staging/{first}/generated/') for item in staged['pages'])
    text = (vault/staged['pages'][0]['staged']).read_text()
    assert 'title: "' in text and '\\n' in text and 'tags: ["中文"]' in text

    compiler_dir = vault/'test-bin'
    compiler_dir.mkdir()
    compiler = compiler_dir/'moon'
    compiler.write_text('#!/bin/sh\nexit 1\n')
    compiler.chmod(0o755)
    env = {**os.environ, 'PATH': str(compiler_dir)+os.pathsep+os.environ['PATH']}
    call('commit', order=first, context_token=token, pages=staged['pages'], at='2026-10-16', env=env, error='moon_check_failed')
    assert (vault/'index.mbt.md').read_bytes() == baseline
    call('commit', order=first, context_token=token, pages=staged['pages'], at='2026-10-16')
    assert call('commit', order=first, context_token=token, pages=staged['pages'], at='2026-10-16')['replayed']
    assert len(call('review-list')) == 1
    assert call('search', query='conversion')['hits']

    (vault/'raw/b.txt').write_text('New evidence about energy.\n')
    call('scan')
    second = call('plan')[0]['id']
    before = call('context', order=second)
    # An explicitly registered page edit invalidates a late analysis even if another client refreshed context.
    published = vault/'wiki/concepts/energy.md'
    published.write_text(published.read_text()+'\nHuman addition.\n')
    call('refresh')
    after = call('context', order=second)
    assert before['context_token'] != after['context_token']
    call('analysis-submit', order=second, context_token=before['context_token'], analysis=ANALYSIS, error='context_stale')
    call('analysis-submit', order=second, context_token=after['context_token'], analysis=ANALYSIS)
    # A change in another raw source/staleness must also invalidate the full-context token.
    (vault/'raw/a.md').write_text('Changed observations.\n')
    call('scan')
    call('draft-submit', order=second, context_token=after['context_token'], pages=[proposal('concepts/new', 'raw/b.txt', 'New evidence.')], error='context_stale')
    current = call('context', order=second)
    assert current['order']['phase'] == 'context-ready' and current['order']['analysis'] is None
    call('analysis-submit', order=second, context_token=current['context_token'], analysis=ANALYSIS)
    new = proposal(current['source_summary_id'], 'raw/b.txt', 'New evidence summary.', 'source-summary')
    staged = call('draft-submit', order=second, context_token=current['context_token'], pages=[new])
    baseline = (vault/'index.mbt.md').read_bytes()
    (vault/'raw/b.txt').write_text('Changed during external model work.\n')
    call('commit', order=second, context_token=current['context_token'], pages=staged['pages'], at='2026-10-16', error='source_missing_or_changed')
    assert (vault/'index.mbt.md').read_bytes() == baseline

print('Authoring: structured staging, whole-batch refusal, compiler failure/retry, token replay and edited/stale input races passed')
