import Foundation

/// Talks to the local oMLX server (OpenAI-compatible API).
///
/// Host, port and API key are read from `~/.omlx/settings.json`, so nothing
/// secret lives in this project.
struct OMLXClient {
    struct Model: Identifiable, Hashable {
        let id: String
        let sizeBytes: Int64
    }

    struct Message: Codable {
        let role: String
        let content: String
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
            return Model(id: id, sizeBytes: size)
        }
        .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Streams the assistant's reply token by token.
    func streamChat(model: String, messages: [Message], maxTokens: Int = 600) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request("v1/chat/completions")
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    let body: [String: Any] = [
                        "model": model,
                        "messages": messages.map { ["role": $0.role, "content": $0.content] },
                        "stream": true,
                        "max_tokens": maxTokens,
                        "temperature": 0.7,
                        // Reasoning models would otherwise "think" silently for seconds before speaking.
                        "chat_template_kwargs": ["enable_thinking": false],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw OMLXError.http(http.statusCode, text)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String, !content.isEmpty
                        else { continue }
                        continuation.yield(content)
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

    private static func check(_ response: URLResponse, _ data: Data) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OMLXError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

enum OMLXError: LocalizedError {
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .http(401, _): return "oMLX rejected the API key in ~/.omlx/settings.json"
        case .http(let code, let body): return "oMLX error \(code): \(body.prefix(200))"
        }
    }
}
