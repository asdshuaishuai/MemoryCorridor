priv struct QualityIssue {
  predicate : String
  subject : String
  page : String
  source : String
  reason : String
}

fn quality_source(entries : Array[@core.Entry], page : String) -> String raise @base.Fault {
  let entry = @core.find(entries, page)
  if !entry.sources.is_empty() { return entry.sources[0] }
  for source in entries {
    if source.kind == "raw" && !source.stale { return source.id }
  }
  @base.fail("quality_source_missing: " + page)
  ""
}

fn page_has_valid_evidence(
  store : @vault.Storage, entries : Array[@core.Entry], page : String,
) -> Bool raise @base.Fault {
  let rows = @base.array(evidence_for_page_checked(store, entries, page))
  rows.any(row => @base.boolean(@base.field(row, "valid")))
}

fn quality_issues(
  store : @vault.Storage, entries : Array[@core.Entry], graph_value : @index.Graph,
) -> Array[QualityIssue] raise @base.Fault {
  let insight = @index.insights(graph_value)
  let evidence = evidence_stats(store, entries)
  let coverage = @base.field(evidence, "coverage")
  let coverage_pages = @base.array(@base.field(coverage, "pages"))
  let issues : Array[QualityIssue] = []
  for value in @base.strings(@base.field(insight, "orphans")) {
    let source = quality_source(entries, value)
    issues.push({ predicate: "orphan_page", subject: value, page: value, source,
      reason: "质量门：孤儿页，当前图中邻居不超过一个：" + value })
  }
  for value in @base.array(@base.field(insight, "sparse_tags")) {
    @base.keys(value, ["tag", "density", "pages"])
    let tag = @base.text(@base.field(value, "tag"))
    let pages = @base.strings(@base.field(value, "pages"))
    if pages.is_empty() { continue }
    let page = pages[0]
    let source = quality_source(entries, page)
    issues.push({ predicate: "sparse_tag", subject: tag, page, source,
      reason: "质量门：标签内互链稀疏：" + tag })
  }
  // A scanned source with no active page dependency is structurally visible
  // but has not entered the knowledge graph yet. This is a HumanGate signal,
  // not a judgment about the source's factual quality.
  for row in @base.array(@base.field(coverage, "sources")) {
    @base.keys(row, ["source", "active", "claims", "valid_claims", "exact_source_claims", "legacy_source_claims", "invalid_source_claims", "pages", "direct_pages", "stale_direct_pages", "support", "provenance", "basis"])
    let source = @base.text(@base.field(row, "source"))
    if @base.boolean(@base.field(row, "active")) && @base.strings(@base.field(row, "direct_pages")).is_empty() {
      issues.push({ predicate: "unreferenced_source", subject: source, page: source, source,
        reason: "质量门：来源已登记但没有活跃知识页依赖：" + source })
    }
  }
  // Evidence is an optional sidecar, so missing evidence remains a HumanGate
  // debt rather than a structural commit failure. Source-summary pages are
  // deterministic navigation fallbacks and do not need semantic claims.
  for node in graph_value.nodes {
    if ["concept", "entity", "synthesis"].contains(node.kind) &&
      !page_has_valid_evidence(store, entries, node.id) {
      let source = quality_source(entries, node.id)
      issues.push({ predicate: "missing_evidence", subject: node.id, page: node.id, source,
        reason: "质量门：页面没有可核对的有效事实证据：" + node.id })
    }
  }
  // A valid claim can still leave most of a page unsupported. This remains a
  // HumanGate signal: byte coverage is measurable, semantic entailment is not.
  for row in coverage_pages {
    @base.keys(row, ["page", "stale", "body_bytes", "claims", "valid_claims", "exact_source_claims", "legacy_source_claims", "invalid_source_claims", "covered_bytes", "coverage_basis_points", "overlap_claims", "complete", "provenance"])
    let page = @base.text(@base.field(row, "page"))
    let entry = @core.find(entries, page)
    let valid_claims = match @base.field(row, "valid_claims") {
      Number(n, ..) => n.to_int()
      _ => 0
    }
    let exact_source_claims = match @base.field(row, "exact_source_claims") {
      Number(n, ..) => n.to_int()
      _ => 0
    }
    let legacy_source_claims = match @base.field(row, "legacy_source_claims") {
      Number(n, ..) => n.to_int()
      _ => 0
    }
    let invalid_source_claims = match @base.field(row, "invalid_source_claims") {
      Number(n, ..) => n.to_int()
      _ => 0
    }
    if ["concept", "entity", "synthesis"].contains(entry.kind) && valid_claims > 0 &&
      legacy_source_claims > 0 && exact_source_claims == 0 {
      let source = quality_source(entries, page)
      issues.push({ predicate: "legacy_evidence_anchor", subject: page, page, source,
        reason: "质量门：页面证据仍使用未核验 raw 原文区间的 legacy 锚点：" + page })
    }
    if ["concept", "entity", "synthesis"].contains(entry.kind) && invalid_source_claims > 0 {
      let source = quality_source(entries, page)
      issues.push({ predicate: "invalid_evidence_anchor", subject: page, page, source,
        reason: "质量门：页面证据的 raw 原文锚点已漂移、撤销或无法核验：" + page })
    }
    let complete = @base.boolean(@base.field(row, "complete"))
    if ["concept", "entity", "synthesis"].contains(entry.kind) && valid_claims > 0 && !complete {
      let body_bytes = match @base.field(row, "body_bytes") {
        Number(n, ..) => n.to_int()
        _ => 0
      }
      let covered_bytes = match @base.field(row, "covered_bytes") {
        Number(n, ..) => n.to_int()
        _ => 0
      }
      let source = quality_source(entries, page)
      issues.push({ predicate: "evidence_coverage_gap", subject: page, page, source,
        reason: "质量门：有效证据仅覆盖页面正文 " + covered_bytes.to_string() + "/" + body_bytes.to_string() + " 个 UTF-8 字节：" + page })
    }
  }
  issues.sort_by((a, b) => {
    let first = @base.compare(a.predicate, b.predicate)
    if first != 0 { first } else { @base.compare(a.subject, b.subject) }
  })
  issues
}

