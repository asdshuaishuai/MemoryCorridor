import assert from 'node:assert/strict';
import { readFile, mkdtemp, writeFile, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { loadCorridor } from '../sdk/wasm.mjs';
import { createWasmSession, restoreWasmSession } from '../sdk/wasm-session.mjs';
import { createNodeWasmStorage } from '../sdk/wasm-node-storage.mjs';

const run = (file, input) => new Promise((resolve, reject) => {
  const child = spawn(file, [], { stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = ''; let stderr = '';
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  child.on('error', reject);
  child.on('close', code => code === 0 ? resolve({ stdout, stderr }) : reject(new Error(`${file} exited ${code}: ${stderr}`)));
  child.stdin.end(input);
});
const root = await mkdtemp(join(tmpdir(), 'corridor-wasm-session-'));
const exe = new URL('../_build/native/debug/build/cli/cli.exe', import.meta.url).pathname;
await run(exe, JSON.stringify({ op: 'init', vault: root, purpose: 'WASM session' }) + '\n');
const oldPurpose = await readFile(join(root, 'purpose.md'), 'utf8');
const oldCatalog = await readFile(join(root, 'index.mbt.md'), 'utf8');
const hash = text => createHash('sha256').update(Buffer.from(text)).digest('hex');
const newPurpose = 'WASM session changed\n';
const newCatalog = oldCatalog.replace(hash(oldPurpose), hash(newPurpose));
const bytes = await readFile(new URL('../_build/wasm/debug/build/wasm/wasm.wasm', import.meta.url));
const kernel = await loadCorridor(bytes);
assert.throws(() => createWasmSession({ kernel, files: { '../escape': 'bad' } }), /invalid session file/);
assert.throws(() => createWasmSession({ kernel, files: { 'index.mbt.md': oldCatalog, 'purpose.md': 'drifted' } }), /session_content_changed/);
const compiled = [];
const session = createWasmSession({
  kernel,
  files: { 'index.mbt.md': oldCatalog, 'purpose.md': oldPurpose },
  compile: async (path, text) => { compiled.push([path, text]); },
});
assert.equal((await session.execute({ op: 'snapshot' })).result.revision, 0);
const change = [
  { path: 'purpose.md', before: oldPurpose, after: newPurpose },
  { path: 'index.mbt.md', before: oldCatalog, after: newCatalog },
];
const planned = await session.execute({ op: 'plan', changes: change });
assert.equal(planned.ok, true);
const committed = await session.execute({ op: 'transaction', changes: change });
assert.equal(committed.ok, true);
assert.deepEqual(compiled.map(row => row[0]), ['index.mbt.md']);
assert.equal(session.snapshot()['purpose.md'], newPurpose);
assert.equal(session.snapshot()['index.mbt.md'], newCatalog);
assert.equal((await session.execute({ op: 'transaction', changes: change })).ok, false);

const failing = createWasmSession({
  kernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  compile: async () => ({ ok: false, error: 'compiler refused' }),
});
const nextPurpose = 'compiler failure must not publish\n';
const nextCatalog = newCatalog.replace(hash(newPurpose), hash(nextPurpose));
const failed = await failing.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: nextPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: nextCatalog },
] });
assert.equal(failed.ok, false);
assert.equal(failing.snapshot()['purpose.md'], newPurpose);

const conflict = await session.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: 'external edit\n', after: 'ignored\n' },
  { path: 'index.mbt.md', before: newCatalog, after: newCatalog },
] });
assert.equal(conflict.ok, false);
assert.equal(session.snapshot()['purpose.md'], newPurpose);

const gcBytes = await readFile(new URL('../_build/wasm-gc/debug/build/wasm/wasm.wasm', import.meta.url));
const gcKernel = await loadCorridor(gcBytes);
const gcSession = createWasmSession({ kernel: gcKernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose } });
assert.equal((await gcSession.execute({ op: 'plan', changes: [
  { path: 'purpose.md', before: newPurpose, after: newPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: newCatalog },
] })).ok, true);

const persisted = { revision: 7, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose } };
const persistedWrites = [];
const storage = {
  async load() { return persisted; },
  async save(value) {
    assert.equal(value.base_revision, persisted.revision);
    persistedWrites.push(value);
    persisted.format = value.format; persisted.revision = value.revision;
    persisted.files = value.files; persisted.sha256 = value.sha256;
    return { ok: true, revision: value.revision };
  },
};
const restored = await restoreWasmSession({ kernel, storage });
assert.equal((await restored.execute({ op: 'snapshot' })).result.revision, 7);
assert.deepEqual(restored.snapshot(), persisted.files);
const persistedPurpose = 'persisted update\n';
const persistedCatalog = newCatalog.replace(hash(newPurpose), hash(persistedPurpose));
const persistedResult = await restored.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: persistedPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: persistedCatalog },
] });
assert.equal(persistedResult.ok, true);
assert.equal(persistedWrites.length, 1);
assert.equal(persistedWrites[0].base_revision, 7);
assert.equal(persistedWrites[0].revision, 8);
assert.equal(persistedWrites[0].format, 'memorycorridor-wasm-snapshot-v1');
assert.match(persistedWrites[0].sha256, /^[0-9a-f]{64}$/);

