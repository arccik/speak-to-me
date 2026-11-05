import SwiftUI

enum Theme {
    /// Settings' tint.
    static let accent = Mood.cherry.color()
    /// The ground behind the conversation.
    static let abyss = Mood.void.color()
    static let acid = Mood.replyInk.color()
    /// The colour of the wisps behind the controls.
    static let mist = RGBA.hex(0xA9B2C2).color()
    /// Words on a wisp of mist.
    static let ink = Mood.youInk.color()
    /// Long replies in the conversation.
    static let replyText = RGBA.hex(0xC8DCEB).color()
    static let text = Mood.youInk.color()
}

extension Font {
    /// Large words are set in Didot, like an inscription; small ones stay plain. Didot and
    /// Avenir Next are Latin only, so text in any other script is set in the system's matching
    /// face as a whole, rather than with their punctuation mixed in.
    static func display(_ size: CGFloat, weight: Font.Weight = .medium, for text: String = "") -> Font {
        let latin = text.unicodeScalars.allSatisfy { !$0.properties.isAlphabetic || $0.value < 0x250 }
        if size >= 21 {
            return latin ? .custom("Didot", size: size) : .system(size: size, weight: .regular, design: .serif)
        }
        return latin ? .custom("Avenir Next", size: size).weight(.medium) : .system(size: size, weight: .medium)
    }

    static func stamp(_ size: CGFloat) -> Font {
        .custom("Didot-Italic", size: size)
    }
}

struct ContentView: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false
    @State private var wordsHeight: CGFloat = 0
    @State private var wake = 0
    @State private var lastWake = Date.distantPast
    @State private var resting = false

    private var showChat: Bool { chatOpen && !session.lines.isEmpty }

    var body: some View {
        ZStack(alignment: .topLeading) {
            persona
                .ignoresSafeArea()
            // The whole window is the control: click to talk.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .pointerStyle(session.canToggle ? .link : .default)
                .onTapGesture { if session.canToggle { session.toggle() } }
                .accessibilityElement()
                .accessibilityLabel(session.isActive ? "Stop talking" : "Start talking")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { if session.canToggle { session.toggle() } }
            VStack(alignment: .leading, spacing: 0) {
                TopBar()
                if !showChat {
                    StatusLine()
                        .padding(.horizontal, 22)
                        .padding(.top, 8)
                }
                Spacer(minLength: showChat ? FaceRenderer.sleeveTop - 30 : 0)
                if showChat {
                    Sleeve()
                        .transition(.move(edge: .bottom))
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Group {
                            if session.lines.isEmpty && (session.liveText ?? "").isEmpty && !session.hasProblem {
                                EmptyWords()
                            } else {
                                Words()
                            }
                        }
                        .transition(.opacity)
                        Dock()
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 16)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wordsHeight = $0 }
                }
            }
            .ignoresSafeArea(.container, edges: .top) // the top bar shares the traffic lights' row
            if let approval = session.approval {
                ApprovalCard(approval: approval)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.1), value: session.approval?.id)
        .animation(.spring(duration: 0.55, bounce: 0.1), value: showChat)
        .tint(Theme.ink)
        .preferredColorScheme(.dark)
        .environment(\.mistDrifts, !resting)
        .onContinuousHover { _ in
            // Someone's here, so stay awake. Once a second is plenty.
            FaceEngine.shared.poke()
            if resting || Date().timeIntervalSince(lastWake) > 1 {
                lastWake = Date()
                wake += 1
            }
        }
        .onAppear(perform: SpaceKey.install)
        .modifier(PersonaSync())
    }

    private var persona: some View {
        Persona(phase: session.phase, muted: session.micMuted, levels: session.levels,
                layout: FaceLayout(style: .stage,
                                   // A still has no second pass to measure in, so it uses a typical height.
                                   hush: showChat ? 0 : Snapshots.isRendering ? 230 : wordsHeight + 14, peek: showChat),
                wake: wake,
                onRest: { resting = $0 })
    }
}

/// Keeps the face in step with the conversation.
struct PersonaSync: ViewModifier {
    @Environment(VoiceSession.self) private var session

