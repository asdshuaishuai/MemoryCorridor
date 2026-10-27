test "both path whitelists read the shared record directory list" {
  // The transaction whitelist and the pack whitelist consume one list, so a
  // record directory can never be writable but unpackable, or vice versa.
  for directory in @core.state_directories() {
    let path = directory + "/" + "0".repeat(64) + ".json"
    ignore(validate_change_path(path))
    // Recovery history is not a record directory but is still packable.
    ignore(validate_change_path("state/transactions/history/" + "0".repeat(64) + ".json"))
  }
  // Paths outside every whitelist are refused.
  for refused in ["state/unknown/x.json", "state/transactions/pending.json",
                  "state/memory", "state/memory/", "vectors/../escape.json",
                  "wiki/../../etc/passwd", "raw/../state/memory/x.json"] {
    let failed = try { ignore(validate_change_path(refused)); false } catch { _ => true }
    assert_true(failed)
  }
  // The known non-record locations stay allowed.
  for allowed in ["purpose.md", "wiki/index.md", "wiki/log.md", "vectors/abc.json"] {
    ignore(validate_change_path(allowed))
  }
  // A record path must sit under a directory, not equal it.
  let bare = try { ignore(validate_change_path("state/memory")); false } catch { _ => true }
  assert_true(bare)
}
