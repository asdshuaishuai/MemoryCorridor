#!/usr/bin/env python3
"""Independent ZIP reader/writer, byte-level mutations and actual on-disk restore."""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

REPO = Path(__file__).resolve().parents[1]
EXE = REPO / "_build/native/debug/build/cli/cli.exe"
CHECKS = []


def call(root, op, error=None, **fields):
    request = {"op": op, "vault": str(root), **fields}
    process = subprocess.run([str(EXE)], input=json.dumps(request) + "\n", capture_output=True, text=True, timeout=30, check=True)
    value = json.loads(process.stdout)
    assert "Warning:" not in process.stderr and "Panic" not in process.stderr, process.stderr
    if error:
        assert not value["ok"] and error in value["error"], value
    else:
        assert value["ok"], value
    return value.get("result", value)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def stored_zip(files):
    out, central = bytearray(), bytearray()
    for path, data in sorted(files.items()):
        name = path.encode()
        crc, size, offset = zlib.crc32(data), len(data), len(out)
        out += struct.pack('<I5H3I2H', 0x04034B50, 20, 0x800, 0, 0, 0x21, crc, size, size, len(name), 0) + name + data
        central += struct.pack('<I6H3I5H2I', 0x02014B50, 0x0314, 20, 0x800, 0, 0, 0x21, crc, size, size, len(name), 0, 0, 0, 0, 0x81A40000, offset) + name
    offset = len(out)
    out += central
    out += struct.pack('<I4H2IH', 0x06054B50, 0, 0, len(files), len(files), len(central), offset, 0)
    return bytes(out)


def make_pack(files, version=1):
    objects, rows = {}, []
    for path in sorted(files, key=lambda p: p.encode('utf-16-be')):
        data = files[path]
        digest = hashlib.sha256(data).hexdigest()
        rows.append({"path": path, "size": len(data), "sha256": digest})
        objects["objects/" + digest] = data
    objects['manifest.json'] = canonical({"format": "memorycorridor-pack", "version": version,
        "vault_fingerprint": hashlib.sha256(files['index.mbt.md']).hexdigest(), "files": rows})
    return stored_zip(objects)


def empty_target(path):
    path.mkdir()
    for directory in ['raw', 'wiki', 'views', 'vectors', 'staging', 'state/transactions/history', 'imports']:
        (path / directory).mkdir(parents=True, exist_ok=True)
    return path


