import AppKit
import Foundation
import Observation

/// Every tool the model can call: the built-in ones (`Tools`), tools from the MCP
/// servers in `mcp.json`, and tools from plugins. Servers start at launch and when
/// switched on, and stop when switched off or when the app quits.
///
/// Files, in ~/Library/Application Support/SpeakToMe:
/// - `mcp.json`: `{"mcpServers": {"name": {"command": …, "args": […], "env": {…}}}}`, or
///   `{"url": …, "headers": {…}}` for a remote server. The same shape as Claude Desktop's.
/// - `Plugins/<folder>/plugin.json`: see `Plugin`.
@MainActor
@Observable
final class ToolHub {
    static let shared = ToolHub()

    /// Past this many tools, small local models pick the wrong one more often.
    static let comfortableToolCount = 20
    /// The longest tool result the model is given.
    static let resultLimit = 4_000

    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    struct Server: Identifiable {
        /// "mcp:<name>" or "plugin:<folder>/<name>": what the on/off switches are saved under.
        let id: String
        let name: String
        let spec: ServerSpec
        /// The plugin folder it comes from, if any.
        let plugin: String?
        /// Prefix of its tools' names as the model sees them: "<prefix>__<tool>".
        let prefix: String
        var status: Status = .off
        var tools: [MCP.Tool] = []
    }

    let root: URL
    private let defaults: UserDefaults
    private(set) var servers: [Server] = []
    private(set) var plugins: [Plugin] = []
    /// A problem reading mcp.json, shown in Settings.
    private(set) var configError: String?
    private var connections: [String: MCP.Connection] = [:]
    private var started = false

