import Foundation
import NaturalLanguage

// Host-side embedding adapter for the operating system's sentence model.
//
// The engine never calls this binary and never imports an OS framework: this is
// the same host seam as adapters/embed-rs. It reads embedding-plan items from
// stdin and writes embedding-submit items with the NLEmbedding sentence vector.
// macOS ships the model; Linux/Windows hosts can provide their own adapter.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func cosine(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0
    var aa = 0.0
    var bb = 0.0
    for i in 0..<min(a.count, b.count) {
        dot += a[i] * b[i]
        aa += a[i] * a[i]
        bb += b[i] * b[i]
    }
    if aa == 0.0 || bb == 0.0 { return 0.0 }
    return dot / (aa.squareRoot() * bb.squareRoot())
}

// One verdict row per model. `dimensions` comes from the runtime embedding, so
// an OS change that alters the model size is reported instead of trusted.
func probeLanguage(_ tag: String, _ nl: NLLanguage, _ expected: Int) -> [String: Any] {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: nl) else {
        return ["language": tag, "available": false, "dimensions": NSNull(),
                "reason": "engine_absent"]
    }
    if embedding.dimension != expected {
        return ["language": tag, "available": false, "dimensions": NSNull(),
                "reason": "dimension_mismatch"]
    }
    return ["language": tag, "available": true, "dimensions": embedding.dimension,
            "reason": NSNull()]
}

var language = "zh"
var languageGiven = false
var selftest = false
var probe = false
var index = 1
while index < CommandLine.arguments.count {
    switch CommandLine.arguments[index] {
    case "--language":
        index += 1
        if index >= CommandLine.arguments.count { fail("--language needs zh|en") }
        language = CommandLine.arguments[index]
        languageGiven = true
    case "--selftest":
        selftest = true
    case "--probe":
        probe = true
    default:
        fail("unknown argument: \(CommandLine.arguments[index])")
    }
    index += 1
}

// A probe is a verdict, not an embedding request: it reads no stdin and never
// touches a vault. Exit 0 means the verdict exists; `available` carries the
// answer. Combining it with the single-language modes is a usage error.
if probe {
    if languageGiven || selftest { fail("probe_exclusive") }
    let languages: [[String: Any]] = [
        probeLanguage("zh", .simplifiedChinese, 640),
        probeLanguage("en", .english, 512),
    ]
    let usable = languages.contains { ($0["available"] as? Bool) == true }
    let firstUnusable = languages.first { ($0["available"] as? Bool) == false }
    var topReason: Any = NSNull()
    if !usable, let row = firstUnusable, let reason = row["reason"] { topReason = reason }
    let verdict: [String: Any] = [
        "probe": "os-embed/v1",
        "available": usable,
        "reason": topReason,
        "languages": languages,
        "engine": "nlembedding",
        "platform": "darwin",
        "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
    ]
    let encoded = try JSONSerialization.data(withJSONObject: verdict)
    FileHandle.standardOutput.write(encoded)
    exit(0)
}

let nlLanguage: NLLanguage
let expectedDimensions: Int
switch language {
case "zh":
    nlLanguage = .simplifiedChinese
    expectedDimensions = 640
case "en":
    nlLanguage = .english
    expectedDimensions = 512
default:
    fail("unsupported language: \(language) (use zh or en)")
}

guard let embedding = NLEmbedding.sentenceEmbedding(for: nlLanguage) else {
    fail("NLEmbedding sentence model unavailable for \(language)")
}
if selftest {
    let first = "龙泉窑青瓷以粉青和梅子青釉色最为著名"
    let second = "梅子青与粉青是龙泉青瓷最具代表性的釉色"
    let unrelated = "JavaScript 对象可以用 JSON.stringify 转成字符串"
    guard let a = embedding.vector(for: first),
          let b = embedding.vector(for: second),
          let c = embedding.vector(for: unrelated) else {
        fail("NLEmbedding returned no vector")
    }
    if a.count != expectedDimensions { fail("unexpected dimension: \(a.count)") }
    let related = cosine(a, b)
    let unrelatedScore = cosine(a, c)
    if related <= unrelatedScore { fail("similar Chinese sentences did not rank above unrelated text") }
    print("os-embed selftest: language=\(language) dimensions=\(a.count) related=\(related) unrelated=\(unrelatedScore)")
    exit(0)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let raw = try? JSONSerialization.jsonObject(with: input) as? [[String: Any]] else {
    fail("stdin must be a JSON array of {page,sha256,text}")
}
var output: [[String: Any]] = []
for item in raw {
    guard let page = item["page"] as? String,
          let sha = item["sha256"] as? String,
          let text = item["text"] as? String else {
        fail("each item needs page, sha256 and text")
    }
    guard let values = embedding.vector(for: text) else {
        fail("NLEmbedding returned no vector for page \(page)")
    }
    if values.count != expectedDimensions { fail("unexpected dimension for \(page): \(values.count)") }
    output.append(["page": page, "sha256": sha, "values": values])
}
let encoded = try JSONSerialization.data(withJSONObject: output)
FileHandle.standardOutput.write(encoded)
