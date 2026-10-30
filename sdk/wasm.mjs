/**
 * Stateless pure kernels only; disk transactions and literate compilation stay
 * in a host (native adapter or hosts/wasm-host.py). The corridor-host stubs
 * keep the service-capable wasm target instantiable here; the pure face never
 * calls them.
 */
const corridorHostStubs = Object.fromEntries(
  ['storage_read', 'storage_write', 'storage_mkdir', 'storage_remove',
   'storage_list', 'storage_check', 'storage_lock', 'storage_unlock',
   'sock_recv', 'sock_send']
    .map(name => [name, () => -1]));

export async function loadCorridor(bytes) {
  const { instance } = await WebAssembly.instantiate(bytes, { 'corridor-host': corridorHostStubs });
  const api = instance.exports;
  const encoder = new TextEncoder();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  return Object.freeze({
    evaluate(request) {
      const input = encoder.encode(JSON.stringify(request));
      if (input.length > 2097152) throw new RangeError('input exceeds 2 MiB');
      api.input_reset();
      for (const byte of input) {
        if (api.input_push(byte) !== 0) throw new Error('input refused');
      }
      const length = api.execute();
      const output = new Uint8Array(length);
      for (let i = 0; i < length; i++) output[i] = api.output_byte(i);
      return JSON.parse(decoder.decode(output));
    },
  });
}