    var configURL: URL { root.appendingPathComponent("mcp.json") }
    var pluginsURL: URL { root.appendingPathComponent("Plugins") }

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakToMe")
        self.defaults = defaults
        enabledPlugins = Set(defaults.stringArray(forKey: "enabledPlugins") ?? [])
        disabledServers = Set(defaults.stringArray(forKey: "disabledServers") ?? [])
        disabledTools = Set(defaults.stringArray(forKey: "disabledTools") ?? [])
    }

    // MARK: Switches

    /// The switches, kept here (not only in UserDefaults) so Settings redraws when they change.
    private var enabledPlugins: Set<String> { didSet { defaults.set(enabledPlugins.sorted(), forKey: "enabledPlugins") } }
    private var disabledServers: Set<String> { didSet { defaults.set(disabledServers.sorted(), forKey: "disabledServers") } }
    private var disabledTools: Set<String> { didSet { defaults.set(disabledTools.sorted(), forKey: "disabledTools") } }

    /// Plugins can run programs, so each one is off until you switch it on.
    func isPluginOn(_ plugin: Plugin) -> Bool { enabledPlugins.contains(plugin.id) }

    func setPlugin(_ plugin: Plugin, on: Bool) {
        if on { enabledPlugins.insert(plugin.id) } else { enabledPlugins.remove(plugin.id) }
        for server in servers where server.plugin == plugin.id { apply(server.id) }
    }

    /// Servers you added yourself are on unless switched off (or `"disabled": true`).
    func isServerOn(_ server: Server) -> Bool {
        if let plugin = server.plugin, !enabledPlugins.contains(plugin) { return false }
        return !server.spec.disabled && !disabledServers.contains(server.id)
    }

    func setServer(_ server: Server, on: Bool) {
        if on { disabledServers.remove(server.id) } else { disabledServers.insert(server.id) }
        // Switched off in mcp.json itself: switching it on takes that out of the file.
        if on, server.spec.disabled, server.plugin == nil {
            try? updateConfig { $0[server.name]?["disabled"] = nil }
            reload()
        } else {
            apply(server.id)
        }
    }

    private func toolKey(_ serverID: String, _ tool: String) -> String { "\(serverID)#\(tool)" }

    func isToolOn(server serverID: String, tool: String) -> Bool {
        !disabledTools.contains(toolKey(serverID, tool))
    }

    func setTool(server serverID: String, tool: String, on: Bool) {
        if on { disabledTools.remove(toolKey(serverID, tool)) } else { disabledTools.insert(toolKey(serverID, tool)) }
    }

    // MARK: What the model sees

    /// Tool definitions for the next request, built-in ones first.
    var definitions: [[String: Any]] {
        let builtIn = Tools.definitions.filter {
            isToolOn(server: "builtin", tool: ($0["function"] as? [String: Any])?["name"] as? String ?? "")
        }
        return builtIn + activeTools.map { server, tool in
            let schema = (try? JSONSerialization.jsonObject(with: tool.schema) as? [String: Any])
                ?? ["type": "object", "properties": [String: Any]()]
            return ["type": "function",
                    "function": ["name": Self.qualifiedName(server.prefix, tool.name),
                                 "description": tool.description, "parameters": schema]]
        }
    }

    var enabledToolCount: Int { definitions.count }

    /// What enabled plugins add to the system prompt.
    var instructions: String {
        plugins.filter { isPluginOn($0) }.compactMap(\.instructions).joined(separator: " ")
    }

    private var activeTools: [(Server, MCP.Tool)] {
        servers.filter { $0.status == .running && isServerOn($0) }.flatMap { server in
            server.tools.filter { isToolOn(server: server.id, tool: $0.name) }.map { (server, $0) }
        }
    }

    private func resolve(_ name: String) -> (Server, MCP.Tool)? {
        activeTools.first { Self.qualifiedName($0.0.prefix, $0.1.name) == name }
    }

    private func hint(_ server: Server, _ tool: MCP.Tool) -> Plugin.Speech? {
        plugins.first { $0.id == server.plugin }?.speech[tool.name]
    }

    func label(for call: OMLXClient.ToolCall) -> String {
        guard let (server, tool) = resolve(call.name) else { return Tools.label(for: call) }
        if let label = hint(server, tool)?.label { return label }
        let name = tool.title ?? tool.name.replacingOccurrences(of: "_", with: " ")
        return "Used \(name) (\(server.name))"
    }

    func filler(for call: OMLXClient.ToolCall) -> String? {
        guard let (server, tool) = resolve(call.name) else { return Tools.filler(for: call) }
        return hint(server, tool)?.filler
    }

    /// Unless a tool says it only reads, assume it changes something: drafts wait for it.
    func hasSideEffects(_ call: OMLXClient.ToolCall) -> Bool {
        guard let (server, tool) = resolve(call.name) else {
            return Tools.definitions.contains { ($0["function"] as? [String: Any])?["name"] as? String == call.name }
                ? Tools.hasSideEffects(call) : false
        }
        if let readOnly = hint(server, tool)?.readOnly { return !readOnly }
        return !tool.readOnly
    }

    func run(_ call: OMLXClient.ToolCall, client: OMLXClient) async -> String {
        guard let (server, tool) = resolve(call.name) else { return await Tools.run(call, client: client) }
        guard let connection = connections[server.id] else { return "\(server.name) isn't running." }
        let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        do {
            let text = try await connection.callTool(tool.name, arguments: arguments)
            return text.count > Self.resultLimit ? String(text.prefix(Self.resultLimit)) + "…" : text
        } catch {
            return "\(tool.name) failed: \(error.localizedDescription)"
        }
    }

    /// OpenAI-style function names allow letters, digits, _ and -, up to 64 characters.
    nonisolated static func qualifiedName(_ prefix: String, _ tool: String) -> String {
        String((prefix + "__" + sanitized(tool)).prefix(64))
    }

    nonisolated static func sanitized(_ text: String) -> String {
        let cleaned = text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" }
        return String(cleaned)
    }

    // MARK: Loading

    /// Reads the config and plugins and starts what's switched on. Once per launch.
    func startOnce() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            ChildProcesses.terminateAll()
        }
        reload()
    }

    /// Stops everything, reads the files again and starts what's on.
    func reload() {
        for connection in connections.values { Task { await connection.close() } }
        connections = [:]
        attempts = [:]
        try? FileManager.default.createDirectory(at: pluginsURL, withIntermediateDirectories: true)

        var specs: [(id: String, name: String, spec: ServerSpec, plugin: String?)] = []
        do {
            for (name, spec) in try readConfig().sorted(by: { $0.key < $1.key }) {
                specs.append(("mcp:\(name)", name, spec, nil))
            }
            configError = nil
        } catch {
            configError = "mcp.json: \(error.localizedDescription)"
        }
        plugins = Plugin.loadAll(from: pluginsURL)
        for plugin in plugins {
            for (name, spec) in plugin.servers.sorted(by: { $0.key < $1.key }) {
                specs.append(("plugin:\(plugin.id)/\(name)", name, spec, plugin.id))
            }
        }
        var prefixes = Set<String>(["builtin"])
        servers = specs.map { entry in
            var prefix = Self.sanitized(entry.name)
            var n = 2
            while prefixes.contains(prefix) { prefix = Self.sanitized(entry.name) + "\(n)"; n += 1 }
            prefixes.insert(prefix)
            return Server(id: entry.id, name: entry.name, spec: entry.spec, plugin: entry.plugin, prefix: prefix)
        }
        for server in servers { apply(server.id) }
    }

    /// Starts or stops one server to match its switch.
    private func apply(_ id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        if isServerOn(servers[index]) {
            if connections[id] == nil { start(id) }
        } else {
            attempts[id] = nil
            if let connection = connections.removeValue(forKey: id) { Task { await connection.close() } }
            servers[index].status = .off
            servers[index].tools = []
        }
    }

    func restart(_ id: String) {
        if let connection = connections.removeValue(forKey: id) { Task { await connection.close() } }
        apply(id)
    }

    /// The latest start of each server; an older start that finishes late is thrown away.
    private var attempts: [String: UUID] = [:]

    private func start(_ id: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        let server = servers[index]
        servers[index].status = .starting
        servers[index].tools = []
        let attempt = UUID()
        attempts[id] = attempt
        let pluginDir = server.plugin.map { pluginsURL.appendingPathComponent($0) }
        Task {
            var connection: MCP.Connection?
            do {
                let transport = try await makeTransport(server.spec, pluginDir: pluginDir, serverID: id)
                guard attempts[id] == attempt else { return }
                let opened = MCP.Connection(transport: transport)
                connection = opened
                connections[id] = opened
                try await opened.open()
                let tools = try await opened.listTools()
                guard attempts[id] == attempt, connections[id] === opened,
                      let i = servers.firstIndex(where: { $0.id == id }) else {
                    await opened.close()
                    return
                }
                servers[i].tools = tools
                servers[i].status = .running
            } catch {
                await connection?.close()
                guard attempts[id] == attempt, let i = servers.firstIndex(where: { $0.id == id }) else { return }
                if connections[id] === connection { connections[id] = nil }
                servers[i].status = .failed(error.localizedDescription)
            }
        }
    }

    private func makeTransport(_ spec: ServerSpec, pluginDir: URL?, serverID: String) async throws -> any MCP.Transport {
        let expand = { (text: String) -> String in
            var text = text
            if let pluginDir { text = text.replacingOccurrences(of: "${PLUGIN_DIR}", with: pluginDir.path) }
            if text.hasPrefix("~/") { text = FileManager.default.homeDirectoryForCurrentUser.path + text.dropFirst(1) }
            return text
        }
        let toolsChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.refreshTools(serverID) }
        }
        switch spec.kind {
        case .remote(let url, let headers):
            guard let url = URL(string: expand(url)), ["http", "https"].contains(url.scheme ?? "") else {
                throw MCP.Failure.server("That isn't a web address: \(url)")
            }
            return MCP.HTTPTransport(url: url, headers: headers.mapValues(expand), onToolsChanged: toolsChanged)
        case .local(let command, let args, let env, let cwd):
            let path = await ShellPath.value
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            for (key, value) in env { environment[key] = expand(value) }
            let command = expand(command)
            guard let executable = ShellPath.find(command, in: path) else { throw MCP.Failure.notFound(command) }
            return MCP.StdioTransport(
                executable: executable, arguments: args.map(expand), environment: environment,
                directory: cwd.map { URL(fileURLWithPath: expand($0)) },
                onExit: { [weak self] detail in
                    Task { @MainActor in self?.exited(serverID, detail) }
                },
                onToolsChanged: toolsChanged)
        }
    }

    private func exited(_ id: String, _ detail: String) {
        connections[id] = nil
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].tools = []
        servers[i].status = .failed(MCP.Failure.exited(detail).localizedDescription)
    }

    private func refreshTools(_ id: String) async {
        guard let connection = connections[id], let tools = try? await connection.listTools(),
              let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].tools = tools
    }

    // MARK: mcp.json

    private func readConfig() throws -> [String: ServerSpec] {
        guard let data = try? Data(contentsOf: configURL) else { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        let entries = json["mcpServers"] as? [String: Any] ?? [:]
        return try entries.reduce(into: [:]) { result, entry in
            guard let object = entry.value as? [String: Any] else { return }
            result[entry.key] = try ServerSpec(object, name: entry.key)
        }
    }

    /// Changes the `mcpServers` object in mcp.json, leaving anything else in the file alone.
    func updateConfig(_ change: (inout [String: [String: Any]]) -> Void) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL) {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCP.Failure.server("mcp.json isn't a JSON object, so it wasn't changed.")
            }
            json = existing
        }
        var servers = (json["mcpServers"] as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: Any] }
        change(&servers)
        json["mcpServers"] = servers
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: configURL, options: .atomic)
    }

    func addServer(name: String, spec: [String: Any]) throws {
        try updateConfig { $0[name] = spec }
        reload()
    }

    func removeServer(_ server: Server) throws {
        guard server.plugin == nil else { return }
        try updateConfig { $0[server.name] = nil }
        reload()
    }

    /// Writes an empty mcp.json if there's none, so there's something to open and edit.
    func ensureConfigFile() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? updateConfig { _ in }
    }
}

