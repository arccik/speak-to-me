import Foundation

/// Marks stressed vowels ("молок+о"), the way F5-TTS Russian was trained to read, using
/// RUAccent's dictionaries (MIT). RUAccent's own neural models need ONNX and Python, so what
/// they'd decide is left to F5-TTS: homographs like "замок", and words not in the dictionary.
///
/// The dictionary has 3.2 million forms, about 1.4 GB once loaded, so it's turned into a sorted
/// file once and searched where it lies on disk: looking up a word costs almost no memory.
struct RussianStress {
    static let indexName = "stress-index.txt"
    private static let plus = UInt8(ascii: "+")
    private static let newline = UInt8(ascii: "\n")

    private let index: Data
    private let yoWords: [String: String]
    private let homographs: Set<String>

    /// nil until `buildIndex` has run.
    init?(folder: URL) {
        func dictionary(_ name: String) -> [String: Any]? {
            guard let file = try? Data(contentsOf: folder.appendingPathComponent("\(name).json")) else { return nil }
            return try? JSONSerialization.jsonObject(with: file) as? [String: Any]
        }
        guard let index = try? Data(contentsOf: folder.appendingPathComponent(Self.indexName), options: .alwaysMapped),
              let yoWords = dictionary("yo_words") as? [String: String],
              let homographs = dictionary("omographs")
        else { return nil }
        self.index = index
        self.yoWords = yoWords
        self.homographs = Set(homographs.keys)
    }

    /// Unpacks the downloaded dictionaries and sorts the big one by its unmarked words.
    static func buildIndex(folder: URL) throws {
        for name in ["accents", "omographs", "yo_words"] {
            let gunzip = Process()
            gunzip.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
            gunzip.arguments = ["-kf", folder.appendingPathComponent("\(name).json.gz").path]
            try gunzip.run()
            gunzip.waitUntilExit()
        }
        let source = folder.appendingPathComponent("accents.json")
        let json = try Data(contentsOf: source, options: .alwaysMapped)

        // One `"word": "w+ord",` per line; only the second string is needed.
        var ranges: [(start: Int, end: Int)] = []
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var quotes = 0, start = 0
            for i in 0..<bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    quotes += 1
                    if quotes == 3 { start = i + 1 }
                    if quotes == 4 { ranges.append((start, i)); quotes = 0 }
                default: break
                }
            }
        }
        json.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            ranges.sort { a, b in
                compareSkippingMarks(UnsafeRawBufferPointer(rebasing: bytes[a.start..<a.end]),
                                     UnsafeRawBufferPointer(rebasing: bytes[b.start..<b.end])) < 0
            }
        }
        var output = Data(capacity: json.count / 2)
        for range in ranges {
            output.append(json[range.start..<range.end])
            output.append(newline)
        }
        try output.write(to: folder.appendingPathComponent(indexName), options: .atomic)
        try? FileManager.default.removeItem(at: source)
    }

    /// Compares two words as if neither had a stress mark.
    private static func compareSkippingMarks(_ a: UnsafeRawBufferPointer, _ b: UnsafeRawBufferPointer) -> Int {
        var i = 0, j = 0
        while true {
            if i < a.count, a[i] == plus { i += 1; continue }
            if j < b.count, b[j] == plus { j += 1; continue }
            if i == a.count || j == b.count { return (i == a.count ? 0 : 1) - (j == b.count ? 0 : 1) }
            if a[i] != b[j] { return Int(a[i]) - Int(b[j]) }
            i += 1
            j += 1
        }
    }

    /// "w+ord" for lowercase `word`, by binary search of the index.
    private func stressed(_ word: String) -> String? {
        let key = Array(word.utf8)
        return index.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            key.withUnsafeBytes { key in
                var low = 0, high = bytes.count
                while low < high {
                    var start = (low + high) / 2
                    while start > low, bytes[start - 1] != Self.newline { start -= 1 }
                    var end = start
                    while end < high, bytes[end] != Self.newline { end += 1 }
                    let line = UnsafeRawBufferPointer(rebasing: bytes[start..<end])
                    let order = Self.compareSkippingMarks(line, key)
                    if order == 0 { return String(decoding: line, as: UTF8.self) }
                    if order < 0 { low = end + 1 } else { high = start }
                }
                return nil
            }
        }
    }

    /// `overrides` maps lowercase words to how you want them marked, ahead of the dictionary.
    func marked(_ text: String, overrides: [String: String] = [:]) -> String {
        var result = ""
        var rest = Substring(text.precomposedStringWithCanonicalMapping)
        while let match = rest.firstMatch(of: #/[а-яёА-ЯЁ]+(?:-[а-яёА-ЯЁ]+)*/#) {
            result += rest[..<match.range.lowerBound]
            result += marked(word: String(match.output), overrides: overrides)
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    private func marked(word: String, overrides: [String: String]) -> String {
        var characters = Array(word)
        if let form = overrides[word.lowercased()] {
            return characters.first?.isUppercase == true ? form.prefix(1).uppercased() + form.dropFirst() : form
        }
        let vowels = characters.filter { "аеёиоуыэюяАЕЁИОУЫЭЮЯ".contains($0) }.count
        var lower = word.lowercased()
        // Restore ё ("еще" to "ещё"), keeping the original's capitals.
        if let yo = yoWords[lower], yo.count == characters.count {
            for (i, letter) in yo.enumerated() where letter == "ё" {
                characters[i] = characters[i].isUppercase ? "Ё" : "ё"
            }
            lower = yo
        }
        // One vowel has nowhere else to go, and most such words are unstressed anyway.
        guard vowels > 1, !homographs.contains(lower),
              let marks = stressed(lower), let plus = marks.firstIndex(of: "+")
        else { return String(characters) }
        characters.insert("+", at: marks.distance(from: marks.startIndex, to: plus))
        return String(characters)
    }
}
