import Foundation

/// Splits a streaming LLM reply into speakable pieces so text-to-speech can start
/// on the first sentence while the model is still writing the rest.
struct SentenceChunker {
    private var buffer = ""
    private var insideThink = false
    private var thinkingBuffer = ""
    private var emittedAny = false
    /// `<prosody>` tags still open, handed on to the next sentence.
    private var openProsody: [String] = []

    /// Feed a token; returns any pieces that are now complete.
    mutating func push(_ token: String) -> [String] {
        thinkingBuffer += token
        stripThinking()
        var pieces: [String] = []
        while let cut = nextBoundary() {
            let piece = String(buffer[..<cut])
            buffer.removeSubrange(..<cut)
            if let spoken = carried(piece) {
                pieces.append(spoken)
                emittedAny = true
            }
        }
        return pieces
    }

    /// Whatever is left once the stream ends.
    mutating func finish() -> [String] {
        stripThinking()
        // An incomplete thinking tag is control text, never something to pronounce.
        thinkingBuffer = ""
        defer { buffer = "" }
        return carried(buffer).map { [$0] } ?? []
    }

    /// A piece ready to speak, in the prosody it's inside. Nil if it's only tags that say nothing.
    private mutating func carried(_ piece: String) -> String? {
        let prefix = openProsody.joined()
        SSML.track(piece, open: &openProsody)
        guard let spoken = Self.speakable(piece) else { return nil }
        return SSML.hasMarkup(spoken) && SSML.segments(of: spoken).isEmpty ? nil : prefix + spoken
    }

    private func nextBoundary() -> String.Index? {
        guard !insideThink else { return nil }
        var index = buffer.startIndex
        var count = 0
        while index < buffer.endIndex {
            let char = buffer[index]
            // Never cut inside a tag, and wait for one that's still arriving.
            if char == "<", SSML.isTagStart(buffer[index...]) {
                guard let close = buffer[index...].firstIndex(of: ">") else { return nil }
                index = buffer.index(after: close)
                continue
            }
            let next = buffer.index(after: index)
            count += 1
            if char == "\n" { return next }
            if "。！？".contains(char), count >= 12 { return next }
            if ".!?;:".contains(char), next < buffer.endIndex, buffer[next].isWhitespace, count >= 12 {
                if char != "." || !isAbbreviation(at: index) { return next }
            }
            // Get the very first audio out fast: break the opening sentence at a comma.
            if !emittedAny, char == ",", next < buffer.endIndex, buffer[next].isWhitespace, count >= 25 {
                return next
            }
            // Bound synthesis latency even when the model writes a long sentence.
            // Use word boundaries so we never cut a word or an SSML tag in half.
            if char.isWhitespace, count >= (emittedAny ? 260 : 140) { return next }
            index = next
        }
        return nil
    }

    private func isAbbreviation(at period: String.Index) -> Bool {
        let word = String(buffer[..<period].reversed().prefix { $0.isLetter || $0 == "." }.reversed()).lowercased()
        return ["mr", "mrs", "ms", "dr", "prof", "sr", "jr", "e.g", "i.e"].contains(word)
            || (word.count == 1 && word.first?.isLetter == true)
    }

    private mutating func stripThinking() {
        while !thinkingBuffer.isEmpty {
            let tag = insideThink ? "</think>" : "<think>"
            if let match = thinkingBuffer.range(of: tag) {
                if !insideThink { buffer += thinkingBuffer[..<match.lowerBound] }
                thinkingBuffer.removeSubrange(..<match.upperBound)
                insideThink.toggle()
                continue
            }
            // Hold only a possible tag prefix between tokens. Discard hidden reasoning
            // immediately, rather than retaining an arbitrarily long thinking block.
            var held = 0
            for length in 1..<tag.count {
                if thinkingBuffer.hasSuffix(String(tag.prefix(length))) { held = length }
            }
            if !insideThink { buffer += thinkingBuffer.dropLast(held) }
            thinkingBuffer = String(thinkingBuffer.suffix(held))
            return
        }
    }

    /// Removes markdown and symbols that sound bad when read aloud.
    static func speakable(_ text: String) -> String? {
        var s = text
        s = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*([#>]+|[-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[*_`#~|]"#, with: "", options: .regularExpression)
        s = s.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }
            .map(String.init).joined()
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.contains(where: { $0.isLetter || $0.isNumber }) ? s : nil
    }
}
