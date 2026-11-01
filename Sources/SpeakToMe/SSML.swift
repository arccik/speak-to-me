import Foundation

/// Models sometimes write SSML (`<prosody>`, `<break>`). None of our speech models read it,
/// so we perform it ourselves, the same way for all of them: pauses become silence, rate
/// goes to the engine's speed, and pitch is a resample of what it says. The tags themselves
/// are never shown or spoken.
enum SSML {
    enum Segment: Equatable {
        case pause(seconds: Float)
        case words(String, rate: Float, semitones: Float)
    }

    private static let names = ["speak", "prosody", "break", "emphasis", "voice", "lang", "say-as", "sub",
                                "phoneme", "mark", "audio", "s", "p"]
    private static let tagPattern = #"</?(?:speak|prosody|break|emphasis|voice|lang|say-as|sub|phoneme|mark|audio|s|p)(?:\s[^<>]*)?/?>"#

    static func hasMarkup(_ text: String) -> Bool {
        text.range(of: tagPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The words alone. Also hides a tag still arriving at the end of a streaming reply.
    static func plain(_ text: String) -> String {
        var body = text[...]
        if let open = body.lastIndex(of: "<"), !body[open...].contains(">"), isTagStart(body[open...]) {
            body = body[..<open]
        }
        guard hasMarkup(String(body)) else { return String(body) }
        return String(body)
            .replacingOccurrences(of: tagPattern, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:…])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Could this unfinished `<...` turn out to be one of our tags? "2 < 3" can't.
    static func isTagStart(_ rest: Substring) -> Bool {
        var name = rest.dropFirst().lowercased()
        if name.hasPrefix("/") { name.removeFirst() }
        if name.isEmpty { return true }
        let word = String(name.prefix { !$0.isWhitespace && $0 != "/" })
        return names.contains { word == $0 || (word.count == name.count && $0.hasPrefix(word)) }
    }

    /// Keeps track of which `<prosody>` tags are open, since a reply is cut into sentences.
    static func track(_ text: String, open: inout [String]) {
        for tag in tags(in: text) {
            if tag.name == "prosody" {
                if tag.closing { _ = open.popLast() } else if !tag.selfClosing { open.append(tag.source) }
            }
        }
    }

    static func segments(of text: String) -> [Segment] {
        var result: [Segment] = []
        var stack: [(rate: Float, semitones: Float)] = []
        var position = text.startIndex

        func addWords(_ range: Range<String.Index>) {
            let words = text[range].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            result.append(.words(words, rate: stack.last?.rate ?? 1, semitones: stack.last?.semitones ?? 0))
        }

        for tag in tags(in: text) {
            addWords(position..<tag.range.lowerBound)
            position = tag.range.upperBound
            switch tag.name {
            case "break":
                let seconds = pause(tag.source)
                if seconds > 0 { result.append(.pause(seconds: seconds)) }
            case "prosody":
                if tag.closing {
                    _ = stack.popLast()
                } else if !tag.selfClosing {
                    let outer = stack.last ?? (1, 0)
                    stack.append((min(1.6, max(0.5, outer.rate * rate(attribute("rate", of: tag.source)))),
                                  min(6, max(-6, outer.semitones + semitones(attribute("pitch", of: tag.source))))))
                }
            default: break
            }
        }
        addWords(position..<text.endIndex)
        return result
    }

    /// Plays `samples` at another pitch: faster and higher, or slower and lower.
    static func shifted(_ samples: [Float], semitones: Float) -> [Float] {
        guard semitones != 0, samples.count > 1 else { return samples }
        let step = pitchFactor(semitones)
        let count = Int(Float(samples.count - 1) / step)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let at = Float(i) * step
            let low = Int(at)
            let fraction = at - Float(low)
            out[i] = samples[low] + (samples[low + 1] - samples[low]) * fraction
        }
        return out
    }

    static func pitchFactor(_ semitones: Float) -> Float { pow(2, semitones / 12) }

    // MARK: Reading tags

    private struct Tag {
        let range: Range<String.Index>
        let source: String
        let name: String
        let closing: Bool
        let selfClosing: Bool
    }

    private static func tags(in text: String) -> [Tag] {
        var result: [Tag] = []
        var from = text.startIndex
        while let range = text.range(of: tagPattern, options: [.regularExpression, .caseInsensitive], range: from..<text.endIndex) {
            let source = String(text[range])
            let inner = source.dropFirst().dropLast()
            let closing = inner.hasPrefix("/")
            let name = inner.drop { $0 == "/" }.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            result.append(Tag(range: range, source: source, name: name, closing: closing, selfClosing: inner.hasSuffix("/")))
            from = range.upperBound
        }
        return result
    }

    private static func attribute(_ name: String, of tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return tag[range].trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func pause(_ tag: String) -> Float {
        if let time = attribute("time", of: tag) {
            let seconds: Float?
            if time.hasSuffix("ms") { seconds = Float(time.dropLast(2)).map { $0 / 1000 } }
            else if time.hasSuffix("s") { seconds = Float(time.dropLast()) }
            else { seconds = nil }
            return min(3, max(0, seconds ?? 0.4))
        }
        switch attribute("strength", of: tag) {
        case "none": return 0
        case "x-weak": return 0.1
        case "weak": return 0.2
        case "strong": return 0.6
        case "x-strong": return 1
        default: return 0.4
        }
    }

    private static func rate(_ value: String?) -> Float {
        guard let value else { return 1 }
        switch value {
        case "x-slow": return 0.6
        case "slow": return 0.8
        case "medium", "default": return 1
        case "fast": return 1.2
        case "x-fast": return 1.4
        default:
            guard value.hasSuffix("%"), let percent = Float(value.dropLast()) else { return 1 }
            // "+10%" changes the rate; "90%" sets it.
            return value.hasPrefix("+") || value.hasPrefix("-") ? 1 + percent / 100 : percent / 100
        }
    }

    private static func semitones(_ value: String?) -> Float {
        guard let value else { return 0 }
        switch value {
        case "x-low": return -4
        case "low": return -2
        case "medium", "default": return 0
        case "high": return 2
        case "x-high": return 4
        default:
            if value.hasSuffix("st") { return Float(value.dropLast(2)) ?? 0 }
            if value.hasSuffix("%"), let percent = Float(value.dropLast()), percent > -100 {
                return 12 * log2(1 + percent / 100)
            }
            return 0
        }
    }
}
