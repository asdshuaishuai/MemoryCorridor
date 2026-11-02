// Real OOXML packages built with the engine's own zip encoder: extraction
// must be exact-text deterministic (entities, tabs, paragraph order), order
// sheets/slides by the workbook/presentation contract rather than file names,
// and refuse malformed or unsupported input instead of guessing.

fn file(path : String, content : String) -> @pack.File {
  { path, data: @utf8.encode(content) }
}

fn ok_bytes(files : Array[@pack.File]) -> Bytes {
  try { @pack.zip_encode(files) } catch { _ => Bytes::new(0) }
}

fn ok_text(format : String, bytes : Bytes) -> String {
  try { text(format, bytes) } catch { @base.Fault(m) => "extraction-failed: " + m }
}

fn error_of(format : String, bytes : Bytes) -> String {
  try { ignore(text(format, bytes)); "" } catch { @base.Fault(m) => m }
}

test "word extraction keeps paragraph, tab and entity semantics" {
  let doc =
    "<?xml version=\"1.0\"?>" +
    "<w:document><w:body>" +
    "<w:p><w:r><w:t>甲</w:t></w:r><w:r><w:tab/><w:t xml:space=\"preserve\"> &amp; 乙&#20013;</w:t></w:r></w:p>" +
    "<w:p><w:r><w:instrText>PAGE</w:instrText><w:br/><w:t>shown</w:t></w:r></w:p>" +
    "<w:p><w:del><w:r><w:delText>removed</w:delText></w:r></w:del></w:p>" +
    "</w:body></w:document>"
  let bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("word/document.xml", doc),
    file("word/footnotes.xml", "<w:document><w:p><w:r><w:t>footnote</w:t></w:r></w:p></w:document>"),
  ])
  // Second paragraph starts with the explicit break from w:br.
  let extracted = ok_text("office-word", bytes)
  assert_eq(extracted, "甲\t & 乙中\n\nshown\n")
  assert_true(!extracted.contains("footnote"))
  assert_true(!extracted.contains("removed"))
  assert_true(!extracted.contains("PAGE"))
}

test "spreadsheet extraction follows workbook sheet order and shared strings" {
  let bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("xl/workbook.xml", "<workbook><sheets>" +
      "<sheet name=\"第一\" r:id=\"rId2\"/><sheet name=\"第二\" r:id=\"rId1\"/>" +
      "</sheets></workbook>"),
    file("xl/_rels/workbook.xml.rels", "<Relationships>" +
      "<Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/>" +
      "<Relationship Id=\"rId2\" Target=\"/xl/worksheets/sheet2.xml\"/>" +
      "</Relationships>"),
    file("xl/sharedStrings.xml", "<sst><si>苹果</si><si><r><t>橙子</t></r><r><t>酱</t></r></si></sst>"),
    file("xl/worksheets/sheet1.xml", "<worksheet><sheetData>" +
      "<row r=\"1\"><c><f>=SUM(A1)</f><v>9</v></c></row>" +
      "</sheetData></worksheet>"),
    file("xl/worksheets/sheet2.xml", "<worksheet><sheetData>" +
      "<row r=\"1\"><c t=\"s\"><v>0</v></c><c t=\"s\"><v>1</v></c></row>" +
      "<row r=\"2\"><c><v>3.14</v></c><c t=\"inlineStr\"><is><t>文本</t></is></c></row>" +
      "</sheetData></worksheet>"),
  ])
  // Sheet order comes from workbook.xml (第一 maps to sheet2.xml), shared
  // string runs concatenate, formulas drop while cached values stay, inline
  // strings resolve, and cells join with tabs.
  let extracted = ok_text("office-spreadsheet", bytes)
  assert_eq(extracted, "# sheet 第一\n苹果\t橙子酱\n3.14\t文本\n\n# sheet 第二\n9")
  assert_true(!extracted.contains("SUM"))
}

test "slides extraction orders numerically and ignores non-slide parts" {
  let bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("ppt/presentation.xml", "<p:presentation><p:sldIdLst/></p:presentation>"),
    file("ppt/slides/slide1.xml", "<p:sld><a:p><a:r><a:t>首页</a:t></a:r></a:p></p:sld>"),
    file("ppt/slides/slide2.xml", "<p:sld><a:p><a:t>乙</a:t></a:p><a:p><a:t>丙</a:t></a:p></p:sld>"),
    file("ppt/slides/slide10.xml", "<p:sld><a:p><a:t>第十</a:t></a:p></p:sld>"),
    file("ppt/notesSlides/notesSlide1.xml", "<p:notes><a:p><a:t>演讲者备注</a:t></a:p></p:notes>"),
    file("ppt/slideLayouts/slideLayout1.xml", "<p:sldLayout><a:p><a:t>版式文字</a:t></a:p></p:sldLayout>"),
  ])
  // Numeric order (1, 2, 10 — not lexicographic), slides only.
  assert_eq(ok_text("office-slides", bytes),
    "# slide 1\n首页\n\n# slide 2\n乙\n丙\n\n# slide 10\n第十")
  let extracted = ok_text("office-slides", bytes)
  assert_true(!extracted.contains("演讲者备注"))
  assert_true(!extracted.contains("版式文字"))
}