fn quality_issue_json(issue : QualityIssue) -> Json {
  { "predicate": issue.predicate, "subject": issue.subject, "page": issue.page,
    "source": issue.source, "reason": issue.reason }
}

pub fn quality_baseline(entries : Array[@core.Entry]) -> String {
  // Quality findings are derived from knowledge inputs only. Review decisions,
  // event history, vectors and provider state must not create a new finding.
  let inputs = entries.filter(e => e.kind == "raw" || e.kind == "purpose" || @core.is_page(e) ||
    (e.kind == "state" && e.path.has_prefix("state/evidence/")))
  @vault.fingerprint(inputs)
}

pub fn quality_audit(store : @vault.Storage, entries : Array[@core.Entry], request : Json) -> Json raise @base.Fault {
  let at = @base.text(@base.field(request, "at"))
  review_at(at, "at")
  let current_fingerprint = @vault.fingerprint(entries)
  // Review records and this operation's own events must not move the input
  // snapshot, otherwise an identical audit would create duplicate debt.
  let baseline = quality_baseline(entries)
  let graph_value = graph(store, entries)
  let issues = quality_issues(store, entries, graph_value)
  let audit_id = @base.hex_hash("quality-audit\n" + at + "\n" + baseline)
  let event_path = "state/events/quality-audit-" + audit_id + ".json"
  if entries.any(e => e.path == event_path) {
    return { "id": audit_id, "issues": issues.map(quality_issue_json).to_json(),
      "created": Json::array([]), "replayed": true, "fingerprint": baseline }
  }
  let mut next = entries.copy()
  let changes : Array[@vault.Change] = []
  let created : Array[String] = []
  let quality_order = @base.hex_hash("quality-order\n" + audit_id)
  for issue in issues {
    let id = @base.hex_hash("quality-review\n" + baseline + "\n" + issue.predicate + "\n" + issue.subject)
    let path = "state/reviews/" + id + ".json"
    if next.any(e => e.path == path) { continue }
    if (store.read)(path) is Some(_) { @base.fail("quality_review_conflict: " + path) }
    let review : Json = { "id": id, "order": quality_order,
      "predicate": issue.predicate, "subject": issue.subject, "page": issue.page,
      "source": issue.source, "reason": issue.reason,
      "input_fingerprint": baseline, "created_at": at, "status": "pending",
      "decision": Json::null() }
    let content = @base.canonical(review)
    changes.push({ path, before: None, after: Some(content) })
    next = upsert(next, { id: path, path, kind: "state", format: "json", sha256: @base.hex_hash(content), sources: [], stale: false })
    created.push(id)
  }
  let event : Json = { "op": "quality-audit", "id": audit_id, "at": at,
    "fingerprint": baseline, "issues": issues.map(quality_issue_json).to_json(), "reviews": created.to_json() }
  let event_content = @base.canonical(event)
  changes.push({ path: event_path, before: None, after: Some(event_content) })
  next = upsert(next, { id: event_path, path: event_path, kind: "state", format: "json", sha256: @base.hex_hash(event_content), sources: [], stale: false })
  with_views(store, next, changes, "## [" + at + "] quality-audit | " + audit_id + "\n")
  @vault.commit(store, current_fingerprint, next, changes)
  { "id": audit_id, "issues": issues.map(quality_issue_json).to_json(),
    "created": created.to_json(), "replayed": false, "fingerprint": @vault.fingerprint(next) }
}
