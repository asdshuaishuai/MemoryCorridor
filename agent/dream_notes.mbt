// Dream notes (companion memory 2.5): the ledger of what a dream distilled.
//
// A note is a proposal, never a second source of truth. Knowledge changes still
// go through the ordinary two-step commit, and memory changes still go through
// memory-submit/supersede/promote. The note records the inputs it read, the
// claims it wants to carry, and — once the host applied it — the exact page or
// memory record that now embodies it. The engine never writes wiki pages or
// memory records from here and never calls a model.

fn dream_note_path(id : String) -> String {
  "state/dream-notes/" + id + ".json"
}

fn dream_note_rows(store : @vault.Storage, entries : Array[@core.Entry]) -> Array[Json] raise @base.Fault {
  let rows : Array[Json] = []
  for entry in entries {
    if entry.kind == "state" && entry.path.has_prefix("state/dream-notes/") {
      rows.push(@base.parse(@vault.required(store, entry.path)))
    }
  }
  rows
}

fn dream_note_workspace(store : @vault.Storage, request : Json) -> String? raise @base.Fault {
  match optional(request, "workspace") {
    None | Some(Null) => None
    Some(value) => {
      let workspace = @base.text(value)
      if !dream_hash_ok(workspace) { @base.fail("dream_workspace_invalid") }
      if (store.read)("state/workspaces/" + workspace + ".json") is None {
        @base.fail("memory_workspace_unknown: " + workspace + "; run workspace-open first")
      }
      Some(workspace)
    }
  }
}

fn dream_note_round(store : @vault.Storage, request : Json) -> String? raise @base.Fault {
  match optional(request, "round") {
    None | Some(Null) => None
    Some(value) => {
      let round = @base.text(value)
      if !dream_hash_ok(round) { @base.fail("dream_round_invalid") }
      if (store.read)(dream_path(round)) is None { @base.fail("dream_not_found: " + round) }
      Some(round)
    }
  }
}

fn dream_note_workspace_json(workspace : String?) -> Json {
  match workspace {
    None => Json::null()
    Some(value) => value.to_json()
  }
}

fn dream_note_inputs_request(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json, workspace : String?,
) -> Json raise @base.Fault {
  let inputs = match optional(request, "inputs") {
    None | Some(Null) => return { "pages": Json::array([]), "notes": Json::array([]) }
    Some(value) => value
  }
  @base.keys(inputs, ["pages", "notes"])
  let pages = match optional(inputs, "pages") {
    None | Some(Null) => []
    Some(value) => @base.strings(value)
  }
  let notes = match optional(inputs, "notes") {
    None | Some(Null) => []
    Some(value) => @base.strings(value)
  }
  if pages.length() > 64 || notes.length() > 128 { @base.fail("dream_note_inputs_invalid") }
  let page_ids = pages.copy()
  page_ids.sort_by(@base.compare)
  let page_rows : Array[Json] = []
  for id in page_ids {
    @base.path(id)
    let entry = @core.find(entries, id)
    if !@core.is_page(entry) || entry.stale { @base.fail("dream_note_page_not_active: " + id) }
    page_rows.push({ "id": id, "hash": entry.sha256 })
  }
  let note_ids = notes.copy()
  note_ids.sort_by(@base.compare)
  let note_rows : Array[Json] = []
  for id in note_ids {
    if !dream_hash_ok(id) { @base.fail("dream_note_note_invalid: " + id) }
    let workspace = match workspace {
      None => raise @base.Fault("dream_note_workspace_required")
      Some(value) => value
    }
    let note = memory_load(store, workspace, id)
    if note.status != "active" { @base.fail("dream_note_note_not_active: " + id) }
    note_rows.push({ "id": id, "hash": note.note_hash })
  }
  { "pages": page_rows.to_json(), "notes": note_rows.to_json() }
}

fn dream_note_claims_request(request : Json) -> Json raise @base.Fault {
  match optional(request, "claims") {
    None | Some(Null) => Json::array([])
    Some(value) => {
      if !(value is Array(_)) { raise @base.Fault("dream_note_claims_invalid") }
      for claim in @base.array(value) {
        @base.keys(claim, ["text", "evidence"])
      }
      value
    }
  }
}

