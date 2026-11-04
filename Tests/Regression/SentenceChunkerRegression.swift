import Foundation

@main
enum SentenceChunkerRegression {
    static func main() {
        func spoken(_ tokens: [String]) -> [String] {
            var chunker = SentenceChunker()
            return tokens.flatMap { chunker.push($0) } + chunker.finish()
        }
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }

        let reply = "<think>Hidden reasoning. Never speak this.</think>Hello there, this is the answer."
        let expected = "Hello there, this is the answer."
        // Every possible two-token split, plus character-at-a-time delivery.
        for offset in 0...reply.count {
            let cut = reply.index(reply.startIndex, offsetBy: offset)
            check(spoken([String(reply[..<cut]), String(reply[cut...])]).joined(separator: " ") == expected,
                  "Thinking filter failed at token split \(offset)")
        }
        check(spoken(reply.map(String.init)).joined(separator: " ") == expected, "Single-character stream")
        check(spoken(["Before the thought <think>secret"]) == ["Before the thought"], "Keep visible prefix")
        check(spoken(["<think>unfinished"]).isEmpty, "Hide unfinished reasoning")
        check(spoken(["Hello there <thi"]) == ["Hello there"], "Hide partial control tag")
        check(spoken(["<think>a</think><think>b</think>Only the answer"]) == ["Only the answer"], "Multiple blocks")

        var chunker = SentenceChunker()
        let longReply = Array(repeating: "natural speech", count: 40).joined(separator: " ")
        let early = chunker.push(longReply)
        check(!early.isEmpty, "Long sentences must start before stream completion")
        let all = early + chunker.finish()
        check(all.joined(separator: " ") == longReply, "Chunking must preserve all words")
        check(early.first!.count <= 150, "Opening chunk should be short")
        check(spoken(["Please speak to Dr. Smith about it. "]) == ["Please speak to Dr. Smith about it."], "Keep titles with names")

        let expressive = spoken(["<prosody rate=\"slow\">First complete sentence. Another complete sentence.</prosody>"])
        check(expressive.count == 2, "Sentence streaming with markup")
        check(expressive.allSatisfy { SSML.segments(of: $0).contains { if case .words(_, rate: 0.8) = $0 { return true }; return false } },
              "Preserve prosody across chunks")
        check(spoken(["这是一个足够长的中文回答。接下来还有另外一句话。"]).count == 2, "CJK punctuation")
        print("Sentence chunker regressions passed")
    }
}
