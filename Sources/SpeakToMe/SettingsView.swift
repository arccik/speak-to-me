import SwiftUI

/// Settings as a sidebar of panes, in the style of System Settings.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, shortcuts, voice, cloning, conversation, model

        var id: Self { self }
        var title: String { self == .cloning ? "Voice Cloning" : rawValue.capitalized }

        var subtitle: String {
            switch self {
            case .general: return "Sounds, the floating record and your history"
            case .shortcuts: return "Talk or bring up the record from any app"
            case .voice: return "Which model speaks each language, and how"
            case .cloning: return "Hear replies in a voice you record"
            case .conversation: return "Turn-taking, personality and tools"
            case .model: return "The language model in oMLX"
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .shortcuts: return "command"
            case .voice: return "waveform"
            case .cloning: return "person.wave.2.fill"
            case .conversation: return "bubble.left.and.bubble.right.fill"
            case .model: return "cpu.fill"
            }
        }
    }

    /// Taller for Snapshots, so a whole pane fits in the picture.
    static var height: CGFloat = 560

    @AppStorage("settingsPane") private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(get: { pane }, set: { if let p = $0 { pane = p } })) { pane in
                Label(pane.title, systemImage: pane.icon)
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
                case .cloning: VoiceCloningPane()
                case .conversation: ConversationPane()
                case .model: ModelPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: Self.height)
        .tint(Theme.vinyl)
    }
}

// MARK: - Building blocks

/// The pane's name, set large, and one line of explanation.
private struct PaneHeader: View {
    let pane: SettingsView.Pane

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title).font(.display(22))
                Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
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
    @Environment(VoiceSession.self) private var session
    @AppStorage("orbOnHotKey") private var orbOnHotKey = true
    @State private var orbVisible = MiniOrbController.shared.isVisible
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var session = session
        Form {
            PaneHeader(pane: .general)
            Section("Sounds") {
                Toggle("Play a sound when the mic turns on and off", isOn: $session.soundCues)
                Toggle("Speak replies out loud", isOn: Binding(get: { !session.muteReplies }, set: { session.muteReplies = !$0 }))
            }
            Section {
                Toggle("Show the floating record", isOn: $orbVisible)
                    .onChange(of: orbVisible) {
                        orbVisible ? MiniOrbController.shared.show(session: session) : MiniOrbController.shared.hide()
                    }
                Toggle("Show it when I use the talk shortcut in another app", isOn: $orbOnHotKey)
            } header: {
                Text("Floating record")
            } footer: {
                Footer("A small always-on-top record you can drag anywhere. Click it to start or stop, right-click for options.")
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
                row("Show or hide the floating record", detail: "Keep it in a corner while you work", action: .floatingOrb)
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
    @Environment(VoiceSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Form {
            PaneHeader(pane: .voice)
            ForEach(SpeechSlot.allCases) { LanguageSection(slot: $0) }
            Section {
                LabeledSlider(title: "Speaking speed", value: $session.speed, range: 0.8...1.4, step: 0.05,
                              low: "Slower", high: "Faster") { String(format: "%.2f×", Double($0)) }
                Toggle("Answer in the language I speak", isOn: $session.matchLanguage)
                LabeledContent("Current language", value: LanguageDetector.name(session.language))
            } header: {
                Text("Playback")
            } footer: {
                Footer("Model changes apply from the next reply. If a model can't speak a sentence, the next available one does.")
            }
            Section {
                Toggle("Expressive voice", isOn: $session.expressiveVoice)
            } footer: {
                Footer("Lets the language model add pauses and change the speed and pitch of its voice, with any speech model and in any language. Applies from the next reply.")
            }
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
            LabeledContent("Model") {
                HStack(spacing: 8) {
                    Picker("Model", selection: Binding(get: { engine }, set: { session.setEngine($0, for: slot) })) {
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
            PaneHeader(pane: .cloning)
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
                        .foregroundStyle(Theme.acid)
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

    private var endOfTurn: Binding<Double> {
        Binding(get: { Double(session.endOfTurnMs) }, set: { session.endOfTurnMs = Int($0) })
    }

    var body: some View {
        @Bindable var session = session
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
                .background(selected ? AnyShapeStyle(Theme.vinyl) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model

private struct ModelPane: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        @Bindable var session = session
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
