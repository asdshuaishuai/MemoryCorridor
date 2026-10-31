pub(all) struct Excerpt {
  text : String
  start_byte : Int
  end_byte : Int
}

// Offsets refer to Page.body, not frontmatter or the rendered citation. Iterate
// original scalars even when case folding changes the UTF-16 string length.
pub fn excerpt(body : String, query : String, budget : Int) -> Excerpt {
  if budget <= 0 { return { text: "", start_byte: 0, end_byte: 0 } }
  let total = @base.utf8_size(body)
  if total <= budget { return { text: body, start_byte: 0, end_byte: total } }
  let terms : Map[String, Bool] = Map([])
  for term in tokens(query) { terms[term] = true }
  let mut best_score = 0
  let mut start = 0
  let mut offset = 0
  let selection_body = if terms.is_empty() { "" } else { body }
  for view in selection_body.split("\n\n") {
    let paragraph = view.to_owned()
    let present : Map[String, Bool] = Map([])
    for term in tokens(paragraph) { present[term] = true }
    let matched = terms.keys().filter(t => present.contains(t)).to_array()
    if matched.length() > best_score {
      best_score = matched.length()
      start = offset
      if @base.utf8_size(paragraph) > budget {
        // Prefer the longest term (CJK bigram over unigram), breaking ties
        // lexically, then use its first occurrence for deterministic selection.
        matched.sort_by((a,b) => if a.length() != b.length() { b.length().compare(a.length()) } else { @base.compare(a,b) })
        let lowered = paragraph.to_lower()
        let anchor = lowered.find(matched[0]).unwrap_or(0)
        let mut folded = 0
        let mut original = 0
        for c in paragraph {
          let width = c.to_string().to_lower().length()
          if folded + width > anchor { break }
          original = original + c.to_string().length()
          folded = folded + width
        }
        let mut leading = 0
        for c in paragraph[:original].to_owned().rev_iter() {
          let size = @base.utf8_size(c.to_string())
          if leading + size > budget/4 { break }
          original = original - c.to_string().length()
          leading = leading + size
        }
        start = offset + original
      }
    }
    offset = offset + paragraph.length() + 2
  }
  let parts : Array[String] = []
  let mut used = 0
  for c in body[start:].to_owned() {
    let text = c.to_string()
    let size = @base.utf8_size(text)
    if used + size > budget { break }
    parts.push(text)
    used = used + size
  }
  let start_byte = @base.utf8_size(body[:start].to_owned())
  { text: parts.join(""), start_byte, end_byte: start_byte + used }
}

pub(all) struct ContextPage {
  entry : @core.Entry
  page : @core.Page
  origin : String
}

priv struct ParagraphSlice {
  text : String
  start_byte : Int
  end_byte : Int
}

fn paragraph_slices(body : String) -> Array[ParagraphSlice] {
  let result : Array[ParagraphSlice] = []
  // Block-level code regions are atomic: a blank line inside a fenced or
  // indented code block must not split the block into separate paragraphs
  // (it would corrupt dedup hashes, byte offsets and the excerpt window).
  let lines = body.split("\n").map(x => x.to_owned()).to_array()
  let mask = @core.code_line_mask(lines)
  let mut char_offset = 0
  let mut buffer : Array[String] = []
  let mut buffer_start = 0
  let mut in_code = false
  let flush = fn() -> Unit {
    if buffer.is_empty() { return }
    let text = buffer.join("\n")
    let start_byte = @base.utf8_size(body[:buffer_start].to_owned())
    result.push({ text, start_byte, end_byte: start_byte + @base.utf8_size(text) })
    buffer = []
  }
  for i = 0; i < lines.length(); i = i + 1 {
    let line = lines[i]
    let is_blank = line.trim().is_empty()
    if mask[i] {
      if !in_code {
        flush()
        in_code = true
        buffer_start = char_offset
        buffer = [line]
      } else {
        buffer.push(line)
      }
    } else {
      if in_code {
        flush()
        in_code = false
      }
      if is_blank {
        flush()
      } else if buffer.is_empty() {
        buffer_start = char_offset
        buffer = [line]
      } else {
        buffer.push(line)
      }
    }
    char_offset = char_offset + line.length() + 1
  }
  flush()
  result
}

fn paragraph_excerpt(body : String, query : String, budget : Int, excluded : Map[String, Bool]) -> Excerpt {
  let terms : Map[String, Bool] = Map([])
  for term in tokens(query) { terms[term] = true }
  let slices = paragraph_slices(body)
  let mut best = -1
  let mut best_score = -1
  for i, slice in slices.iter2() {
    if excluded.contains(slice.text) { continue }
    let present : Map[String, Bool] = Map([])
    for term in tokens(slice.text) { present[term] = true }
    let score = terms.keys().filter(term => present.contains(term)).length()
    if best < 0 || score > best_score { best = i; best_score = score }
  }
  if best < 0 { return { text: "", start_byte: 0, end_byte: 0 } }
  let selected = excerpt(slices[best].text, query, budget)
  { text: selected.text, start_byte: slices[best].start_byte + selected.start_byte,
    end_byte: slices[best].start_byte + selected.end_byte }
}

