// Deterministic host-facing cost heuristic. It is deliberately not a model
// tokenizer: CJK/kana/hangul scalars count once each, Latin/digit runs count
// once per word, and whitespace or punctuation are free. Hosts may override
// the estimate before applying a model-specific budget.
pub fn estimate_tokens(text : String) -> Int {
  let mut count = 0
  let mut in_word = false
  for c in text {
    let code = c.to_int()
    let cjk = (code >= 0x3400 && code <= 0x9fff) || (code >= 0x20000 && code <= 0x323af) ||
      (code >= 0x3041 && code <= 0x30fa) || (code >= 0xac00 && code <= 0xd7a3)
    if cjk {
      count = count + 1
      in_word = false
    } else {
      let word = (code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5a) ||
        (code >= 0x61 && code <= 0x7a) ||
        (code >= 0x00c0 && code <= 0x02af && code != 0x00d7 && code != 0x00f7) ||
        (code >= 0x0370 && code <= 0x052f)
      if word {
        if !in_word {
          count = count + 1
          in_word = true
        }
      } else {
        in_word = false
      }
    }
  }
  count
}