pub fn dream_note_submit(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "workspace", "round", "kind", "title",
    "body", "inputs", "claims", "at"])
  let workspace = dream_note_workspace(store, request)
  let round = dream_note_round(store, request)
  match (round, workspace) {
    (Some(round_id), Some(workspace_id)) => {
      let round_row = @base.parse(@vault.required(store, dream_path(round_id)))
      match optional(round_row, "workspace") {
        Some(String(round_workspace)) => if round_workspace != workspace_id {
          @base.fail("dream_note_round_workspace_mismatch")
        }
        _ => ()
      }
    }
    _ => ()
  }
  let kind = @base.text(@base.field(request, "kind"))
  let title = @base.text(@base.field(request, "title"))
  let body = @base.text(@base.field(request, "body"))
  if title.is_empty() || title.length() > 256 || title.contains("\n") || title.contains("\r") {
    @base.fail("dream_note_title_invalid")
  }
  if body.is_empty() || body.length() > 8192 || body.contains("\r") {
    @base.fail("dream_note_body_invalid")
  }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  // Materialize hashes at submit time: a note whose input changed afterwards
  // must be visibly stale rather than silently rest on new bytes.
  let inputs = dream_note_inputs_request(store, entries, request, workspace)
  let claims = dream_note_claims_request(request)
  let workspace_json = dream_note_workspace_json(workspace)
  let round_json = match round {
    None => Json::null()
    Some(value) => value.to_json()
  }
  let content_hash = @core.dream_note_content_hash(workspace_json, round_json, kind, title,
    body, inputs, claims)
  let id = @core.dream_note_id(content_hash)
  let path = dream_note_path(id)
  match (store.read)(path) {
    Some(existing) => {
      let old = @base.parse(existing)
      return { "id": id, "path": path, "replayed": true, "status":
        @base.text(@base.field(old, "status")), "record": old }
    }
    None => ()
  }
  let record : Json = {
    "version": 1,
    "id": id,
    "workspace": workspace_json,
    "round": round_json,
    "at": at,
    "kind": kind,
    "title": title,
    "body": body,
    "inputs": inputs,
    "claims": claims,
    "status": "proposed",
    "target": Json::null(),
    "resolved_at": Json::null(),
    "content_hash": content_hash,
  }
  let content = @base.canonical(record)
  let event_path = "state/events/dream-note-submit-" + id + "-" + @base.hex_hash(at) + ".json"
  let event_content = @base.canonical({ "op": "dream-note-submit", "dream_note": id, "at": at })
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, [
    { path, before: None, after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "path": path, "replayed": false, "status": "proposed", "record": record,
    "event": event_path }
}

pub fn dream_note_list(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "workspace", "round", "status"])
  let workspace = dream_note_workspace(store, request)
  let round = dream_note_round(store, request)
  let status = match optional(request, "status") {
    None | Some(Null) => ""
    Some(value) => {
      let value = @base.text(value)
      if !["proposed", "retained", "rejected", "applied"].contains(value) {
        @base.fail("dream_note_status_invalid: " + value)
      }
      value
    }
  }
  let notes : Array[Json] = []
  for row in dream_note_rows(store, entries) {
    if workspace is Some(only) && @base.field(row, "workspace") != only.to_json() { continue }
    if round is Some(only) && @base.field(row, "round") != only.to_json() { continue }
    let row_status = @base.text(@base.field(row, "status"))
    if status != "" && row_status != status { continue }
    notes.push(row)
  }
  // Counts are over the filtered set, so a workspace-scoped view never leaks
  // another workspace's totals.
  let mut total = 0
  let mut proposed = 0
  let mut retained = 0
  let mut rejected = 0
  let mut applied = 0
  for row in notes {
    total = total + 1
    let row_status = @base.text(@base.field(row, "status"))
    if row_status == "proposed" { proposed = proposed + 1 }
    if row_status == "retained" { retained = retained + 1 }
    if row_status == "rejected" { rejected = rejected + 1 }
    if row_status == "applied" { applied = applied + 1 }
  }
  {
    "notes": notes.to_json(),
    "counts": { "total": total, "proposed": proposed, "retained": retained,
      "rejected": rejected, "applied": applied },
    "fingerprint": @vault.fingerprint(entries),
  }
}

