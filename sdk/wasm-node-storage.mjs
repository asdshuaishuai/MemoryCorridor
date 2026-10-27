// Node host adapter for sdk/wasm-session.mjs. This module is intentionally
// outside the WASM kernel: it owns filesystem durability, while the session
// still owns snapshot validation and publication ordering.
import { open, mkdir, readFile, rename, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { dirname } from 'node:path';

const FORMAT = 'memorycorridor-wasm-snapshot-v1';

function revisionOf(value, missing = false) {
  if (value === null && missing) return 0;
  if (!value || typeof value !== 'object' || !Number.isSafeInteger(value.revision) || value.revision < 0) {
    throw new Error('session_storage_corrupt');
  }
  return value.revision;
}

function snapshotOf(payload) {
  if (!payload || typeof payload !== 'object' || !Number.isSafeInteger(payload.revision) ||
      payload.revision < 0 || !Number.isSafeInteger(payload.base_revision) || payload.base_revision < 0 ||
      payload.format !== FORMAT || !payload.files || typeof payload.files !== 'object' ||
      Array.isArray(payload.files) || typeof payload.sha256 !== 'string') {
    throw new TypeError('invalid session persistence payload');
  }
  const files = Object.fromEntries(Object.entries(payload.files).sort(([a], [b]) => a.localeCompare(b)));
  for (const [path, text] of Object.entries(files)) {
    if (!path || typeof text !== 'string' || path.startsWith('/') || path.includes('\\') || path.includes(':') ||
        path.includes('\0') || path.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new TypeError('invalid session file: ' + path);
    }
  }
  if (!/^[0-9a-f]{64}$/.test(payload.sha256)) throw new TypeError('invalid session persistence hash');
  return {
    format: payload.format,
    revision: payload.revision,
    files,
    sha256: payload.sha256,
  };
}

/**
 * Create a filesystem-backed WASM snapshot adapter.
 *
 * Writes are serialized within this adapter and by a PID lock file shared by
 * adapter instances and processes. The lock covers the base_revision check,
 * durable temporary write, and atomic rename. A lock owned by a dead PID is
 * reclaimed; malformed lock metadata remains conservative and refuses writes.
 */
export function createNodeWasmStorage(filePath) {
  if (typeof filePath !== 'string' || filePath.length === 0 || filePath.includes('\0')) {
    throw new TypeError('snapshot path must be a non-empty string');
  }
  const target = filePath;
  const temporary = `${filePath}.tmp`;
  const lockPath = `${filePath}.lock`;
  const lockToken = randomUUID();
  let queue = Promise.resolve();

  async function load() {
    try {
      return JSON.parse(await readFile(target, 'utf8'));
    } catch (error) {
      if (error?.code === 'ENOENT') return null;
      if (error instanceof SyntaxError) throw new Error('session_storage_corrupt');
      throw error;
    }
  }

  async function write(payload) {
    const snapshot = snapshotOf(payload);
    await mkdir(dirname(target), { recursive: true });
    const acquired = await acquireLock();
    if (!acquired) return { ok: false, error: 'session_storage_locked' };
    try {
      const current = await load();
      const currentRevision = revisionOf(current, true);
      if (currentRevision !== payload.base_revision) {
        return { ok: false, error: 'session_persist_conflict', revision: currentRevision };
      }
      const text = JSON.stringify(snapshot);
      let handle;
      try {
        handle = await open(temporary, 'w', 0o600);
        await handle.writeFile(text, 'utf8');
        await handle.sync();
        await handle.close();
        handle = undefined;
        await rename(temporary, target);
      } catch (error) {
        try { await handle?.close(); } catch {}
        try { await unlink(temporary); } catch (cleanup) { if (cleanup?.code !== 'ENOENT') {} }
        throw error;
      }
      return { ok: true, revision: snapshot.revision, format: snapshot.format, sha256: snapshot.sha256 };
    } finally {
      await releaseLock();
    }
  }

  async function acquireLock() {
    try {
      await createLock();
      return true;
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error;
    }
    let owner;
    try {
      owner = JSON.parse(await readFile(lockPath, 'utf8'));
    } catch {
      return false;
    }
    if (!Number.isInteger(owner?.pid) || owner.pid <= 0 || typeof owner.token !== 'string' || !owner.token) return false;
    try {
      process.kill(owner.pid, 0);
      return false;
    } catch (error) {
      if (error?.code !== 'ESRCH') return false;
    }
    try {
      await unlink(lockPath);
    } catch (error) {
      if (error?.code !== 'ENOENT') return false;
    }
    try {
      await createLock();
      return true;
    } catch (error) {
      if (error?.code === 'EEXIST') return false;
      throw error;
    }
  }

  async function createLock() {
    let handle;
    let created = false;
    try {
      handle = await open(lockPath, 'wx', 0o600);
      created = true;
      await handle.writeFile(JSON.stringify({ pid: process.pid, token: lockToken }), 'utf8');
      await handle.sync();
      await handle.close();
      handle = undefined;
    } catch (error) {
      try { await handle?.close(); } catch {}
      if (created) {
        try { await unlink(lockPath); } catch (cleanup) { if (cleanup?.code !== 'ENOENT') {} }
      }
      throw error;
    }
  }

  async function releaseLock() {
    try {
      const owner = JSON.parse(await readFile(lockPath, 'utf8'));
      if (owner?.pid === process.pid && owner?.token === lockToken) await unlink(lockPath);
    } catch (error) {
      if (error?.code !== 'ENOENT') {}
    }
  }

  function save(payload) {
    const result = queue.then(() => write(payload), () => write(payload));
    queue = result.then(() => undefined, () => undefined);
    return result;
  }

  return Object.freeze({ load, save });
}
