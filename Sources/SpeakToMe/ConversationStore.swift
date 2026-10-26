import Foundation

/// Saves each conversation as a JSON file in ~/Library/Application Support/SpeakToMe/Conversations.
struct ConversationStore {
    struct Conversation: Codable {
        var id: UUID
        var created: Date
        var updated: Date
        var lines: [VoiceSession.Line]
    }

    struct Summary: Identifiable, Hashable {
        let id: UUID
        let title: String
        let updated: Date
        let messageCount: Int
    }

    /// Writes happen off the main thread, in order; reads wait for any pending write.
    private static let queue = DispatchQueue(label: "ConversationStore", qos: .utility)

    private let directory = SpeechModels.appRoot.appendingPathComponent("Conversations", isDirectory: true)

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ conversation: Conversation) {
        let directory = directory, file = url(conversation.id)
        Self.queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(conversation) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }

    func load(_ id: UUID) -> Conversation? {
        Self.queue.sync { read(id) }
    }

    private func read(_ id: UUID) -> Conversation? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(id)) else { return nil }
        return try? decoder.decode(Conversation.self, from: data)
    }

    func delete(_ id: UUID) {
        let file = url(id)
        Self.queue.async { try? FileManager.default.removeItem(at: file) }
    }

    static func summary(of conversation: Conversation) -> Summary? {
        guard !conversation.lines.isEmpty else { return nil }
        let first = conversation.lines.first { $0.role == "user" }?.text ?? "Conversation"
        return Summary(id: conversation.id, title: first, updated: conversation.updated,
                       messageCount: conversation.lines.filter { $0.role != "error" }.count)
    }

    /// Newest first.
    func list() -> [Summary] {
        Self.queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { file -> Summary? in
                guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                      let conversation = read(id)
                else { return nil }
                return Self.summary(of: conversation)
            }
            .sorted { $0.updated > $1.updated }
        }
    }
}
