import AppKit
import Foundation
import Network

/// `--mcptest`: MCP servers and plugins end to end, with no oMLX and no downloads.
/// The app itself plays a local server (`--mcp-test-server`) and a remote one (a tiny
/// HTTP server on a free port), set up in a temporary folder like a real mcp.json
/// and Plugins folder.
enum MCPSelfTest {
    actor FixtureTransport: MCP.Transport {
        enum Mode { case repeatedCursor, tooManyTools, duplicateNames, tooManyPages, tooMuchMetadata }
        let mode: Mode
        private(set) var requests = 0
        init(mode: Mode) { self.mode = mode }
        func start() async throws {}
        func close() async {}
        func notify(_ message: [String: Any]) async throws {}
        func request(_ message: [String: Any], id: Int, timeout: TimeInterval) async throws -> [String: Any] {
            requests += 1
            let tool: [String: Any] = ["name": "example", "inputSchema": ["type": "object"]]
            let result: [String: Any]
            switch mode {
            case .repeatedCursor: result = ["tools": [Any](), "nextCursor": "same"]
            case .tooManyTools: result = ["tools": Array(repeating: tool, count: 501)]
            case .duplicateNames: result = ["tools": [tool, tool]]
            case .tooManyPages: result = ["tools": [Any](), "nextCursor": "page-\(requests)"]
            case .tooMuchMetadata:
                result = ["tools": [["name": "tool\(requests)", "description": String(repeating: "x", count: 1_048_576)]], "nextCursor": "page-\(requests)"]
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        }
    }
    // MARK: The test servers

    /// A stdio MCP server with a few tools, run as `SpeakToMe --mcp-test-server`.
    static func runStdioServer() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        var changedSchema = false
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
            if (message["params"] as? [String: Any])?["name"] as? String == "note",
               ((message["params"] as? [String: Any])?["arguments"] as? [String: Any])?["changeSchema"] as? Bool == true {
                changedSchema = true
                send(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
            }
            if var reply = answer(message) {
                if changedSchema, message["method"] as? String == "tools/list",
                   var result = reply["result"] as? [String: Any], var tools = result["tools"] as? [[String: Any]], !tools.isEmpty {
                    tools[0]["description"] = "Updated echo tool"
                    tools[0]["inputSchema"] = ["type": "object", "properties": ["text": ["type": "string"], "scope": ["type": "string"]]]
                    result["tools"] = tools
                    reply["result"] = result
                }
                send(reply)
            }
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
                ["name": "note", "description": "Adds a note.", "annotations": ["destructiveHint": false],
                 "inputSchema": object(["text": ["type": "string"]])],
                ["name": "secret", "description": "The app's secret variable, if passed on.", "inputSchema": object([:])],
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
            case "note": result = text("noted")
            case "secret": result = text(ProcessInfo.processInfo.environment["SPEAKTOME_TEST_SECRET"] ?? "unset")
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
        private var missingSession = false
        private var expireNext = false
        private var attempts = 0
        private var initializations = 0
        var sawMissingSession: Bool { queue.sync { missingSession } }
        var toolAttempts: Int { queue.sync { attempts } }
        var initializationCount: Int { queue.sync { initializations } }
        func expireSession() { queue.sync { expireNext = true } }

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
            if method == "initialize" { initializations += 1 }
            if method == "tools/call" {
                attempts += 1
                if expireNext { expireNext = false; return send("404 Not Found", [:], "expired") }
            }
            if method != "initialize" && request.headers["mcp-session-id"] != "test-session" {
                missingSession = true
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
        setvbuf(stdout, nil, _IOLBF, 0)
        var failures = 0
        var checks = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            checks += 1
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
            "plain": ["url": "http://example.com/mcp"],
        ]]
        try! JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("mcp.json"))
        let manifest: [String: Any] = [
            "name": "Demo", "description": "A test plugin", "version": "1.0",
            "instructions": "Use the demo tools for demos.",
            "mcpServers": ["demo": ["command": me, "args": ["--mcp-test-server"], "env": ["WHERE": "${PLUGIN_DIR}"]]],
            "speech": ["echo": ["label": "Echoed it", "filler": "One moment."], "add": ["readOnly": true]],
        ]
        try! JSONSerialization.data(withJSONObject: manifest).write(to: pluginDir.appendingPathComponent("plugin.json"))

