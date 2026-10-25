import Foundation

/// Talks to the local oMLX server (OpenAI-compatible API).
///
/// Host, port and API key are read from `~/.omlx/settings.json`, so nothing
/// secret lives in this project.
struct OMLXClient {
    struct Model: Identifiable, Hashable {
        let id: String
        let sizeBytes: Int64
        /// Vision-language models can look at screenshots.
        var isVision = false
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: String
    }

    struct Message {
        let role: String
        var content: String
        var images: [Data] = []
        var toolCalls: [ToolCall] = []
        var toolCallID: String?

        init(role: String, content: String, images: [Data] = [], toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.images = images
            self.toolCalls = toolCalls
            self.toolCallID = toolCallID
        }

        var json: [String: Any] {
            var object: [String: Any] = ["role": role]
            if images.isEmpty {
                object["content"] = content
            } else {
                object["content"] = [["type": "text", "text": content]] + images.map {
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
                }
            }
            if !toolCalls.isEmpty {
                object["tool_calls"] = toolCalls.map {
                    ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]]
                }
            }
            if let toolCallID { object["tool_call_id"] = toolCallID }
            return object
        }
    }

    enum StreamEvent {
        case text(String)
        case toolCall(ToolCall)
    }

    let baseURL: URL
    let apiKey: String?

    static func fromSettings() -> OMLXClient {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/settings.json")
        var host = "127.0.0.1"
        var port = 8000
        var key: String?
        if let data = try? Data(contentsOf: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let server = json["server"] as? [String: Any] {
                host = server["host"] as? String ?? host
                port = server["port"] as? Int ?? port
            }
            if let auth = json["auth"] as? [String: Any] {
                key = auth["api_key"] as? String
            }
        }
        if host == "0.0.0.0" { host = "127.0.0.1" }
        return OMLXClient(baseURL: URL(string: "http://\(host):\(port)")!, apiKey: key)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Chat-capable models (LLM and VLM) that oMLX can serve.
    func chatModels() async throws -> [Model] {
        let (data, response) = try await URLSession.shared.data(for: request("v1/models/status"))
        try Self.check(response, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = (json?["models"] ?? json?["data"]) as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let type = entry["model_type"] as? String,
                  type == "llm" || type == "vlm"
            else { return nil }
            let size = (entry["estimated_size"] as? NSNumber)?.int64Value ?? 0
            return Model(id: id, sizeBytes: size, isVision: type == "vlm")
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Streams the assistant's reply: text as it's written, then any tool calls.
    func streamChat(
        model: String, messages: [Message], tools: [[String: Any]] = [], maxTokens: Int = 600
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request("v1/chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = [
                        "model": model,
                        "messages": messages.map(\.json),
                        "stream": true,
                        "max_tokens": maxTokens,
                        "temperature": 0.7,
                        // Reasoning models would otherwise "think" silently for seconds before speaking.
                        "chat_template_kwargs": ["enable_thinking": false],
                    ]
                    if !tools.isEmpty { body["tools"] = tools }
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw OMLXError.http(http.statusCode, text)
                    }
                    // Tool calls can arrive in pieces; assemble them by index.
                    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }
                        // oMLX reports mid-stream failures (e.g. out of memory) as an error event.
                        if let error = json["error"] {
                            let message = (error as? [String: Any])?["message"] as? String ?? "\(error)"
                            throw OMLXError.stream(message)
                        }
                        guard let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any]
                        else { continue }
                        if let content = delta["content"] as? String, !content.isEmpty {
                            continuation.yield(.text(content))
                        }
                        for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                            let index = call["index"] as? Int ?? 0
                            let function = call["function"] as? [String: Any] ?? [:]
                            var entry = calls[index] ?? (id: "", name: "", arguments: "")
                            if let id = call["id"] as? String { entry.id = id }
                            if let name = function["name"] as? String { entry.name += name }
                            if let arguments = function["arguments"] as? String { entry.arguments += arguments }
                            calls[index] = entry
                        }
                    }
                    for index in calls.keys.sorted() {
                        let call = calls[index]!
                        continuation.yield(.toolCall(ToolCall(
                            id: call.id.isEmpty ? "call_\(index)" : call.id, name: call.name, arguments: call.arguments)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Asks oMLX to load the model now so the first real reply isn't delayed.
    func warmUp(model: String) async throws {
        for try await _ in streamChat(
            model: model, messages: [Message(role: "user", content: "Hi")], maxTokens: 1)
        {}
    }

    /// Pins (or unpins) a model in oMLX so it stays in memory between conversations.
    /// Uses oMLX's admin API, which needs a session cookie from logging in with the API key.
    func setPinned(_ pinned: Bool, model: String) async throws {
        guard let apiKey else { return }
        var login = request("admin/api/login")
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["api_key": apiKey])
        let (loginData, loginResponse) = try await URLSession.shared.data(for: login)
        try Self.check(loginResponse, loginData)

        let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        var update = request("admin/api/models/\(id)/settings")
        update.httpMethod = "PUT"
        update.setValue("application/json", forHTTPHeaderField: "Content-Type")
        update.httpBody = try JSONSerialization.data(withJSONObject: ["is_pinned": pinned])
        let (data, response) = try await URLSession.shared.data(for: update)
        try Self.check(response, data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OMLXError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

enum OMLXError: LocalizedError {
    case http(Int, String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .http(401, _): return "oMLX rejected the API key in ~/.omlx/settings.json"
        case .http(_, let body) where body.contains("Insufficient Memory"):
            return "oMLX ran out of memory. Too many models are loaded at once; unload one in oMLX or pick a smaller model."
        case .http(let code, let body): return "oMLX error \(code): \(body.prefix(200))"
        case .stream(let message) where message.contains("Insufficient Memory"):
            return "oMLX ran out of memory. Too many models are loaded at once; unload one in oMLX or pick a smaller model."
        case .stream(let message): return "oMLX: \(message.prefix(200))"
        }
    }
}
