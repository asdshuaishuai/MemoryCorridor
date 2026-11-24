// The CJK scalar ranges the text pipeline treats as indexable units: Han,
// kana (including halfwidth forms and kana punctuation), kana supplement,
// CJK compatibility ideographs and Hangul syllables. The tokenizer
// (index/search.mbt) and the cost estimate below must classify the same
// scalars, so both read this one predicate; widening one side alone makes
// the estimate drift away from what is actually retrievable.
pub fn cjk_unit(code : Int) -> Bool {
  (code >= 0x3400 && code <= 0x9fff) || (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0x20000 && code <= 0x323af) ||
    (code >= 0x3040 && code <= 0x309f) || (code >= 0x30a0 && code <= 0x30ff) ||
    (code >= 0x31f0 && code <= 0x31ff) || (code >= 0xff66 && code <= 0xff9d) ||
    (code >= 0xac00 && code <= 0xd7a3)
}

// Deterministic host-facing cost heuristic. It is deliberately not a model
// tokenizer: CJK/kana/hangul scalars count once each, Latin/digit runs count
// once per word, and whitespace or punctuation are free. Hosts may override
// the estimate before applying a model-specific budget.
pub fn estimate_tokens(text : String) -> Int {
  let mut count = 0
  let mut in_word = false
  for c in text {
    let code = c.to_int()
    let cjk = cjk_unit(code)
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


// Strict ISO-8601 UTC (YYYY-MM-DDTHH:MM:SSZ) to Unix seconds. Calendar math is
// the days-from-civil algorithm; anything not exactly 20 well-formed characters
// returns None so callers can decide whether "no time" means "no arithmetic".
fn utc_two(value : String, pos : Int) -> Int? {
  if pos + 1 >= value.length() { return None }
  let high = value[pos].to_int()
  let low = value[pos + 1].to_int()
  if high < 48 || high > 57 || low < 48 || low > 57 { return None }
  Some((high - 48) * 10 + (low - 48))
}

pub fn utc_epoch(value : String) -> Int? {
  if value.length() != 20 { return None }
  if value[4].to_int() != 45 || value[7].to_int() != 45 || value[10].to_int() != 84 ||
    value[13].to_int() != 58 || value[16].to_int() != 58 || value[19].to_int() != 90 {
    return None
  }
  let year = match (utc_two(value, 0), utc_two(value, 2)) {
    (Some(a), Some(b)) => Some(a * 100 + b)
    _ => None
  }
  let month = utc_two(value, 5)
  let day = utc_two(value, 8)
  let hour = utc_two(value, 11)
  let minute = utc_two(value, 14)
  let second = utc_two(value, 17)
  match (year, month, day, hour, minute, second) {
    (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s)) => {
      if mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59 { return None }
      let yy = if mo <= 2 { y - 1 } else { y }
      let era = if yy >= 0 { yy / 400 } else { (yy - 399) / 400 }
      let yoe = yy - era * 400
      let mp = if mo > 2 { mo - 3 } else { mo + 9 }
      let doy = (153 * mp + 2) / 5 + d - 1
      let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
      let days = era * 146097 + doe - 719468
      Some(days * 86400 + h * 3600 + mi * 60 + s)
    }
    _ => None
  }
}
