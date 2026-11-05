import AppKit
import SwiftUI

/// Settings → Tools: the built-in tools, MCP servers from mcp.json, and plugins.
struct ToolsPane: View {
    @Environment(VoiceSession.self) private var session
    private let hub = ToolHub.shared
    @State private var adding = false
    @State private var removing: ToolHub.Server?

    private static let builtInNames: [String: String] = [
        "web_search": "Search the web",
        "fetch_url": "Read web pages",
        "get_time": "Check the time",
        "open_app": "Open apps",
        "open_url": "Open web pages",
    ]

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                Toggle("Let it use tools", isOn: $session.useTools)
            } footer: {
                Footer(countNote)
            }
            .onAppear { hub.startOnce() }

            Section {
                ForEach(Tools.definitions.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }, id: \.self) { name in
                    ToolSwitch(serverID: "builtin", tool: name, title: Self.builtInNames[name] ?? name, detail: nil)
                }
            } header: {
                Text("Built-in")
            }
            .disabled(!session.useTools)

            Section {
                let own = hub.servers.filter { $0.plugin == nil }
                if own.isEmpty {
                    Text("No servers yet").foregroundStyle(.secondary)
                }
                ForEach(own) { server in
                    ServerRow(server: server, onRemove: { removing = server })
                }
                if let error = hub.configError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                HStack {
                    Button("Add Server…") { adding = true }
                    Button("Edit mcp.json") {
                        hub.ensureConfigFile()
                        NSWorkspace.shared.open(hub.configURL)
                    }
                    Spacer()
                    Button("Reload") { hub.reload() }
                        .help("Read mcp.json and the plugins again, and restart every server")
                }
            } header: {
                Text("MCP servers")
            } footer: {
                Footer("Tools from Model Context Protocol servers, as programs on this Mac or web addresses. A tool that can change things asks you in the main window before it runs, and one that may delete or overwrite things asks every time. Only add servers you trust: a program you add here runs with your permissions. mcp.json uses the same mcpServers format as Claude Desktop, so you can paste a server from there. Anything you put in it, tokens too, is saved as plain text in ~/Library/Application Support/SpeakToMe.")
            }

            Section {
                if hub.plugins.isEmpty {
                    Text("No plugins installed").foregroundStyle(.secondary)
                }
                ForEach(hub.plugins) { plugin in
                    PluginRow(plugin: plugin)
                }
                HStack {
                    Button("Open Plugins Folder") {
                        try? FileManager.default.createDirectory(at: hub.pluginsURL, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(hub.pluginsURL)
                    }
                    Spacer()
                    Button("Reload") { hub.reload() }
                }
            } header: {
                Text("Plugins")
            } footer: {
                Footer("A plugin is a folder with a plugin.json that lists MCP servers to start, instructions for the model and how to announce its tools out loud. Plugins can run programs, so each one stays off until you switch it on.")
            }
        }
        .sheet(isPresented: $adding) { AddServerSheet() }
        .confirmationDialog("Remove \(removing?.name ?? "this server")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let server = removing { try? hub.removeServer(server) }
                removing = nil
            }
        } message: {
            Text("It's taken out of mcp.json.")
        }
    }

    private var countNote: String {
        let count = hub.enabledToolCount
        var note = "\(count) \(count == 1 ? "tool is" : "tools are") on. Replies that use a tool take a few seconds longer."
        if count > ToolHub.comfortableToolCount {
            note += " With more than \(ToolHub.comfortableToolCount), a small model picks the wrong one more often, and every tool makes replies a little slower to start. Switch off the ones you don't need."
        }
        return note
    }
}

/// One tool's on/off switch.
private struct ToolSwitch: View {
    let serverID: String
    let tool: String
    let title: String
    let detail: String?
    private let hub = ToolHub.shared

