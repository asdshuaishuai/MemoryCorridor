// The recovery-history whitelist must read the same shared record-directory
// list the transaction whitelist reads: the engine writes history journals
// covering state/memory and state/impacts commits, so a vault that survived an
// interrupt must stay unpackable from its own backup.
fn recovery_history(path : String) -> String {
  let purpose = "研究目标\n"
  let entries : Array[@core.Entry] = [
    { id: "purpose.md", path: "purpose.md", kind: "purpose", format: "markdown",
      sha256: @base.hex_hash(purpose), sources: [], stale: false },
  ]
  let index = @decl.generate(entries)
  let value : Json = {
    "version": 1, "direction": "forward",
    "journal": { "version": 1, "old_index": index, "new_index": index,
      "changes": [{ "path": path, "before": Json::null(), "after": "{}" }] },
  }
  @base.canonical(value)
}

test "recovery history accepts every committed record directory" {
  for directory in @core.state_directories() {
    validate_recovery_history(recovery_history(directory + "/" + "0".repeat(64) + ".json"))
  }
  validate_recovery_history(recovery_history("state/transactions/history/" + "0".repeat(64) + ".json"))
  validate_recovery_history(recovery_history("purpose.md"))
  validate_recovery_history(recovery_history("wiki/concepts/x.md"))
  validate_recovery_history(recovery_history("vectors/space.json"))
  for refused in ["state/unknown/x.json", "state/transactions/pending.json", "raw/leak.md"] {
    assert_true(try { validate_recovery_history(recovery_history(refused)); false } catch { _ => true })
  }
}