with tempfile.TemporaryDirectory(prefix='corridor-pack-') as work:
    work = Path(work)
    source = work / 'source'
    subprocess.run(['python3', str(REPO / 'scripts/make_demo.py'), str(source)], check=True, capture_output=True, text=True)
    binary = b'%PDF-1.7\x00\xff\x80binary'
    (source / 'raw/binary.pdf').write_bytes(binary)
    order = call(source, 'scan')['orders'][0]
    call(source, 'context', order=order)
    (source / 'staging' / order / 'draft.md').write_text('未提交草稿，不得被快照遗漏。')
    page = call(source, 'read-page', id='concepts/文学化目录')
    body = page['text'].split('---\n', 2)[-1]
    quote = 'index.mbt.md'
    start = len(body.encode('utf-8').split(quote.encode('utf-8'), 1)[0])
    evidence = call(source, 'evidence-submit', page='concepts/文学化目录', page_hash=page['entry']['sha256'],
                    items=[{'source': 'raw/项目方案.md', 'body_start': start,
                            'body_end': start + len(quote.encode('utf-8')), 'quote': quote}])
    call(source, 'forget', source='raw/LICENSE.txt', at='2026-10-16')
    (source / 'raw/LICENSE.txt').unlink()  # Forgotten and physically absent is legal.
    current_index = (source / 'index.mbt.md').read_text()
    recovery_journal = {'version': 1, 'old_index': current_index, 'new_index': current_index, 'changes': []}
    (source / 'state/transactions/pending.json').write_text(json.dumps(recovery_journal))
    call(source, 'recover')
    history_payload = {'version': 1, 'direction': 'forward', 'journal': recovery_journal}
    history_bytes = canonical(history_payload)
    history_path = 'state/transactions/history/' + hashlib.sha256(history_bytes).hexdigest() + '.json'
    assert (source / history_path).read_bytes() == history_bytes
    a = call(source, 'pack', output='exports/a.mcpack')
    b = call(source, 'pack', output='exports/b.mcpack')
    blob = (source / a['output']).read_bytes()
    assert blob == (source / b['output']).read_bytes()
    assert hashlib.sha256(blob).hexdigest() == a['pack_fingerprint']
    call(source, 'pack', output='exports/a.mcpack', error='export_already_exists')
    with zipfile.ZipFile(source / a['output']) as archive:
        assert archive.testzip() is None
        manifest = json.loads(archive.read('manifest.json'))
        files = {row['path']: archive.read('objects/' + row['sha256']) for row in manifest['files']}
        assert all(hashlib.sha256(files[r['path']]).hexdigest() == r['sha256'] and len(files[r['path']]) == r['size'] for r in manifest['files'])
        assert all(info.compress_type == zipfile.ZIP_STORED and info.date_time == (1980, 1, 1, 0, 0, 0) for info in archive.infolist())
    assert make_pack(files) == blob  # Independent writer agrees byte-for-byte.
    assert not any(p.startswith(('.corridor/', 'exports/')) or '/_build/' in p for p in files)
    assert files['raw/binary.pdf'] == binary and 'raw/LICENSE.txt' not in files
    assert 'staging/' + order + '/draft.md' in files
    assert files[history_path] == history_bytes
    assert 'state/evidence/' + evidence['id'] + '.json' in files
    CHECKS.append('standard ZIP compatibility, independent deterministic bytes and content-addressed manifest')

    target = empty_target(work / 'restored')
    (target / 'imports/test.mcpack').write_bytes(blob)
    result = call(target, 'unpack', file='imports/test.mcpack')
    assert result['vault_fingerprint'] == a['vault_fingerprint']
    for path, data in files.items():
        assert (target / path).read_bytes() == data
    call(target, 'rebuild')
    call(target, 'verify')
    call(target, 'render-view')
    assert call(target, 'search', query='EmbeddingProvider')['hits'] == call(source, 'search', query='EmbeddingProvider')['hits']
    assert call(target, 'status')['fingerprint'] == call(source, 'status')['fingerprint']
    assert call(target, 'plan')[0]['id'] == order
    call(target, 'unpack', file='imports/test.mcpack', error='unpack_requires_empty_vault')
    CHECKS.append('native binary/staging/state/view restore, same fingerprint and retrieval, overwrite refused')

    variants = [('future version', make_pack(files, 2), 'pack_version_unsupported'),
                ('truncated', blob[:-1], 'zip_noncanonical'),
                ('trailing bytes', blob + b'hidden', 'zip_noncanonical')]
    traversal = dict(files)
    traversal['../outside'] = b'escape'
    variants.append(('path traversal', make_pack(traversal), 'unsafe_path'))
    unsupported = dict(files)
    unsupported['state/transactions/forged.json'] = b'{}'
    variants.append(('transaction injection', make_pack(unsupported), 'pack_path_refused'))
    malformed_history = dict(files)
    malformed_history['state/transactions/history/bad.json'] = b'{}'
    variants.append(('malformed recovery history', make_pack(malformed_history), 'missing_field'))
    corrupt = bytearray(blob)
    corrupt[14] ^= 1
    variants.append(('CRC', bytes(corrupt), 'zip_crc_mismatch'))
    link = bytearray(blob)
    central = link.index(b'PK\x01\x02')
    struct.pack_into('<I', link, central + 38, 0xA1FF0000)
    variants.append(('symlink', bytes(link), 'zip_noncanonical'))
    broken_order = dict(files)
    order_path = 'state/orders/' + order + '.json'
    old_hash = hashlib.sha256(broken_order[order_path]).hexdigest()
    broken_order[order_path] = b'{}'
    broken_order['index.mbt.md'] = broken_order['index.mbt.md'].replace(old_hash.encode(), hashlib.sha256(b'{}').hexdigest().encode())
    variants.append(('invalid persistent order', make_pack(broken_order), 'missing_field'))
    for i, (name, data, error) in enumerate(variants):
        dest = empty_target(work / ('rejected-' + str(i)))
        (dest / 'imports/test.mcpack').write_bytes(data)
        call(dest, 'unpack', file='imports/test.mcpack', error=error)
        assert not (dest / 'index.mbt.md').exists(), name
        assert not (dest / 'state/transactions/unpack.json').exists(), name
        assert list((dest / 'raw').iterdir()) == [], name
    CHECKS.append('future versions, CRC, truncation, traversal, hidden data, symlinks and malformed orders rejected before prepare')

    for published in [False, True]:
        dest = empty_target(work / ('resume-' + str(published)))
        (dest / 'state/transactions/unpack.mcpack').write_bytes(blob)
        (dest / 'state/transactions/unpack.json').write_bytes(canonical({'version': 1, 'sha256': hashlib.sha256(blob).hexdigest()}))
        for i, (path, data) in enumerate(files.items()):
            if (published or i < 3) and (published or path != 'index.mbt.md'):
                (dest / path).parent.mkdir(parents=True, exist_ok=True)
                (dest / path).write_bytes(data)
        assert call(dest, 'recover')['recovered']
        assert all((dest / path).read_bytes() == data for path, data in files.items())
        assert not (dest / 'state/transactions/unpack.json').exists()
        call(dest, 'rebuild')
        call(dest, 'verify')
    conflict = empty_target(work / 'conflict')
    (conflict / 'state/transactions/unpack.mcpack').write_bytes(blob)
    (conflict / 'state/transactions/unpack.json').write_bytes(canonical({'version': 1, 'sha256': hashlib.sha256(blob).hexdigest()}))
    (conflict / 'purpose.md').write_text('human edit')
    call(conflict, 'recover', error='unpack_conflict')
    assert (conflict / 'purpose.md').read_text() == 'human edit'
    assert (conflict / 'state/transactions/unpack.json').exists()
    assert not (conflict / 'index.mbt.md').exists()
    CHECKS.append('actual disk recovery before/after publication and external edit conflict preservation')

print(json.dumps({'passed': len(CHECKS), 'checks': CHECKS}, ensure_ascii=False, indent=2))
