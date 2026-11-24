// Algorithmic vector lane: hashed character n-grams plus Latin word tokens,
// signed into a fixed number of buckets and L2-normalized. It needs no model
// and no network, works the same for every script, and is the fallback when no
// system embedding engine exists (and the whole vector lane for mixed-script
// queries, which a monolingual system engine cannot cover in one space).
//
// It is a lexical signal, not semantics: a paraphrase with no shared
// characters or words does not match. That trade-off is deliberate and is
// stated in the protocol docs.

pub const FEATURE_DIMENSIONS : Int = 256
pub const FEATURE_SPACE : String = "algo-v1"

fn space_char(c : Char) -> Bool {
  c == ' ' || c == '\n' || c == '\t' || c == '\r'
}

fn ascii_word_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

fn nibble(c : Char) -> Int {
  if c >= '0' && c <= '9' { return c.to_int() - '0'.to_int() }
  c.to_int() - 'a'.to_int() + 10
}

// One bucket index and one sign from a SHA-256 digest. Seven nibbles stay
// positive in a signed Int32; the eighth picks the sign. Signed hashing keeps
// colliding features from always reinforcing each other.
fn bucket_and_sign(digest : String) -> (Int, Double) {
  let mut value = 0
  for i = 0; i < 7; i = i + 1 {
    let c = match digest.get_char(i) { Some(value) => value; None => '0' }
    value = value * 16 + nibble(c)
  }
  let sign_byte = match digest.get_char(7) { Some(value) => nibble(value); None => 0 }
  let bucket = value % FEATURE_DIMENSIONS
  if sign_byte % 2 == 0 { (bucket, 1.0) } else { (bucket, -1.0) }
}

fn add_feature(weights : Array[Double], gram : String, weight : Double) -> Unit {
  let (bucket, sign) = bucket_and_sign(@base.hex_hash(gram))
  weights[bucket] = weights[bucket] + sign * weight
}

fn normalize(weights : Array[Double]) -> Array[Double] {
  let mut sum = 0.0
  for value in weights { sum = sum + value * value }
  if sum <= 0.0 { return weights }
  let norm = sum.sqrt()
  for i = 0; i < weights.length(); i = i + 1 { weights[i] = weights[i] / norm }
  weights
}

pub fn features(text : String) -> Array[Double] {
  let weights : Array[Double] = Array::make(FEATURE_DIMENSIONS, 0.0)
  let lower = text.to_lower()
  let chars : Array[Char] = []
  for c in lower.iter() { chars.push(c) }
  // Character 2- and 3-grams cover every script; whitespace breaks a gram.
  for i = 0; i + 1 < chars.length(); i = i + 1 {
    if space_char(chars[i]) || space_char(chars[i + 1]) { continue }
    add_feature(weights, chars[i].to_string() + chars[i + 1].to_string(), 1.0)
  }
  for i = 0; i + 2 < chars.length(); i = i + 1 {
    if space_char(chars[i]) || space_char(chars[i + 1]) || space_char(chars[i + 2]) { continue }
    add_feature(weights, chars[i].to_string() + chars[i + 1].to_string() + chars[i + 2].to_string(), 1.0)
  }
  // Latin/digit runs stay whole words, so identifiers keep their identity
  // beyond their trigrams.
  let mut word = ""
  for c in chars {
    if ascii_word_char(c) {
      word = word + c.to_string()
    } else if word != "" {
      add_feature(weights, "w:" + word, 2.0)
      word = ""
    }
  }
  if word != "" { add_feature(weights, "w:" + word, 2.0) }
  normalize(weights)
}

pub fn dot(a : Array[Double], b : Array[Double]) -> Double {
  if a.length() != b.length() { return 0.0 }
  let mut sum = 0.0
  for i = 0; i < a.length(); i = i + 1 { sum = sum + a[i] * b[i] }
  sum
}
