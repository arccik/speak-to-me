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
        /// It may delete or overwrite things. MCP assumes so unless the server says otherwise,
        /// and such tools always need your OK.
        let destructive: Bool
    }

    /// The most a server may send in one message; more is refused rather than kept in memory.
    static let messageLimit = 8 * 1024 * 1024

    enum Failure: LocalizedError {
        case notFound(String)
        case exited(String)
        case timedOut(String)
        case server(String)
        case http(Int, String)
        case badReply
        case sessionExpired

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
            case .sessionExpired: return "The server session expired. Reconnecting; this action was not retried."
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
            try Task.checkCancellation()
            try await transport.start()
            let result = try await call("initialize", [
                "protocolVersion": MCP.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "SpeakToMe", "title": "Speak to Me", "version": "1.0"],
            ], timeout: 90) // `npx -y` may download the server first
            guard let version = result["protocolVersion"] as? String,
                  ["2025-03-26", "2025-06-18", "2025-11-25"].contains(version) else { throw Failure.badReply }
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
            var cursors = Set<String>()
            var pages = 0
            var metadataBytes = 0
            var names = Set<String>()
            repeat {
                try Task.checkCancellation()
                pages += 1
                guard pages <= 50 else { throw Failure.server("The server sent too many tool-list pages.") }
                let result = try await call("tools/list", cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
                metadataBytes += try JSONSerialization.data(withJSONObject: result).count
                guard metadataBytes <= MCP.messageLimit else { throw Failure.server("The server's tool list was too large.") }
                guard let entries = result["tools"] as? [[String: Any]], tools.count + entries.count <= 500 else {
                    throw Failure.server("The server's tool list is invalid or exceeds 500 tools.")
                }
                for entry in entries {
                    guard let name = entry["name"] as? String, !name.isEmpty, names.insert(name).inserted else {
                        throw Failure.server("The server sent an empty or duplicate tool name.")
                    }
                    let annotations = entry["annotations"] as? [String: Any] ?? [:]
                    let schema = entry["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [String: Any]()]
                    tools.append(Tool(
                        name: name,
                        title: (entry["title"] ?? annotations["title"]) as? String,
                        description: entry["description"] as? String ?? "",
                        schema: (try? JSONSerialization.data(withJSONObject: schema)) ?? Data("{}".utf8),
                        readOnly: annotations["readOnlyHint"] as? Bool ?? false,
                        destructive: !(annotations["readOnlyHint"] as? Bool ?? false)
                            && (annotations["destructiveHint"] as? Bool ?? true)))
                }
                cursor = result["nextCursor"] as? String
                if let cursor, !cursors.insert(cursor).inserted { throw Failure.server("The server repeated a tool-list cursor.") }
            } while cursor != nil
            return tools
        }

        /// The tool's answer as text for the model. A tool that fails says so in words,
        /// so the model can tell the user rather than the reply breaking.
        func callTool(_ name: String, arguments: [String: Any]) async throws -> ToolResult {
            let result = try await call("tools/call", ["name": name, "arguments": arguments], timeout: 120)
            guard result["content"] is [[String: Any]] || result["structuredContent"] != nil else { throw Failure.badReply }
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
            return ToolResult(text: text.isEmpty ? "Done." : text, isError: result["isError"] as? Bool ?? false)
        }

        func close() async {
            await transport.close()
        }

        private func call(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
            try Task.checkCancellation()
            let id = nextID
            nextID += 1
            let response = try await transport.request(
                ["jsonrpc": "2.0", "id": id, "method": method, "params": params], id: id, timeout: timeout)
            if let error = response["error"] as? [String: Any] {
                throw Failure.server(error["message"] as? String ?? "The server refused \(method).")
            }
            guard response["jsonrpc"] as? String == "2.0", let result = response["result"] as? [String: Any] else { throw Failure.badReply }
            return result
        }
    }

    struct ToolResult: Sendable {
        let text: String
        let isError: Bool
    }

    struct LineFramer {
        private var buffer = Data()

        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var lines: [Data] = []
            while let newline = buffer.firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: newline) <= MCP.messageLimit else {
                    throw Failure.server("The server's message was too large.")
                }
                lines.append(Data(buffer[..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            guard buffer.count <= MCP.messageLimit else { throw Failure.server("The server's message was too large.") }
            return lines
        }
    }

    /// Bound bytes before line decoding, including lines without a newline. SSE joins
    /// multiple data fields with a newline and dispatches only at an empty line.
    struct EventDecoder {
        private var line = Data()
        private var fields: [String] = []
        private var count = 0

        mutating func push(_ byte: UInt8) throws -> [String: Any]? {
            count += 1
            guard count <= MCP.messageLimit else { throw Failure.server("The server's answer was too large.") }
            guard byte == 10 else { line.append(byte); return nil }
            if line.last == 13 { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                guard !fields.isEmpty else { return nil }
                let data = Data(fields.joined(separator: "\n").utf8)
                fields.removeAll(keepingCapacity: true)
                guard let message = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.badReply }
                return message
            }
            if text == "data" { fields.append("") }
            else if text.hasPrefix("data:") {
                var field = text.dropFirst(5)
                if field.first == " " { field = field.dropFirst() }
                fields.append(String(field))
            }
            return nil
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
        private var framer = LineFramer()
        private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
        private var deadlines: [Int: Task<Void, Never>] = [:]
        private var stderrTail = ""
        private var closing = false
        private let writer = DispatchQueue(label: "MCP.stdin")
        private var queuedBytes = 0

        /// A single bounded POSIX read returns what is ready, without waiting to fill
        /// a Foundation read buffer while the server waits for our next request.
        private nonisolated static func readChunk(_ handle: FileHandle) -> Data {
            var data = Data(count: 65_536)
            let count = data.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return Data() }
            data.removeSubrange(count..<data.count)
            return data
        }

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

            let (chunks, sink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(32))
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = Self.readChunk(handle)
                if data.isEmpty { handle.readabilityHandler = nil; sink.finish() }
                else if case .dropped = sink.yield(data) {
                    handle.readabilityHandler = nil
                    sink.finish()
                    Task { await self?.overflow() }
                }
            }
            Task { [weak self] in
                for await data in chunks { await self?.received(data) }
            }
            let (errors, errorSink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = Self.readChunk(handle)
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
            try Task.checkCancellation()
            guard process != nil else { throw Failure.exited(stderrTail) }
            let method = message["method"] as? String ?? "a request"
            return try await withTaskCancellationHandler {
              try Task.checkCancellation()
              return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try write(message)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                    return
                }
                deadlines[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    await self?.expire(id, method: method)
                }
              }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }

        func notify(_ message: [String: Any]) async throws {
            try write(message)
        }

        func close() async {
            closing = true
            failPending(Failure.exited("stopped"))
            guard let process else { return }
            try? input?.close()
            input = nil
            process.terminationHandler = nil
            if process.isRunning { process.terminate() }
            ChildProcesses.remove(process)
            self.process = nil
        }

        private func write(_ message: [String: Any]) throws {
            guard let input else { throw Failure.exited(stderrTail) }
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            guard data.count <= MCP.messageLimit, queuedBytes + data.count <= MCP.messageLimit else {
                overflow()
                throw Failure.server("The server isn't consuming requests fast enough.")
            }
            queuedBytes += data.count
            // A server that stops reading stdin must not block the transport actor,
            // including its cancellation and timeout handlers.
            let bytes = data
            writer.async { [weak self] in
                do { try input.write(contentsOf: bytes) }
                catch { Task { await self?.writeFailed(error) } }
                Task { await self?.wrote(bytes.count) }
            }
        }

        private func writeFailed(_ error: Error) {
            failPending(error)
        }

        private func wrote(_ count: Int) { queuedBytes -= count }

        private func received(_ data: Data) {
            guard !closing else { return }
            do {
                for line in try framer.append(data) {
                    guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: line) else { continue }
                    for message in (object as? [[String: Any]]) ?? [object as? [String: Any]].compactMap({ $0 }) { handle(message) }
                }
            } catch { overflow() }
        }

        private func overflow() {
            framer = LineFramer()
            failPending(Failure.server("The server exceeded its message or output buffer limit."))
            closing = true
            if let process, process.isRunning { process.terminate() }
            onExit("The server exceeded its message or output buffer limit.")
        }

        private func cancel(_ id: Int) {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            deadlines.removeValue(forKey: id)?.cancel()
            // Cancellation is best effort: a server may already have completed a write.
            try? write(["jsonrpc": "2.0", "method": "notifications/cancelled",
                        "params": ["requestId": id, "reason": "The user stopped the reply."]])
            continuation.resume(throwing: CancellationError())
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
            deadlines.removeValue(forKey: id)?.cancel()
            continuation.resume(returning: message)
        }

        private func logged(_ data: Data) {
            stderrTail = String((stderrTail + String(decoding: data, as: UTF8.self)).suffix(600))
        }

        private func expire(_ id: Int, method: String) {
            deadlines.removeValue(forKey: id)?.cancel()
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
            for task in deadlines.values { task.cancel() }
            deadlines.removeAll()
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

        /// Redirects aren't followed: they'd carry your headers (tokens) to wherever they point.
        private let session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForResource = 130
            return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }()
        private var closed = false

        /// Plain http only on this Mac: elsewhere your tokens and words would cross the network unencrypted.
        static func isAllowed(_ url: URL) -> Bool {
            if url.scheme == "https" { return true }
            guard url.scheme == "http", let host = url.host()?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
        }

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
            try await withTaskCancellationHandler {
                try await receive(message, id: id, timeout: timeout)
            } onCancel: {
                if message["method"] as? String != "initialize" {
                    Task { try? await self.notify(["jsonrpc": "2.0", "method": "notifications/cancelled",
                        "params": ["requestId": id, "reason": "The user stopped the reply."]]) }
                }
            }
        }

        private func receive(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
            let (bytes, response) = try await post(message, timeout: timeout)
            let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
            if type.contains("text/event-stream") {
                var decoder = EventDecoder()
                for try await byte in bytes {
                    if let message = try decoder.push(byte), let answer = await handle(message, waitingFor: id) { return answer }
                }
                throw Failure.badReply
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > MCP.messageLimit { throw Failure.server("The server's answer was too large.") }
            }
            let object = try? JSONSerialization.jsonObject(with: data)
            for message in (object as? [[String: Any]]) ?? [object as? [String: Any]].compactMap({ $0 }) {
                if let answer = await handle(message, waitingFor: id) { return answer }
            }
            throw Failure.badReply
        }

        func notify(_ message: [String: Any]) async throws {
            let (bytes, _) = try await post(message, timeout: 15)
            var count = 0
            for try await _ in bytes {
                count += 1
                if count > MCP.messageLimit { throw Failure.server("The server's answer was too large.") }
            }
        }

        func close() async {
            guard !closed else { return }
            closed = true
            // Cancel in-flight requests before asking the server to discard the session.
            session.invalidateAndCancel()
            guard let sessionID else { return }
            self.sessionID = nil
            let cleanup = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
            defer { cleanup.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 3
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            if let (bytes, _) = try? await cleanup.bytes(for: request) {
                var count = 0
                do { for try await _ in bytes { count += 1; if count > 1024 { break } } } catch {}
            }
        }

        private func post(_ message: [String: Any], timeout: TimeInterval) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
            try Task.checkCancellation()
            guard !closed else { throw Failure.exited("stopped") }
            var request = URLRequest(url: url)
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
            request.httpBody = try JSONSerialization.data(withJSONObject: message)
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.badReply }
            if let session = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = session }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 404, sessionID != nil {
                    sessionID = nil
                    throw Failure.sessionExpired
                }
                var body = Data()
                for try await byte in bytes { body.append(byte); if body.count >= 300 { break } }
                throw Failure.http(http.statusCode, String(decoding: body, as: UTF8.self))
            }
            return (bytes, http)
        }

        /// Our answer, or nil after dealing with anything else the server sent.
        private func handle(_ message: [String: Any], waitingFor id: Int) async -> [String: Any]? {
            if let method = message["method"] as? String {
                if message["id"] != nil {
                    try? await notify(MCP.reply(to: message))
                } else if method == "notifications/tools/list_changed" {
                    onToolsChanged()
                }
                return nil
            }
            return MCP.messageID(message) == id ? message : nil
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