        setenv("SPEAKTOME_TEST_SECRET", "leaked", 1)
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
        check("local server starts and lists its tools", server("local")?.tools.count == 7, "\(String(describing: server("local")?.status))")
        check("remote server starts and lists its tools (event stream)", server("remote")?.tools.count == 7,
              "\(String(describing: server("remote")?.status))")
        check("a missing program is reported", {
            if case .failed(let message) = server("broken")?.status { return message.contains("Couldn't find") }
            return false
        }(), "\(String(describing: server("broken")?.status))")
        check("\"disabled\": true keeps a server off", server("sleeping")?.status == .off)
        check("plain http to another computer is refused", {
            if case .failed(let message) = server("plain")?.status { return message.contains("https") }
            return false
        }(), "\(String(describing: server("plain")?.status))")
        check("plugins start off", server("demo")?.status == .off && !names().contains("demo__echo"))
        check("built-in tools come first", names().first == "web_search")
        check("tools are named server__tool", names().contains("local__echo") && names().contains("remote__add"), "\(names())")

        // Test code grants explicit one-call approval, just as the UI does.
        func execute(_ request: OMLXClient.ToolCall, approved: Bool = true) async -> ToolOutcome {
            do { return await hub.run(try hub.prepare(request, catalog: hub.catalog()), approved: approved, client: client) }
            catch { return .init(state: .blocked, text: error.localizedDescription) }
        }
        check("read-only claims require explicit trust", hub.needsApproval(call("local__echo")))
        check("untrusted reads wait for the real reply", hub.hasSideEffects(call("local__echo")))
        check("dispatcher rejects missing permission", await execute(call("local__note"), approved: false).state == .blocked)
        hub.setTrusted(server: "mcp:local", tool: "echo", trusted: true)

