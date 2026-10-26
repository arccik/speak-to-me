import SwiftUI

/// Settings as a sidebar of panes, in the style of System Settings.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, shortcuts, voice, conversation, model

        var id: Self { self }
        var title: String { rawValue.capitalized }

        var subtitle: String {
            switch self {
            case .general: return "Sounds, the floating orb and your history"
            case .shortcuts: return "Talk or bring up the orb from any app"
            case .voice: return "How replies sound"
            case .conversation: return "Turn-taking, personality and tools"
            case .model: return "The language model in oMLX"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .shortcuts: return "command"
            case .voice: return "waveform"
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .model: return "cpu.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: return Color(white: 0.5)
            case .shortcuts: return RGBA.hex(0x3FA6FF).color()
            case .voice: return RGBA.hex(0x8E62F7).color()
            case .conversation: return RGBA.hex(0x2CC4A6).color()
            case .model: return RGBA.hex(0xF08A3C).color()
            }
        }
    }

    @AppStorage("settingsPane") private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    IconTile(systemImage: pane.icon, color: pane.color, size: 22)
                }
                .padding(.vertical, 2)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .shortcuts: ShortcutsPane()
                case .voice: VoicePane()
                case .conversation: ConversationPane()
                case .model: ModelPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 560)
        .tint(Theme.violet)
    }
}

// MARK: - Building blocks

/// A rounded square with a white symbol, like System Settings' sidebar icons.
private struct IconTile: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}

/// Big icon, title and one line of explanation at the top of each pane.
private struct PaneHeader: View {
    let pane: SettingsView.Pane

    var body: some View {
        Section {
            HStack(spacing: 14) {
                IconTile(systemImage: pane.icon, color: pane.color, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.title2.weight(.semibold))
                    Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A slider with words at each end and the current value on the right.
private struct LabeledSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride
    let low: String
    let high: String
    let format: (V) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            // Snapped by hand: a stepped Slider draws a tick for every step.
            Slider(value: Binding(get: { value }, set: { value = ($0 / V(step)).rounded() * V(step) }), in: range)
                .labelsHidden()
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }
}

/// Section footer: small, secondary, leading-aligned however long it wraps.
private struct Footer: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var session: VoiceSession
    @AppStorage("orbOnHotKey") private var orbOnHotKey = true
    @State private var orbVisible = MiniOrbController.shared.isVisible
    @State private var confirmDelete = false

    var body: some View {
        Form {
            PaneHeader(pane: .general)
            Section("Sounds") {
                Toggle("Play a sound when the mic turns on and off", isOn: $session.soundCues)
                Toggle("Speak replies out loud", isOn: Binding(get: { !session.muteReplies }, set: { session.muteReplies = !$0 }))
            }
            Section {
                Toggle("Show the floating orb", isOn: $orbVisible)
                    .onChange(of: orbVisible) {
                        orbVisible ? MiniOrbController.shared.show(session: session) : MiniOrbController.shared.hide()
                    }
                Toggle("Show it when I use the talk shortcut in another app", isOn: $orbOnHotKey)
            } header: {
                Text("Floating orb")
            } footer: {
                Footer("A small always-on-top orb you can drag anywhere. Click it to start or stop, right-click for options.")
            }
            Section {
                LabeledContent("Saved conversations") {
                    Text("\(session.savedConversations.count)").monospacedDigit()
                }
                Button("Delete All Conversations…", role: .destructive) { confirmDelete = true }
                    .disabled(session.savedConversations.isEmpty && session.lines.isEmpty)
                    .confirmationDialog("Delete all conversations?", isPresented: $confirmDelete) {
                        Button("Delete All", role: .destructive) { session.deleteAllConversations() }
                    } message: {
                        Text("This can't be undone.")
                    }
            } header: {
                Text("History")
            } footer: {
                Footer("Conversations are saved on this Mac only.")
            }
        }
        .onAppear { orbVisible = MiniOrbController.shared.isVisible }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        Form {
            PaneHeader(pane: .shortcuts)
            Section {
                row("Start or stop talking", detail: "Works in every app", action: .talk)
                row("Show or hide the floating orb", detail: "Keep it in a corner while you work", action: .floatingOrb)
            } header: {
                Text("From any app")
            } footer: {
                Footer("Click a shortcut, then press the new keys. Esc cancels, Delete turns it off. Use at least one of ⌘, ⌥ or ⌃.")
            }
            Section("In the Speak to Me window") {
                KeyRow(keys: "Space", title: "Start or stop talking")
                KeyRow(keys: "M", title: "Mute or unmute the mic")
                KeyRow(keys: "Esc", title: "Stop the current reply")
                KeyRow(keys: "↩", title: "Send a typed message")
                KeyRow(keys: "⌘N", title: "New conversation")
                KeyRow(keys: "⌘,", title: "Settings")
            }
        }
    }

    private func row(_ title: String, detail: String, action: Shortcuts.Action) -> some View {
        LabeledContent {
            ShortcutRecorder(action: action)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if shortcuts.conflict == action {
                    Label("Another app is using this shortcut. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct KeyRow: View {
    let keys: String
    let title: String

    var body: some View {
        LabeledContent(title) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 8)
                .frame(minWidth: 28, minHeight: 22)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.12)))
        }
    }
}