// MARK: - Server and plugin files

/// How to reach one MCP server, as written in mcp.json or a plugin.
struct ServerSpec {
    enum Kind {
        case local(command: String, args: [String], env: [String: String], cwd: String?)
        case remote(url: String, headers: [String: String])
    }

    let kind: Kind
    var disabled = false

    init(_ object: [String: Any], name: String) throws {
        disabled = object["disabled"] as? Bool ?? false
        let strings = { (key: String) -> [String: String] in
            (object[key] as? [String: Any] ?? [:]).compactMapValues { $0 as? String ?? ($0 as? NSNumber)?.stringValue }
        }
        if let url = object["url"] as? String ?? object["serverUrl"] as? String {
            kind = .remote(url: url, headers: strings("headers"))
        } else if let command = object["command"] as? String, !command.isEmpty {
            kind = .local(command: command, args: (object["args"] as? [Any] ?? []).map { "\($0)" },
                          env: strings("env"), cwd: object["cwd"] as? String)
        } else {
            throw MCP.Failure.server("“\(name)” needs a \"command\" or a \"url\".")
        }
    }

    /// One line for Settings: the command or the address.
    var summary: String {
        switch kind {
        case .local(let command, let args, _, _): return ([command] + args).joined(separator: " ")
        case .remote(let url, _): return url
        }
    }
}

