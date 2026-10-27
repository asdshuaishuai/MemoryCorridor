import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createWebWasmStorage } from '../sdk/wasm-web-storage.mjs';
import { createWasmSession, restoreWasmSession } from '../sdk/wasm-session.mjs';

const canonical = value => Array.isArray(value) ? '[' + value.map(canonical).join(',') + ']' :
  value && typeof value === 'object' ? '{' + Object.keys(value).sort().map(k => JSON.stringify(k) + ':' + canonical(value[k])).join(',') + '}' : JSON.stringify(value);
const hash = value => createHash('sha256').update(canonical(value)).digest('hex');
const records = new Map();
const storage = {
  getItem(key) { return records.has(key) ? records.get(key) : null; },
  setItem(key, value) { records.set(key, value); },
};
let lockCalls = 0;
const locks = { async request(name, options, callback) {
  assert.match(name, /^memorycorridor:(mc|session)$/);
  assert.equal(options.mode, 'exclusive');
  lockCalls += 1;
  return callback();
} };
const adapter = createWebWasmStorage({ key: 'mc', storage, locks });
const files = { 'index.mbt.md': 'catalog', 'purpose.md': 'purpose' };
const body = { format: 'memorycorridor-wasm-snapshot-v1', revision: 1, files };
const payload = { ...body, base_revision: 0, sha256: hash(body) };
assert.deepEqual(await adapter.load(), null);
assert.deepEqual(await adapter.save(payload), { ok: true, revision: 1, format: body.format, sha256: payload.sha256 });
assert.equal(lockCalls, 1);
assert.deepEqual((await adapter.load()).files, files);
const conflict = await adapter.save({ ...payload, base_revision: 0, revision: 2, sha256: hash({ ...body, revision: 2 }) });
assert.deepEqual(conflict, { ok: false, error: 'session_persist_conflict', revision: 1 });
const noLocks = createWebWasmStorage({ key: 'no-lock', storage, locks: null });
assert.deepEqual(await noLocks.save(payload), { ok: false, error: 'session_storage_lock_unavailable' });
records.set('bad', '{broken');
await assert.rejects(createWebWasmStorage({ key: 'bad', storage }).load(), /session_storage_corrupt/);
const sessionStorage = createWebWasmStorage({ key: 'session', storage, locks });
const kernel = { evaluate(request) {
  if (request.op === 'session-verify') return { ok: true, result: {} };
  if (request.op === 'session-plan') return { ok: true, result: { planned: true } };
  throw new Error('unexpected kernel operation');
} };
const session = createWasmSession({ kernel, files: { 'index.mbt.md': 'catalog' }, persist: value => sessionStorage.save(value) });
const committed = await session.execute({ op: 'transaction', changes: [
  { path: 'index.mbt.md', before: 'catalog', after: 'catalog-v2' },
] });
assert.equal(committed.ok, true, JSON.stringify(committed));
const restored = await restoreWasmSession({ kernel, storage: sessionStorage });
assert.equal((await restored.execute({ op: 'snapshot' })).result.revision, 1);
assert.equal(restored.snapshot()['index.mbt.md'], 'catalog-v2');
console.log('Web WASM storage: Web Locks/CAS, hash envelope, conflict and explicit lock refusal passed');