fn dream_note_target_request(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
  workspace : String?,
) -> Json raise @base.Fault {
  @base.keys(request, ["kind", "id", "hash"])
  let kind = @base.text(@base.field(request, "kind"))
  if !["page", "memory"].contains(kind) { @base.fail("dream_note_target_kind_invalid") }
  let id = @base.text(@base.field(request, "id"))
  let hash = @base.text(@base.field(request, "hash"))
  if !dream_hash_ok(hash) { @base.fail("dream_note_target_hash_invalid") }
  if kind == "page" {
    @base.path(id)
    let entry = @core.find(entries, id)
    if !@core.is_page(entry) || entry.stale { @base.fail("dream_note_target_missing: " + id) }
    if entry.sha256 != hash { @base.fail("dream_note_target_drift: " + id) }
  } else {
    if !dream_hash_ok(id) { @base.fail("dream_note_target_id_invalid") }
    let workspace = match workspace {
      None => raise @base.Fault("dream_note_workspace_required")
      Some(value) => value
    }
    let note = memory_load(store, workspace, id)
    if note.status != "active" { @base.fail("dream_note_target_missing: " + id) }
    if note.note_hash != hash { @base.fail("dream_note_target_drift: " + id) }
  }
  { "kind": kind, "id": id, "hash": hash }
}

pub fn dream_note_resolve(
  store : @vault.Storage, entries : Array[@core.Entry], request : Json,
) -> Json raise @base.Fault {
  @vault.verify(store, entries)
  @base.keys(request, ["op", "vault", "request_id", "id", "status", "target", "at"])
  let id = @base.text(@base.field(request, "id"))
  if !dream_hash_ok(id) { @base.fail("dream_note_id_invalid") }
  let path = dream_note_path(id)
  let text = match (store.read)(path) {
    None => { @base.fail("dream_note_not_found: " + id); "" }
    Some(value) => value
  }
  let record = @base.parse(text)
  let status = @base.text(@base.field(request, "status"))
  if !["retained", "rejected", "applied"].contains(status) {
    @base.fail("dream_note_status_invalid: " + status)
  }
  let at = @base.text(@base.field(request, "at"))
  dream_time(at)
  let workspace = match @base.field(record, "workspace") {
    Null => None
    String(value) => Some(value)
    _ => raise @base.Fault("dream_note_workspace_invalid")
  }
  let target = if status == "applied" {
    match optional(request, "target") {
      None | Some(Null) => raise @base.Fault("dream_note_target_required")
      Some(value) => dream_note_target_request(store, entries, value, workspace)
    }
  } else {
    match optional(request, "target") {
      None | Some(Null) => Json::null()
      Some(_) => raise @base.Fault("dream_note_target_unexpected")
    }
  }
  let old_status = @base.text(@base.field(record, "status"))
  if old_status != "proposed" {
    let same = old_status == status && @base.field(record, "resolved_at") == at.to_json() &&
      @base.field(record, "target") == target
    if same {
      return { "id": id, "status": status, "replayed": true, "record": record }
    }
    @base.fail("dream_note_terminal: " + id)
  }
  if @base.compare(at, @base.text(@base.field(record, "at"))) < 0 {
    @base.fail("dream_note_resolve_order_invalid")
  }
  let updated : Json = match record {
    Object(fields) => {
      let copy = fields.copy()
      copy["status"] = status.to_json()
      copy["resolved_at"] = at.to_json()
      copy["target"] = target
      Json::object(copy)
    }
    other => other
  }
  let content = @base.canonical(updated)
  let event_path = "state/events/dream-note-resolve-" + id + "-" +
    @base.hex_hash(status + "\n" + at) + ".json"
  let event_content = @base.canonical({ "op": "dream-note-resolve", "dream_note": id,
    "status": status, "at": at })
  let next = upsert(upsert(entries, { id: path, path, kind: "state", format: "json",
    sha256: @base.hex_hash(content), sources: [], stale: false }),
    { id: event_path, path: event_path, kind: "state", format: "json",
      sha256: @base.hex_hash(event_content), sources: [], stale: false })
  @vault.commit(store, @vault.fingerprint(entries), next, [
    { path, before: Some(text), after: Some(content) },
    { path: event_path, before: None, after: Some(event_content) },
  ])
  { "id": id, "status": status, "replayed": false, "record": updated, "event": event_path }
}

// ---- workspace memory inside a dream round ---------------------------------

fn dream_memory_rows(
  store : @vault.Storage, entries : Array[@core.Entry], workspace : String,
) -> Array[MemoryNote] raise @base.Fault {
  memory_entries(entries, workspace)
    .map(e => memory_from_json(@base.parse(@vault.required(store, e.path))))
}