    private var signature: String {
        "\(session.lines.first?.id.uuidString ?? "")-\(session.lines.count)-\(session.lines.suffix(2).map(\.interrupted))"
    }

    func body(content: Content) -> some View {
        content.onChange(of: signature, initial: true) { FaceEngine.shared.sync(lines: session.lines) }
    }
}

extension VoiceSession {
    var hasProblem: Bool {
        if micNotice != nil { return true }
        switch phase {
        case .failed, .loading: return true
        default: return false
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(VoiceSession.self) private var session
    @ObservedObject private var shortcuts = Shortcuts.shared
    @AppStorage("chatOpen") private var chatOpen = false

    var body: some View {
        HStack(spacing: 4) {
            TopIconButton(systemImage: "square.and.pencil", help: "New conversation (\u{2318}N)") { session.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(session.lines.isEmpty)
            HistoryButton()
            Spacer(minLength: 8)
            ModelMenu()
            TopIconButton(systemImage: "pip.enter",
                          help: shortcuts.floatingOrb.map { "Floating face (\($0.display))" } ?? "Floating face") {
                MiniOrbController.shared.toggle(session: session)
            }
            SettingsLink { TopIconLabel(systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help("Settings (\u{2318},)")
        }
        .padding(.leading, 76) // keep clear of the window's traffic lights
        .padding(.trailing, 10)
        .frame(height: 30)
    }
}

private struct TopIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { TopIconLabel(systemImage: systemImage) }
            .buttonStyle(.plain)
            .help(help)
    }
}

private struct TopIconLabel: View {
    let systemImage: String
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(hovering ? Theme.ink : Theme.text)
            .frame(width: 28, height: 24)
            .background(MistBackground(firm: true, opacity: hovering ? 1 : 0, seed: systemImage.count, spill: CGSize(width: 7, height: 8)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// Past conversations, newest first. Click to reopen, right-click to delete.
private struct HistoryButton: View {
    @Environment(VoiceSession.self) private var session
    @State private var open = false

    var body: some View {
        TopIconButton(systemImage: "clock.arrow.circlepath", help: "Past conversations") { open.toggle() }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Conversations").font(.headline)
                        Spacer()
                        Button("New") {
                            session.newConversation()
                            open = false
                        }
                    }
                    .padding(12)
                    Divider()
                    if session.savedConversations.isEmpty {
                        Text("Nothing saved yet. Conversations are saved automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(16)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(session.savedConversations) { item in
                                    Button {
                                        session.openConversation(item.id)
                                        open = false
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title).lineLimit(1)
                                            Text("\(item.updated.formatted(.relative(presentation: .named))) · \(item.messageCount) messages")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("Delete", role: .destructive) { session.deleteConversation(item.id) }
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 360)
                        Divider()
                        Text("Right-click a conversation to delete it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .frame(width: 320)
            }
    }
}

private struct ModelMenu: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        Menu {
            if let ms = session.lastLatencyMs {
                Text("Last reply started in \(ms) ms")
                Divider()
            }
            if session.models.isEmpty {
                Text("No chat models in oMLX yet")
                Text("Download one in oMLX, then reopen this menu")
            }
            ForEach(session.models) { model in
                Button {
                    session.modelID = model.id
                    session.modelChanged()
                } label: {
                    if model.id == session.modelID {
                        Label("\(model.id)  \u{00B7}  \(Self.gb(model.sizeBytes))", systemImage: "checkmark")
                    } else {
                        Text("\(model.id)  \u{00B7}  \(Self.gb(model.sizeBytes))")
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(session.modelID.isEmpty ? "Model" : session.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .heavy))
            }
            .font(.display(12, weight: .bold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .frame(maxWidth: 190)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
    }

    private var helpText: String {
        guard let ms = session.lastLatencyMs else { return "Language model in oMLX" }
        return "Language model in oMLX. Last reply started \(ms) ms after you stopped talking."
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Status

/// What's happening, in one word you can read from across the room.
/// A tool wants to change something on your Mac or in your accounts: it waits for you.
private struct ApprovalCard: View {
    @Environment(VoiceSession.self) private var session
    let approval: VoiceSession.Approval

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(approval.destructive ? "Allow this? It may delete or overwrite things." : "Allow this?",
                  systemImage: approval.destructive ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(approval.destructive ? Color.orange : Theme.replyText)
            Text("\(approval.title)  ·  \(approval.server)")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.replyText)
            ScrollView {
                Text(approval.arguments)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.replyText.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("Check what it will do. Talking, or no answer in 2 minutes, counts as no.")
                .font(.caption)
                .foregroundStyle(Theme.replyText.opacity(0.7))
            HStack {
                Spacer()
                Button("Don't Allow") { session.answerApproval(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { session.answerApproval(true) }
                    .tint(approval.destructive ? .orange : Theme.accent)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: 460)
        .background(Theme.abyss.opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(radius: 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed for \(approval.title)")
    }
}

private struct StatusLine: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.stamp(24))
                .foregroundStyle(Theme.text)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: title)
            if let notice = session.micNotice {
                Text(notice)
                    .font(.display(13, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .allowsHitTesting(false)
    }

    private var title: String {
        if session.micMuted, session.phase == .listening { return "Mic muted" }
        switch session.phase {
        case .loading: return "Warming up"
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .hearing: return "Hearing you"
        case .transcribing, .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .failed: return "Stuck"
        }
    }
}

// MARK: - Words in the dark

private struct EmptyWords: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.isActive ? "Go ahead, I'm listening." : "Click anywhere and start talking.")
                .font(.display(34))
                .lineSpacing(1)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
            HStack(spacing: 24) {
                ForEach(["Tell me a fun fact", "Plan my evening", "Explain black holes"], id: \.self) { prompt in
                    TextAction(text: prompt, help: "Ask this") { session.send(prompt) }
                        .disabled(!session.canToggle)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }
}

/// With the sleeve closed, only what's being said right now: your words in white, the
/// reply's in bone, the same as their ripples. Long replies keep their newest words in view.
private struct Words: View {
    @Environment(VoiceSession.self) private var session

    private struct Current: Equatable {
        var id: String
        var role: String
        var text: String
        var live: Bool
        var interrupted = false
    }

    private var current: Current? {
        switch session.phase {
        case .loading(let message): return Current(id: "loading", role: "system", text: message, live: true)
        case .failed(let message): return Current(id: "failed", role: "system", text: message, live: false)
        default: break
        }
        if let text = session.liveText, !text.isEmpty {
            return Current(id: "live", role: "user", text: text, live: true)
        }
        guard let line = session.lines.last else { return nil }
        let speaking = line.role == "assistant" && !line.interrupted
            && (session.phase == .thinking || session.phase == .speaking)
        return Current(id: line.id.uuidString, role: line.role, text: session.currentText(of: line), live: speaking,
                       interrupted: line.interrupted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                if let current {
                    words(current)
                        .id(current.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: current?.id)
            if case .failed = session.phase {
                TextAction(text: "Try again", help: "Reconnect") { Task { await session.connect() } }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    @ViewBuilder
    private func words(_ current: Current) -> some View {
        // Nothing written yet: the dark turning red and the face sinking back say it's thinking.
        if !current.text.isEmpty {
            let shown = current.role == "system" ? Self.unbrokenLinks(current.text) : current.text
            let size: CGFloat = current.role == "system" ? 26 : current.text.count < 70 ? 34 : current.text.count < 150 ? 26 : 21
            Text(shown)
                .font(.display(size, weight: size > 30 ? .heavy : .bold, for: shown))
                .lineSpacing(2)
                .foregroundStyle(color(current))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 190, alignment: .bottomLeading)
                .fixedSize(horizontal: false, vertical: true) // only as tall as the words, up to that
                .clipped()
                // Newest words at the bottom; older ones fade out over the top.
                .mask(
                    LinearGradient(stops: [.init(color: current.text.count > 190 ? .clear : .black, location: 0),
                                           .init(color: .black, location: 0.24)],
                                   startPoint: .top, endPoint: .bottom))
        }
    }

    /// Keeps an address like http://127.0.0.1:8000 in one piece when the line wraps.
    private static func unbrokenLinks(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { word in
            word.contains("://") ? word.map(String.init).joined(separator: "\u{2060}") : String(word)
        }.joined(separator: " ")
    }

    private func color(_ current: Current) -> Color {
        current.role == "assistant" ? Theme.acid : Theme.text
    }
}

/// A wisp of mist with a word in it. It drifts at rest, thickens under the pointer and
/// scatters when clicked.
struct TextAction: View {
    let text: String
    var systemImage: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var burst = 0
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            burst += 1
            action()
        } label: {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .heavy)) }
                Text(text)
            }
            .font(.display(13))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 6)
            .frame(height: 26)
            .background(MistBackground(firm: hovering, burst: burst, seed: text.count))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.55)
        .onHover { hovering = $0 && enabled }
        .help(help)
    }
}

// MARK: - The sleeve

/// The conversation rolls in like a bank of fog, with the small face still talking above it.
private struct Sleeve: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                StatusLine()
                Spacer()
                TextAction(text: "Hide", help: "Hide the conversation (C)") { chatOpen = false }
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            Transcript()
            Dock()
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .background {
            // Soft along the top, like the edge of a bank of fog.
            Theme.abyss
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.03)],
                                     startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
        }
    }
}

// MARK: - Transcript

private struct Transcript: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        Group {
            if Snapshots.isRendering {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    ForEach(session.lines) {
                        MessageRow(line: $0, isLive: isLive($0), isLast: $0.id == session.lines.last?.id,
                                   isStreaming: $0.id == session.streamingLineID)
                    }
                    LiveUserText()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(session.lines) { line in
                                MessageRow(line: line, isLive: isLive(line), isLast: line.id == session.lines.last?.id,
                                           isStreaming: line.id == session.streamingLineID)
                                    .id(line.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: 12)),
                                        removal: .opacity))
                            }
                            LiveUserText()
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .animation(.easeOut(duration: 0.25), value: session.lines.count)
                    }
                    .scrollIndicators(.never)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05)],
                                         startPoint: .top, endPoint: .bottom))
                    .background(FollowLatest(proxy: proxy))
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func isLive(_ line: VoiceSession.Line) -> Bool {
        guard line.id == session.lines.last?.id, line.role == "assistant", !line.interrupted else { return false }
        return session.phase == .thinking || session.phase == .speaking
    }
}

