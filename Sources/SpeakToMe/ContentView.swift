import SwiftUI

enum Theme {
    static let backgroundTop = RGBA.hex(0x10132A).color()
    static let backgroundBottom = RGBA.hex(0x0A0B18).color()
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.09)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.42)
    static let accent = RGBA.hex(0x46C8F0).color()
    static let violet = RGBA.hex(0x8E62F7).color()
    static let brand = LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ContentView: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false

    var body: some View {
        let showChat = chatOpen && !session.lines.isEmpty
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                TopBar()
                if !showChat { Spacer(minLength: 0) }
                hero(compact: showChat)
                if showChat {
                    Transcript()
                        .transition(.opacity.combined(with: .offset(y: 30)))
                } else {
                    Group {
                        if session.lines.isEmpty && (session.liveText ?? "").isEmpty {
                            EmptyState()
                        } else {
                            Caption()
                        }
                    }
                    .transition(.opacity)
                    Spacer(minLength: 0)
                }
                Dock()
            }
            .ignoresSafeArea(.container, edges: .top) // the top bar shares the traffic lights' row
            .animation(.spring(duration: 0.6, bounce: 0.12), value: showChat)
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: SpaceKey.install)
    }

    /// The orb is the whole show until you open the chat, then it shrinks to make room for it.
    private func hero(compact: Bool) -> some View {
        // Negative spacing: the cloud only fills the middle of its canvas, so tuck the label under it.
        VStack(spacing: compact ? -4 : -70) {
            MistOrb(phase: session.phase, levels: session.levels)
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 0, maxWidth: compact ? 120 : 460, minHeight: 0, maxHeight: compact ? 120 : 460)
                .contentShape(Circle().scale(0.6))
                .onTapGesture { if session.canToggle { session.toggle() } }
                .help(session.isActive ? "Stop" : "Start talking")
            StatusLabel()
        }
        .padding(.top, compact ? 0 : 4)
        .padding(.bottom, compact ? 4 : 0)
    }
}

// MARK: - Backdrop

