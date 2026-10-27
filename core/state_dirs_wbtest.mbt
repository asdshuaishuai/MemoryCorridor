test "every record directory has a validation branch" {
  // A durable-work kind registered in the shared list but missing from
  // `validate_record` would be accepted by the transaction and pack whitelists
  // yet never validated, so its content could drift unnoticed.
  let directories = state_directories()
  assert_eq(directories.length(), 11)
  let entry = (path : String) => {
    { id: path, path, kind: "state", format: "json", sha256: "0".repeat(64),
      sources: [], stale: false }
  }
  for directory in directories {
    let path = directory + "/" + "0".repeat(64) + ".json"
    let outcome = try {
      ignore(validate_record(entry(path), "{}"))
      "accepted"
    } catch {
      @base.Fault(message) => message
    }
    // Reaching a branch means the record failed on its content, not on its path.
    assert_true(outcome != "state_record_path_unsupported")
  }
  // A directory outside the list is still refused by name.
  let unknown = "state/unknown/" + "0".repeat(64) + ".json"
  let refused = try {
    ignore(validate_record(entry(unknown), "{}"))
    "accepted"
  } catch {
    @base.Fault(message) => message
  }
  assert_eq(refused, "state_record_path_unsupported")
}
