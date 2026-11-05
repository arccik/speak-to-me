import AppKit
import Foundation

/// Things the assistant can do besides talking. The model decides when to call them.
enum Tools {
    static let definitions: [[String: Any]] = [
        function("web_search", "Search the web for current or factual information (news, weather, prices, facts you're unsure of).",
                 ["query": ["type": "string", "description": "What to search for"]], required: ["query"]),
        function("fetch_url", "Read the text of a web page, e.g. a search result, for details.",
                 ["url": ["type": "string"]], required: ["url"]),
        function("get_time", "The user's current local date, time and time zone.", [:], required: []),
        function("open_app", "Open an application on the user's Mac by name, e.g. Safari, Notes, Music.",
                 ["name": ["type": "string"]], required: ["name"]),
        function("open_url", "Open a web page in the user's browser.",
                 ["url": ["type": "string"]], required: ["url"]),
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description,
                      "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    /// What to show under the reply while/after a tool runs.
    static func label(for call: OMLXClient.ToolCall) -> String {
        let args = arguments(call)
        switch call.name {
        case "web_search": return "Searched the web: \(args["query"] as? String ?? "")"
        case "fetch_url": return "Read \(URL(string: args["url"] as? String ?? "")?.host() ?? "a web page")"
        case "get_time": return "Checked the time"
        case "open_app": return "Opened \(args["name"] as? String ?? "an app")"
        case "open_url": return "Opened \(URL(string: args["url"] as? String ?? "")?.host() ?? "a web page")"
        default: return "Used \(call.name)"
        }
    }

    /// A short line to say while a slow tool runs, so the silence doesn't feel broken.
    static func filler(for call: OMLXClient.ToolCall) -> String? {
        switch call.name {
        case "web_search": return "Let me look that up."
        case "fetch_url": return "Reading that now."
        default: return nil
        }
    }

    /// Opening apps and pages has side effects, so drafts (which may be thrown away) skip them.
    static func hasSideEffects(_ call: OMLXClient.ToolCall) -> Bool {
        call.name == "open_app" || call.name == "open_url"
    }

    static func runOutcome(_ call: OMLXClient.ToolCall, client: OMLXClient) async -> ToolOutcome {
        let args = arguments(call)
        do {
            try Task.checkCancellation()
            let text: String
            switch call.name {
            case "web_search": text = try await client.toolWebSearch(args["query"] as? String ?? "")
            case "fetch_url": text = try await client.toolFetchPage(args["url"] as? String ?? "")
            case "get_time": text = "\(Date().formatted(date: .complete, time: .shortened)), time zone \(TimeZone.current.identifier)"
            case "open_app": text = try await openApp(args["name"] as? String ?? "")
            case "open_url":
                guard let url = URL(string: args["url"] as? String ?? ""), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                    throw MCP.Failure.server("That isn't a web address I can open.")
                }
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else { throw MCP.Failure.server("macOS couldn't open that page.") }
                text = "Opened \(url.absoluteString)"
            default: return .init(state: .blocked, text: "Unknown tool. Nothing ran.")
            }
            return .init(state: .succeeded, text: text)
        } catch {
            return .init(state: Task.isCancelled ? (hasSideEffects(call) ? .unknown : .cancelled) : .failed,
                         text: Task.isCancelled ? "The reply was stopped." : error.localizedDescription)
        }
    }

    private static func arguments(_ call: OMLXClient.ToolCall) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
    }

    private static func openApp(_ name: String) async throws -> String {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        guard !wanted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCP.Failure.server("An app name is required.") }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            if let match = apps.first(where: { $0.lowercased() == wanted + ".app" })
                ?? apps.first(where: { $0.lowercased().hasPrefix(wanted) && $0.hasSuffix(".app") }) {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(match)
                let config = NSWorkspace.OpenConfiguration()
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                return "Opened \(match.replacingOccurrences(of: ".app", with: ""))"
            }
        }
        throw MCP.Failure.server("I couldn't find an app called \(name).")
    }
}

extension OMLXClient {
    /// oMLX's built-in web search (DuckDuckGo by default; configurable in oMLX).
    func toolWebSearch(_ query: String) async throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCP.Failure.server("A search query is required.") }
        let json = try await toolPostJSON("v1/web/search", ["query": query])
        let results = json["results"] as? [[String: Any]] ?? []
        guard !results.isEmpty else { return (json["error"] as? String) ?? "No results." }
        return results.prefix(5).enumerated().map { i, r in
            "\(i + 1). \(r["title"] as? String ?? "") — \(r["snippet"] as? String ?? "") (\(r["url"] as? String ?? ""))"
        }.joined(separator: "\n")
    }

    func toolFetchPage(_ url: String) async throws -> String {
        guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme ?? ""), parsed.host != nil else {
            throw MCP.Failure.server("A valid http or https page address is required.")
        }
        let json = try await toolPostJSON("v1/web/fetch", ["url": url])
        let text = (json["content"] ?? json["text"] ?? json["markdown"]) as? String ?? (json["error"] as? String ?? "Empty page.")
        return String(text.prefix(4_000))
    }

    private func toolPostJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw MCP.Failure.server("The web request failed.") }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count > MCP.messageLimit { throw MCP.Failure.server("The web reply was too large.") } }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCP.Failure.badReply }
        if let error = json["error"] as? String { throw MCP.Failure.server(error) }
        return json
    }
}
