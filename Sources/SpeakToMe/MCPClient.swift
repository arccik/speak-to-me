import Foundation

/// A small Model Context Protocol client: enough to list a server's tools and call them.
/// Resources, prompts and sampling aren't used. Two transports: a local server the app
/// launches and talks to over stdin/stdout, and a remote one over Streamable HTTP.
/// Messages are JSON-RPC 2.0 (https://modelcontextprotocol.io/specification).
enum MCP {
    static let protocolVersion = "2025-06-18"

    struct Tool: Identifiable, Sendable {
        var id: String { name }
        let name: String
        let title: String?
        let description: String
        /// The tool's JSON Schema for its arguments, kept as data so it can cross actors.
        let schema: Data
        /// The server says calling it changes nothing, so a draft reply may call it.
        let readOnly: Bool
    }

    enum Failure: LocalizedError {
        case notFound(String)
        case exited(String)
        case timedOut(String)
        case server(String)
        case http(Int, String)
        case badReply

        var errorDescription: String? {
            switch self {
            case .notFound(let command): return "Couldn't find \(command). Install it, or give its full path."
            case .exited(let detail): return detail.isEmpty ? "The server quit." : "The server quit: \(detail)"
            case .timedOut(let method): return "The server didn't answer \(method) in time."
            case .server(let message): return message
            case .http(401, _), .http(403, _):
                return "The server wants a sign-in. Add a token in its headers (sign-in with a browser isn't supported yet)."
            case .http(let code, let body): return "HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(160))")"
            case .badReply: return "The server sent something that isn't MCP."
            }
        }
    }

    /// The app's own tool calls go through this; what's inside depends on the server.
    protocol Transport: Actor {
        func start() async throws
        /// Sends a request and waits for the response with the same id.
        func request(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any]
        func notify(_ message: [String: Any]) async throws
        func close() async
    }

    /// One server, after the handshake.
    actor Connection {
        private let transport: any Transport
        private var nextID = 1
        private(set) var serverName: String?
        private(set) var instructions: String?

        init(transport: any Transport) {
            self.transport = transport
        }

        func open() async throws {
            try await transport.start()
            let result = try await call("initialize", [
                "protocolVersion": MCP.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "SpeakToMe", "title": "Speak to Me", "version": "1.0"],
            ], timeout: 90) // `npx -y` may download the server first
            serverName = (result["serverInfo"] as? [String: Any])?["name"] as? String
            instructions = result["instructions"] as? String
            if let http = transport as? HTTPTransport, let version = result["protocolVersion"] as? String {
                await http.setProtocolVersion(version)
            }
            try await transport.notify(["jsonrpc": "2.0", "method": "notifications/initialized"])
        }

        func listTools() async throws -> [Tool] {
            var tools: [Tool] = []
            var cursor: String?
            repeat {
                let result = try await call("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
                for entry in result["tools"] as? [[String: Any]] ?? [] {
                    guard let name = entry["name"] as? String else { continue }
                    let annotations = entry["annotations"] as? [String: Any] ?? [:]
                    let schema = entry["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
                    tools.append(Tool(
                        name: name,
                        title: (entry["title"] ?? annotations["title"]) as? String,
                        description: entry["description"] as? String ?? "",
                        schema: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8),
                        readOnly: annotations["readOnlyHint"] as? Bool ?? false))
                }
                cursor = result["nextCursor"] as? String
            } while cursor != nil && tools.count < 500
            return tools
        }

        /// The tool's answer as text for the model. A tool that fails says so in words,
        /// so the model can tell the user rather than the reply breaking.
        func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
            let result = try await call("tools/call", ["name": name, "arguments": arguments], timeout: 120)
            var parts: [String] = []
            for item in result["content"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "text": parts.append(item["text"] as? String ?? "")
                case "image": parts.append("[an image]")
                case "audio": parts.append("[a sound clip]")
                case "resource":
                    let resource = item["resource"] as? [String: Any] ?? [:]
                    parts.append(resource["text"] as? String ?? "[\(resource["uri"] as? String ?? "a file")]")
                case "resource_link": parts.append("[\(item["name"] as? String ?? item["uri"] as? String ?? "a link")]")
                default: break
                }
            }
            if parts.isEmpty, let structured = result["structuredContent"],
               let data = try? JSONSerialization.data(withJSONObject: structured) {
                parts.append(String(decoding: data, as: UTF8.self))
            }
            let text = parts.joined(separator: "\n")
            if result["isError"] as? Bool == true { return "The tool failed: \(text)" }
            return text.isEmpty ? "Done." : text
        }

        func close() async {
            await transport.close()
        }

        private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
            let id = nextID
            nextID += 1
            let response = try await transport.request(
                ["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id, timeout: timeout)
            if let error = response["error"] as? [String: Any] {
                throw Failure.server(error["message"] as? String ?? "The server refused \(method).")
            }
            return response["result"] as? [String: Any] ?? [:]
        }
    }

    /// The JSON-RPC id of a message, whether the server wrote it as a number or a string.
    static func messageID(_ message: [String: Any]) -> Int? {
        if let number = message["id"] as? NSNumber { return number.intValue }
        if let text = message["id"] as? String { return Int(text) }
        return nil
    }

    /// What the app says back when a server asks it something.
    static func reply(to request: [String: Any]) -> [String: Any] {
        var reply: [String: Any] = ["jsonrpc": "2.0", "id": request["id"] ?? NSNull()]
        switch request["method"] as? String {
        case "ping": reply["result"] = [String: Any]()
        case "roots/list": reply["result"] = ["roots": [Any]()]
        default: reply["error"] = ["code": -32601, "message": "Speak to Me doesn't support that."]
        }
        return reply
    }
}