/// Keeps the newest words in view. A view of its own, so text streaming in redraws only
/// this, not the whole transcript. New messages glide into view; streaming text, which
/// grows ~15 times a second, follows without animation so scrolls don't pile up.
private struct FollowLatest: View {
    @Environment(VoiceSession.self) private var session
    let proxy: ScrollViewProxy

    var body: some View {
        Color.clear
            .onChange(of: session.lines.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.lines.last?.text) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.liveText) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
}

/// Your words appearing as you speak, before the turn is final.
private struct LiveUserText: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        if let text = session.liveText, !text.isEmpty {
            Text(text)
                .font(.display(16, weight: .heavy, for: text))
                .foregroundStyle(Theme.text)
                .opacity(0.8)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 400, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
        }
    }
}

private struct MessageRow: View {
    @Environment(VoiceSession.self) private var session
    let line: VoiceSession.Line
    let isLive: Bool
    let isLast: Bool
    /// The reply is still streaming in: its text comes from `ReplyText`.
    var isStreaming = false
    @State private var hovering = false

    var body: some View {
        switch line.role {
        case "user": user
        case "error": error
        default: assistant
        }
    }

    /// Yours in heavy white on the right, the reply in pale yellow on the left: no bubbles.
    private var user: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(line.text)
                .font(.display(16, weight: .heavy, for: line.text))
                .lineSpacing(2)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400, alignment: .trailing)
            if let note = line.note { NoteLabel(text: note, systemImage: "eye") }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistant: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if isStreaming {
                    StreamingReply(isLive: isLive)
                } else {
                    ReplyText(text: line.text, isLive: isLive, interrupted: line.interrupted)
                }
                if let note = line.note { NoteLabel(text: note, systemImage: "wrench.and.screwdriver") }
                if line.interrupted {
                    Label("You cut in here", systemImage: "scissors")
                        .font(.display(12, weight: .bold))
                        .foregroundStyle(Theme.text)
                }
                if !line.text.isEmpty, !isLive {
                    actions
                        // Always on the latest reply so they're discoverable; on hover for the rest.
                        .opacity(hovering || isLast ? 1 : 0)
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            Spacer(minLength: 30)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            MessageAction(systemImage: "doc.on.doc", doneImage: "checkmark", help: "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
            MessageAction(systemImage: "speaker.wave.2", help: "Read aloud") { session.readAloud(line.text) }
                .disabled(!session.canToggle)
            if isLast, session.canRetry {
                MessageAction(systemImage: "arrow.clockwise", help: "Ask again") { session.retryLast() }
                    .disabled(!session.canToggle || session.isReplying)
            }
        }
        .padding(.leading, -6) // optically align the icons with the text
    }

    private var error: some View {
        Label(line.text, systemImage: "exclamationmark.triangle.fill")
            .font(.display(14, weight: .bold, for: line.text))
            .foregroundStyle(Theme.acid)
    }
}