/// Deep navy, with a soft glow behind the orb that takes on the colour of the current phase.
private struct Backdrop: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false

    var body: some View {
        let compact = chatOpen && !session.lines.isEmpty
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                Ellipse()
                    .fill(Mood.of(session.phase).mid.color(compact ? 0.22 : 0.34))
                    .frame(width: geo.size.width * 1.2, height: compact ? 260 : 560)
                    .blur(radius: 120)
                    .position(x: geo.size.width / 2, y: compact ? 60 : geo.size.height * 0.36)
                    .animation(.easeInOut(duration: 0.9), value: session.phase)
                    .animation(.spring(duration: 0.6), value: compact)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Environment(VoiceSession.self) private var session
    @ObservedObject private var shortcuts = Shortcuts.shared
    @AppStorage("chatOpen") private var chatOpen = false

    var body: some View {
        HStack(spacing: 4) {
            TopIconButton(systemImage: "square.and.pencil", help: "New conversation (⌘N)") { session.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(session.lines.isEmpty)
            HistoryButton()
            TopIconButton(systemImage: chatOpen ? "text.bubble.fill" : "text.bubble",
                          help: chatOpen ? "Hide the conversation (C)" : "Show the conversation (C)") {
                chatOpen.toggle()
            }
            .disabled(session.lines.isEmpty)
            Spacer(minLength: 8)
            ModelMenu()
            TopIconButton(systemImage: "pip.enter",
                          help: shortcuts.floatingOrb.map { "Floating orb (\($0.display))" } ?? "Floating orb") {
                MiniOrbController.shared.toggle(session: session)
            }
            SettingsLink { TopIconLabel(systemImage: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
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

/// Borderless until hovered, so the title bar row stays calm.
private struct TopIconLabel: View {
    let systemImage: String
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hovering ? Theme.text : Theme.secondary)
            .frame(width: 28, height: 24)
            .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && enabled }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
            ForEach(session.models) { model in
                Button {
                    session.modelID = model.id
                    session.modelChanged()
                } label: {
                    if model.id == session.modelID {
                        Label("\(model.id)  ·  \(Self.gb(model.sizeBytes))", systemImage: "checkmark")
                    } else {
                        Text("\(model.id)  ·  \(Self.gb(model.sizeBytes))")
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(session.modelID.isEmpty ? Theme.tertiary : RGBA.hex(0x5BE0A0).color())
                    .frame(width: 6, height: 6)
                Text(session.modelID.isEmpty ? "Model" : session.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .frame(maxWidth: 200)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
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

/// One quiet line under the orb; the orb itself carries the mood.
private struct StatusLabel: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                if case .loading = session.phase {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 5, height: 5)
                        .shadow(color: dotColor, radius: 4)
                }
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .tracking(2)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(Theme.secondary)
            .frame(height: 18)
            .animation(.easeOut(duration: 0.25), value: title)

            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(isProblem ? RGBA.hex(0xFF8A8A).color() : Theme.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .transition(.opacity)
            }
        }
    }

    private var title: String {
        if session.micMuted, session.phase == .listening { return "MIC MUTED" }
        switch session.phase {
        case .loading: return "LOADING"
        case .ready: return "READY"
        case .listening: return "LISTENING"
        case .hearing: return "HEARING YOU"
        case .transcribing, .thinking: return "THINKING"
        case .speaking: return "SPEAKING"
        case .failed: return "ERROR"
        }
    }

    private var detail: String? {
        if let notice = session.micNotice { return notice }
        switch session.phase {
        case .loading(let message): return message
        case .failed(let message): return message
        default: return nil
        }
    }

    private var isProblem: Bool {
        if session.micNotice != nil { return true }
        if case .failed = session.phase { return true }
        return false
    }

    private var dotColor: Color {
        if session.micMuted, session.phase == .listening { return RGBA.hex(0xFFB36B).color() }
        switch session.phase {
        case .listening, .hearing: return Theme.accent
        case .thinking, .transcribing: return Theme.violet
        case .speaking: return RGBA.hex(0x3FA6FF).color()
        case .failed: return .red
        default: return Theme.secondary
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
                .padding(.vertical, 18)
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
                        .padding(.vertical, 18)
                        .animation(.easeOut(duration: 0.25), value: session.lines.count)
                    }
                    .scrollIndicators(.never)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                    .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
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
            HStack {
                Spacer(minLength: 60)
                HStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: 14.5))
                        .foregroundStyle(Theme.text.opacity(0.75))
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(BubbleShape().stroke(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            .transition(.opacity)
        }
    }
}

private struct EmptyState: View {
    @Environment(VoiceSession.self) private var session

    var body: some View {
        VStack(spacing: 14) {
            Text(session.isActive ? "Go ahead, I'm listening" : "Talk to your local AI")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.text)
            Text(session.isActive
                 ? "Speak naturally. Pause when you're done, or talk over me to interrupt."
                 : "Press Space or tap the orb, then just speak.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                ForEach(["Tell me a fun fact", "Plan my evening", "Explain black holes"], id: \.self) { prompt in
                    SuggestionChip(text: prompt) { session.send(prompt) }
                        .disabled(!session.canToggle)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }
}

/// With the chat closed, only what's being said right now: your words as you speak,
/// or the latest reply. Long replies keep their newest words in view; click to open the chat.
private struct Caption: View {
    @Environment(VoiceSession.self) private var session
    @AppStorage("chatOpen") private var chatOpen = false
    @State private var hovering = false

    private struct Current: Equatable {
        var id: String
        var role: String
        var text: String
        var live: Bool
        var interrupted = false
    }

    private var current: Current? {
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
        Button { chatOpen = true } label: {
            VStack(spacing: 10) {
                // A fixed stage for the words, so the orb never shifts as they come and go.
                ZStack(alignment: .top) {
                    if let current {
                        words(current)
                            .id(current.id)
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
                    }
                }
                .frame(height: 112)
                .padding(.top, 10)
                if !session.lines.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        Text("Show conversation · \(session.lines.count)")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hovering ? Theme.secondary : Theme.tertiary)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(hovering ? Theme.surface : .clear, in: Capsule())
                    .overlay(Capsule().stroke(hovering ? Theme.hairline : .clear))
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.3), value: current?.id)
        .help("Show the whole conversation (C)")
    }

    @ViewBuilder
    private func words(_ current: Current) -> some View {
        if current.text.isEmpty {
            TypingDots()
        } else {
            let tail = current.live && current.role == "assistant" ? " ▍" : ""
            (Text(current.text) + Text(tail).foregroundColor(Theme.accent))
                .font(.system(size: current.role == "user" ? 17 : 18, weight: .regular, design: .rounded))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .foregroundStyle(color(current))
                .fixedSize(horizontal: false, vertical: true)
                // Newest words at the bottom; older ones fade out over the top.
                .frame(maxHeight: 112, alignment: needsFade(current.text) ? .bottom : .top)
                .clipped()
                .mask(
                    LinearGradient(stops: [.init(color: needsFade(current.text) ? .clear : .black, location: 0),
                                           .init(color: .black, location: 0.28)],
                                   startPoint: .top, endPoint: .bottom))
        }
    }

    private func color(_ current: Current) -> Color {
        switch current.role {
        case "error": return RGBA.hex(0xFF9A9A).color()
        // Yours in a cool tint, so it's clear who's talking without a label.
        case "user": return RGBA.hex(0xBFEFFF).color(current.live ? 0.75 : 0.85)
        default: return Color.white.opacity(current.interrupted ? 0.5 : current.live ? 0.96 : 0.85)
        }
    }

    /// Roughly more than four lines: only then does the top need to fade.
    private func needsFade(_ text: String) -> Bool { text.count > 150 }
}

private struct SuggestionChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(hovering ? Color.white.opacity(0.1) : Theme.surface, in: Capsule())
                .overlay(Capsule().stroke(hovering ? Theme.accent.opacity(0.4) : Theme.hairline))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Ask this")
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

    private var user: some View {
        VStack(alignment: .trailing, spacing: 4) {
            userBubble
            if let note = line.note { NoteLabel(text: note, systemImage: "eye") }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 60)
            Text(line.text)
                .font(.system(size: 14.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: [RGBA.hex(0x3A4FB8).color(0.55), RGBA.hex(0x5B3FD8).color(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: BubbleShape())
                .overlay(BubbleShape().stroke(Color.white.opacity(0.1)))
                .frame(maxWidth: 360, alignment: .trailing)
        }
    }

    /// Plain text on the left, no avatar: alignment already says who's talking. Capped
    /// at a comfortable reading width; the reply being spoken stays brightest.
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
                    Label("Interrupted", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                }
                if !line.text.isEmpty, !isLive {
                    actions
                        // Always on the latest reply so they're discoverable; on hover for the rest.
                        .opacity(hovering || isLast ? 1 : 0)
                        .animation(.easeOut(duration: 0.15), value: hovering)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            Spacer(minLength: 30)
        }
        .padding(.leading, 4)
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
            .font(.callout)
            .foregroundStyle(RGBA.hex(0xFF9A9A).color())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        if text.isEmpty {
            TypingDots()
        } else {
            (Text(text) + Text(isLive ? " ▍" : "").foregroundColor(Theme.accent))
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(Color.white.opacity(interrupted ? 0.5 : isLive ? 0.95 : 0.82))
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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(done ? Theme.accent : hovering ? Theme.text : Theme.tertiary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 22)
                .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }
        .help(help)
    }
}

private struct NoteLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.accent.opacity(0.8))
            .lineLimit(2)
    }
}

/// Rounded bubble with a tighter bottom-right corner, pointing at the speaker.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18,
            style: .continuous
        ).path(in: rect)
    }
}