// MARK: - Local servers (stdio)

extension MCP {
    /// Launches the server as a child process. Each message is one line of JSON.
    actor StdioTransport: Transport {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let directory: URL?
        /// Called once if the server quits on its own, with its last words on stderr.
        private let onExit: @Sendable (String) -> Void
        private let onToolsChanged: @Sendable () -> Void

        private var process: Process?
        private var input: FileHandle?
        private var buffer = Data()
        private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        private var stderrTail = ""
        private var closing = false

        init(executable: URL, arguments: [String], environment: [String: String], directory: URL?,
             onExit: @escaping @Sendable (String) -> Void, onToolsChanged: @escaping @Sendable () -> Void) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
            self.onExit = onExit
            self.onToolsChanged = onToolsChanged
        }

        func start() async throws {
            // Writing to a server that just died would otherwise kill the app.
            signal(SIGPIPE, SIG_IGN)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            if let directory { process.currentDirectoryURL = directory }
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            let (chunks, sink) = AsyncStream<Data>.makeStream()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; sink.finish() } else { sink.yield(data) }
            }
            Task { [weak self] in
                for await data in chunks { await self?.received(data) }
            }
            let (errors, errorSink) = AsyncStream<Data>.makeStream()
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; errorSink.finish() } else { errorSink.yield(data) }
            }
            Task { [weak self] in
                for await data in errors { await self?.logged(data) }
            }
            process.terminationHandler = { [weak self] _ in
                Task { await self?.terminated() }
            }
            do {
                try process.run()
            } catch {
                throw Failure.server("Couldn't start \(executable.lastPathComponent): \(error.localizedDescription)")
            }
            ChildProcesses.add(process)
            self.process = process
            self.input = stdin.fileHandleForWriting
        }

        func request(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
            guard process != nil else { throw Failure.exited(stderrTail) }
            let method = message["method"] as? String ?? "a request"
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(message)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                    return
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    await self?.expire(id, method: method)
                }
            }
        }

        func notify(_ message: [String: Any]) async throws {
            try write(message)
        }

        func close() async {
            closing = true
            guard let process else { return }
            try? input?.close()
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            ChildProcesses.remove(process)
            self.process = nil
            failPending(Failure.exited("stopped"))
        }

        private func write(_ message: [String: Any]) throws {
            guard let input else { throw Failure.exited(stderrTail) }
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.write(contentsOf: data)
        }

        private func received(_ data: Data) {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) else { continue }
                // A server may batch several messages into one array.
                for message in (object as? [[String: Any]]) ?? [object as? [String: Any]].compactMap({ $0 }) {
                    handle(message)
                }
            }
        }

        private func handle(_ message: [String: Any]) {
            if let method = message["method"] as? String {
                if message["id"] != nil {
                    try? write(MCP.reply(to: message))
                } else if method == "notifications/tools/list_changed" {
                    onToolsChanged()
                }
                return
            }
            guard let id = MCP.messageID(message), let continuation = pending.removeValue(forKey: id) else { return }
            continuation.resume(returning: message)
        }

        private func logged(_ data: Data) {
            stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(600))
        }

        private func expire(_ id: Int, method: String) {
            pending.removeValue(forKey: id)?.resume(throwing: Failure.timedOut(method))
        }

        private func terminated() {
            if let process { ChildProcesses.remove(process) }
            process = nil
            input = nil
            // Give stderr a moment to arrive: it usually says why.
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                let detail = lastWords()
                failPending(Failure.exited(detail))
                if !closing { onExit(detail) }
            }
        }

        private func lastWords() -> String {
            stderrTail.split(separator: "\n").suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        private func failPending(_ error: Error) {
            let waiting = pending.values
            pending.removeAll()
            for continuation in waiting { continuation.resume(throwing: error) }
        }
    }
}

