import Foundation

struct ToolOutcome {
    let state: ToolAction.State
    let text: String
}

/// Only the action's identity, status and timing are saved. Arguments and results
/// are available for inspection during this session, but never written to chats.
struct ToolAction: Identifiable, Codable {
    enum State: String, Codable {
        case waiting, running, succeeded, failed, denied, cancelled, unknown, blocked

        var label: String {
            switch self {
            case .waiting: return "Waiting for permission"
            case .running: return "Running"
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            case .denied: return "Not allowed"
            case .cancelled: return "Cancelled"
            case .unknown: return "Outcome unknown"
            case .blocked: return "Didn’t run"
            }
        }

        var symbol: String {
            switch self {
            case .waiting: return "hand.raised"
            case .running: return "hourglass"
            case .succeeded: return "checkmark.circle"
            case .failed: return "exclamationmark.circle"
            case .denied, .blocked: return "nosign"
            case .cancelled: return "stop.circle"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    var id = UUID()
    let title: String
    let server: String
    var state: State
    var started = Date()
    var finished: Date?
    var arguments: String? = nil
    var result: String? = nil
    var serverID: String? = nil
    var mayChange = true

    enum CodingKeys: String, CodingKey { case id, title, server, state, started, finished }

    init(title: String, server: String, state: State, arguments: String? = nil, serverID: String? = nil, mayChange: Bool = true) {
        self.title = title
        self.server = server
        self.state = state
        self.arguments = arguments
        self.serverID = serverID
        self.mayChange = mayChange
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        server = try values.decode(String.self, forKey: .server)
        state = try values.decode(State.self, forKey: .state)
        started = try values.decode(Date.self, forKey: .started)
        finished = try values.decodeIfPresent(Date.self, forKey: .finished)
        if state == .running { state = .unknown }
        if state == .waiting { state = .cancelled }
    }

    /// Redact common credential fields recursively in the live history. The approval
    /// itself still shows the exact arguments, so no part of consent is concealed.
    static func privateArguments(_ text: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return "Arguments unavailable" }
        func redacted(_ object: Any) -> Any {
            if let dictionary = object as? [String: Any] {
                return dictionary.reduce(into: [String: Any]()) { result, entry in
                    let key = entry.key.lowercased().filter { $0.isLetter || $0.isNumber }
                    let sensitive = ["password", "passwd", "token", "secret", "authorization", "apikey", "cookie", "credential", "privatekey"]
                        .contains { key.contains($0) }
                    result[entry.key] = sensitive ? "[redacted]" : redacted(entry.value)
                }
            }
            if let array = object as? [Any] { return array.map(redacted) }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: redacted(object), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "Arguments unavailable" }
        return String(decoding: data, as: UTF8.self)
    }
}