private struct TypingDots: View {
    @State private var onScreen = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !onScreen)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Theme.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .frame(height: 20)
        }
        .onWindowVisibilityChange { onScreen = $0 }
    }
}

// MARK: - Composer

/// Small icon toggle inside the composer; tinted with a soft backing while it's on.
private struct ComposerToggle: View {
    let systemImage: String
    let tint: Color?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(tint ?? (hovering ? Theme.text : Theme.secondary))
                .frame(width: 28, height: 28)
                .background((tint ?? .white).opacity(tint != nil ? 0.16 : hovering ? 0.07 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Space toggles the mic, M mutes it, C shows or hides the chat and Esc stops a reply,
/// except while you're typing in a text field.
@MainActor
enum SpaceKey {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard [49, 46, 8, 53].contains(event.keyCode),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  !(event.window?.firstResponder is NSText),
                  event.window?.identifier?.rawValue.hasPrefix("main") == true
            else { return event }
            let session = VoiceSession.shared
            switch event.keyCode {
            case 49: if session.canToggle { session.toggle() }
            case 46: guard session.micOn else { return event }; session.micMuted.toggle()
            case 8:
                guard !session.lines.isEmpty else { return event }
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "chatOpen"), forKey: "chatOpen")
            default: guard session.isReplying else { return event }; session.stopReply()
            }
            return nil
        }
    }
}

