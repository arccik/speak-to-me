import Foundation

/// Models sometimes write SSML (`<prosody>`, `<break>`). None of our speech models read it,
/// so we perform it ourselves, the same way for all of them: pauses become silence and rate
/// goes to the engine's speed. Pitch is ignored: resampling it sounded like a put-on voice.
/// The tags themselves are never shown or spoken.
enum SSML {
    enum Segment: Equatable {
        case pause(seconds: Float)
        case words(String, rate: Float)
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
        var rates: [Float] = []
        var position = text.startIndex

        func addWords(_ range: Range<String.Index>) {
            let words = text[range].replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard words.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            result.append(.words(words, rate: rates.last ?? 1))
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
                    _ = rates.popLast()
                } else if !tag.selfClosing {
                    // Models often forget to close a tag before the next, so an inner rate replaces
                    // the outer one rather than multiplying it, or the voice drifts further each time.
                    let newRate = attribute("rate", of: tag.source)
                    rates.append(newRate == nil ? rates.last ?? 1 : min(1.6, max(0.5, rate(newRate))))
                }
            default: break
            }
        }
        addWords(position..<text.endIndex)
        return result
    }

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
}