/// The reply that's being written, read straight from the session so only this redraws
/// as tokens arrive.
private struct StreamingReply: View {
    @Environment(VoiceSession.self) private var session
    let isLive: Bool

    var body: some View {
        ReplyText(text: session.streamingText, isLive: isLive, interrupted: false)
    }
}

private struct ReplyText: View {
    let text: String
    let isLive: Bool
    let interrupted: Bool

    var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.display(16, weight: .medium, for: text))
                .lineSpacing(4)
                .foregroundStyle(Theme.replyText)
                .opacity(interrupted ? 0.82 : 1)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A tiny icon button under a reply; can flash a checkmark to confirm it worked.
private struct MessageAction: View {
    let systemImage: String
    var doneImage: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var done = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            action()
            guard doneImage != nil else { return }
            done = true
            Task { try? await Task.sleep(for: .seconds(1.2)); done = false }
        } label: {
            Image(systemName: done ? doneImage ?? systemImage : systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hovering ? Theme.ink : done ? Theme.acid : Theme.text)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 22)
                .background(MistBackground(firm: true, opacity: hovering ? 1 : 0, seed: systemImage.count, spill: CGSize(width: 6, height: 7)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 && enabled }
        .help(help)
    }
}

private struct NoteLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.display(12, weight: .semibold, for: text))
            .foregroundStyle(Theme.text)
            .lineLimit(2)
    }
}

