pub(all) struct Document {
  id : String
  title : String
  body : String
  title_terms : Array[String]
  body_terms : Array[String]
} derive(ToJson)
pub extend Document with ToJson::{to_json}

pub(all) struct Hit {
  id : String
  title : String
  score : Double
  excerpt : String
} derive(ToJson)
pub extend Hit with ToJson::{to_json}

pub(all) struct Posting {
  id : String
  weight : Double
} derive(ToJson)
pub extend Posting with ToJson::{to_json}

pub(all) struct TextIndex {
  documents : Array[Document]
  postings : Map[String, Array[Posting]]
} derive(ToJson)
pub extend TextIndex with ToJson::{to_json}

pub fn build_index(documents : Array[Document]) -> TextIndex {
  let postings : Map[String, Array[Posting]] = Map([])
  for doc in documents {
    let title : Map[String, Int] = Map([])
    let body : Map[String, Int] = Map([])
    for term in doc.title_terms { title[term] = title.get(term).unwrap_or(0) + 1 }
    for term in doc.body_terms { body[term] = body.get(term).unwrap_or(0) + 1 }
    let terms : Map[String, Bool] = Map([])
    for term in title.keys() { terms[term] = true }
    for term in body.keys() { terms[term] = true }
    for term in terms.keys() {
      let t = title.get(term).unwrap_or(0).to_double()
      let b = body.get(term).unwrap_or(0).to_double()
      let weight = 2.0*t/(t+1.0) + b/(b+1.0)
      let row = postings.get(term).unwrap_or([])
      row.push({ id: doc.id, weight })
      postings[term] = row
    }
  }
  for row in postings.values() { row.sort_by((a,b) => @base.compare(a.id, b.id)) }
  { documents, postings }
}

// CJK text is indexed as unigrams plus bigrams across Han, kana and Hangul
// syllables, so substring queries work without a language-specific dictionary.
// Latin/Greek/Cyrillic runs stay word tokens; punctuation and whitespace split.
fn cjk_unit(code : Int) -> Bool {
  (code >= 0x3400 && code <= 0x9fff) || (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0x20000 && code <= 0x323af) ||
    (code >= 0x3040 && code <= 0x309f) || (code >= 0x30a0 && code <= 0x30ff) ||
    (code >= 0x31f0 && code <= 0x31ff) || (code >= 0xff66 && code <= 0xff9d) ||
    (code >= 0xac00 && code <= 0xd7a3)
}

pub fn tokens(text : String) -> Array[String] {
  let out : Array[String] = []
  let mut word = ""
  let mut previous = ""
  for c in text.to_lower().iter() {
    let code = c.to_int()
    if cjk_unit(code) {
      if word != "" { out.push(word); word = "" }
      let current = c.to_string()
      out.push(current)
      if previous != "" { out.push(previous + current) }
      previous = current
    } else {
      previous = ""
      let letter = (code >= 0x00c0 && code <= 0x02af && code != 0x00d7 && code != 0x00f7) ||
        (code >= 0x0370 && code <= 0x052f)
      if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || letter {
        word = word + c.to_string()
      } else if word != "" { out.push(word); word = "" }
    }
  }
  if word != "" { out.push(word) }
  out
}

pub fn document(entry : @core.Entry, text : String) -> Document raise @base.Fault {
  let page = @core.parse_page(text)
  { id: entry.id, title: page.title, body: page.body,
    title_terms: tokens(page.title), body_terms: tokens(page.body) }
}

pub fn search(documents : Array[Document], query : String, limit? : Int = 10) -> Array[Hit] {
  search_index(build_index(documents), query, limit~)
}

pub fn search_index(index : TextIndex, query : String, limit? : Int = 10) -> Array[Hit] {
  let terms = tokens(query)
  let unique : Map[String, Bool] = Map([])
  for term in terms { unique[term] = true }
  let scores : Map[String, Double] = Map([])
  let sorted_terms = unique.keys().to_array()
  sorted_terms.sort_by(@base.compare)
  for term in sorted_terms {
    for p in index.postings.get(term).unwrap_or([]) {
      scores[p.id] = scores.get(p.id).unwrap_or(0.0) + p.weight
    }
  }
  let hits : Array[Hit] = []
  for doc in index.documents {
    let score = scores.get(doc.id).unwrap_or(0.0)
    if score > 0.0 {
      hits.push({ id: doc.id, title: doc.title, score, excerpt: excerpt(doc.body, query, 360).text })
    }
  }
  hits.sort_by((a, b) => {
    if a.score > b.score { -1 } else if a.score < b.score { 1 } else { @base.compare(a.id, b.id) }
  })
  hits[:Int::max(0, Int::min(limit, hits.length()))].to_owned()
}

pub fn from_json(value : Json) -> Document raise @base.Fault {
  @base.keys(value, ["id", "title", "body", "title_terms", "body_terms"])
  let title = @base.text(@base.field(value, "title"))
  let body = @base.text(@base.field(value, "body"))
  let tt = @base.strings(@base.field(value, "title_terms"))
  let bt = @base.strings(@base.field(value, "body_terms"))
  if tt != tokens(title) || bt != tokens(body) { @base.fail("index_terms_corrupt") }
  { id: @base.text(@base.field(value, "id")), title, body, title_terms: tt, body_terms: bt }
}
