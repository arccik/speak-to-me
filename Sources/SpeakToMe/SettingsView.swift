import AVFoundation
import SwiftUI

/// Settings as a sidebar of panes, in the style of System Settings.
struct SettingsView: View {
    // Keep existing raw values so previously selected categories still restore.
    enum Pane: String, CaseIterable, Identifiable {
        case overview, model, listening, voice, cloning, conversation, general, shortcuts, history, tools, connections

        var id: Self { self }
        var title: String {
            switch self {
            case .overview: return "Start Here"
            case .model: return "AI Model"
            case .listening: return "Microphone & Listening"
            case .voice: return "Voice & Language"
            case .cloning: return "Voice Cloning"
            case .conversation: return "Assistant & Replies"
            case .general: return "Appearance & Sounds"
            case .shortcuts: return "Keyboard Shortcuts"
            case .history: return "Conversation History"
            case .tools: return "Tools"
            case .connections: return "Servers & Plugins"
            }
        }

        var subtitle: String {
            switch self {
            case .overview: return "A few simple steps to make Speak to Me yours."
            case .model: return "Choose the AI that writes your replies."
            case .listening: return "Help the mic hear you and set when the assistant responds."
            case .voice: return "Choose how replies sound and which language to use."
            case .cloning: return "Record or import a voice for English or Russian replies."
            case .conversation: return "Choose the assistant’s personality and instructions."
            case .general: return "Manage the floating face and microphone sounds."
            case .shortcuts: return "Control conversations from this window or any app."
            case .history: return "Manage conversations saved on this Mac."
            case .tools: return "Choose what the assistant can do beyond replying."
            case .connections: return "Connect extra tools through MCP servers and plugins."
            }
        }

        var topics: [String] {
            switch self {
            case .overview: return ["First-time setup", "Getting started"]
            case .model: return ["Chat model", "oMLX server", "Memory and keep loaded", "Reply latency"]
            case .listening: return ["Microphone sensitivity and test", "Pause before replying", "Interrupt replies", "Echo cancellation", "Headphones"]
            case .voice: return ["Speak replies out loud", "Mute reply audio", "Speaking speed", "Language detection", "English Kokoro PocketTTS", "Russian F5-TTS", "Other languages Supertonic macOS", "Expressive voice", "Pronunciation and word stress"]
            case .cloning: return ["Record a voice", "Import an audio file", "English PocketTTS", "Russian F5-TTS", "Rename or delete recordings", "Transcript"]
            case .conversation: return ["Personality presets", "Friendly Concise Tutor Playful", "System prompt", "Custom instructions"]
            case .general: return ["Floating face", "Show face with talk shortcut", "Microphone sound cues and beeps"]
            case .shortcuts: return ["Global hotkeys", "Keyboard controls", "Start or stop talking", "Mute microphone", "Type a message"]
            case .history: return ["Saved conversations", "Local storage and privacy", "Delete all conversations"]
            case .tools: return ["Enable tools", "Web search", "Read web pages", "Check time", "Open apps and URLs"]
            case .connections: return ["MCP servers", "Add server", "Edit mcp.json", "Plugins folder", "Tool permissions and trust", "Reload connections"]
            }
        }

        var icon: String {
            switch self {
            case .overview: return "hand.wave"
            case .model: return "cpu"
            case .listening: return "mic"
            case .voice: return "waveform"
            case .cloning: return "person.wave.2"
            case .conversation: return "bubble.left.and.bubble.right"
            case .general: return "macwindow"
            case .shortcuts: return "command"
            case .history: return "clock.arrow.circlepath"
            case .tools: return "wrench.and.screwdriver"
            case .connections: return "puzzlepiece.extension"
            }
        }