// MARK: - Composer

/// Small icon toggle in the typing row; a firm puff of mist while it's on.
private struct ComposerToggle: View {
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.ink)
                .opacity(isOn || hovering ? 1 : 0.55)
                .frame(width: 28, height: 28)
                .background(MistBackground(firm: true, opacity: isOn ? 1 : hovering ? 0.7 : 0, seed: systemImage.count, spill: CGSize(width: 3, height: 3)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Space toggles the mic, M mutes it, C shows or hides the chat, T starts typing and Esc
/// stops a reply, except while you're typing in a text field.
@MainActor
enum SpaceKey {
    private static var monitor: Any?
    /// Posted for T; the dock opens its text field.
    static let startTyping = Notification.Name("SpeakToMe.startTyping")

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard [49, 46, 8, 17, 53].contains(event.keyCode),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  !(event.window?.firstResponder is NSText),
                  event.window?.identifier?.rawValue.hasPrefix("main") == true
            else { return event }
            // With Full Keyboard Access, Space belongs to whichever control has the focus.
            if event.keyCode == 49, NSApp.isFullKeyboardAccessEnabled, let window = event.window,
               window.firstResponder !== window, window.firstResponder !== window.contentView {
                return event
            }
            let session = VoiceSession.shared
            switch event.keyCode {
            case 49: if session.canToggle { session.toggle() }
            case 46: guard session.micOn else { return event }; session.micMuted.toggle()
            case 8:
                guard !session.lines.isEmpty else { return event }
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "chatOpen"), forKey: "chatOpen")
            case 17: NotificationCenter.default.post(name: startTyping, object: nil)
            default: guard session.isReplying else { return event }; session.stopReply()
            }
            return nil
        }
    }
}

// MARK: - Dock

