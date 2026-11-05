import AppKit
import CryptoKit
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
        disabledServers = Set(defaults.stringArray(forKey: "disabledServers") ?? [])
        disabledTools = Set(defaults.stringArray(forKey: "disabledTools") ?? [])
        trustedTools = Set(defaults.stringArray(forKey: "trustedToolFingerprintsV2") ?? [])
        approvedPlugins = defaults.dictionary(forKey: "approvedPlugins") as? [String: String] ?? [:]
    }

    // MARK: Switches

    /// The switches, kept here (not only in UserDefaults) so Settings redraws when they change.
    /// Each plugin you switched on, with a fingerprint of its files at that moment.
    private var approvedPlugins: [String: String] { didSet { defaults.set(approvedPlugins, forKey: "approvedPlugins") } }
    /// Explicit grants bound to a server configuration and tool definition.
    private var trustedTools: Set<String> { didSet { defaults.set(trustedTools.sorted(), forKey: "trustedToolFingerprintsV2") } }
    private var disabledServers: Set<String> { didSet { defaults.set(disabledServers.sorted(), forKey: "disabledServers") } }
    private var disabledTools: Set<String> { didSet { defaults.set(disabledTools.sorted(), forKey: "disabledTools") } }

    /// Plugins can run programs, so each one is off until you switch it on. Reload
    /// notices manifest/instruction edits; it does not verify executable dependencies.
    func isPluginOn(_ plugin: Plugin) -> Bool {
        plugin.problem == nil && approvedPlugins[plugin.id] == plugin.fingerprint
    }

    /// Switched on once, but its files changed since.
    func pluginChanged(_ plugin: Plugin) -> Bool {
        approvedPlugins[plugin.id].map { $0 != plugin.fingerprint } ?? false
    }

    func setPlugin(_ plugin: Plugin, on: Bool) {
        approvedPlugins[plugin.id] = on ? plugin.fingerprint : nil
        for server in servers where server.plugin == plugin.id { apply(server.id) }
    }

    /// Servers you added yourself are on unless switched off (or `"disabled": true`).
    func isServerOn(_ server: Server) -> Bool {
        if let id = server.plugin, !(plugins.first { $0.id == id }.map(isPluginOn) ?? false) { return false }
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
        policyGeneration = UUID()
        if on { disabledTools.remove(toolKey(serverID, tool)) } else { disabledTools.insert(toolKey(serverID, tool)) }
    }

    /// How a tool is allowed to run.
    enum Permission {
        /// You explicitly trust the server's claim that it only reads.
        case readOnly
        /// It changes things, and asks first unless you said otherwise.
        case asks(trusted: Bool)
        /// It may delete or overwrite things: it asks every time, and that can't be switched off.
        case alwaysAsks
    }

    /// An annotation alone never grants automatic execution. A read-only claim needs
    /// explicit user trust; destructive tools always ask regardless of saved grants.
    func permission(server serverID: String, tool: MCP.Tool) -> Permission {
        if tool.destructive { return .alwaysAsks }
        let trusted = trustKey(serverID, tool).map { trustedTools.contains($0) } ?? false
        if tool.readOnly && trusted { return .readOnly }
        return .asks(trusted: trusted)
    }

    func setTrusted(server serverID: String, tool: String, trusted: Bool) {
        policyGeneration = UUID()
        guard let definition = servers.first(where: { $0.id == serverID })?.tools.first(where: { $0.name == tool }),
              let key = trustKey(serverID, definition) else { return }
        if trusted { trustedTools.insert(key) } else { trustedTools.remove(key) }
    }

    /// The model wants to run something that needs your OK first. Built-in tools never do:
    /// they can only open apps and http(s) pages, and read the web.
    func needsApproval(_ call: OMLXClient.ToolCall) -> Bool {
        guard let (server, tool) = resolve(call.name) else { return false }
        switch permission(server: server.id, tool: tool) {
        case .readOnly, .asks(trusted: true): return false
        case .asks(trusted: false), .alwaysAsks: return true
        }
    }

    /// What the approval card shows: which tool, from where, and with what.
    func approvalDetails(_ call: OMLXClient.ToolCall) -> (title: String, server: String, arguments: String, destructive: Bool) {
        guard let (server, tool) = resolve(call.name) else { return (call.name, "", call.arguments, true) }
        var arguments = call.arguments
        if let object = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            arguments = String(decoding: pretty, as: UTF8.self)
        }
        let origin = server.plugin.map { id in "\(plugins.first { $0.id == id }?.name ?? id) plugin" } ?? server.name
        let title = tool.title.map { $0 == tool.name ? $0 : "\($0) (\(tool.name))" } ?? tool.name
        return (title, origin, arguments, tool.destructive)
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
        let matches = activeTools.filter { Self.qualifiedName($0.0.prefix, $0.1.name) == name }
        return matches.count == 1 ? matches[0] : nil
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
        // Only explicitly trusted, server-declared reads can run in a draft.
        if case .readOnly = permission(server: server.id, tool: tool) { return false }
        return true
    }

    /// A request keeps the identities it was actually offered. A model cannot invent
    /// a tool or reuse an old name after a reload and get it dispatched.
    struct Catalog {
        let definitions: [[String: Any]]
        fileprivate let identities: [String: String]
    }

    struct PreparedCall {
        let call: OMLXClient.ToolCall
        let title: String
        let server: String
        let serverID: String?
        let arguments: String
        let needsApproval: Bool
        let hasSideEffects: Bool
        let destructive: Bool
        fileprivate let identity: String
    }

    var enabled = true { didSet { if enabled != oldValue { policyGeneration = UUID() } } }

    func catalog(available: Bool = true) -> Catalog {
        guard enabled && available else { return Catalog(definitions: [], identities: [:]) }
        let definitions = definitions.filter { definition in
            guard let name = (definition["function"] as? [String: Any])?["name"] as? String else { return false }
            return identity(for: name) != nil
        }
        var identities: [String: String] = [:]
        for definition in definitions {
            if let name = (definition["function"] as? [String: Any])?["name"] as? String { identities[name] = identity(for: name) }
        }
        return Catalog(definitions: definitions, identities: identities)
    }

    func prepare(_ call: OMLXClient.ToolCall, catalog: Catalog) throws -> PreparedCall {
        guard enabled, let offered = catalog.identities[call.name], offered == identity(for: call.name) else {
            throw MCP.Failure.server("This tool is off, changed, or wasn't offered for this reply. Nothing ran.")
        }
        guard call.arguments.utf8.count <= MCP.messageLimit,
              (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) is [String: Any] else {
            throw MCP.Failure.server("The tool arguments aren't a valid JSON object. Nothing ran.")
        }
        let details = approvalDetails(call)
        return PreparedCall(call: call, title: details.title, server: details.server.isEmpty ? "Built-in" : details.server,
                            serverID: resolve(call.name)?.0.id, arguments: details.arguments,
                            needsApproval: needsApproval(call), hasSideEffects: hasSideEffects(call),
                            destructive: details.destructive, identity: offered)
    }

    func isCurrent(_ prepared: PreparedCall) -> Bool {
        enabled && prepared.identity == identity(for: prepared.call.name)
    }

    func run(_ prepared: PreparedCall, approved: Bool = false, client: OMLXClient) async -> ToolOutcome {
        guard !Task.isCancelled else { return .init(state: .cancelled, text: "Cancelled before starting. Nothing ran.") }
        guard isCurrent(prepared) else { return .init(state: .blocked, text: "This tool is off or changed. Nothing ran. Ask again to use the current tool.") }
        guard !prepared.needsApproval || approved else { return .init(state: .blocked, text: "This action needs permission. Nothing ran.") }
        let call = prepared.call
        guard let (server, tool) = resolve(call.name) else {
            return await Tools.runOutcome(call, client: client)
        }
        guard let connection = connections[server.id],
              let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] else {
            return .init(state: .blocked, text: "The server isn't available. Nothing ran.")
        }
        do {
            let result = try await connection.callTool(tool.name, arguments: arguments)
            let text = String(result.text.prefix(Self.resultLimit)) + (result.text.count > Self.resultLimit ? "…" : "")
            return .init(state: result.isError ? .failed : .succeeded, text: result.isError ? "The tool reported an error: \(text)" : text)
        } catch {
            if case MCP.Failure.sessionExpired = error, connections[server.id] === connection { restart(server.id) }
            let cancelled = Task.isCancelled || error is CancellationError
            let state: ToolAction.State = prepared.hasSideEffects ? .unknown : (cancelled ? .cancelled : .failed)
            let detail = prepared.hasSideEffects
                ? "The action may have completed. Check \(server.name) before trying again. " : ""
            return .init(state: state, text: detail + (cancelled ? "The reply was stopped." : error.localizedDescription))
        }
    }

    private func identity(for name: String) -> String? {
        if Tools.definitions.contains(where: { ($0["function"] as? [String: Any])?["name"] as? String == name }) {
            return isToolOn(server: "builtin", tool: name) ? "builtin/" + name + "/" + policyGeneration.uuidString : nil
        }
        guard let (server, tool) = resolve(name), let generation = attempts[server.id], let key = trustKey(server.id, tool) else { return nil }
        return key + "/" + generation.uuidString + "/" + policyGeneration.uuidString
    }

    private var policyGeneration = UUID()

    private func trustKey(_ id: String, _ tool: MCP.Tool) -> String? {
        guard let server = servers.first(where: { $0.id == id }) else { return nil }
        let object: [String: Any] = ["server": id, "config": server.spec.fingerprint,
            "plugin": server.plugin.flatMap { id in plugins.first { $0.id == id }?.fingerprint } ?? "",
            "name": tool.name, "title": tool.title ?? "", "description": tool.description,
            "schema": (try? JSONSerialization.jsonObject(with: tool.schema)) ?? [:],
            "readOnly": tool.readOnly, "destructive": tool.destructive]
        return Self.digest((try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data())
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Preserve simple names, reserving a digest suffix for lossy transformations.
    nonisolated static func qualifiedName(_ prefix: String, _ tool: String) -> String {
        let readable = sanitized(prefix) + "__" + sanitized(tool)
        if readable.count <= 64 && sanitized(tool) == tool && sanitized(prefix) == prefix
            && !prefix.contains("__") && !tool.contains("__") { return readable }
        let suffix = String(digest(Data((prefix + "\u{0}" + tool).utf8)).prefix(16))
        return String(readable.prefix(46)) + "__" + suffix
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
        policyGeneration = UUID()
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
                let transport = try await makeTransport(server.spec, pluginDir: pluginDir, serverID: id, attempt: attempt)
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

    private func makeTransport(_ spec: ServerSpec, pluginDir: URL?, serverID: String, attempt: UUID) async throws -> any MCP.Transport {
        let expand = { (text: String) -> String in
            var text = text
            if let pluginDir { text = text.replacingOccurrences(of: "${PLUGIN_DIR}", with: pluginDir.path) }
            if text.hasPrefix("~/") { text = FileManager.default.homeDirectoryForCurrentUser.path + text.dropFirst(1) }
            return text
        }
        let toolsChanged: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in await self?.refreshTools(serverID, attempt: attempt) }
        }
        switch spec.kind {
        case .remote(let url, let headers):
            guard let url = URL(string: expand(url)), ["http", "https"].contains(url.scheme ?? "") else {
                throw MCP.Failure.server("That isn't a web address: \(url)")
            }
            guard MCP.HTTPTransport.isAllowed(url) else {
                throw MCP.Failure.server("Use https:// for a server on another computer: over plain http, anyone on the network could read or change what's sent.")
            }
            return MCP.HTTPTransport(url: url, headers: headers.mapValues(expand), onToolsChanged: toolsChanged)
        case .local(let command, let args, let env, let cwd):
            let path = await ShellPath.value
            // Only what a program needs to run; nothing else from the app's own environment.
            let inherited = ProcessInfo.processInfo.environment
            var environment = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "__CF_USER_TEXT_ENCODING"]
                .reduce(into: [String: String]()) { $0[$1] = inherited[$1] }
            environment["PATH"] = path
            for (key, value) in env { environment[key] = expand(value) }
            let command = expand(command)
            guard let executable = ShellPath.find(command, in: path) else { throw MCP.Failure.notFound(command) }
            return MCP.StdioTransport(
                executable: executable, arguments: args.map(expand), environment: environment,
                directory: cwd.map { URL(fileURLWithPath: expand($0)) },
                onExit: { [weak self] detail in
                    Task { @MainActor in self?.exited(serverID, detail, attempt: attempt) }
                },
                onToolsChanged: toolsChanged)
        }
    }

    private func exited(_ id: String, _ detail: String, attempt: UUID) {
        guard attempts[id] == attempt else { return }
        connections[id] = nil
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].tools = []
        servers[i].status = .failed(MCP.Failure.exited(detail).localizedDescription)
    }

    private var refreshing: [String: UUID] = [:]
    private var refreshAgain: [String: UUID] = [:]

    private func refreshTools(_ id: String, attempt: UUID) async {
        guard attempts[id] == attempt, let connection = connections[id] else { return }
        if refreshing[id] == attempt { refreshAgain[id] = attempt; return }
        refreshing[id] = attempt
        defer {
            if refreshing[id] == attempt { refreshing[id] = nil }
            if refreshAgain[id] == attempt {
                refreshAgain[id] = nil
                Task { await refreshTools(id, attempt: attempt) }
            }
        }
        do {
            let tools = try await connection.listTools()
            guard attempts[id] == attempt, connections[id] === connection,
                  let i = servers.firstIndex(where: { $0.id == id }) else { return }
            servers[i].tools = tools
        } catch {
            guard attempts[id] == attempt, connections[id] === connection else { return }
            connections[id] = nil
            await connection.close()
            guard attempts[id] == attempt, let i = servers.firstIndex(where: { $0.id == id }) else { return }
            servers[i].tools = []
            servers[i].status = .failed(error.localizedDescription)
        }
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
        // It can hold tokens: readable by you only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
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
    let fingerprint: String
    var disabled = false

    init(_ object: [String: Any], name: String) throws {
        fingerprint = ToolHub.digest(try JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
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
    /// A hash of plugin.json and instructions.md, to notice when either changes.
    var fingerprint = ""

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
        var plugin = Plugin(
            id: id, name: json["name"] as? String ?? id, description: json["description"] as? String ?? "",
            version: (json["version"] as? String) ?? (json["version"] as? NSNumber)?.stringValue,
            instructions: instructions.isEmpty ? nil : instructions, servers: servers, speech: speech, problem: problem)
        let hashed = data + Data((file ?? "").utf8)
        plugin.fingerprint = SHA256.hash(data: hashed).map { String(format: "%02x", $0) }.joined()
        return plugin
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
