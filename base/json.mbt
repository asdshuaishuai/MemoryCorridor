pub(all) suberror Fault {
  Fault(String)
}

pub extend Fault with Show::{to_string, output}

pub impl Show for Fault with output(self, logger) {
  let Fault(message) = self
  logger.write_string(message)
}

pub fn fail(message : String) -> Unit raise Fault {
  raise Fault(message)
}

pub fn parse(text : String) -> Json raise Fault {
  try @json.parse(text) catch {
    _ => raise Fault("invalid_json: JSON 格式无效")
  }
}

pub fn field(value : Json, key : String) -> Json raise Fault {
  match value {
    Object(fields) => match fields.get(key) {
      Some(v) => v
      None => raise Fault("missing_field: " + key)
    }
    _ => raise Fault("expected_object: " + key)
  }
}

pub fn text(value : Json) -> String raise Fault {
  match value {
    String(v) => v
    _ => raise Fault("expected_string")
  }
}

pub fn strings(value : Json) -> Array[String] raise Fault {
  match value {
    Array(v) => v.map(x => text(x))
    _ => raise Fault("expected_string_array")
  }
}

pub fn array(value : Json) -> Array[Json] raise Fault {
  match value {
    Array(v) => v
    _ => raise Fault("expected_array")
  }
}

pub fn boolean(value : Json) -> Bool raise Fault {
  match value {
    True => true
    False => false
    _ => raise Fault("expected_boolean")
  }
}

pub fn keys(value : Json, allowed : Array[String]) -> Unit raise Fault {
  match value {
    Object(fields) => for key in fields.keys() {
      if !allowed.contains(key) {
        fail("unknown_field: " + key + "; allowed=" + allowed.join(","))
      }
    }
    _ => fail("expected_object")
  }
}

pub fn quoted(text : String) -> String {
  Json::string(text).stringify()
}

// Fault messages keep their human-readable detail on the wire while the
// stable prefix gives agents a deterministic repair key.
pub fn fault_code(message : String) -> String {
  match message.split_once(":") {
    Some((code, _)) => code.trim().to_owned()
    None => message.trim().to_owned()
  }
}

pub fn fault_hint(code : String) -> String {
  match code {
    "unknown_field" => "删除未声明字段；先调用 list-tools 查看 schema"
    "missing_field" | "expected_object" | "expected_string" | "expected_array" | "expected_string_array" => "按工具 schema 修正请求字段和类型后重试"
    "context_stale" | "source_changed" | "content_changed" | "purpose_conflict" => "重新调用 context 或 refresh，使用最新版本重新提交"
    "vault_locked" => "释放其他进程的 vault 锁后重试"
    "index_missing_or_invalid" | "index_corrupt_or_stale" => "先调用 rebuild，再重试读取或检索"
    "moon_check_failed" => "修复 MoonBit 编译诊断后重新提交"
    "catalog_literate_tail" | "view_literate_tail" => "在首个受检代码块与后续内容之间补一个空行；说明文字和辅助块必须与围栏空行分隔"
    "invalid_wikilink_anchor" => "锚点必须非空、只含一个 # 分隔符且不能含换行；使用 [[page#标题]]"
    "vector_content_version_mismatch" | "vector_page_not_active" => "重新调用 embedding-plan，使用当前活跃页面版本提交向量"
    "vector_values_encoding_exclusive" => "向量载荷在 values（JSON 数组）和 values_b64（little-endian f32 Base64）之间二选一"
    "vector_base64_invalid" | "vector_base64_length_mismatch" | "vector_base64_nonfinite" => "检查 RFC 4648 Base64、dimensions*4 字节长度和有限 f32 数值"
    "provider_not_registered" | "provider_record_unregistered" => "先调用 provider-register 注册相同空间和能力的 provider"
    "provider_not_active" | "provider_already_revoked" => "调用 provider-list 检查状态，使用新的 provider 或重新注册"
    "provider_space_mismatch" | "provider_kind_mismatch" => "让请求空间/操作类型与 provider-register 的声明完全一致"
    "provider_registration_conflict" => "相同 provider 名称只能复用完全相同的注册配置，或换用新名称"
    "provider_job_key_conflict" | "provider_job_terminal" => "读取 provider-job-list；相同幂等键不能复用不同请求或重复关闭任务"
    "provider_job_already_claimed" | "provider_job_worker_mismatch" => "读取 provider-job-list；使用当前租约 worker，或等待 lease_until 过期后重新 claim"
    "provider_job_worker_required" | "provider_job_lease_expired" | "provider_job_lease_invalid" => "使用有效的 worker 与严格晚于 at 的 lease_until；过期任务由领取者用 provider-job-fail 记录超时"
    "provider_job_lease_pair_invalid" => "worker 与 lease_until 必须同时为空或同时存在"
    "provider_job_payload_too_large" | "provider_job_embedding_item_invalid" | "provider_job_query_too_large" => "缩小 provider 任务输入并按 provider-job-open schema 重试"
    "provider_job_page_version_mismatch" | "provider_job_embedding_text_mismatch" | "provider_job_text_recipe_invalid" => "重新调用 embedding-plan，原样提交当前页面哈希、文本配方和截断标记"
    "provider_job_error_invalid" => "提供 1..4096 个不含换行的失败原因；超时、进程错误和协议错误均可记录为失败终态"
    "provider_job_not_found" => "先调用 provider-job-list 获取有效任务 id"
    "provider_time_invalid" => "提供不含换行的 ISO 日期时间字符串"
    "research_source_not_active" => "先把外部结果写入 raw/ 并调用 scan，再用当前有效来源调用 research-complete"
    "research_key_conflict" => "复用相同幂等键时必须保持主题和查询完全一致，或换用新的 key"
    "research_terminal" => "研究工单已进入终态；读取 research-list 后使用新的主题工单"
    "research_event_conflict" => "检查并恢复未完成事务，避免重复写入研究事件"
    "overview_suggestion_stale" => "重新调用 overview-suggest，使用最新页面/目标基线生成综述"
    "overview_source_not_active" => "先调用 scan 登记并核验综述引用的 raw 来源，再重试 overview-apply"
    "overview_terminal" => "综述建议已进入终态；重新调用 overview-suggest 获取新基线"
    "overview_key_conflict" => "相同幂等键必须保持相同的目标和页面版本，或换用新的 key"
    "evidence_page_version_mismatch" | "evidence_page_changed" => "重新读取页面并使用当前 entry.sha256 提交证据"
    "evidence_source_not_active" => "先调用 scan 登记来源，且只能引用当前未撤销的 raw 文件"
    "evidence_quote_mismatch" | "utf8_range_boundary_invalid" => "按 Page.body 的 UTF-8 字节半开区间重新计算 body_start/body_end 与 quote"
    "session_vault_mismatch" | "session_already_open" => "关闭当前会话或继续使用已绑定的 vault"
    _ => "根据 error_code 修正请求；必要时先读取 status 或 context"
  }
}

