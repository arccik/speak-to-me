import Foundation
import Network

/// `--mcptest`: MCP servers and plugins end to end, with no oMLX and no downloads.
/// The app itself plays a local server (`--mcp-test-server`) and a remote one (a tiny
/// HTTP server on a free port), set up in a temporary folder like a real mcp.json
/// and Plugins folder.
enum MCPSelfTest {
    // MARK: The test servers

    /// A stdio MCP server with a few tools, run as `SpeakToMe --mcp-test-server`.
    static func runStdioServer() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine() {
            guard let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if message["method"] as? String == "tools/call",
               (message["params"] as? [String: Any])?["name"] as? String == "quit" {
                FileHandle.standardError.write(Data("test server quitting as asked\n".utf8))
                exit(3)
            }
            // A notification first, which the client should ignore.
            if message["method"] as? String == "tools/call" { send(["jsonrpc": "2.0", "method": "notifications/message",
                                                                   "params": ["level": "info", "data": "working"]]) }
            if let reply = answer(message) { send(reply) }
        }
        exit(0)
    }

    private static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        print(String(decoding: data, as: UTF8.self))
    }

    /// The server's side of the protocol, shared by both test servers.
    static func answer(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            result = ["protocolVersion": MCP.protocolVersion, "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "speaktome-test", "version": "1"]]
        case "tools/list":
            let object = { (props: [String: Any]) in ["type": "object", "properties": props] as [String: Any] }
            result = ["tools": [
                ["name": "echo", "description": "Says the text back.", "annotations": ["readOnlyHint": true],
                 "inputSchema": object(["text": ["type": "string"]])],
                ["name": "add", "title": "Add numbers", "description": "Adds two numbers.",
                 "inputSchema": object(["a": ["type": "number"], "b": ["type": "number"]])],
                ["name": "fail", "description": "Always fails.", "inputSchema": object([:])],
                ["name": "where", "description": "The WHERE variable.", "inputSchema": object([:])],
                ["name": "quit", "description": "Stops the server.", "inputSchema": object([:])],
            ]]
        case "tools/call":
            let args = params["arguments"] as? [String: Any] ?? [:]
            func text(_ s: String, error: Bool = false) -> [String: Any] {
                ["content": [["type": "text", "text": s]], "isError": error]
            }
            switch params["name"] as? String {
            case "echo": result = text("echo: \(args["text"] as? String ?? "")")
            case "add":
                let sum = ((args["a"] as? NSNumber)?.doubleValue ?? 0) + ((args["b"] as? NSNumber)?.doubleValue ?? 0)
                result = text("\(sum)")
            case "fail": result = text("it broke", error: true)
            case "where": result = text(ProcessInfo.processInfo.environment["WHERE"] ?? "unset")
            default:
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "No such tool"]]
            }
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unknown method"]]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    /// Streamable HTTP, one request per connection. tools/list answers as an event
    /// stream (with a notification first), everything else as plain JSON, and every
    /// request after initialize must carry the session id.
    final class HTTPServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "mcp-test-http")
        private(set) var sawMissingSession = false

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async -> UInt16 {
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.start(queue: queue)
            while listener.port == nil || listener.port?.rawValue == 0 { try? await Task.sleep(for: .milliseconds(20)) }
            return listener.port!.rawValue
        }

        func stop() { listener.cancel() }

        private func serve(_ connection: NWConnection) {
            connection.start(queue: queue)
            read(connection, buffer: Data())
        }

        private func read(_ connection: NWConnection, buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.respond(connection, request)
                } else if !done {
                    self.read(connection, buffer: buffer)
                } else {
                    connection.cancel()
                }
            }
        }

        private static func parse(_ data: Data) -> (method: String, headers: [String: String], body: Data)? {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let body = data[end.upperBound...]
            guard body.count >= length else { return nil }
            return (String(head.first?.split(separator: " ").first ?? ""), headers, Data(body.prefix(length)))
        }

        private func respond(_ connection: NWConnection, _ request: (method: String, headers: [String: String], body: Data)) {
            func send(_ status: String, _ headers: [String: String], _ body: String) {
                var text = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n"
                for (k, v) in headers { text += "\(k): \(v)\r\n" }
                text += "\r\n" + body
                connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            if request.method == "DELETE" { return send("200 OK", [:], "") }
            guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return send("400 Bad Request", [:], "")
            }
            let method = message["method"] as? String
            if method != "initialize" && request.headers["mcp-session-id"] != "test-session" {
                sawMissingSession = true
                return send("400 Bad Request", [:], "missing session")
            }
            guard let reply = MCPSelfTest.answer(message) else { return send("202 Accepted", [:], "") }
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(), as: UTF8.self)
            var headers = ["Mcp-Session-Id": "test-session"]
            if method == "tools/list" {
                headers["Content-Type"] = "text/event-stream"
                send("200 OK", headers, "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/message\",\"params\":{}}\n\nevent: message\ndata: \(json)\n\n")
            } else {
                headers["Content-Type"] = "application/json"
                send("200 OK", headers, json)
            }
        }
    }

    /// `--mcplist [dir]`: starts the servers in your mcp.json (or another folder's) and
    /// plugins that are on, and prints what each one offers or why it failed.
    @MainActor
    static func list(root: URL?) async {
        let hub = root.map { ToolHub(root: $0) } ?? ToolHub.shared
        hub.startOnce()
        let deadline = Date().addingTimeInterval(120)
        while hub.servers.contains(where: { $0.status == .starting }) && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if let error = hub.configError { print("! \(error)") }
        if hub.servers.isEmpty { print("No servers in \(hub.configURL.path) and no plugins switched on.") }
        for server in hub.servers {
            print("\(server.plugin.map { "[\($0)] " } ?? "")\(server.name): \(server.status)  (\(server.spec.summary))")
            for tool in server.tools {
                let about = tool.description.prefix(70).replacingOccurrences(of: "\n", with: " ")
                print("    \(ToolHub.qualifiedName(server.prefix, tool.name))\(tool.readOnly ? " (read-only)" : "")  \(about)")
            }
        }
        print("\(hub.enabledToolCount) tools on, built-in ones included.")
        ChildProcesses.terminateAll()
        exit(0)
    }

    // MARK: The test

    @MainActor
    static func run() async {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(ok ? "" : "  — \(detail())")")
            if !ok { failures += 1 }
        }
        func waitFor(_ what: String, seconds: Double = 20, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            if !condition() { print("      (gave up waiting for \(what))") }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaktome-mcptest-\(UUID().uuidString)")
        let pluginDir = root.appendingPathComponent("Plugins/demo")
        try? FileManager.default.createDirectory(at: pluginDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "speaktome-mcptest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let http = try! HTTPServer()
        let port = await http.start()
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

        let config: [String: Any] = ["mcpServers": [
            "local": ["command": me, "args": ["--mcp-test-server"]],
            "remote": ["url": "http://127.0.0.1:\(port)/mcp"],
            "broken": ["command": "speaktome-no-such-program"],
            "sleeping": ["command": me, "args": ["--mcp-test-server"], "disabled": true],
        ]]
        try! JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("mcp.json"))
        let manifest: [String: Any] = [
            "name": "Demo", "description": "A test plugin", "version": "1.0",
            "instructions": "Use the demo tools for demos.",
            "mcpServers": ["demo": ["command": me, "args": ["--mcp-test-server"], "env": ["WHERE": "${PLUGIN_DIR}"]]],
            "speech": ["echo": ["label": "Echoed it", "filler": "One moment."], "add": ["readOnly": true]],
        ]
        try! JSONSerialization.data(withJSONObject: manifest).write(to: pluginDir.appendingPathComponent("plugin.json"))

        let hub = ToolHub(root: root, defaults: defaults)
        hub.startOnce()
        func server(_ name: String) -> ToolHub.Server? { hub.servers.first { $0.name == name } }
        func names() -> [String] { hub.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String } }
        func call(_ name: String, _ args: String = "{}") -> OMLXClient.ToolCall { .init(id: "t", name: name, arguments: args) }
        let client = OMLXClient(baseURL: URL(string: "http://127.0.0.1:9")!, apiKey: nil)

        await waitFor("servers to start") {
            server("local")?.status == .running && server("remote")?.status == .running
                && { if case .failed = server("broken")?.status { return true }; return false }()
        }
        check("local server starts and lists its tools", server("local")?.tools.count == 5, "\(String(describing: server("local")?.status))")
        check("remote server starts and lists its tools (event stream)", server("remote")?.tools.count == 5,
              "\(String(describing: server("remote")?.status))")
        check("a missing program is reported", {
            if case .failed(let message) = server("broken")?.status { return message.contains("Couldn't find") }
            return false
        }(), "\(String(describing: server("broken")?.status))")
        check("\"disabled\": true keeps a server off", server("sleeping")?.status == .off)
        check("plugins start off", server("demo")?.status == .off && !names().contains("demo__echo"))
        check("built-in tools come first", names().first == "web_search")
        check("tools are named server__tool", names().contains("local__echo") && names().contains("remote__add"), "\(names())")

        check("local tool call", await hub.run(call("local__echo", #"{"text":"hi"}"#), client: client) == "echo: hi")
        check("remote tool call (session id kept)", await hub.run(call("remote__add", #"{"a":2,"b":3}"#), client: client) == "5.0")
        check("remote server always got its session id", !http.sawMissingSession)
        check("a failing tool says so", await hub.run(call("local__fail"), client: client).hasPrefix("The tool failed"))
        check("read-only tools may run in drafts", !hub.hasSideEffects(call("local__echo")))
        check("other tools wait for the real reply", hub.hasSideEffects(call("local__add")))
        check("built-in side effects are unchanged", hub.hasSideEffects(call("open_app")) && !hub.hasSideEffects(call("get_time")))
        check("labels use the tool's title", hub.label(for: call("local__add")) == "Used Add numbers (local)",
              hub.label(for: call("local__add")))

        hub.setTool(server: "mcp:local", tool: "add", on: false)
        check("a tool switched off leaves the list", !names().contains("local__add") && names().contains("local__echo"))
        hub.setTool(server: "mcp:local", tool: "add", on: true)
        hub.setTool(server: "builtin", tool: "open_app", on: false)
        check("a built-in tool can be switched off", !names().contains("open_app"))

        let demo = hub.plugins.first { $0.id == "demo" }
        check("plugin.json is read", demo?.name == "Demo" && demo?.problem == nil)
        check("plugin instructions are off with the plugin", hub.instructions.isEmpty)
        if let demo { hub.setPlugin(demo, on: true) }
        await waitFor("plugin server") { server("demo")?.status == .running }
        check("switching a plugin on starts its server", server("demo")?.status == .running)
        check("plugin instructions join the prompt", hub.instructions == "Use the demo tools for demos.")
        check("plugin labels and fillers are spoken", hub.label(for: call("demo__echo")) == "Echoed it"
              && hub.filler(for: call("demo__echo")) == "One moment.")
        check("a plugin can mark a tool read-only", !hub.hasSideEffects(call("demo__add")))
        let whereResult = await hub.run(call("demo__where"), client: client)
        check("${PLUGIN_DIR} is filled in", whereResult == pluginDir.path, whereResult)

        if let local = server("local") { hub.setServer(local, on: false) }
        check("switching a server off removes its tools", server("local")?.status == .off && !names().contains("local__echo"))
        if let local = server("local") { hub.setServer(local, on: true) }
        await waitFor("restart") { server("local")?.status == .running }
        check("switching it back on starts it again", server("local")?.status == .running)

        _ = await hub.run(call("local__quit"), client: client)
        await waitFor("exit") { if case .failed = server("local")?.status { return true }; return false }
        check("a server that quits is shown with its last words", {
            if case .failed(let message) = server("local")?.status { return message.contains("quitting as asked") }
            return false
        }(), "\(String(describing: server("local")?.status))")

        try? hub.addServer(name: "added", spec: ["command": me, "args": ["--mcp-test-server"]])
        await waitFor("added server") { server("added")?.status == .running }
        check("Add Server writes mcp.json and starts it", server("added")?.status == .running)
        if let added = server("added") { try? hub.removeServer(added) }
        check("Remove takes it out", server("added") == nil)
        let saved = (try? JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mcp.json")))) as? [String: Any]
        check("mcp.json keeps the other servers", ((saved?["mcpServers"] as? [String: Any])?.keys.count ?? 0) == 4)

        check("command lines split like a shell", ShellPath.words(#"npx -y "a b" c\ d 'e "f"'"#) == ["npx", "-y", "a b", "c d", #"e "f""#])
        check("long names fit the 64-character limit", ToolHub.qualifiedName(String(repeating: "s", count: 40), String(repeating: "t", count: 40)).count == 64)

        hub.reload()
        ChildProcesses.terminateAll()
        http.stop()
        print(failures == 0 ? "\nAll MCP checks passed." : "\n\(failures) MCP check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
