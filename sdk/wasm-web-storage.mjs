// Browser/Worker persistence adapter for sdk/wasm-session.mjs.
// Web Locks provides the cross-tab/process critical section; without it a
// localStorage implementation cannot make the revision check and write one
// atomic operation, so writes fail explicitly.

import { canonical, sha256, validateFiles, FORMAT } from './wasm-session.mjs';

export function createWebWasmStorage({ key, storage = globalThis.localStorage, locks = globalThis.navigator?.locks } = {}) {
  if (typeof key !== 'string' || key.length === 0 || key.includes('\0')) {
    throw new TypeError('storage key must be a non-empty string');
  }
  if (!storage || typeof storage.getItem !== 'function' || typeof storage.setItem !== 'function') {
    throw new TypeError('storage must implement getItem/setItem');
  }

  async function load() {
    const text = storage.getItem(key);
    if (text === null) return null;
    try {
      return JSON.parse(text);
    } catch {
      throw new Error('session_storage_corrupt');
    }
  }

  async function save(payload) {
    const snapshot = await checkedSnapshot(payload);
    if (!locks || typeof locks.request !== 'function') {
      return { ok: false, error: 'session_storage_lock_unavailable' };
    }
    let outcome;
    try {
      await locks.request(`memorycorridor:${key}`, { mode: 'exclusive' }, async () => {
        const current = await load();
        const currentRevision = revisionOf(current);
        if (currentRevision !== payload.base_revision) {
          outcome = { ok: false, error: 'session_persist_conflict', revision: currentRevision };
          return;
        }
        storage.setItem(key, JSON.stringify(snapshot));
        outcome = { ok: true, revision: snapshot.revision, format: snapshot.format, sha256: snapshot.sha256 };
      });
    } catch (error) {
      if (error?.message === 'session_storage_corrupt') throw error;
      return { ok: false, error: 'session_storage_write_failed' };
    }
    return outcome || { ok: false, error: 'session_storage_write_failed' };
  }

  return Object.freeze({ load, save });
}

async function checkedSnapshot(payload) {
  if (!payload || typeof payload !== 'object' || !Number.isSafeInteger(payload.revision) || payload.revision < 0 ||
      !Number.isSafeInteger(payload.base_revision) || payload.base_revision < 0 || payload.format !== FORMAT ||
      !payload.files || typeof payload.files !== 'object' || Array.isArray(payload.files) ||
      typeof payload.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(payload.sha256)) {
    throw new TypeError('invalid session persistence payload');
  }
  const files = Object.fromEntries(Object.entries(payload.files).sort(([a], [b]) => a.localeCompare(b)));
  validateFiles(files);
  const body = { format: FORMAT, revision: payload.revision, files };
  if (await sha256(canonical(body)) !== payload.sha256) throw new Error('session_snapshot_hash_mismatch');
  return { ...body, sha256: payload.sha256 };
}

function revisionOf(value) {
  if (value === null) return 0;
  if (!value || typeof value !== 'object' || !Number.isSafeInteger(value.revision) || value.revision < 0) {
    throw new Error('session_storage_corrupt');
  }
  return value.revision;
}