// Structural failures carry a machine-readable repair record in addition to
// the stable error code.  The core still raises one Fault; transports decide
// how to place this data in their protocol envelope.
pub fn fault_violations(message : String) -> Json? {
  let code = fault_code(message)
  let structural = [
    "catalog_header_invalid", "catalog_block_unclosed", "catalog_non_literal",
    "catalog_noncanonical", "catalog_literate_tail", "view_literate_tail", "entry_arity", "moon_check_failed", "unsafe_path",
    "frontmatter_required", "unterminated_frontmatter", "unknown_or_duplicate_frontmatter",
    "frontmatter_mapping_required", "frontmatter_string_required", "title_required",
    "type_required", "wikilink_unresolved", "invalid_wikilink_anchor",
    "source_unresolved", "invalid_page_entry", "page_metadata_mismatch",
    "source_missing_or_changed", "content_changed", "staging_order_mismatch",
  ]
  if !structural.contains(code) { return None }
  let page = match message.split_once(": ") {
    Some((_, detail)) => match detail.split_once(" -> ") {
      Some((owner, _)) => Some(owner.to_owned())
      None => if code == "page_metadata_mismatch" { Some(detail.to_owned()) } else { None }
    }
    None => None
  }
  let fix = fault_hint(code)
  let row : Json = {
    "predicate": code,
    "detail": message,
    "fix": fix,
  }
  let enriched = match page {
    Some(value) => match row {
      Object(fields) => { fields["page"] = value.to_json(); Json::object(fields) }
      _ => row
    }
    None => row
  }
  Some([enriched].to_json())
}

pub fn fault_data(message : String) -> Json {
  let code = fault_code(message)
  let value : Json = {
    "error_code": code,
    "hint": fault_hint(code),
  }
  match fault_violations(message) {
    Some(violations) => match value {
      Object(fields) => { fields["violations"] = violations; Json::object(fields) }
      _ => value
    }
    None => value
  }
}

// MoonBit's default String order is shortlex. The wire/catalog format uses
// lexicographic UTF-16 code-unit order explicitly, independent of that default.
pub fn compare(a : String, b : String) -> Int {
  let count = Int::min(a.length(), b.length())
  for i = 0; i < count; i = i + 1 {
    if a[i] < b[i] { return -1 }
    if a[i] > b[i] { return 1 }
  }
  a.length().compare(b.length())
}

pub fn canonical(value : Json) -> String {
  match value {
    Object(fields) => {
      let names = fields.keys().to_array()
      names.sort_by(compare)
      "{" + names.map(fn(k) {
        quoted(k) + ":" + canonical(fields[k])
      }).join(",") + "}"
    }
    Array(values) => "[" + values.map(canonical).join(",") + "]"
    _ => value.stringify()
  }
}

pub fn path(path : String) -> Unit raise Fault {
  if path.is_empty() || path.has_prefix("/") || path.contains("\\") ||
    path.contains(":") || path.contains_char('\u0000') || path.contains("\n") ||
    path.contains("\r") {
    fail("unsafe_path: " + quoted(path))
  }
  for part in path.split("/") {
    if part == "" || part == "." || part == ".." {
      fail("unsafe_path: " + quoted(path))
    }
  }
}

pub fn hex_hash(text : String) -> String {
  sha256_hex(@utf8.encode(text))
}

pub fn utf8_size(text : String) -> Int {
  @utf8.encode(text).length()
}

pub fn utf8_slice(text : String, start : Int, end : Int) -> String raise Fault {
  let bytes = @utf8.encode(text)
  if start < 0 || end < start || end > bytes.length() { fail("invalid_utf8_range") }
  try @utf8.decode(bytes[start:end]) catch { _ => raise Fault("utf8_range_boundary_invalid") }
}

pub fn replace_all(text : String, old : String, replacement : String) -> String {
  text.split(old).map(x => x.to_owned()).to_array().join(replacement)
}