fn reference(candidate : ContextPage) -> Json {
  let e = candidate.entry
  { "id": e.id, "path": e.path, "sha256": e.sha256, "sources": e.sources.to_json(), "origin": candidate.origin }
}

fn paragraph_reference(candidate : ContextPage, slice : ParagraphSlice) -> Json {
  let e = candidate.entry
  { "id": e.id, "path": e.path, "sha256": e.sha256, "sources": e.sources.to_json(), "origin": candidate.origin,
    "paragraph_hash": @base.hex_hash(slice.text), "paragraph_start": slice.start_byte, "paragraph_end": slice.end_byte }
}

// Near-duplicate classification for "similar" dedup mode. Two texts merge only
// when both reach the byte gate and carry identical token sequences: the token
// lexer folds case and drops whitespace and punctuation, so formatting-only
// variants qualify while reordered words, swapped digits or changed CJK
// characters can never merge. Short text carries too little signal, and exact
// duplicates below the gate are already covered by the exact path. Calibrated
// and regression-pinned by scripts/similarity_calibration.py.
pub const SIMILAR_BYTE_GATE : Int = 64

pub fn similar_tokens(text : String) -> Array[String] {
  tokens(text)
}

pub fn similar_merge(entry_tokens : Array[String], other_tokens : Array[String]) -> Bool {
  if entry_tokens.length() != other_tokens.length() { return false }
  for i = 0; i < entry_tokens.length(); i = i + 1 {
    if entry_tokens[i] != other_tokens[i] { return false }
  }
  true
}

// Both sides of a near-duplicate pair must clear the gate, so short notes are
// never merged on a coincidental token sequence.
pub fn similar_eligible(text : String) -> Bool {
  @base.utf8_size(text) >= SIMILAR_BYTE_GATE
}

fn similar_reference(candidate : ContextPage) -> Json {
  let reference = reference(candidate)
  match reference {
    Object(fields) => {
      fields["similarity"] = 1.0.to_json()
      Json::object(fields)
    }
    _ => reference
  }
}

fn similar_paragraph_reference(candidate : ContextPage, slice : ParagraphSlice, keeper : String) -> Json {
  let reference = paragraph_reference(candidate, slice)
  match reference {
    Object(fields) => {
      fields["similarity"] = 1.0.to_json()
      fields["keeper_id"] = keeper.to_json()
      Json::object(fields)
    }
    _ => reference
  }
}