// MARK: - Dock

/// Voice first: a big piece of the orb in the middle, with the voice waves flowing out of it.
/// Typing is one click away on the keyboard button, and Esc folds it back into voice.
private struct Dock: View {
    @Environment(VoiceSession.self) private var session
    @ObservedObject private var shortcuts = Shortcuts.shared
    @FocusState private var focused: Bool
    @State private var typing = false
    @State private var draft = ""

    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                if typing {
                    typeBar
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)),
                                                removal: .opacity.combined(with: .scale(scale: 0.96))))
                } else {
                    voiceRow
                        .transition(.opacity.combined(with: .scale(scale: 1.04)))
                }
            }
            .frame(minHeight: 76)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: hint)
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .animation(.spring(duration: 0.4, bounce: 0.15), value: typing)
        .onChange(of: focused) { _, isFocused in
            // Clicking away from an empty field goes back to voice.
            if !isFocused && !hasDraft { typing = false }
        }
    }

    // MARK: Voice

    private var voiceRow: some View {
        let mood = Mood.of(session.phase)
        return HStack(spacing: 10) {
            GlassButton(systemImage: "keyboard", tint: nil, help: "Type instead") { startTyping() }
            waves.scaleEffect(x: -1) // mirrored, so both sides flow out of the orb
            OrbButton(mood: mood, symbol: session.micOn ? "stop.fill" : "mic.fill", size: 68,
                      live: session.micOn, levels: session.levels, enabled: session.canToggle,
                      help: session.micOn ? "Stop (Space)" : "Start talking (Space)") { session.toggle() }
            waves
            sideAction
        }
        .frame(maxWidth: 480)
        .animation(.easeInOut(duration: 0.8), value: session.phase)
    }

    /// The one control that matters right now: stop a reply, mute the mic, or mute spoken replies.
    @ViewBuilder private var sideAction: some View {
        if session.isReplying {
            GlassButton(systemImage: "stop.fill", tint: nil, help: "Stop this reply (Esc)") { session.stopReply() }
        } else if session.micOn {
            GlassButton(
                systemImage: session.micMuted ? "mic.slash.fill" : "mic.fill",
                tint: session.micMuted ? RGBA.hex(0xFFB36B).color() : nil,
                help: session.micMuted ? "Unmute the mic (M)" : "Mute the mic, keep the conversation going (M)"
            ) { session.micMuted.toggle() }
        } else {
            GlassButton(
                systemImage: session.muteReplies ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: session.muteReplies ? RGBA.hex(0xFFB3B3).color() : nil,
                help: session.muteReplies ? "Replies are text only. Click to hear them again." : "Mute spoken replies"
            ) { session.muteReplies.toggle() }
        }
    }

    private var waves: some View {
        GlowWaves(phase: session.phase, levels: session.levels)
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .opacity(session.isActive ? 1 : 0.3)
            .animation(.easeOut(duration: 0.4), value: session.isActive)
    }

    // MARK: Typing

    private var typeBar: some View {
        let mood = Mood.of(session.phase)
        let shape = RoundedRectangle(cornerRadius: 25, style: .continuous)
        return HStack(alignment: .bottom, spacing: 2) {
            TextField("Type a message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand(perform: stopTyping)
                .padding(.leading, 14)
                .padding(.trailing, 4)
                .padding(.vertical, 12)
            Group {
                ComposerToggle(
                    systemImage: session.attachScreenNext ? "eye.fill" : "eye",
                    tint: session.attachScreenNext ? Theme.accent : nil,
                    help: session.attachScreenNext
                        ? "Your screen will be shared with the next message"
                        : "Share your screen with the next message (or just ask \u{201C}what's on my screen?\u{201D})"
                ) { session.attachScreenNext.toggle() }
                ComposerToggle(
                    systemImage: session.muteReplies ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    tint: session.muteReplies ? RGBA.hex(0xFFB3B3).color() : nil,
                    help: session.muteReplies ? "Replies are text only. Click to hear them again." : "Mute spoken replies"
                ) { session.muteReplies.toggle() }
            }
            .padding(.bottom, 6)
            // Send once there's something typed; otherwise straight back to talking.
            OrbButton(mood: mood, symbol: hasDraft ? "arrow.up" : "waveform", size: 40,
                      live: false, levels: session.levels, enabled: hasDraft ? session.canToggle : true,
                      help: hasDraft ? "Send (Return)" : "Back to voice (Esc)") {
                hasDraft ? send() : stopTyping()
            }
            .padding(.leading, 4)
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background {
            shape.fill(LinearGradient(colors: [.white.opacity(0.085), .white.opacity(0.045)], startPoint: .top, endPoint: .bottom))
                .overlay(shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.16), mood.mid.color(0.4), .white.opacity(0.03)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: mood.mid.color(0.2), radius: 22, y: 4)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
        }
        .frame(maxWidth: 560)
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
        if typing { return "Return to send  ·  Esc to go back to voice" }
        if session.isReplying {
            if !session.micOn { return "Esc to stop the reply" }
            return session.micMuted ? "Esc to stop the reply  ·  M to unmute" : "Esc or talk over me to stop the reply"
        }
        if session.micMuted { return "Mic muted  ·  M to unmute" }
        if session.micOn { return "Space to stop  ·  M to mute" }
        return shortcuts.talk.map { "Space to talk  ·  \($0.display) from any app" } ?? "Space to talk"
    }
}