fn dream_memory_metrics(
  store : @vault.Storage, entries : Array[@core.Entry], workspace : String, at : String,
) -> Json raise @base.Fault {
  let rows = dream_memory_rows(store, entries, workspace)
  let active = rows.filter(n => n.status == "active")
  // A round is opened for a workspace, not for one conversation. Debt that can
  // only be resolved with a live session id is counted separately but never
  // gates retention, or every closed session would look like a regression.
  let project = active.filter(n => n.scope == "project")
  let conflicted = memory_conflicted(project)
  let candidates = memory_candidates(store, entries, { "workspace": workspace, "now": at })
  {
    "active": active.length(),
    "session": active.filter(n => n.scope == "session").length(),
    "conflicted": conflicted.keys().length(),
    "invalid": project.filter(n => !invalid_memory_sources(n, entries).is_empty()).length(),
    "drifted": project.filter(n => !drifted_memory_sources(n, entries).is_empty()).length(),
    "episodes": project.filter(n => n.layer == "episode").length(),
    "profiles": project.filter(n => n.layer == "profile").length(),
    "prune": @base.array(@base.field(candidates, "prune")).length(),
  }
}

fn dream_memory_value(row : Json, field : String) -> Int {
  match optional(row, field) {
    Some(Number(n, ..)) => n.to_int()
    _ => 0
  }
}

fn dream_memory_delta(base : Json, current : Json) -> Json {
  {
    "active": (dream_memory_value(current, "active") - dream_memory_value(base, "active")).to_json(),
    "session": (dream_memory_value(current, "session") - dream_memory_value(base, "session")).to_json(),
    "conflicted": (dream_memory_value(current, "conflicted") - dream_memory_value(base, "conflicted")).to_json(),
    "invalid": (dream_memory_value(current, "invalid") - dream_memory_value(base, "invalid")).to_json(),
    "drifted": (dream_memory_value(current, "drifted") - dream_memory_value(base, "drifted")).to_json(),
    "episodes": (dream_memory_value(current, "episodes") - dream_memory_value(base, "episodes")).to_json(),
    "profiles": (dream_memory_value(current, "profiles") - dream_memory_value(base, "profiles")).to_json(),
    "prune": (dream_memory_value(current, "prune") - dream_memory_value(base, "prune")).to_json(),
  }
}

fn dream_memory_compatible(base : Json, current : Json) -> Unit raise @base.Fault {
  for field in ["conflicted", "invalid", "drifted", "prune"] {
    if dream_memory_value(current, field) > dream_memory_value(base, field) {
      @base.fail("dream_compat_memory_regression: " + field)
    }
  }
}

fn dream_memory_opportunities(
  store : @vault.Storage, entries : Array[@core.Entry], workspace : String, at : String,
) -> Array[Json] raise @base.Fault {
  let rows = dream_memory_rows(store, entries, workspace)
  let active = rows.filter(n => n.status == "active" && n.scope == "project")
  let conflicted = memory_conflicted(active)
  let rows_out : Array[(Int, String, String, Json)] = []
  let seen : Map[String, Bool] = Map([])
  let add = (kind : String, subject : String, detail : String) => {
    let key = kind + "\n" + subject
    if !seen.contains(key) {
      seen[key] = true
      rows_out.push((dream_kind_priority(kind), kind, subject, {
        "kind": kind, "id": subject, "detail": detail
      }))
    }
  }
  let candidates = memory_candidates(store, entries, { "workspace": workspace, "now": at })
  for row in @base.array(@base.field(candidates, "merge")) {
    let duplicate = @base.text(@base.field(row, "duplicate"))
    let keeper = @base.text(@base.field(row, "keeper"))
    add("memory_merge", duplicate, "merge into " + keeper)
  }
  for row in @base.array(@base.field(candidates, "prune")) {
    add("memory_prune", @base.text(@base.field(row, "id")),
      "weak strength (" + @base.canonical(@base.field(row, "strength")) + "); archive only after review")
  }
  for group in memory_conflict_groups(active) {
    add("memory_conflict", group[0].id, "competing judgments: " +
      group.map(n => n.id).join(", "))
  }
  for note in active {
    if conflicted.get(note.id).unwrap_or(false) { continue }
    if !invalid_memory_sources(note, entries).is_empty() ||
      !drifted_memory_sources(note, entries).is_empty() {
      add("memory_source_stale", note.id, "bound source was revoked or rewritten")
      continue
    }
    if note.layer != "episode" && (note.importance.unwrap_or(0.0) >= 0.7 ||
      memory_intensity(note) >= 0.7) {
      add("memory_promote", note.id, "importance or emotion intensity reaches 0.7")
    }
  }
  rows_out.sort_by((a, b) => if a.0 != b.0 { a.0 - b.0 } else {
    let order = @base.compare(a.1, b.1)
    if order != 0 { order } else { @base.compare(a.2, b.2) }
  })
  rows_out.map(row => row.3)
}