        func matches(_ query: String) -> Bool {
            let text = ([title, subtitle] + topics).joined(separator: " ")
            return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
                text.localizedStandardContains(String($0))
            }
        }
    }

    static let groups: [(String, [Pane])] = [
        ("Get started", [.overview, .model]),
        ("Conversation", [.listening, .voice, .cloning, .conversation]),
        ("App", [.general, .shortcuts, .history]),
        ("Extensions", [.tools, .connections]),
    ]
    static var height: CGFloat = 680
    static let width: CGFloat = 900

    @AppStorage("settingsPane") private var pane: Pane = .overview
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    init(initialSearch: String = "") {
        _search = State(initialValue: initialSearch)
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var results: [Pane] { Pane.allCases.filter { $0.matches(query) } }

    private func navigate(to destination: Pane) {
        pane = destination
        search = ""
        searchFocused = false
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search settings", text: $search)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { search = ""; searchFocused = false }
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear settings search")
                    }
                }
                .padding(8)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .padding(12)
                List(selection: Binding<Pane?>(get: { query.isEmpty ? pane : nil }, set: {
                    if let destination = $0 { navigate(to: destination) }
                })) {
                    ForEach(Self.groups, id: \.0) { group in
                        Section(group.0) {
                            ForEach(group.1) { destination in
                                Label {
                                    Text(destination.title)
                                } icon: {
                                    Image(systemName: destination.icon).foregroundStyle(Theme.accent)
                                }
                                .padding(.vertical, 3)
                                .tag(destination)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                Text("Changes save automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            .frame(minWidth: 230, maxWidth: 230)
            .navigationSplitViewColumnWidth(230)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(query.isEmpty ? pane.title : "Search Settings").font(.display(24))
                    Text(query.isEmpty ? pane.subtitle : "Find a category by name or by what you want to change.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 22)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.horizontal, 28)
                Group {
                    if !query.isEmpty {
                        searchResults
                    } else {
                        switch pane {
                        case .overview: OverviewPane(navigate: navigate)
                        case .general: GeneralPane()
                        case .shortcuts: ShortcutsPane()
                        case .listening: ListeningPane()
                        case .voice: VoicePane()
                        case .cloning: VoiceCloningPane()
                        case .conversation: ConversationPane()
                        case .history: HistoryPane()
                        case .tools: ToolsPane()
                        case .connections: ToolsPane(connections: true)
                        case .model: ModelPane()
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(query.isEmpty ? pane.rawValue : "search")
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Settings")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: Self.width, height: Self.height)
        .tint(Theme.accent)
    }

    private var searchResults: some View {
        Group {
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No Settings Found", systemImage: "magnifyingglass")
                } description: {
                    Text("Try a word like “voice”, “microphone”, “shortcut” or “server”.")
                } actions: {
                    Button("Clear Search") { search = ""; searchFocused = true }
                }
            } else {
                Form {
                    Section("\(results.count) matching \(results.count == 1 ? "category" : "categories")") {
                        ForEach(results) { destination in
                            SettingsLink(destination: destination, detail: destination.topics.joined(separator: " · ")) {
                                navigate(to: destination)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsLink: View {
    let destination: SettingsView.Pane
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: destination.icon)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title).fontWeight(.medium).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewPane: View {
    @Environment(VoiceSession.self) private var session
    let navigate: (SettingsView.Pane) -> Void

    var body: some View {
        Form {
            Section {
                SettingsLink(destination: .model,
                             detail: session.models.isEmpty ? "Start oMLX with a chat model, then choose it here." : "Selected: \(session.modelID)") { navigate(.model) }
                SettingsLink(destination: .listening, detail: "Test your mic and choose how long to pause before a reply.") { navigate(.listening) }
                SettingsLink(destination: .voice, detail: "Pick a voice, preview it, and set the reply language.") { navigate(.voice) }
            } header: {
                Text("Set up your first conversation")
            } footer: {
                Footer("Already happy with the defaults? Click the main window or press Space to start talking.")
            }
            Section("Make it yours") {
                SettingsLink(destination: .conversation, detail: "Try a personality or write your own instructions.") { navigate(.conversation) }
                SettingsLink(destination: .shortcuts, detail: "Set a shortcut to talk from any app.") { navigate(.shortcuts) }
            }
            Section {
                Text("Speech recognition, the AI model and speech synthesis run on your Mac. Web tools and connected servers can send data outside it.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Your data")
            }
        }
    }
}

// MARK: - Building blocks

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
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            HStack {
                Text(low)
                Spacer()
                Text(high)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// Section footer: small, secondary, leading-aligned however long it wraps.
struct Footer: View {
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
    @Environment(VoiceSession.self) private var session
    @AppStorage("orbOnHotKey") private var orbOnHotKey = true
    @State private var orbVisible = MiniOrbController.shared.isVisible

    var body: some View {
        @Bindable var session = session
        Form {
            Section("Microphone sounds") {
                Toggle("Play a sound when the mic turns on and off", isOn: $session.soundCues)
            }
            Section {
                Toggle("Show the floating face", isOn: $orbVisible)
                    .onChange(of: orbVisible) {
                        orbVisible ? MiniOrbController.shared.show(session: session) : MiniOrbController.shared.hide()
                    }
                Toggle("Show it when I use the talk shortcut in another app", isOn: $orbOnHotKey)
            } header: {
                Text("Floating face")
            } footer: {
                Footer("A small always-on-top face you can drag anywhere. Click it to start or stop, right-click for options.")
            }
        }
        .onAppear { orbVisible = MiniOrbController.shared.isVisible }
    }
}

private struct HistoryPane: View {
    @Environment(VoiceSession.self) private var session
    @State private var confirmDelete = false

    var body: some View {
        Form {
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
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        Form {
            Section {
                row("Start or stop talking", detail: "Works in every app", action: .talk)
                row("Show or hide the floating face", detail: "Keep it in a corner while you work", action: .floatingOrb)
            } header: {
                Text("From any app")
            } footer: {
                Footer("Click a shortcut, then press the new keys. Esc cancels, Delete turns it off. Use at least one of ⌘, ⌥ or ⌃.")
            }
            Section {
                KeyRow(keys: "Space", title: "Start or stop talking")
                KeyRow(keys: "M", title: "Mute or unmute the mic")
                KeyRow(keys: "Esc", title: "Stop the current reply")
                KeyRow(keys: "C", title: "Show or hide the conversation")
                KeyRow(keys: "T", title: "Type a message")
                KeyRow(keys: "↩", title: "Send a typed message")
                KeyRow(keys: "⌘N", title: "New conversation")
                KeyRow(keys: "⌘,", title: "Settings")
            } header: {
                Text("In the Speak to Me window")
            } footer: {
                Footer("Single keys work while you're not typing in a text field.")
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
    @Environment(VoiceSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                Toggle("Speak replies out loud", isOn: Binding(get: { !session.muteReplies }, set: { session.muteReplies = !$0 }))
                LabeledSlider(title: "Speaking speed", value: $session.speed, range: 0.8...1.4, step: 0.05,
                              low: "Slower", high: "Faster") { String(format: "%.2f×", Double($0)) }
                Toggle("Answer in the language I speak", isOn: $session.matchLanguage)
                LabeledContent("Current language", value: LanguageDetector.name(session.language))
            } header: {
                Text("Reply voice and language")
            } footer: {
                Footer("Model changes apply from the next reply. If a model can't speak a sentence, the next available one does.")
            }
            Section("Expression") {
                Toggle("Expressive voice", isOn: $session.expressiveVoice)
                DisclosureGroup("How expressive voice works") {
                    Footer("Lets the AI add pauses and change speaking speed in any language. Applies from the next reply.")
                }
            }
            ForEach(SpeechSlot.allCases) { LanguageSection(slot: $0) }
        }
    }
}

/// One language group: which model speaks it, in which voice.
private struct LanguageSection: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("settingsPane") private var pane: SettingsView.Pane = .voice
    @State private var showsF5Options = false
    let slot: SpeechSlot

    /// Preview lines, in the conversation's language where possible.
    private static let previews = [
        "en": "Hi! This is how I'll sound when we talk.",
        "ru": "Привет! Вот так я буду звучать, когда мы говорим по-русски.",
        "uk": "Привіт! Ось так я звучатиму, коли ми говоримо українською.",
        "pl": "Cześć! Tak będę brzmieć, kiedy rozmawiamy po polsku.",
        "de": "Hallo! So klinge ich, wenn wir Deutsch sprechen.",
        "fr": "Salut ! Voilà comment je parlerai quand nous discutons en français.",
        "es": "¡Hola! Así sonaré cuando hablemos en español.",
    ]

    private var language: String {
        switch slot {
        case .english: return "en"
        case .russian: return "ru"
        case .other: return SpeechSlot(language: session.language) == .other ? session.language : "pl"
        }
    }

    private var engine: SpeechEngine { session.speechEngines[slot] ?? slot.engines[0] }

    var body: some View {
        Section {
            LabeledContent("Speech model") {
                HStack(spacing: 8) {
                    Picker("Speech model", selection: Binding(get: { engine }, set: { session.setEngine($0, for: slot) })) {
                        ForEach(slot.engines) { option in
                            Text(option.name)
                                .tag(option)
                                .disabled(option == .myVoice && !session.hasMyVoice)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button {
                        session.readAloud(Self.previews[language] ?? Self.previews["pl"]!)
                    } label: {
                        Label("Preview", systemImage: "play.fill")
                    }
                    .disabled(!session.canToggle || (slot != .english && !session.matchLanguage))
                    .help(slot != .english && !session.matchLanguage
                        ? "Turn on \"Answer in the language I speak\" to hear this" : "Hear this model")
                }
            }
            if session.state(of: engine) != .ready {
                SpeechModelStatus(engine: engine)
            }
            voiceRow
            if engine == .f5Russian {
                DisclosureGroup("F5-TTS options", isExpanded: $showsF5Options) { F5Options() }
            }
        } header: {
            Text(slot.title)
        } footer: {
            Footer(engine.summary)
        }
    }

    @ViewBuilder private var voiceRow: some View {
        @Bindable var session = session
        switch engine {
        case .kokoro:
            Picker("Voice", selection: $session.voice) {
                ForEach(kokoroGroups, id: \.0) { group, ids in
                    Section(group.capitalized) {
                        ForEach(ids, id: \.self) {
                            Text(VoiceSession.voiceName($0).components(separatedBy: " · ").first ?? $0).tag($0)
                        }
                    }
                }
            }
        case .myVoice:
            LabeledContent("Voice", value: session.hasMyVoice ? "Your recording" : "Not recorded yet")
        case .supertonic:
            Picker("Voice", selection: $session.languageVoice) { builtInVoices }
        case .f5Russian:
            LabeledContent("Voice") {
                HStack(spacing: 8) {
                    Picker("Voice", selection: f5Voice) {
                        Section("Built-in") {
                            ForEach(MultilingualVoices.voices, id: \.self) { Text(Self.voiceLabel($0)).tag("builtin:\($0)") }
                        }
                        if !session.f5Voices.isEmpty {
                            Section("Cloned") {
                                ForEach(session.f5Voices) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Clone a Voice…") { pane = .cloning }
                }
            }
        case .macOS:
            if let voice = SystemVoice.bestVoice(for: language) {
                LabeledContent("Voice", value: voice.name)
            } else {
                LabeledContent("Voice") {
                    Label("None installed for \(LanguageDetector.name(language))", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder private var builtInVoices: some View {
        ForEach(MultilingualVoices.voices, id: \.self) { Text(Self.voiceLabel($0)).tag($0) }
    }

    private static func voiceLabel(_ id: String) -> String {
        "\(id.hasPrefix("M") ? "Male" : "Female") \(id.dropFirst())"
    }

    /// Built-in and cloned voices in one menu, though they're stored apart.
    private var f5Voice: Binding<String> {
        Binding(
            get: { session.selectedF5Voice?.id ?? "builtin:\(session.languageVoice)" },
            set: { choice in
                if choice.hasPrefix("builtin:") {
                    session.languageVoice = String(choice.dropFirst("builtin:".count))
                    session.f5VoiceID = ""
                } else {
                    session.f5VoiceID = choice
                }
            })
    }

    /// Kokoro's voices grouped like "American female", in the order they're listed.
    private var kokoroGroups: [(String, [String])] {
        var order: [String] = []
        var byGroup: [String: [String]] = [:]
        for id in VoiceSession.voices {
            let group = VoiceSession.voiceName(id).components(separatedBy: " · ").last ?? ""
            if byGroup[group] == nil { order.append(group) }
            byGroup[group, default: []].append(id)
        }
        return order.map { ($0, byGroup[$0]!) }
    }
}

/// F5-TTS's quality, and how it stresses words.
private struct F5Options: View {
    @Environment(VoiceSession.self) private var session
    @State private var newPronunciation = ""

    var body: some View {
        @Bindable var session = session
        Picker("Quality", selection: $session.f5Steps) {
            Text("Fastest").tag(8)
            Text("Balanced").tag(12)
            Text("Best").tag(16)
        }
        Toggle("Mark word stress (RUAccent dictionary)", isOn: $session.f5MarksStress)
        if session.f5MarksStress {
            LabeledContent {
                HStack {
                    TextField("зам+ок", text: $newPronunciation)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .onSubmit(addPronunciation)
                    Button("Add", action: addPronunciation)
                        .disabled(!newPronunciation.contains("+"))
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fix a word")
                    Text("Put + before the stressed vowel").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(session.f5Pronunciations.keys.sorted(), id: \.self) { word in
                LabeledContent(session.f5Pronunciations[word] ?? word) {
                    Button("Remove") { session.removePronunciation(word) }
                }
            }
        }
    }

    private func addPronunciation() {
        session.addPronunciation(newPronunciation)
        newPronunciation = ""
    }
}

/// Shown under a speech model only while it's busy or something's wrong.
private struct SpeechModelStatus: View {
    @Environment(VoiceSession.self) private var session
    let engine: SpeechEngine

    var body: some View {
        HStack(spacing: 8) {
            switch session.state(of: engine) {
            case .loading:
                Spacer()
                ProgressView().controlSize(.small)
                Text("Loading…")
            case .downloading(let fraction):
                Text("Downloading \(engine.downloadSize ?? "")")
                Spacer()
                ProgressView(value: fraction).frame(width: 120).controlSize(.small)
                Text("\(Int(fraction * 100))%").monospacedDigit().frame(width: 34, alignment: .trailing)
            case .notDownloaded:
                Text("Not downloaded yet (\(engine.downloadSize ?? ""))")
                Spacer()
                Button("Download Now") { session.prepareEngine(engine) }
                    .controlSize(.small)
            case .failed(let message):
                Label("Couldn't load: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("Try Again") { session.prepareEngine(engine) }
                    .controlSize(.small)
            case .ready:
                EmptyView()
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Voice cloning

private struct VoiceCloningPane: View {
    var body: some View {
        Form {
            RussianCloningSection()
            EnglishCloningSection()
        }
    }
}

/// Text to read, buttons to record or pick a file, and how that's going.
private struct VoiceCapture: View {
    let script: String
    let seconds: Int
    let busy: Bool
    let status: String?
    let record: () async -> Void
    let importFile: (URL) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read this aloud")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(script)
                .font(.callout)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        HStack {
            Button {
                Task { await record() }
            } label: {
                Label("Record (\(seconds) s)", systemImage: "record.circle")
            }
            Button("Use an Audio File…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio]
                if panel.runModal() == .OK, let url = panel.url {
                    Task { await importFile(url) }
                }
            }
        }
        .disabled(busy)
        if let status {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                Text(status).font(.callout)
            }
        }
    }
}

private struct RussianCloningSection: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        Section {
            if session.speechEngines[.russian] == .f5Russian {
                VoiceCapture(
                    script: VoiceSession.f5VoiceScript, seconds: 8, busy: session.f5VoiceBusy, status: session.f5VoiceStatus,
                    record: { await session.recordF5Voice() }, importFile: { await session.importF5Voice(from: $0) })
                ForEach(session.f5Voices) { ClonedVoiceRow(voice: $0) }
            } else {
                LabeledContent {
                    Button("Use F5-TTS for Russian") { session.setEngine(.f5Russian, for: .russian) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("F5-TTS Russian isn't on")
                        if !SpeechEngine.f5Russian.isInstalled, let size = SpeechEngine.f5Russian.downloadSize {
                            Text("Downloads \(size)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Russian, with F5-TTS")
        } footer: {
            Footer("A clear clip of one person works best, and up to 8 seconds is used. Only clone a voice you have permission to use. Everything stays on this Mac.")
        }
    }
}

/// A cloned voice: use it, rename it, correct what it says, or delete it.
private struct ClonedVoiceRow: View {
    @Environment(VoiceSession.self) private var session
    @State private var confirmDelete = false
    let voice: F5ClonedVoice

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Name", text: Binding(
                    get: { voice.name }, set: { session.updateF5Voice(voice.id, name: $0) }))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                if session.f5VoiceID == voice.id {
                    Label("In use", systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.primary)
                } else {
                    Button("Use") { session.f5VoiceID = voice.id }
                }
                Button("Delete", role: .destructive) { confirmDelete = true }
                    .confirmationDialog("Delete \(voice.name)?", isPresented: $confirmDelete) {
                        Button("Delete", role: .destructive) { session.deleteF5Voice(voice.id) }
                    } message: {
                        Text("This can't be undone.")
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What's said in the clip (the words must match)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What's said in the clip", text: Binding(
                    get: { voice.transcript }, set: { session.updateF5Voice(voice.id, transcript: $0) }),
                    axis: .vertical)
                    .labelsHidden()
                    .font(.callout)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct EnglishCloningSection: View {
    @Environment(VoiceSession.self) private var session
    @State private var confirmDelete = false

    var body: some View {
        Section {
            VoiceCapture(
                script: VoiceSession.voiceScript, seconds: 12, busy: session.myVoiceBusy, status: session.myVoiceStatus,
                record: { await session.recordMyVoice() }, importFile: { await session.importMyVoice(from: $0) })
            if session.hasMyVoice {
                LabeledContent(session.speechEngines[.english] == .myVoice ? "In use for English" : "Your recording") {
                    HStack(spacing: 8) {
                        if session.speechEngines[.english] != .myVoice {
                            Button("Use") { session.setEngine(.myVoice, for: .english) }
                        }
                        Button("Delete", role: .destructive) { confirmDelete = true }
                            .confirmationDialog("Delete your recorded voice?", isPresented: $confirmDelete) {
                                Button("Delete", role: .destructive) { session.deleteMyVoice() }
                            } message: {
                                Text("This can't be undone.")
                            }
                    }
                }
            }
        } header: {
            Text("English, with PocketTTS")
        } footer: {
            Footer("Read at your normal pace in a quiet room. Everything stays on this Mac. A little slower than the built-in voices.")
        }
    }
}

// MARK: - Listening

private struct ListeningPane: View {
    @Environment(VoiceSession.self) private var session

    private var endOfTurn: Binding<Double> {
        Binding(get: { Double(session.endOfTurnMs) }, set: { session.endOfTurnMs = Int($0) })
    }

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                LabeledSlider(title: "Wait after I stop speaking", value: endOfTurn, range: 256...2048, step: 128,
                              low: "Snappy", high: "Patient") { "\(Int($0)) ms" }
            } header: {
                Text("When to reply")
            } footer: {
                Footer("Shorter feels snappier; longer gives you time to think mid-sentence.")
            }
            MicSensitivitySection()
            Section {
                Toggle("Let me interrupt replies without headphones", isOn: $session.echoCancellation)
                DisclosureGroup("How interruptions affect audio") {
                    Footer("Echo cancellation removes the assistant’s voice from the mic. macOS lowers other apps’ audio while it runs. After 45 quiet seconds it stops, so the next reply takes about 2 seconds longer to start. When off, the mic pauses during replies. Changes apply the next time you start talking.")
                }
            } header: {
                Text("Interruptions")
            } footer: {
                Footer("Speak while the assistant is talking to interrupt it, even on speakers.")
            }
        }
    }
}

// MARK: - Conversation

private struct ConversationPane: View {
    @Environment(VoiceSession.self) private var session

    private static let rule = " Never use markdown, lists, headings, code blocks or emoji: everything you write is read aloud."

    private static let presets: [(name: String, icon: String, prompt: String)] = [
        ("Friendly", "face.smiling", VoiceSession.defaultPrompt),
        ("Concise", "bolt", "You are a calm, efficient voice assistant. Answer in one short sentence whenever you can, and only add detail when asked." + rule),
        ("Tutor", "graduationcap", "You are a patient tutor in a spoken conversation. Explain things simply, one idea at a time, use everyday examples, and end with a short question to check understanding." + rule),
        ("Playful", "sparkles", "You are a witty, playful voice companion. Keep answers short and fun, with light humour, while still being genuinely helpful." + rule),
    ]

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                HStack(spacing: 8) {
                    ForEach(Self.presets, id: \.name) { preset in
                        PresetChip(name: preset.name, icon: preset.icon,
                                   selected: session.systemPrompt == preset.prompt) {
                            session.systemPrompt = preset.prompt
                        }
                    }
                    if !Self.presets.contains(where: { $0.prompt == session.systemPrompt }) {
                        Text("Custom").font(.callout).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                TextEditor(text: $session.systemPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 140)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if session.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Describe who the assistant is and how it talks. Left empty, the default is used.")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("System prompt")
                HStack {
                    Button("Reset to Default") {
                        session.setWritesWholePrompt(false)
                        session.systemPrompt = VoiceSession.defaultPrompt
                    }
                    .disabled(session.systemPrompt == VoiceSession.defaultPrompt && session.addsPromptRules)
                    Spacer()
                    Text("\(session.systemPrompt.count) characters")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: Binding(get: { !session.addsPromptRules }, set: { session.setWritesWholePrompt($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write the whole prompt myself")
                        Text(session.addsPromptRules
                             ? "The app adds its rules for tools, language and expressive voice after your text"
                             : "Sent exactly as written. Tools stay available, but nothing tells the model to use them")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if session.addsPromptRules {
                    DisclosureGroup("Full prompt sent to the model") {
                        Text(session.fullSystemPrompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            } header: {
                Text("Personality and instructions")
            } footer: {
                Footer(session.addsPromptRules
                    ? "Your system prompt comes first. After it the app adds its own rules for what's switched on: how to use tools (Tools), answering in your language and expressive voice (Voice & Language), so those keep working whatever you write. Keep the no-markdown rule: everything is read aloud. Changes apply from the next reply."
                    : "The text above is the entire system prompt. Keep the no-markdown rule: everything is read aloud. Changes apply from the next reply; start a new conversation (⌘N) if replies keep echoing the old style.")
            }
        }
    }
}

/// How quiet you can be and still start a turn, with a live meter to see where that falls.
private struct MicSensitivitySection: View {
    @Environment(VoiceSession.self) private var session
    @State private var tester = MicTester()
    @State private var testing = false
    @State private var testError: String?

    /// The conversation's own mic when it's on, otherwise the test one.
    private var live: Bool { session.micOn || testing || Snapshots.isRendering }

    var body: some View {
        @Bindable var session = session
        Section {
            LabeledSlider(title: "Mic sensitivity", value: $session.micSensitivity, range: 0...1, step: 0.05,
                          low: "Only clear, close speech", high: "Picks up quiet speech") { "\(Int(($0 * 100).rounded()))%" }
            LabeledContent {
                HStack(spacing: 8) {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !live)) { _ in
                        MicMeter(level: live ? (session.micOn || Snapshots.isRendering ? session.levels.mic : tester.levels.mic) : 0,
                                 threshold: VoiceSession.speechGate(sensitivity: session.micSensitivity).level)
                    }
                    .frame(height: 10)
                    if !session.micOn {
                        Button(testing ? "Stop" : "Test Mic") { testing ? stopTest() : startTest() }
                            .fixedSize()
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Level")
                    Text(testError ?? (live ? "Talk: the bar must pass the mark" : "Test to see your level"))
                        .font(.caption)
                        .foregroundStyle(testError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                }
            }
            Button("Reset to Default") { session.micSensitivity = VoiceSession.defaultMicSensitivity }
                .disabled(abs(session.micSensitivity - VoiceSession.defaultMicSensitivity) < 0.001)
        } header: {
            Text("Microphone")
        } footer: {
            Footer("Turn it up if it misses you when you speak softly or sit far away. Turn it down if background noise, music or other people set it off. Applies straight away.")
        }
        .onChange(of: session.micOn) { if session.micOn { stopTest() } }
        .onDisappear(perform: stopTest)
    }

    private func startTest() {
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                testError = "Microphone access is off in System Settings"
                return
            }
            do {
                try tester.start()
                testError = nil
                testing = true
            } catch {
                testError = "Couldn't start the mic: \(error.localizedDescription)"
            }
        }
    }

    private func stopTest() {
        tester.stop()
        testing = false
    }
}

/// Loudness on the same 0…1 scale the turn-taking uses, with the start threshold marked.
private struct MicMeter: View {
    let level: Float
    let threshold: Float

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(level >= threshold ? Theme.accent : Color.secondary)
                    .frame(width: max(0, width * CGFloat(min(1, level))))
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: geo.size.height + 6)
                    .offset(x: width * CGFloat(threshold) - 1)
            }
        }
        .frame(minWidth: 160)
        .accessibilityElement()
        .accessibilityLabel("Mic level")
        .accessibilityValue("\(Int(level * 100)) percent, starts listening at \(Int(threshold * 100))")
    }
}

/// A second, bare listener for Settings while no conversation is running; it only
/// measures loudness and never records.
private final class MicTester: @unchecked Sendable {
    let levels = AudioLevels()
    private var engine: AVAudioEngine?

    func start() throws {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let levels = levels
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            levels.mic = AudioLevels.rms(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }
        try engine.start()
        self.engine = engine
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        levels.mic = 0
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
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Model

private struct ModelPane: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            Section {
                if session.models.isEmpty {
                    LabeledContent("Model") {
                        Label("No chat models found in oMLX", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Picker("Model", selection: Binding(get: { session.modelID }, set: {
                        session.modelID = $0
                        session.modelChanged()
                    })) {
                        ForEach(session.models) { model in
                            Text("\(model.id)  ·  \(String(format: "%.1f GB", Double(model.sizeBytes) / 1_073_741_824))")
                                .tag(model.id)
                        }
                    }
                }
                LabeledContent("oMLX server", value: session.serverAddress)
                    .textSelection(.enabled)
                if let ms = session.lastLatencyMs {
                    LabeledContent("Last reply started after", value: "\(ms) ms")
                }
            } footer: {
                Footer("Start oMLX and load a chat model to make it available here. The server address comes from ~/.omlx/settings.json. Models with a3b or a4b in the name usually reply fastest.")
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