    var body: some View {
        Toggle(isOn: Binding(get: { hub.isToolOn(server: serverID, tool: tool) },
                             set: { hub.setTool(server: serverID, tool: tool, on: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// Under each MCP tool: whether it runs on its own or waits for your OK.
private struct PermissionLine: View {
    let serverID: String
    let tool: MCP.Tool
    private let hub = ToolHub.shared

    var body: some View {
        switch hub.permission(server: serverID, tool: tool) {
        case .readOnly:
            note("Only reads, so it runs without asking", "eye")
        case .alwaysAsks:
            note("May delete or overwrite things, so it asks every time", "exclamationmark.shield")
        case .asks(let trusted):
            Toggle(isOn: Binding(get: { !trusted }, set: { hub.setTrusted(server: serverID, tool: tool.name, trusted: !$0) })) {
                Label("Ask before it changes anything", systemImage: "hand.raised")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.mini)
            .padding(.leading, 12)
        }
    }

    private func note(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
    }
}

private struct ServerRow: View {
    let server: ToolHub.Server
    var onRemove: (() -> Void)?
    private let hub = ToolHub.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer()
                Menu {
                    Button("Restart") { hub.restart(server.id) }
                        .disabled(!hub.isServerOn(server))
                    if let onRemove {
                        Divider()
                        Button("Remove…", role: .destructive, action: onRemove)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Toggle("", isOn: Binding(get: { hub.isServerOn(server) }, set: { hub.setServer(server, on: $0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if !server.tools.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(server.tools) { tool in
                        ToolSwitch(serverID: server.id, tool: tool.name, title: tool.title ?? tool.name,
                                   detail: tool.description)
                        PermissionLine(serverID: server.id, tool: tool)
                    }
                } label: {
                    Text("\(server.tools.count) \(server.tools.count == 1 ? "tool" : "tools")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var isFailed: Bool {
        if case .failed = server.status { return true }
        return false
    }

    private var color: Color {
        switch server.status {
        case .off: return .secondary.opacity(0.4)
        case .starting: return .yellow
        case .running: return .green
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch server.status {
        case .off: return server.spec.summary
        case .starting: return "Starting…"
        case .running: return server.spec.summary
        case .failed(let message): return message
        }
    }
}

private struct PluginRow: View {
    let plugin: Plugin
    private let hub = ToolHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name)
                        if let version = plugin.version {
                            Text(version).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if !plugin.description.isEmpty {
                        Text(plugin.description).font(.caption).foregroundStyle(.secondary)
                    }
                    if hub.pluginChanged(plugin) {
                        Label("Its files changed since you switched it on, so it's off until you check it and switch it on again.",
                              systemImage: "exclamationmark.shield.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let problem = plugin.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Toggle("", isOn: Binding(get: { hub.isPluginOn(plugin) }, set: { hub.setPlugin(plugin, on: $0) }))
                    .disabled(plugin.problem != nil)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            if hub.isPluginOn(plugin) {
                ForEach(hub.servers.filter { $0.plugin == plugin.id }) { server in
                    ServerRow(server: server).padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Adds a server to mcp.json: a command to run, or a web address.
private struct AddServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let hub = ToolHub.shared

    enum Kind: String, CaseIterable, Identifiable {
        case command = "Program on this Mac"
        case url = "Web address"
        var id: Self { self }
    }

    @State private var name = ""
    @State private var kind = Kind.command
    @State private var command = ""
    @State private var environment = ""
    @State private var url = ""
    @State private var headers = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add an MCP Server").font(.display(20)).padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("filesystem"))
                Picker("Runs as", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch kind {
                case .command:
                    TextField("Command", text: $command,
                              prompt: Text("npx -y @modelcontextprotocol/server-filesystem ~/Documents"))
                        .font(.body.monospaced())
                    LabeledLines(title: "Environment", text: $environment, placeholder: "API_KEY=…  (one per line)")
                case .url:
                    TextField("Address", text: $url, prompt: Text("https://example.com/mcp"))
                        .font(.body.monospaced())
                    LabeledLines(title: "Headers", text: $headers, placeholder: "Authorization: Bearer …  (one per line)")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (kind == .command ? command : url).trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    private func add() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !hub.servers.contains(where: { $0.plugin == nil && $0.name == name }) else {
            error = "There's already a server called \(name)."
            return
        }
        var spec: [String: Any] = [:]
        switch kind {
        case .command:
            let words = ShellPath.words(command)
            guard let first = words.first else { return }
            spec["command"] = first
            if words.count > 1 { spec["args"] = Array(words.dropFirst()) }
            let env = Self.pairs(environment, separator: "=")
            if !env.isEmpty { spec["env"] = env }
        case .url:
            let address = url.trimmingCharacters(in: .whitespaces)
            guard let parsed = URL(string: address), ["http", "https"].contains(parsed.scheme ?? "") else {
                error = "That doesn't look like a web address. It should start with https://."
                return
            }
            spec["url"] = address
            let pairs = Self.pairs(headers, separator: ":")
            if !pairs.isEmpty { spec["headers"] = pairs }
        }
        do {
            try hub.addServer(name: name, spec: spec)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// "KEY=value" or "Name: value" lines into a dictionary.
    private static func pairs(_ text: String, separator: Character) -> [String: String] {
        text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard let split = line.firstIndex(of: separator) else { return }
            let key = line[..<split].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
    }
}

private struct LabeledLines: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 60)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
