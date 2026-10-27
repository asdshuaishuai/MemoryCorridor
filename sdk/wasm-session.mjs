export const FORMAT = 'memorycorridor-wasm-snapshot-v1';

/**
 * Host session for the pure WASM planner. Files are UTF-8 text snapshots;
 * binary assets remain native-host responsibilities. The planner never sees
 * or mutates this Map, so compile failures cannot partially publish it.
 */
export function createWasmSession({ kernel, files = {}, compile = async () => {}, persist = null, revision: initialRevision = 0 }) {
  if (!kernel || typeof kernel.evaluate !== 'function') throw new TypeError('kernel.evaluate is required');
  if (!Number.isSafeInteger(initialRevision) || initialRevision < 0) throw new TypeError('revision must be a non-negative safe integer');
  if (persist !== null && typeof persist !== 'function') throw new TypeError('persist must be a function');
  validateFiles(files);
  const state = new Map(Object.entries(files));
  verifyInitialSnapshot(kernel, state);
  let revision = initialRevision;
  // Serialize asynchronous transactions on one session instance. Without a
  // queue, two callers can both pass the in-memory revision check while an
  // awaited compile or persist callback is still pending.
  let transactionTail = Promise.resolve();
  const snapshot = () => Object.fromEntries([...state.entries()].sort(([a], [b]) => a.localeCompare(b)));
  const rows = () => [...state.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([path, text]) => ({ path, text }));
  const failure = message => ({ ok: false, error: message });

  async function transact(changes) {
    if (!Array.isArray(changes)) return failure('session_changes_array_required');
    const baselineRevision = revision;
    const catalog = state.get('index.mbt.md');
    if (typeof catalog !== 'string') return failure('session_catalog_missing');
    const plan = kernel.evaluate({ op: 'session-plan', catalog, files: rows(), changes });
    if (!plan.ok) return plan;
    const candidate = new Map(state);
    for (const change of changes) {
      if (change.after === null) candidate.delete(change.path);
      else candidate.set(change.path, change.after);
    }
    let compilingPath = 'unknown';
    try {
      // Compile declarations before touching the host snapshot. A callback may
      // return false or {ok:false,error}; either form is a hard refusal.
      for (const change of [...changes].sort((a, b) => a.path.localeCompare(b.path))) {
        compilingPath = change.path;
        if (change.after !== null && change.path.endsWith('.mbt.md')) {
          const result = await compile(change.path, change.after);
          if (result === false || (result && result.ok === false)) {
            return failure('session_compile_failed: ' + change.path);
          }
        }
      }
    } catch (error) {
      return failure('session_compile_failed: ' + compilingPath + ': ' + String(error?.message || error));
    }
    if (revision !== baselineRevision) return failure('session_snapshot_changed');
    for (const change of changes) {
      const actual = state.has(change.path) ? state.get(change.path) : null;
      if (actual !== change.before) return failure('session_write_conflict: ' + change.path);
    }
    if (persist) {
      try {
        const nextRevision = revision + 1;
        const envelope = await snapshotEnvelope(nextRevision, candidate);
        const saved = await persist({
          format: envelope.format,
          base_revision: baselineRevision,
          revision: nextRevision,
          files: envelope.files,
          sha256: envelope.sha256,
        });
        if (saved === false) return failure('session_persist_failed');
        if (saved && saved.ok === false) return failure(saved.error || 'session_persist_failed');
        if (saved && typeof saved === 'object') {
          if (Object.prototype.hasOwnProperty.call(saved, 'revision') &&
              (!Number.isSafeInteger(saved.revision) || saved.revision !== nextRevision)) {
            return failure('session_persist_conflict');
          }
          if (Object.prototype.hasOwnProperty.call(saved, 'format') && saved.format !== envelope.format) {
            return failure('session_persist_conflict');
          }
          if (Object.prototype.hasOwnProperty.call(saved, 'sha256') && saved.sha256 !== envelope.sha256) {
            return failure('session_persist_conflict');
          }
        }
      } catch (error) {
        return failure('session_persist_failed: ' + String(error?.message || error));
      }
    }
    // Publish knowledge files first and the catalog last, matching native
    // recovery semantics. Map updates are synchronous once all checks pass.
    for (const change of changes.filter(change => change.path !== 'index.mbt.md')) {
      if (change.after === null) state.delete(change.path); else state.set(change.path, change.after);
    }
    const indexChange = changes.find(change => change.path === 'index.mbt.md');
    if (indexChange) state.set(indexChange.path, indexChange.after);
    revision += 1;
    return { ok: true, result: { ...plan.result, revision, files: snapshot() } };
  }

  function enqueue(changes) {
    const result = transactionTail.then(() => transact(changes));
    // A failed transaction must not poison the queue for later retries.
    transactionTail = result.then(() => undefined, () => undefined);
    return result;
  }

  return Object.freeze({
    snapshot,
    async execute(request) {
      if (!request || typeof request !== 'object') return failure('session_request_object_required');
      if (request.op === 'snapshot') return { ok: true, result: { revision, files: snapshot() } };
      if (request.op === 'transaction') return enqueue(request.changes);
      if (request.op === 'plan') {
        const catalog = state.get('index.mbt.md');
        if (typeof catalog !== 'string') return failure('session_catalog_missing');
        return kernel.evaluate({ op: 'session-plan', catalog, files: rows(), changes: request.changes });
      }
      return failure('unsupported_session_operation');
    },
  });
}