/// The round buttons either side of the orb: the same frosted glass as the typing bar.
private struct GlassButton: View {
    let systemImage: String
    let tint: Color?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? (hovering ? Theme.text : Theme.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 42, height: 42)
                .background {
                    Circle()
                        .fill(tint.map { AnyShapeStyle($0.opacity(0.16)) } ?? AnyShapeStyle(
                            LinearGradient(colors: [.white.opacity(hovering ? 0.12 : 0.08), .white.opacity(hovering ? 0.06 : 0.03)],
                                           startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().strokeBorder(
                            LinearGradient(colors: [(tint ?? .white).opacity(0.3), (tint ?? .white).opacity(0.04)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: tint != nil)
    }
}

/// A piece of the orb: the same core-to-edge colours as the current mood, glowing, with
/// rings that ride the audio while the mic is live.
private struct OrbButton: View {
    let mood: Mood
    let symbol: String
    let size: CGFloat
    let live: Bool
    let levels: AudioLevels
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var onScreen = true

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || !onScreen)) { timeline in
                let level = Double(max(levels.mic, levels.speaker))
                let breath = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                ZStack {
                    if live {
                        Circle()
                            .stroke(mood.mid.color(0.55 * (1 - breath)), lineWidth: 1.5)
                            .scaleEffect(1 + breath * 0.5)
                        Circle()
                            .stroke(mood.core.color(0.5 + level * 0.5), lineWidth: 2)
                            .scaleEffect(1.06 + level * 0.3)
                            .opacity(0.3 + level * 0.7)
                    }
                    Circle()
                        .fill(RadialGradient(colors: [mood.core.color(), mood.mid.color(), mood.edge.color()],
                                             center: UnitPoint(x: 0.42, y: 0.36), startRadius: 0, endRadius: size * 0.75))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
                        .shadow(color: mood.mid.color(live ? 0.75 : hovering ? 0.6 : 0.45), radius: size * (live ? 0.4 : 0.28))
                        .shadow(color: mood.edge.color(0.5), radius: 6, y: 3)
                    Image(systemName: symbol)
                        .font(.system(size: size * (symbol == "mic.fill" ? 0.36 : 0.32), weight: .bold))
                        .foregroundStyle(mood.edge.mix(.hex(0x0A0B18), 0.45).color())
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.05 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .saturation(enabled ? 1 : 0)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 && enabled }
        .onWindowVisibilityChange { onScreen = $0 }
        .help(help)
        .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
        .animation(.easeOut(duration: 0.2), value: symbol)
    }
}
