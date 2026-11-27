// Native-only extraction bridge.
//
// `context` has already verified the order, the source digest and the active
// extraction state. When it still reports extraction_required, the native host
// runs the locally installed OCR/PDF adapter, checks the adapter's source
// digest against the booked one, books the text through the existing
// `extraction-submit` op, and re-runs `context` so the caller receives the
// source text directly. The agent/core packages stay model-free; WASM faces
// never reach this file. Every failure returns the original context response:
// no partial sidecar and no changed protocol.

fn ocr_request(
  store : @vault.Storage, source : String, source_hash : String, output : String,
  cached_catalog : String?,
) -> Bool {
  let payload = try Some(@base.parse(output)) catch { _ => None }
  let value = match payload {
    None => return false
    Some(value) => value
  }
  let reported_hash = try @base.text(@base.field(value, "sha256")) catch {
    _ => return false
  }
  // The adapter hashes the bytes it read. Requiring the booked digest here is
  // what makes a stale, symlinked or substituted file a refusal rather than a
  // sidecar that claims to describe the registered source.
  if reported_hash != source_hash { return false }
  let text = try @base.text(@base.field(value, "text")) catch { _ => return false }
  if text == "" || text.contains_char('\r') { return false }
  if @utf8.encode(text).length() > 1048576 { return false }
  let kind = try @base.text(@base.field(value, "kind")) catch { _ => return false }
  if kind == "" { return false }
  let origin = try @base.text(@base.field(value, "source")) catch { _ => return false }
  let extractor = if origin == "text-layer" {
    "lopdf"
  } else if origin == "ocr" {
    "ppocrv4-mobile-ocr-rs"
  } else {
    return false
  }
  let at = try @platform.now_utc() catch { _ => return false }
  let request : Json = {
    "op": "extraction-submit", "source": source, "kind": kind,
    "extractor": extractor, "version": "1", "text": text, "at": at,
  }
  // `cached_catalog` is still the pre-submit catalog; submit appends the
  // sidecar and event through the normal transactional path.
  let _ = try @agent.dispatch_with_catalog(store, request, cached_catalog) catch {
    _ => return false
  }
  true
}

/// Post-context hook. Returns the original response unless the adapter output
/// passed every binding check and the fresh context can serve the sidecar.
pub fn ocr_after_context(
  store : @vault.Storage, request : Json, value : Json, cached_catalog : String?,
) -> Json {
  let required = try @base.boolean(@base.field(value, "extraction_required")) catch {
    _ => false
  }
  if !required { return value }
  let order = try Some(@base.field(value, "order")) catch { _ => None }
  let order = match order {
    None => return value
    Some(order) => order
  }
  let source = try @base.text(@base.field(order, "source")) catch { _ => return value }
  let source_hash = try @base.text(@base.field(order, "source_hash")) catch {
    _ => return value
  }
  let (status, output) = try @platform.ocr(source) catch { _ => (-1, "") }
  if status != 0 {
    // Adapter absence/failure is a normal fallback. The caller still sees
    // extraction_required and can use extraction-submit itself.
    return value
  }
  if !ocr_request(store, source, source_hash, output, cached_catalog) { return value }
  // Re-read the catalog after the submit; using the old parsed catalog here
  // would hide the new sidecar entry from context's sidecar_for lookup.
  try @agent.dispatch_with_catalog(store, request, None) catch { _ => value }
}

fn is_ocr_source(source : String) -> Bool {
  let lower = source.to_lower()
  [".pdf", ".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff"]
    .iter()
    .any(suffix => lower.has_suffix(suffix))
}

/// Import-time scheduling: scan creates one order per changed raw source. The
/// native host runs OCR/PDF extraction only for the imported file types that
/// need it, so a later context already sees the sidecar. Textual/office/html
/// sources never enter this loop. Failure is silent (the context hook can
/// still retry); the scan response itself is unchanged.
pub fn ocr_after_scan(store : @vault.Storage, value : Json) -> Json {
  let orders = try @base.array(@base.field(value, "orders")) catch { _ => return value }
  let mut applied = false
  for order_id in orders {
    let id = try @base.text(order_id) catch { _ => continue }
    let order = try @agent.load_order(store, id) catch { _ => continue }
    if !is_ocr_source(order.source) { continue }
    let (status, output) = try @platform.ocr(order.source) catch { _ => (-1, "") }
    if status != 0 { continue }
    if ocr_request(store, order.source, order.source_hash, output, None) { applied = true }
  }
  if !applied { return value }
  // scan/refresh computed their fingerprint before this hook booked sidecars.
  // Return the post-intake fingerprint so a caller cannot anchor the next
  // request on a baseline that no longer matches the vault.
  let current = try @agent.dispatch_with_catalog(store, { "op": "fingerprints" }, None) catch {
    _ => return value
  }
  let fingerprint = try @base.text(@base.field(current, "vault")) catch { _ => return value }
  let orders = try @base.field(value, "orders") catch { _ => return value }
  { "orders": orders, "fingerprint": fingerprint.to_json() }
}
