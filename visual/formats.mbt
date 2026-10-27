pub fn source_format(path : String) -> String {
  // Keep the renderer's compatibility helper on the core catalog contract.
  @core.format_for_path(path)
}

pub fn image_mime(path : String) -> String {
  let normalized = path.to_lower()
  if normalized.has_suffix(".png") { "image/png" }
  else if normalized.has_suffix(".gif") { "image/gif" }
  else if normalized.has_suffix(".webp") { "image/webp" }
  else { "image/jpeg" }
}