/// A folder in Plugins with a `plugin.json`:
///
/// ```json
/// {
///   "name": "Calendar",
///   "description": "Reads your calendar",
///   "version": "1.0",
///   "instructions": "Use the calendar tools when the user asks about their day.",
///   "mcpServers": { "calendar": { "command": "${PLUGIN_DIR}/calendar-server" } },
///   "speech": { "list_events": { "label": "Checked your calendar",
///                                "filler": "Let me look at your calendar.", "readOnly": true } }
/// }
/// ```
/// `${PLUGIN_DIR}` is the plugin's folder. `instructions.md` next to it works too.
struct Plugin: Identifiable {
    struct Speech {
        var label: String?
        var filler: String?
        var readOnly: Bool?
    }

    /// The folder's name.
    let id: String
    let name: String
    let description: String
    let version: String?
    let instructions: String?
    let servers: [String: ServerSpec]
    /// Keyed by the tool's own name (without the server prefix).
    let speech: [String: Speech]
    /// Why it couldn't be read, if it couldn't.
    let problem: String?

    static func loadAll(from folder: URL) -> [Plugin] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(load)
    }

    static func load(_ folder: URL) -> Plugin {
        let id = folder.lastPathComponent
        let manifest = folder.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifest) else {
            return Plugin(id: id, name: id, description: "", version: nil, instructions: nil, servers: [:], speech: [:],
                          problem: "No plugin.json in this folder.")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return Plugin(id: id, name: id, description: "", version: nil, instructions: nil, servers: [:], speech: [:],
                          problem: "plugin.json isn't valid JSON.")
        }
        var servers: [String: ServerSpec] = [:]
        var problem: String?
        for (name, value) in json["mcpServers"] as? [String: Any] ?? [:] {
            guard let object = value as? [String: Any] else { continue }
            do { servers[name] = try ServerSpec(object, name: name) } catch { problem = error.localizedDescription }
        }
        var speech: [String: Speech] = [:]
        for (tool, value) in json["speech"] as? [String: Any] ?? [:] {
            guard let object = value as? [String: Any] else { continue }
            speech[tool] = Speech(label: object["label"] as? String, filler: object["filler"] as? String,
                                  readOnly: object["readOnly"] as? Bool)
        }
        let file = try? String(contentsOf: folder.appendingPathComponent("instructions.md"), encoding: .utf8)
        let instructions = [json["instructions"] as? String, file]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Plugin(
            id: id, name: json["name"] as? String ?? id, description: json["description"] as? String ?? "",
            version: (json["version"] as? String) ?? (json["version"] as? NSNumber)?.stringValue,
            instructions: instructions.isEmpty ? nil : instructions, servers: servers, speech: speech, problem: problem)
    }
}