/// Every server process the app started, so quitting the app stops them all.
enum ChildProcesses {
    nonisolated(unsafe) private static var processes: [ObjectIdentifier: Process] = [:]
    private static let lock = NSLock()

    static func add(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = process }
    }

    static func remove(_ process: Process) {
        lock.withLock { processes[ObjectIdentifier(process)] = nil }
    }

    static func terminateAll() {
        let all = lock.withLock { Array(processes.values) }
        for process in all where process.isRunning { process.terminate() }
    }
}

// MARK: - Remote servers (Streamable HTTP)

extension MCP {
    /// Each message is a POST; the answer comes back as JSON or as a short event stream.
    actor HTTPTransport: Transport {
        let url: URL
        let headers: [String: String]
        private let onToolsChanged: @Sendable () -> Void
        private var sessionID: String?
        private var negotiatedVersion: String?

        init(url: URL, headers: [String: String], onToolsChanged: @escaping @Sendable () -> Void) {
            self.url = url
            self.headers = headers
            self.onToolsChanged = onToolsChanged
        }

        func setProtocolVersion(_ version: String) {
            negotiatedVersion = version
        }

        func start() async throws {}

        func request(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
            let (bytes, response) = try await post(message, timeout: timeout)
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            if type.contains("text/event-stream") {
                // Each event's data is one JSON message; skip the server's own requests and
                // notifications until our answer arrives.
                var pendingData = ""
                for try await line in bytes.lines {
                    guard line.hasPrefix("data:") else { continue }
                    pendingData += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let message = try? JSONSerialization.jsonObject(with: Data(pendingData.utf8)) as? [String: Any]
                    else { continue }
                    pendingData = ""
                    if let answer = await handle(message, waitingFor: id) { return answer }
                }
                throw Failure.badReply
            }
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let object = try? JSONSerialization.jsonObject(with: data)
            for message in (object as? [[String: Any]]) ?? [object as? [String: Any]].compactMap({ $0 }) {
                if let answer = await handle(message, waitingFor: id) { return answer }
            }
            throw Failure.badReply
        }

        func notify(_ message: [String: Any]) async throws {
            let (bytes, _) = try await post(message, timeout: 15)
            for try await _ in bytes {}
        }

        func close() async {
            guard let sessionID else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 3
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            _ = try? await URLSession.shared.data(for: request)
            self.sessionID = nil
        }

        private func post(_ message: [String: Any], timeout: TimeInterval) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.httpBody = try JSONSerialization.data(withJSONObject: message)
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badReply }
            if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 300 { break } }
                if http.statusCode == 404, sessionID != nil { sessionID = nil } // the session expired
                throw Failure.http(http.statusCode, body)
            }
            return (bytes, http)
        }

        /// Our answer, or nil after dealing with anything else the server sent.
        private func handle(_ message: [String: Any], waitingFor id: Int) async -> [String: Any]? {
            if let method = message["method"] as? String {
                if message["id"] != nil {
                    _ = try? await post(MCP.reply(to: message), timeout: 10)
                } else if method == "notifications/tools/list_changed" {
                    onToolsChanged()
                }
                return nil
            }
            return MCP.messageID(message) == id ? message : nil
        }
    }
}