const nodeStorage = createNodeWasmStorage(join(root, 'state', 'wasm-snapshot.json'));
const nodeSession = createWasmSession({
  kernel,
  files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  persist: payload => nodeStorage.save(payload),
});
const nodePurpose = 'node filesystem adapter\n';
const nodeCatalog = newCatalog.replace(hash(newPurpose), hash(nodePurpose));
const nodeCommit = await nodeSession.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: nodePurpose },
  { path: 'index.mbt.md', before: newCatalog, after: nodeCatalog },
] });
assert.equal(nodeCommit.ok, true);
const nodeSnapshot = await nodeStorage.load();
assert.equal(nodeSnapshot.revision, 1);
assert.equal(nodeSnapshot.format, 'memorycorridor-wasm-snapshot-v1');
const nodeRestored = await restoreWasmSession({ kernel, storage: nodeStorage });
assert.equal((await nodeRestored.execute({ op: 'snapshot' })).result.revision, 1);
assert.equal(nodeRestored.snapshot()['purpose.md'], nodePurpose);
await writeFile(join(root, 'state', 'wasm-snapshot.json.tmp'), '{ interrupted write');
const recoveredNode = await restoreWasmSession({ kernel, storage: nodeStorage });
assert.equal((await recoveredNode.execute({ op: 'snapshot' })).result.revision, 1);
assert.equal(recoveredNode.snapshot()['purpose.md'], nodePurpose);
const staleNodeWrite = await nodeStorage.save({
  ...nodeSnapshot, base_revision: 0, revision: 2,
});
assert.equal(staleNodeWrite.ok, false);
assert.equal(staleNodeWrite.error, 'session_persist_conflict');
const nodeLockPath = join(root, 'state', 'wasm-snapshot.json.lock');
await writeFile(nodeLockPath, JSON.stringify({ pid: process.pid, token: 'active-owner' }));
const lockedNodeWrite = await nodeStorage.save({
  ...nodeSnapshot, base_revision: 1, revision: 2,
});
assert.equal(lockedNodeWrite.ok, false);
assert.equal(lockedNodeWrite.error, 'session_storage_locked');
await unlink(nodeLockPath);
await writeFile(nodeLockPath, JSON.stringify({ pid: 2147483647, token: 'dead-owner' }));
const reclaimedNodeWrite = await nodeStorage.save({
  ...nodeSnapshot, base_revision: 1, revision: 2,
});
assert.equal(reclaimedNodeWrite.ok, true);

await assert.rejects(
  restoreWasmSession({ kernel, storage: { load: async () => ({ ...persisted,
    files: { ...persisted.files, 'purpose.md': 'tampered' } }), save: async () => {} } }),
  /session_snapshot_hash_mismatch/,
);

const concurrent = createWasmSession({
  kernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  compile: async () => { await new Promise(resolve => setTimeout(resolve, 1)); },
});
const concurrentPurposeA = 'first queued transaction\n';
const concurrentPurposeB = 'second queued transaction\n';
const concurrentA = [
  { path: 'purpose.md', before: newPurpose, after: concurrentPurposeA },
  { path: 'index.mbt.md', before: newCatalog, after: newCatalog.replace(hash(newPurpose), hash(concurrentPurposeA)) },
];
const concurrentB = [
  { path: 'purpose.md', before: newPurpose, after: concurrentPurposeB },
  { path: 'index.mbt.md', before: newCatalog, after: newCatalog.replace(hash(newPurpose), hash(concurrentPurposeB)) },
];
const concurrentResults = await Promise.all([
  concurrent.execute({ op: 'transaction', changes: concurrentA }),
  concurrent.execute({ op: 'transaction', changes: concurrentB }),
]);
assert.equal(concurrentResults.filter(value => value.ok).length, 1);
assert.equal(concurrentResults.filter(value => !value.ok).length, 1);
assert.equal((await concurrent.execute({ op: 'snapshot' })).result.revision, 1);

const persistFailure = createWasmSession({
  kernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  persist: async () => false,
});
const failedPurpose = 'durability refusal must preserve memory\n';
const failedCatalog = newCatalog.replace(hash(newPurpose), hash(failedPurpose));
const refused = await persistFailure.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: failedPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: failedCatalog },
] });
assert.equal(refused.ok, false);
assert.equal(refused.error, 'session_persist_failed');
assert.equal(persistFailure.snapshot()['purpose.md'], newPurpose);

const persistConflict = createWasmSession({
  kernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  persist: async payload => ({ ok: true, revision: payload.revision + 1 }),
});
const conflictPersisted = await persistConflict.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: failedPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: failedCatalog },
] });
assert.equal(conflictPersisted.ok, false);
assert.equal(conflictPersisted.error, 'session_persist_conflict');
assert.equal(persistConflict.snapshot()['purpose.md'], newPurpose);

const persistHashConflict = createWasmSession({
  kernel, files: { 'index.mbt.md': newCatalog, 'purpose.md': newPurpose },
  persist: async payload => ({ ok: true, format: payload.format, sha256: '0'.repeat(64) }),
});
const hashConflict = await persistHashConflict.execute({ op: 'transaction', changes: [
  { path: 'purpose.md', before: newPurpose, after: failedPurpose },
  { path: 'index.mbt.md', before: newCatalog, after: failedCatalog },
] });
assert.equal(hashConflict.ok, false);
assert.equal(hashConflict.error, 'session_persist_conflict');
assert.equal(persistHashConflict.snapshot()['purpose.md'], newPurpose);

await assert.rejects(
  restoreWasmSession({ kernel, storage: { load: async () => ({ revision: 0, files: { 'index.mbt.md': 'bad' } }), save: async () => {} } }),
  /catalog_header_invalid/,
);
await assert.rejects(
  restoreWasmSession({ kernel, storage: { load: async () => ({ revision: 0, files: { '../escape': 'bad' } }), save: async () => {} } }),
  /invalid session file/,
);
console.log('WASM session snapshot planning, host compile callback, index-last commit, retry and conflict preservation: passed');