// MARK: - Voice

private struct VoicePane: View {
    @EnvironmentObject private var session: VoiceSession

    /// Voices grouped like "American female", in the order they're listed.
    private var groups: [(String, [String])] {
        var order: [String] = []
        var byGroup: [String: [String]] = [:]
        for id in VoiceSession.voices {
            let group = VoiceSession.voiceName(id).components(separatedBy: " · ").last ?? ""
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(id)
        }
        return order.map { ($0, byGroup[$0]!) }
    }

    var body: some View {
        Form {
            PaneHeader(pane: .voice)
            Section {
                LabeledContent("Voice") {
                    HStack(spacing: 8) {
                        Picker("Voice", selection: $session.voice) {
                            ForEach(groups, id: \.0) { group, ids in
                                Section(group.capitalized) {
                                    ForEach(ids, id: \.self) {
                                        Text(VoiceSession.voiceName($0).components(separatedBy: " · ").first ?? $0).tag($0)
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            session.readAloud("Hi! This is how I'll sound when we talk.")
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                        }
                        .disabled(!session.canToggle)
                        .help("Hear this voice")
                    }
                }
                LabeledSlider(title: "Speaking speed", value: $session.speed, range: 0.8...1.4, step: 0.05,
                              low: "Slower", high: "Faster") { String(format: "%.2f×", Double($0)) }
            }
            Section {
                Toggle("Answer in the language I speak", isOn: $session.matchLanguage)
                LabeledContent("Current language", value: LanguageDetector.name(session.language))
            } header: {
                Text("Language")
            } footer: {
                Footer("English uses the voice above. Other languages use macOS voices; get better ones in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            }
            MyVoiceSection()
        }
    }
}

/// Record (or pick) a sample of your voice, then hear replies in it.
private struct MyVoiceSection: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Section {
            Toggle("Speak replies in my voice", isOn: $session.useMyVoice)
                .disabled(!session.hasMyVoice)
            VStack(alignment: .leading, spacing: 6) {
                Text("Read this aloud")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(VoiceSession.voiceScript)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack {
                Button {
                    Task { await session.recordMyVoice() }
                } label: {
                    Label(session.hasMyVoice ? "Re-record (12 s)" : "Record My Voice (12 s)", systemImage: "record.circle")
                }
                Button("Use an Audio File…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.audio]
                    if panel.runModal() == .OK, let url = panel.url {
                        Task { await session.importMyVoice(from: url) }
                    }
                }
                Spacer()
                if session.hasMyVoice {
                    Button("Delete", role: .destructive) { session.deleteMyVoice() }
                }
            }
            .disabled(session.myVoiceBusy)
            if let status = session.myVoiceStatus {
                HStack(spacing: 6) {
                    if session.myVoiceBusy { ProgressView().controlSize(.small) }
                    Text(status).font(.callout)
                }
            }
        } header: {
            Text("Your voice")
        } footer: {
            Footer("Read at your normal pace in a quiet room. Everything stays on this Mac. Used for English replies; a little slower than the built-in voices.")
        }
    }
}

// MARK: - Conversation

private struct ConversationPane: View {
    @EnvironmentObject private var session: VoiceSession

    private static let rule = " Never use markdown, lists, headings, code blocks or emoji: everything you write is read aloud."

    private static let presets: [(name: String, icon: String, prompt: String)] = [
        ("Friendly", "face.smiling", VoiceSession.defaultPrompt),
        ("Concise", "bolt", "You are a calm, efficient voice assistant. Answer in one short sentence whenever you can, and only add detail when asked." + rule),
        ("Tutor", "graduationcap", "You are a patient tutor in a spoken conversation. Explain things simply, one idea at a time, use everyday examples, and end with a short question to check understanding." + rule),
        ("Playful", "sparkles", "You are a witty, playful voice companion. Keep answers short and fun, with light humour, while still being genuinely helpful." + rule),
    ]

    private var endOfTurn: Binding<Double> {
        Binding(get: { Double(session.endOfTurnMs) }, set: { session.endOfTurnMs = Int($0) })
    }

    var body: some View {
        Form {
            PaneHeader(pane: .conversation)
            Section {
                LabeledSlider(title: "Reply after a pause of", value: endOfTurn, range: 256...2048, step: 128,
                              low: "Snappy", high: "Patient") { "\(Int($0)) ms" }
            } header: {
                Text("Turn-taking")
            } footer: {
                Footer("Shorter feels snappier; longer gives you time to think mid-sentence.")
            }
            Section {
                Toggle("Let me interrupt replies without headphones", isOn: $session.echoCancellation)
            } footer: {
                Footer("Cancels the assistant's voice from the mic so you can talk over it. It only runs while a reply is under way; macOS turns down other apps' sound, like YouTube or music, during that time. When off, the mic pauses while a reply plays. Takes effect the next time you start talking.")
            }
            Section("Personality") {
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.name) { preset in
                        PresetChip(name: preset.name, icon: preset.icon,
                                   selected: session.systemPrompt == preset.prompt) {
                            session.systemPrompt = preset.prompt
                        }
                    }
                }
                TextEditor(text: $session.systemPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 110)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Section {
                Toggle("Let it use tools", isOn: $session.useTools)
            } header: {
                Text("Tools")
            } footer: {
                Footer("Web search, the time, and opening apps or pages. Replies that need them take a few seconds longer.")
            }
        }
    }
}

private struct PresetChip: View {
    let name: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(name, systemImage: icon)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model

private struct ModelPane: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Form {
            PaneHeader(pane: .model)
            Section {
                Picker("Model", selection: Binding(get: { session.modelID }, set: {
                    session.modelID = $0
                    session.modelChanged()
                })) {
                    ForEach(session.models) { model in
                        Text("\(model.id)  ·  \(String(format: "%.1f GB", Double(model.sizeBytes) / 1_073_741_824))")
                            .tag(model.id)
                    }
                }
                LabeledContent("Server", value: session.serverAddress)
                if let ms = session.lastLatencyMs {
                    LabeledContent("Last reply started after", value: "\(ms) ms")
                }
            } footer: {
                Footer("Mixture-of-experts models (names with a3b or a4b) reply fastest. The server address comes from ~/.omlx/settings.json.")
            }
            Section {
                Toggle("Keep the model loaded in oMLX", isOn: $session.keepModelLoaded)
                    .onChange(of: session.keepModelLoaded) { Task { await session.updatePin() } }
            } footer: {
                Footer("Pinning keeps replies instant but holds the model's memory while oMLX runs.")
            }
        }
    }
}