/// No buttons to talk: the whole window does that. What's left are a few puffs of mist.
private struct Dock: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false
    @ObservedObject private var shortcuts = Shortcuts.shared
    @FocusState private var focused: Bool
    @State private var typing = false
    @State private var draft = ""

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if typing { typeBar } else { actions }
            Text(hint)
                .font(.display(12, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(.opacity)
                .allowsHitTesting(false)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: typing)
        .animation(.easeOut(duration: 0.2), value: hint)
        .onReceive(NotificationCenter.default.publisher(for: SpaceKey.startTyping)) { _ in startTyping() }
        .onChange(of: focused) { _, isFocused in
            // Clicking away from an empty field goes back to voice.
            if !isFocused && !hasDraft { typing = false }
        }
    }

    private var actions: some View {
        HStack(spacing: 26) {
            TextAction(text: "Type", systemImage: "keyboard", help: "Type instead (T)") { startTyping() }
            if !chatOpen, !session.lines.isEmpty {
                TextAction(text: "Conversation \u{00B7} \(session.lines.count)", help: "Show the whole conversation (C)") { chatOpen = true }
            }
            Spacer(minLength: 0)
            sideAction
        }
    }

    /// The one control that matters right now: stop a reply, mute the mic, or mute spoken replies.
    @ViewBuilder private var sideAction: some View {
        if session.isReplying {
            TextAction(text: "Stop reply", systemImage: "stop.fill", help: "Stop this reply (Esc)") { session.stopReply() }
        } else if session.micOn {
            TextAction(text: session.micMuted ? "Unmute mic" : "Mute mic",
                       systemImage: session.micMuted ? "mic.slash.fill" : "mic.fill",
                       help: session.micMuted ? "Unmute the mic (M)" : "Mute the mic, keep the conversation going (M)") {
                session.micMuted.toggle()
            }
        } else {
            TextAction(text: session.muteReplies ? "Replies muted" : "Mute replies",
                       systemImage: session.muteReplies ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       help: session.muteReplies ? "Replies are text only. Click to hear them again." : "Mute spoken replies") {
                session.muteReplies.toggle()
            }
        }
    }

    // MARK: Typing

    private var typeBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                TextField("", text: $draft, prompt: Text("Type something").foregroundStyle(Theme.ink.opacity(0.7)), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.display(22, for: draft))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .onExitCommand(perform: stopTyping)
                ComposerToggle(
                    systemImage: session.attachScreenNext ? "eye.fill" : "eye",
                    isOn: session.attachScreenNext,
                    help: session.attachScreenNext
                        ? "Your screen will be shared with the next message"
                        : "Share your screen with the next message (or just ask \u{201C}what's on my screen?\u{201D})"
                ) { session.attachScreenNext.toggle() }
                ComposerToggle(
                    systemImage: session.muteReplies ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    isOn: session.muteReplies,
                    help: session.muteReplies ? "Replies are text only. Click to hear them again." : "Mute spoken replies"
                ) { session.muteReplies.toggle() }
                TextAction(text: hasDraft ? "Send" : "Back", help: hasDraft ? "Send (Return)" : "Back to voice (Esc)") {
                    hasDraft ? send() : stopTyping()
                }
                .disabled(hasDraft && !session.canToggle)
                .padding(.leading, 8)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(MistBackground(firm: true, seed: 2, spill: CGSize(width: 12, height: 12)))
        }
    }

    private func startTyping() {
        typing = true
        DispatchQueue.main.async { focused = true }
    }

    private func stopTyping() {
        focused = false
        typing = false
    }

    private func send() {
        guard hasDraft, session.canToggle else { return }
        session.send(draft)
        draft = ""
    }

    private var hint: String {
        if typing { return "Return to send  \u{00B7}  Esc to go back to voice" }
        if session.isReplying {
            if !session.micOn { return "Esc to stop the reply" }
            return session.micMuted ? "Esc to stop the reply  \u{00B7}  M to unmute" : "Talk over it to cut in  \u{00B7}  Esc to stop"
        }
        if session.micMuted { return "Mic muted  \u{00B7}  M to unmute" }
        if session.micOn { return "Click or Space to stop  \u{00B7}  M to mute" }
        let start = session.lines.isEmpty ? "Space works too" : "Space to talk"
        return shortcuts.talk.map { "\(start)  \u{00B7}  \($0.display) from any app" } ?? start
    }
}