        check("local tool call", await execute(call("local__echo", #"{"text":"hi"}"#)).text == "echo: hi")
        check("remote tool call (session id kept)", await execute(call("remote__add", #"{"a":2,"b":3}"#)).text == "5.0")
        check("remote server always got its session id", !http.sawMissingSession)
        let attemptsBeforeExpiry = http.toolAttempts
        let handshakesBeforeExpiry = http.initializationCount
        http.expireSession()
        let expiredOutcome = await execute(call("remote__note"))
        check("expired write session has an uncertain outcome", expiredOutcome.state == .unknown)
        await waitFor("expired session reconnect") { server("remote")?.status == .running && http.initializationCount > handshakesBeforeExpiry }
        check("expired session reconnects with a handshake", http.initializationCount > handshakesBeforeExpiry)
        check("reconnect does not replay the write", http.toolAttempts == attemptsBeforeExpiry + 1)
        let cancelledPrepared = try! hub.prepare(call("remote__note"), catalog: hub.catalog())
        let attemptsBeforeCancel = http.toolAttempts
        let cancelledDispatch = Task { await hub.run(cancelledPrepared, approved: true, client: client) }
        cancelledDispatch.cancel()
        check("cancelled-before-start actions do not dispatch", await cancelledDispatch.value.state == .cancelled && http.toolAttempts == attemptsBeforeCancel)
        check("a failing tool says so", await execute(call("local__fail")).state == .failed)
        check("read-only tools may run in drafts", !hub.hasSideEffects(call("local__echo")))
        check("other tools wait for the real reply", hub.hasSideEffects(call("local__add")))
        check("built-in side effects are unchanged", hub.hasSideEffects(call("open_app")) && !hub.hasSideEffects(call("get_time")))
        check("read-only tools run without asking", !hub.needsApproval(call("local__echo")))
        check("tools that may delete ask (MCP's default)", hub.needsApproval(call("local__add")))
        check("tools that change things ask", hub.needsApproval(call("local__note")))
        hub.setTrusted(server: "mcp:local", tool: "note", trusted: true)
        hub.setTrusted(server: "mcp:local", tool: "add", trusted: true)
        check("you can let a non-deleting tool run without asking", !hub.needsApproval(call("local__note")))
        check("a tool that may delete asks however it's set", hub.needsApproval(call("local__add")))
        check("built-in tools never ask", !hub.needsApproval(call("open_url")) && !hub.needsApproval(call("web_search")))
        check("the app's environment isn't passed on", await execute(call("local__secret")).text == "unset")
        check("labels use the tool's title", hub.label(for: call("local__add")) == "Used Add numbers (local)",
              hub.label(for: call("local__add")))

        hub.setTool(server: "mcp:local", tool: "add", on: false)
        check("a tool switched off leaves the list", !names().contains("local__add") && names().contains("local__echo"))
        hub.setTool(server: "mcp:local", tool: "add", on: true)
        hub.setTool(server: "builtin", tool: "open_app", on: false)
        check("a built-in tool can be switched off", !names().contains("open_app"))

        hub.setTool(server: "builtin", tool: "get_time", on: false)
        check("disabled built-ins cannot execute", await execute(call("get_time")).state == .blocked)
        hub.setTool(server: "builtin", tool: "get_time", on: true)
        check("invented tools cannot execute", await execute(call("invented")).state == .blocked)
        check("malformed arguments cannot become an empty object", await execute(call("local__note", "oops")).state == .blocked)
        check("an empty catalog rejects model calls", (try? hub.prepare(call("get_time"), catalog: hub.catalog(available: false))) == nil)
        let globalPending = try! hub.prepare(call("get_time"), catalog: hub.catalog())
        hub.enabled = false
        check("global tools switch blocks already-prepared calls", await hub.run(globalPending, client: client).state == .blocked)
        hub.enabled = true
        let pending = try! hub.prepare(call("local__note"), catalog: hub.catalog())
        hub.restart("mcp:local")
        await waitFor("restarted identity") { server("local")?.status == .running }
        check("restart invalidates a pending approval", await hub.run(pending, approved: true, client: client).state == .blocked)
        let longArguments = String(decoding: try! JSONSerialization.data(withJSONObject: ["body": String(repeating: "a", count: 2000), "destination": "visible-destination"]), as: UTF8.self)
        check("approval keeps arguments beyond 1500 characters", hub.approvalDetails(call("local__note", longArguments)).arguments.contains("visible-destination"))
        hub.setTrusted(server: "mcp:local", tool: "note", trusted: true)
        try! hub.addServer(name: "local", spec: ["command": me, "args": ["--mcp-test-server"], "env": ["CHANGED": "1"]])
        await waitFor("changed configuration") { server("local")?.status == .running }
        check("changed server config revokes tool trust", hub.needsApproval(call("local__note")))
        let trustedBefore = try! hub.prepare(call("local__echo"), catalog: hub.catalog())
        hub.setTrusted(server: "mcp:local", tool: "echo", trusted: false)
        check("permission changes invalidate pending calls", !hub.isCurrent(trustedBefore))
        hub.setTrusted(server: "mcp:local", tool: "echo", trusted: true)
        let catalogBeforeSchema = hub.catalog()
        let approvalBeforeSchema = try! hub.prepare(call("local__echo"), catalog: catalogBeforeSchema)
        _ = await execute(call("local__note", #"{"changeSchema":true}"#))
        await waitFor("tool-list notification") { server("local")?.tools.first?.description == "Updated echo tool" }
        check("tool-list notifications refresh definitions", server("local")?.tools.first?.description == "Updated echo tool")
        check("changed schemas revoke automatic execution", hub.needsApproval(call("local__echo")))
        check("changed definitions invalidate old catalogs", (try? hub.prepare(call("local__echo"), catalog: catalogBeforeSchema)) == nil)
        check("changed definitions invalidate prepared calls", await hub.run(approvalBeforeSchema, approved: true, client: client).state == .blocked)

        let demo = hub.plugins.first { $0.id == "demo" }
        check("plugin.json is read", demo?.name == "Demo" && demo?.problem == nil)
        check("plugin instructions are off with the plugin", hub.instructions.isEmpty)
        if let demo { hub.setPlugin(demo, on: true) }
        await waitFor("plugin server") { server("demo")?.status == .running }
        check("switching a plugin on starts its server", server("demo")?.status == .running)
        check("plugin instructions join the prompt", hub.instructions == "Use the demo tools for demos.")
        check("plugin labels and fillers are spoken", hub.label(for: call("demo__echo")) == "Echoed it"
              && hub.filler(for: call("demo__echo")) == "One moment.")
        check("a plugin hint cannot put an untrusted write in a draft", hub.hasSideEffects(call("demo__add")))
        check("but can't skip asking", hub.needsApproval(call("demo__add")))
        let whereResult = await execute(call("demo__where")).text
        check("${PLUGIN_DIR} is filled in", whereResult == pluginDir.path, whereResult)

        if let local = server("local") { hub.setServer(local, on: false) }
        check("switching a server off removes its tools", server("local")?.status == .off && !names().contains("local__echo"))
        if let local = server("local") { hub.setServer(local, on: true) }
        await waitFor("restart") { server("local")?.status == .running }
        check("switching it back on starts it again", server("local")?.status == .running)

        check("a lost write response reports an unknown outcome", await execute(call("local__quit")).state == .unknown)
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
        check("mcp.json keeps the other servers", ((saved?["mcpServers"] as? [String: Any])?.keys.count ?? 0) == 5)
        let mode = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("mcp.json").path))?[.posixPermissions] as? Int
        check("mcp.json is readable by you only", mode == 0o600, "\(String(describing: mode))")

        var changed = manifest
        changed["mcpServers"] = ["demo": ["command": "/bin/rm", "args": ["-rf", "/tmp/speaktome-never"]]]
        try? JSONSerialization.data(withJSONObject: changed).write(to: pluginDir.appendingPathComponent("plugin.json"))
        hub.reload()
        let edited = hub.plugins.first { $0.id == "demo" }
        check("a plugin whose files changed goes off", edited.map { !hub.isPluginOn($0) && hub.pluginChanged($0) } ?? false)
        check("and its servers don't start", server("demo")?.status == .off)

        check("command lines split like a shell", ShellPath.words(#"npx -y "a b" c\ d 'e "f"'"#) == ["npx", "-y", "a b", "c d", #"e "f""#])
        check("long names fit the 64-character limit", ToolHub.qualifiedName(String(repeating: "s", count: 40), String(repeating: "t", count: 40)).count == 64)

        let longPrefix = String(repeating: "s", count: 64)
        check("long-prefix tool names stay distinct", ToolHub.qualifiedName(longPrefix, "read") != ToolHub.qualifiedName(longPrefix, "delete"))
        check("sanitized tool names stay distinct", ToolHub.qualifiedName("local", "a.b") != ToolHub.qualifiedName("local", "a_b"))
        check("separator boundaries stay distinct", ToolHub.qualifiedName("a__b", "c") != ToolHub.qualifiedName("a", "b__c"))
        let repeated = FixtureTransport(mode: .repeatedCursor)
        do { _ = try await MCP.Connection(transport: repeated).listTools(); check("repeated cursors fail", false) }
        catch { check("repeated cursors fail promptly", await repeated.requests == 2) }
        for mode: FixtureTransport.Mode in [.tooManyTools, .duplicateNames, .tooManyPages, .tooMuchMetadata] {
            do { _ = try await MCP.Connection(transport: FixtureTransport(mode: mode)).listTools(); check("invalid discovery \(mode) fails", false) }
            catch { check("invalid discovery \(mode) fails", true) }
        }
        var framer = MCP.LineFramer()
        let large = Data(repeating: 65, count: MCP.messageLimit + 1)
        do { _ = try framer.append(large + Data([10])); check("oversized completed frame refused", false) }
        catch { check("oversized completed frame refused", true) }
        framer = MCP.LineFramer()
        do { _ = try framer.append(Data([10]) + large); check("oversized tail after newline refused", false) }
        catch { check("oversized tail after newline refused", true) }
        var sse = MCP.EventDecoder()
        var decoded: [String: Any]?
        for byte in Data("data: {\r\ndata: \"jsonrpc\": \"2.0\", \"id\": 7,\r\ndata: \"result\": {}}\r\n\r\n".utf8) {
            do { if let message = try sse.push(byte) { decoded = message } } catch { break }
        }
        check("SSE multi-line data and CRLF decode", MCP.messageID(decoded ?? [:]) == 7)
        sse = MCP.EventDecoder()
        do { for byte in large { _ = try sse.push(byte) }; check("SSE unterminated line bounded", false) }
        catch { check("SSE unterminated line bounded", true) }

        let sleeper = MCP.StdioTransport(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], directory: nil, onExit: { _ in }, onToolsChanged: {})
        try! await sleeper.start()
        let request = Task { try await sleeper.request(["jsonrpc": "2.0", "id": 1, "method": "tools/call"], id: 1, timeout: 20) }
        try? await Task.sleep(for: .milliseconds(50))
        let cancelTime = Date()
        request.cancel()
        do { _ = try await request.value; check("stdio cancellation throws", false) }
        catch { check("stdio cancellation is prompt", error is CancellationError && Date().timeIntervalSince(cancelTime) < 1) }
        await sleeper.close()

        var action = ToolAction(title: "Note", server: "Local", state: .running, arguments: "private-payload")
        action.result = "private-result"
        let actionData = try! JSONEncoder().encode(action)
        let actionJSON = String(decoding: actionData, as: UTF8.self)
        check("saved action history omits payloads", !actionJSON.contains("private-payload") && !actionJSON.contains("private-result"))
        check("unfinished actions restore as unknown", (try? JSONDecoder().decode(ToolAction.self, from: actionData).state) == .unknown)
        let privateArgs = ToolAction.privateArguments(#"{"nested":{"api_key":"secret-value"},"destination":"visible"}"#)
        check("credential fields are redacted in history", !privateArgs.contains("secret-value") && privateArgs.contains("visible"))
        let legacyLine = Data(#"{"id":"00000000-0000-0000-0000-000000000001","role":"assistant","text":"old chat","interrupted":false}"#.utf8)
        check("old conversation lines still decode", (try? JSONDecoder().decode(VoiceSession.Line.self, from: legacyLine)) != nil)

        // The approval card: yes, no, talking over it (the turn is cancelled), and a newer one.
        _ = NSApplication.shared
        let session = VoiceSession()
        func ask() -> Task<Bool, Never> { Task { await session.askApproval(for: call("x__delete")) } }
        var asking = ask()
        await waitFor("card", seconds: 3) { session.approval != nil }
        session.answerApproval(true)
        check("Allow lets it run", await asking.value && session.approval == nil)
        asking = ask()
        await waitFor("card", seconds: 3) { session.approval != nil }
        session.answerApproval(false)
        check("Don't Allow stops it", !(await asking.value))
        asking = ask()
        await waitFor("card", seconds: 3) { session.approval != nil }
        asking.cancel()
        let cancelled = await asking.value
        check("talking over it counts as no", !cancelled && session.approval == nil)
        let first = ask()
        await waitFor("card", seconds: 3) { session.approval != nil }
        let firstCard = session.approval?.id
        asking = ask()
        await waitFor("second card", seconds: 3) { session.approval != nil && session.approval?.id != firstCard }
        check("a newer request says no to the older one", !(await first.value) && session.approval != nil)
        session.answerApproval(false)
        _ = await asking.value

        hub.reload()
        ChildProcesses.terminateAll()
        http.stop()
        print(failures == 0 ? "\nAll \(checks) MCP checks passed." : "\n\(failures) of \(checks) MCP checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