// MARK: - Finding programs

/// Apps opened from the Dock get a bare PATH (/usr/bin:/bin…), so `npx`, `uvx` or
/// anything from Homebrew wouldn't be found. The login shell knows where they are.
enum ShellPath {
    static var value: String {
        get async { await Cache.shared.path() }
    }

    private actor Cache {
        static let shared = Cache()
        private var cached: String?

        func path() -> String {
            if let cached { return cached }
            let found = Self.loginShellPath()
            let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            var parts: [String] = []
            for part in (found ?? "").split(separator: ":").map(String.init) + extra where !parts.contains(part) && !part.isEmpty {
                parts.append(part)
            }
            let path = parts.joined(separator: ":")
            cached = path
            return path
        }

        private static func loginShellPath() -> String? {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", "printf '\\n__PATH__%s\\n' \"$PATH\""]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            // A slow shell profile shouldn't hold servers up for long.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            if process.isRunning { process.terminate(); return nil }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return text.components(separatedBy: "\n").first { $0.hasPrefix("__PATH__") }.map { String($0.dropFirst(8)) }
        }
    }

    /// A full path to the command, looking through PATH if it's a bare name.
    static func find(_ command: String, in path: String) -> URL? {
        let manager = FileManager.default
        if command.contains("/") {
            return manager.isExecutableFile(atPath: command) ? URL(fileURLWithPath: command) : nil
        }
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(command)"
            if manager.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// Splits a typed command line into words, honouring quotes and backslashes.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, escaped = false, inWord = false
        for c in line {
            if escaped { current.append(c); escaped = false; continue }
            if c == "\\" && quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
                continue
            }
            if c == "\"" || c == "'" { quote = c; inWord = true; continue }
            if c.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
                continue
            }
            current.append(c)
            inWord = true
        }
        if inWord { words.append(current) }
        return words
    }
}