test "whitelist capture: self-closing skip tags hide nothing downstream" {
  // F1: `<w:delText/>`/`<w:instrText/>` self-closing used to latch skip with
  // no End; the rest of the document vanished while ok=true carried the
  // deterministic-extraction marker. Whitelist capture removes the latch.
  let doc =
    "<w:document><w:body>" +
    "<w:p><w:r><w:t>ALPHA</w:t></w:r></w:p>" +
    "<w:p><w:r><w:delText/><w:instrText>R</w:instrText></w:r></w:p>" +
    "<w:p><w:r><w:t>BRAVO</w:t></w:r></w:p>" +
    "</w:body></w:document>"
  let bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("word/document.xml", doc),
  ])
  assert_eq(ok_text("office-word", bytes), "ALPHA\n\nBRAVO")
  // F3: a space-only preserve run must survive verbatim.
  let spaced =
    "<w:document><w:body><w:p><w:r><w:t>Hello</w:t></w:r>" +
    "<w:r><w:t xml:space=\"preserve\"> </w:t></w:r>" +
    "<w:r><w:t>World</w:t></w:r></w:p></w:body></w:document>"
  let spaced_bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("word/document.xml", spaced),
  ])
  assert_eq(ok_text("office-word", spaced_bytes), "Hello World")
}