function persisted(value) {
  if (!value || typeof value !== 'object' || !Number.isSafeInteger(value.revision) || value.revision < 0 ||
      !value.files || typeof value.files !== 'object' || Array.isArray(value.files)) {
    throw new TypeError('invalid persisted WASM session');
  }
  validateFiles(value.files);
  if (value.format !== undefined && value.format !== FORMAT) {
    throw new TypeError('unsupported persisted WASM session format');
  }
  if (value.sha256 !== undefined &&
      (typeof value.sha256 !== 'string' || !/^[0-9a-f]{64}$/.test(value.sha256))) {
    throw new TypeError('invalid persisted WASM session hash');
  }
  return value;
}

export function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') {
    return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  }
  return JSON.stringify(value);
}

export async function sha256(text) {
  if (!globalThis.crypto?.subtle || typeof TextEncoder !== 'function') {
    throw new Error('web_crypto_required');
  }
  const digest = await globalThis.crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

async function snapshotEnvelope(revision, files) {
  const entries = files instanceof Map ? [...files.entries()] : Object.entries(files);
  const normalized = Object.fromEntries(entries.sort(([a], [b]) => a.localeCompare(b)));
  const body = { format: FORMAT, revision, files: normalized };
  return { ...body, sha256: await sha256(canonical(body)) };
}

async function verifyPersisted(value) {
  const checked = persisted(value);
  if (checked.sha256 !== undefined) {
    const expected = await snapshotEnvelope(checked.revision, checked.files);
    if (checked.format !== expected.format || checked.sha256 !== expected.sha256) {
      throw new Error('session_snapshot_hash_mismatch');
    }
  }
  return checked;
}

export function validateFiles(files) {
  if (!files || typeof files !== 'object' || Array.isArray(files)) throw new TypeError('files must be an object');
  for (const [path, text] of Object.entries(files)) {
    if (!path || typeof text !== 'string' || path.startsWith('/') || path.includes('\\') || path.includes(':') ||
        path.includes('\0') || path.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new TypeError('invalid session file: ' + path);
    }
  }
}

function verifyInitialSnapshot(kernel, state) {
  const catalog = state.get('index.mbt.md');
  if (typeof catalog !== 'string') return;
  const verification = kernel.evaluate({
    op: 'session-verify', catalog,
    files: [...state.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([path, text]) => ({ path, text })),
  });
  if (!verification.ok) throw new Error(verification.error);
}

export async function restoreWasmSession({ kernel, storage, compile = async () => {} }) {
  if (!kernel || typeof kernel.evaluate !== 'function') throw new TypeError('kernel.evaluate is required');
  if (!storage || typeof storage.load !== 'function' || typeof storage.save !== 'function') {
    throw new TypeError('storage.load and storage.save are required');
  }
  const value = await verifyPersisted(await storage.load());
  const catalog = value.files['index.mbt.md'];
  if (typeof catalog !== 'string') throw new Error('session_catalog_missing');
  const verification = kernel.evaluate({
    op: 'session-verify', catalog,
    files: Object.entries(value.files).sort(([a], [b]) => a.localeCompare(b)).map(([path, text]) => ({ path, text })),
  });
  if (!verification.ok) throw new Error(verification.error);
  return createWasmSession({ kernel, files: value.files, revision: value.revision, compile, persist: payload => storage.save(payload) });
}