// The caller supplies verified pages in retrieval-then-graph order. Default
// `dedup:"exact"` keeps whole-body/paragraph equality deliberate: similarity
// must never erase distinct evidence. `dedup:"similar"` is an explicit opt-in
// that additionally merges near-duplicate texts under the token-sequence gate
// above; `spread:"even"` divides the remaining budget by the candidates left
// instead of ranking halves, so one early page cannot starve the tail.
pub fn assemble_context(
  candidates : Array[ContextPage],
  query : String,
  budget : Int,
  dedup? : String = "exact",
  spread? : String = "ranked",
) -> Json {
  let similar_mode = dedup == "similar"
  let unique : Array[ContextPage] = []
  let duplicates : Array[Array[Json]] = []
  let similar_duplicates : Array[Array[Json]] = []
  let paragraph_duplicates : Array[Array[Json]] = []
  let similar_paragraph_duplicates : Array[Array[Json]] = []
  let paragraph_token_owners : Array[Array[Array[String]]] = []
  let bodies : Map[String, Int] = Map([])
  let paragraph_owners : Map[String, Int] = Map([])
  let similar_paragraph_owners : Map[String, Int] = Map([])
  for candidate in candidates {
    if candidate.page.body.is_empty() { continue }
    let candidate_tokens = if similar_mode && similar_eligible(candidate.page.body) {
      Some(similar_tokens(candidate.page.body))
    } else { None }
    let mut duplicate_index = -1
    match bodies.get(candidate.page.body) {
      Some(index) => duplicate_index = index
      None => ()
    }
    if duplicate_index < 0 && similar_mode {
      match candidate_tokens {
        Some(tokens_value) => {
          for i = 0; i < unique.length(); i = i + 1 {
            if similar_merge(similar_tokens(unique[i].page.body), tokens_value) { duplicate_index = i; break }
          }
        }
        None => ()
      }
    }
    if duplicate_index >= 0 {
      duplicates[duplicate_index].push(reference(candidate))
      if similar_mode { similar_duplicates[duplicate_index].push(similar_reference(candidate)) }
      continue
    }
    let index = unique.length()
    bodies[candidate.page.body] = index
    unique.push(candidate)
    duplicates.push([])
    similar_duplicates.push([])
    paragraph_duplicates.push([])
    similar_paragraph_duplicates.push([])
    let owned_tokens : Array[Array[String]] = []
    for slice in paragraph_slices(candidate.page.body) {
      match paragraph_owners.get(slice.text) {
        Some(owner) if owner != index => paragraph_duplicates[owner].push(paragraph_reference(candidate, slice))
        None => paragraph_owners[slice.text] = index
        _ => ()
      }
      let owned = match paragraph_owners.get(slice.text) {
        Some(owner) => owner == index
        None => false
      }
      if owned && similar_mode && similar_eligible(slice.text) {
        let slice_tokens = similar_tokens(slice.text)
        let mut matched = false
        for i = 0; i < index; i = i + 1 {
          for owned_other in paragraph_token_owners[i] {
            if similar_merge(owned_other, slice_tokens) {
              similar_paragraph_duplicates[i].push(similar_paragraph_reference(candidate, slice, unique[i].entry.id))
              similar_paragraph_owners[slice.text] = i
              matched = true
              break
            }
          }
          if matched { break }
        }
        if !matched { owned_tokens.push(slice_tokens) }
      }
    }
    paragraph_token_owners.push(owned_tokens)
  }
  let blocks : Array[Json] = []
  let mut used = 0
  let mut estimated = 0
  let mut any_truncated = false
  for index, candidate in unique.iter2() {
    let e = candidate.entry
    let page = candidate.page
    let citation = "[" + e.id + "] " + page.title + "\n"
    let overhead = @base.utf8_size(citation)
    let remaining = budget - used
    if overhead >= remaining { continue }
    let last = index + 1 == unique.length()
    let allocation = if last { remaining } else if spread == "even" {
      // Even spread: every remaining candidate gets an equal share, while a
      // short page still releases its unused balance to the tail.
      Int::min(remaining, Int::max(overhead + 4, remaining / (unique.length() - index)))
    } else {
      // Keep room for another ranked candidate. Tiny budgets must still be
      // able to carry the first citation and one complete Unicode scalar.
      Int::min(remaining, Int::max(overhead + 4, remaining/2))
    }
    let excluded : Map[String, Bool] = Map([])
    for i, owner in unique.iter2() {
      if i == index { continue }
      for slice in paragraph_slices(owner.page.body) {
        match paragraph_owners.get(slice.text) {
          Some(owner_index) if owner_index != index => excluded[slice.text] = true
          _ => ()
        }
      }
    }
    for slice in paragraph_slices(page.body) {
      match similar_paragraph_owners.get(slice.text) {
        Some(owner_index) if owner_index != index => excluded[slice.text] = true
        _ => ()
      }
    }
    let selected = if excluded.is_empty() { excerpt(page.body, query, allocation - overhead) }
      else { paragraph_excerpt(page.body, query, allocation - overhead, excluded) }
    if selected.text.is_empty() { continue }
    used = used + overhead + @base.utf8_size(selected.text)
    let text = citation + selected.text
    let estimate = @base.estimate_tokens(text)
    estimated = estimated + estimate
    let truncated = selected.text != page.body
    if truncated { any_truncated = true }
    blocks.push({ "id": e.id, "path": e.path, "sha256": e.sha256, "sources": e.sources.to_json(),
      "text": text, "truncated": truncated, "estimated_tokens": estimate, "origin": candidate.origin,
      "body_start": selected.start_byte, "body_end": selected.end_byte, "duplicates": duplicates[index].to_json(),
      "similar_duplicates": similar_duplicates[index].to_json(),
      "paragraph_duplicates": paragraph_duplicates[index].to_json(),
      "similar_paragraph_duplicates": similar_paragraph_duplicates[index].to_json() })
  }
  let paragraph_rows : Array[Json] = []
  let similar_paragraph_rows : Array[Json] = []
  let similar_duplicate_rows : Array[Json] = []
  for index, candidate in unique.iter2() {
    if !paragraph_duplicates[index].is_empty() {
      paragraph_rows.push({ "owner": candidate.entry.id, "duplicates": paragraph_duplicates[index].to_json() })
    }
    if !similar_paragraph_duplicates[index].is_empty() {
      similar_paragraph_rows.push({ "owner": candidate.entry.id, "duplicates": similar_paragraph_duplicates[index].to_json() })
    }
    if !similar_duplicates[index].is_empty() {
      similar_duplicate_rows.push({ "owner": candidate.entry.id, "duplicates": similar_duplicates[index].to_json() })
    }
  }
  let strategy = if !similar_mode && spread == "ranked" { "ranked_halves_exact_body_paragraph_v1" }
    else { (if similar_mode { "similar" } else { "exact" }) + "_body_paragraph_" + spread + "_v2" }
  { "budget": budget, "used": used, "unit": "utf8_bytes_upper_bound", "offset_unit": "body_utf8_bytes",
    "estimated_tokens": estimated, "estimate_recipe": "cjk_char_latin_word_v1", "truncated": any_truncated,
    "strategy": strategy, "blocks": blocks.to_json(),
    "paragraph_duplicates": paragraph_rows.to_json(),
    "similar_duplicates": similar_duplicate_rows.to_json(),
    "similar_paragraph_duplicates": similar_paragraph_rows.to_json() }
}