test "excel latches and index integrity: f-is-si self-closing and bounded indices" {
  // F2: `<f/>` used to latch skipping for the remainder of the sheet --
  // every later cell silently emptied. F4: a self-closing `<si/>` was
  // dropped, shifting all later shared indices by one.
  let sst = "<sst><si><t>ALPHA</t></si><si/><si><t>TWO</t></si></sst>"
  let sheet =
    "<worksheet>" +
    "<row r=\"1\"><c r=\"A1\"><f/><v>999</v></c><c r=\"B1\" t=\"s\"><v>2</v></c></row>" +
    "<row r=\"2\"><c r=\"A2\"><is><t>inline&#32;ok</t></is></c><c r=\"B2\"><v>7</v></c></row>" +
    "</worksheet>"
  let bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("xl/workbook.xml", "<workbook><sheets><sheet name=\"S1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
    file("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
    file("xl/sharedStrings.xml", sst),
    file("xl/worksheets/sheet1.xml", sheet),
  ])
  // index 2 = TWO (the empty <si/> keeps slot 1); formula body gone, v kept
  assert_eq(ok_text("office-spreadsheet", bytes), "# sheet S1\n999\tTWO\ninline ok\t7")
  // F5: an astronomical index wrapping back into range must refuse, not fold
  let wrap =
    "<worksheet><row r=\"1\"><c r=\"A1\" t=\"s\"><v>101457092405402533889</v></c></row></worksheet>"
  let wrap_bytes = ok_bytes([
    file("[Content_Types].xml", "<Types/>"),
    file("xl/workbook.xml", "<workbook><sheets><sheet name=\"S1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"),
    file("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"rId1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
    file("xl/sharedStrings.xml", sst),
    file("xl/worksheets/sheet1.xml", wrap),
  ])
  // exact-message assertion: with the bound removed the number wraps back
  // to a valid index and resolves to a *string* instead of refusing, so an
  // equality on the refusal message is what pins this defense (续十六 F5)
  assert_eq(error_of("office-spreadsheet", wrap_bytes), "office_shared_index: 101457092405402533889")
}

test "slides: named-pattern enforcement and a:t-only text" {
  // F6: slide parts outside `slide<N>.xml` used to vanish silently; Text
  // outside `a:t` (cached fields, metadata, arbitrary namespaced elements)
  // used to be published as visible slide text.
  let base = [
    file("[Content_Types].xml", "<Types/>"),
    file("ppt/slides/slide1.xml",
         "<p><a:p><a:tbl/><a:t>REAL</a:t></a:p><a:blah>HIDDEN</a:blah></p>"),
  ]
  assert_eq(ok_text("office-slides", ok_bytes(base)), "# slide 1\nREAL")
  let ghost : Array[@pack.File] = base + [file("ppt/slides/slideA.xml", "<p><a:t>GHOST</a:t></p>")]
  assert_true(error_of("office-slides", ok_bytes(ghost)).has_prefix("office_slide_unnamed"))
  let dup : Array[@pack.File] = base + [file("ppt/slides/slide01.xml", "<p><a:t>DUP</a:t></p>")]
  assert_true(error_of("office-slides", ok_bytes(dup)).has_prefix("office_slide_duplicate"))
}

test "office extraction refuses malformed packages and unsupported formats" {
  assert_true(!error_of("office-word", @utf8.encode("not a zip archive at all\n\n\n\n")).is_empty())
  let no_ct = ok_bytes([file("word/document.xml", "<w:document/>")])
  assert_true(error_of("office-word", no_ct).has_prefix("office_not_office"))
  let no_doc = ok_bytes([file("[Content_Types].xml", "<Types/>")])
  assert_true(error_of("office-word", no_doc).has_prefix("office_part_missing"))
  let wrong_format = error_of("office-pptx", no_ct)
  assert_true(wrong_format.has_prefix("office_format_unsupported"))
  let no_slides = ok_bytes([file("[Content_Types].xml", "<Types/>")])
  assert_true(error_of("office-slides", no_slides).has_prefix("office_not_office: no slides"))
}

test "shared string indices are validated against the table" {
  let header = [
    file("[Content_Types].xml", "<Types/>"),
    file("xl/workbook.xml", "<workbook><sheets><sheet name=\"s\" r:id=\"r1\"/></sheets></workbook>"),
    file("xl/_rels/workbook.xml.rels", "<Relationships><Relationship Id=\"r1\" Target=\"worksheets/sheet1.xml\"/></Relationships>"),
  ]
  let out_of_range = ok_bytes(header + [
    file("xl/sharedStrings.xml", "<sst><si>只有一条</si></sst>"),
    file("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c t=\"s\"><v>7</v></c></row></sheetData></worksheet>"),
  ])
  assert_true(error_of("office-spreadsheet", out_of_range).has_prefix("office_shared_index: out of range"))
  let not_a_number = ok_bytes(header + [
    file("xl/sharedStrings.xml", "<sst/>"),
    file("xl/worksheets/sheet1.xml", "<worksheet><sheetData><row><c t=\"s\"><v>abc</v></c></row></sheetData></worksheet>"),
  ])
  assert_true(error_of("office-spreadsheet", not_a_number).has_prefix("office_shared_index: abc"))
}

test "xml scanner refuses markup the deterministic contract excludes" {
  fn run(source : String) -> String {
    try { xml_events(source).map(e => e.describe()).join("|") } catch { @base.Fault(m) => "error:" + m }
  }
  assert_eq(run("<>"), "error:xml_unnamed_tag")
  assert_eq(run("<!DOCTYPE html><a/>"), "error:xml_dtd_unsupported")
  assert_eq(run("<a><![CDATA[x]]></a>"), "error:xml_cdata_unsupported")
  assert_eq(run("<a b=c>"), "error:xml_attribute_value_unquoted")
  assert_eq(run("<a/"), "error:xml_unterminated_tag")
  assert_eq(run("</a>"), "end a")
  assert_eq(run("</>"), "error:xml_unnamed_tag")
  assert_eq(run("<!-- skip --><a/>"), "start a /")
  // whitespace between tags now emits a verbatim Text event (续十六围猎 F3:
  // swallowing whitespace-only nodes also deleted `<w:t> </w:t>` word-space
  // runs); extractors ignore inter-element text via their leaf whitelists
  assert_eq(run("<?xml v?>\n<a k=\"x&quot;y\">body</a>"), "text \n|start a k=x\"y|text body|end a")
  assert_eq(run("<a><b/><a:x>文&#x4e2D;</a:x></a>"), "start a|start b /|start a:x|text 文中|end a:x|end a")
  // 续十六围猎 F8: complete entity syntax that does not decode is malformed
  // markup and refuses outright instead of leaking raw `&name;` residue or
  // control bytes into published text
  assert_eq(run("<a>1&nbsp;2</a>"), "error:xml_entity_unknown: nbsp")
  assert_eq(run("<a>A&#x1;B</a>"), "error:xml_entity_codepoint_invalid: #x1")
  assert_eq(run("<a>&#xD800;</a>"), "error:xml_entity_codepoint_invalid: #xD800")
  assert_eq(run("<a>&#0;</a>"), "error:xml_entity_codepoint_invalid: #0")
  assert_eq(run("<a>x & y</a>"), "start a|text x & y|end a") // bare & stays literal (leniency kept)
}
