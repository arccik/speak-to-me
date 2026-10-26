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
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                TopBar()
                hero
                Transcript()
                Dock()
            }
            .ignoresSafeArea(.container, edges: .top) // the top bar shares the traffic lights' row
        }
        .preferredColorScheme(.dark)
        .onAppear(perform: SpaceKey.install)
    }

    /// The orb takes centre stage until there's a conversation, then shrinks to make room for it.
    private var hero: some View {
        let compact = !session.lines.isEmpty
        // Negative spacing: the cloud only fills the middle of its canvas, so tuck the label under it.
        return VStack(spacing: compact ? -8 : -40) {
            MistOrb(phase: session.phase, levels: session.levels)
                .frame(width: compact ? 130 : 300, height: compact ? 110 : 300)
                .contentShape(Circle())
                .onTapGesture { if session.canToggle { session.toggle() } }
                .help(session.isActive ? "Stop" : "Start talking")
            StatusLabel()
        }
        .padding(.top, compact ? 4 : 24)
        .padding(.bottom, compact ? 4 : 0)
        .animation(.spring(duration: 0.6, bounce: 0.15), value: compact)
    }
}

// MARK: - Backdrop

/// Deep navy, with a soft glow behind the orb that takes on the colour of the current phase.
private struct Backdrop: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        let compact = !session.lines.isEmpty
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            GeometryReader { geo in
                Ellipse()
                    .fill(Mood.of(session.phase).mid.color(compact ? 0.22 : 0.3))
                    .frame(width: geo.size.width * 1.1, height: compact ? 260 : 460)
                    .blur(radius: 110)
                    .position(x: geo.size.width / 2, y: compact ? 60 : 200)
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
    @EnvironmentObject private var session: VoiceSession
    @ObservedObject private var shortcuts = Shortcuts.shared

    var body: some View {
        HStack(spacing: 4) {
            TopIconButton(systemImage: "square.and.pencil", help: "New conversation (⌘N)") { session.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(session.lines.isEmpty)
            HistoryButton()
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
    @EnvironmentObject private var session: VoiceSession
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
    @EnvironmentObject private var session: VoiceSession

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
    @EnvironmentObject private var session: VoiceSession

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
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Group {
            if session.lines.isEmpty && (session.liveText ?? "").isEmpty {
                EmptyState()
            } else if Snapshots.isRendering {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    ForEach(session.lines) { MessageRow(line: $0, isLive: isLive($0), isLast: $0.id == session.lines.last?.id) }
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
                                MessageRow(line: line, isLive: isLive(line), isLast: line.id == session.lines.last?.id)
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
                    .onChange(of: session.lines.last?.text) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: session.liveText) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .onChange(of: session.lines.count) {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
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

/// Your words appearing as you speak, before the turn is final.
private struct LiveUserText: View {
    @EnvironmentObject private var session: VoiceSession

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
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
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
            Spacer()
        }
        .padding(.horizontal, 24)
    }
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
    @EnvironmentObject private var session: VoiceSession
    let line: VoiceSession.Line
    let isLive: Bool
    let isLast: Bool
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
                if line.text.isEmpty {
                    TypingDots()
                } else {
                    (Text(line.text) + Text(isLive ? " ▍" : "").foregroundColor(Theme.accent))
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(Color.white.opacity(line.interrupted ? 0.5 : isLive ? 0.95 : 0.82))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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

/// Type instead of talking. Enter sends; the speaker button mutes spoken replies.
private struct Composer: View {
    @EnvironmentObject private var session: VoiceSession
    @FocusState.Binding var focused: Bool
    @State private var draft = ""

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty && session.canToggle }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit(send)
                .onExitCommand { focused = false }
                .padding(.vertical, 5)
                .padding(.trailing, 4)
            ComposerToggle(
                systemImage: session.attachScreenNext ? "eye.fill" : "eye",
                tint: session.attachScreenNext ? Theme.accent : nil,
                help: session.attachScreenNext
                    ? "Your screen will be shared with the next message"
                    : "Share your screen with the next message (or just ask \u{201C}what's on my screen?\u{201D})"
            ) { session.attachScreenNext.toggle() }
            ComposerToggle(
                systemImage: session.muteReplies ? "speaker.slash.fill" : "speaker.wave.2.fill",
                tint: session.muteReplies ? RGBA.hex(0xFF9A9A).color() : nil,
                help: session.muteReplies ? "Replies are text only. Click to hear them again." : "Mute spoken replies"
            ) { session.muteReplies.toggle() }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(canSend ? .white : Theme.tertiary)
                    .frame(width: 28, height: 28)
                    .background(canSend ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.surface), in: Circle())
                    .shadow(color: canSend ? Theme.accent.opacity(0.4) : .clear, radius: 8)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send (Return)")
            .animation(.easeOut(duration: 0.15), value: canSend)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color.white.opacity(focused ? 0.075 : 0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(focused ? AnyShapeStyle(Theme.brand.opacity(0.7)) : AnyShapeStyle(Theme.hairline), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
    }

    private func send() {
        guard canSend else { return }
        session.send(draft)
        draft = ""
    }
}

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

/// Space toggles the mic, M mutes it and Esc stops a reply, except while you're typing in a text field.
@MainActor
enum SpaceKey {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard [49, 46, 53].contains(event.keyCode),
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty,
                  !(event.window?.firstResponder is NSText),
                  event.window?.identifier?.rawValue.hasPrefix("main") == true
            else { return event }
            let session = VoiceSession.shared
            switch event.keyCode {
            case 49: if session.canToggle { session.toggle() }
            case 46: guard session.micOn else { return event }; session.micMuted.toggle()
            default: guard session.isReplying else { return event }; session.stopReply()
            }
            return nil
        }
    }
}

// MARK: - Dock

/// Composer on top, then the mic with the voice waves flowing out of either side.
private struct Dock: View {
    @EnvironmentObject private var session: VoiceSession
    @ObservedObject private var shortcuts = Shortcuts.shared
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Composer(focused: $composerFocused)
            HStack(spacing: 10) {
                DockButton(
                    systemImage: session.micMuted ? "mic.slash.fill" : "mic.fill",
                    tint: session.micMuted ? RGBA.hex(0xFFB36B).color() : nil,
                    help: session.micMuted ? "Unmute the mic (M)" : "Mute the mic, keep the conversation going (M)"
                ) { session.micMuted.toggle() }
                    .disabled(!session.micOn)
                waves.scaleEffect(x: -1) // mirrored, so both sides flow out of the mic
                MicButton()
                waves
                DockButton(systemImage: "stop.circle", tint: nil, help: "Stop this reply (Esc)") { session.stopReply() }
                    .disabled(!session.isReplying)
            }
            .frame(maxWidth: 460)
            Text(hint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: hint)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 14)
    }

    private var waves: some View {
        GlowWaves(phase: session.phase, levels: session.levels)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .opacity(session.isActive ? 1 : 0.3)
            .animation(.easeOut(duration: 0.4), value: session.isActive)
    }

    private var hint: String {
        if composerFocused { return "Return to send  ·  Esc to go back to voice" }
        if session.isReplying {
            if !session.micOn { return "Esc to stop the reply" }
            return session.micMuted ? "Esc to stop the reply  ·  M to unmute" : "Esc or talk over me to stop the reply"
        }
        if session.micMuted { return "Mic muted  ·  M to unmute" }
        if session.micOn { return "Space to stop  ·  M to mute" }
        return shortcuts.talk.map { "Space to talk  ·  \($0.display) from any app" } ?? "Space to talk"
    }
}

/// The small round buttons at either end of the dock.
private struct DockButton: View {
    let systemImage: String
    let tint: Color?
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint ?? (hovering ? Theme.text : Theme.secondary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .background((tint ?? .white).opacity(tint != nil ? 0.16 : hovering ? 0.1 : 0.06), in: Circle())
                .overlay(Circle().stroke(tint?.opacity(0.4) ?? Theme.hairline))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovering = $0 && enabled }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: tint != nil)
    }
}

private struct MicButton: View {
    @EnvironmentObject private var session: VoiceSession
    @State private var hovering = false
    @State private var onScreen = true

    var body: some View {
        Button { session.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !session.micOn || !onScreen)) { timeline in
                let level = Double(max(session.levels.mic, session.levels.speaker))
                let t = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    if session.micOn {
                        // Two rings: one breathing on a clock, one riding the audio level.
                        let breath = (t.truncatingRemainder(dividingBy: 2.4)) / 2.4
                        Circle()
                            .stroke(Theme.accent.opacity(0.5 * (1 - breath)), lineWidth: 1.5)
                            .scaleEffect(1 + breath * 0.55)
                        Circle()
                            .stroke(Theme.brand, lineWidth: 2)
                            .scaleEffect(1.08 + level * 0.32)
                            .opacity(0.35 + level * 0.65)
                    }
                    Circle()
                        .fill(Theme.brand)
                        .overlay(
                            // Glassy top highlight.
                            Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear],
                                                         startPoint: .top, endPoint: .center))
                                .padding(2))
                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                        .shadow(color: Theme.accent.opacity(session.micOn ? 0.6 : 0.3), radius: session.micOn ? 22 : 14)
                        .shadow(color: Theme.violet.opacity(0.35), radius: 6, y: 3)
                    Image(systemName: session.micOn ? "stop.fill" : "mic.fill")
                        .font(.system(size: session.micOn ? 20 : 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 66, height: 66)
                .scaleEffect(hovering ? 1.05 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!session.canToggle)
        .saturation(session.canToggle ? 1 : 0)
        .opacity(session.canToggle ? 1 : 0.45)
        .onHover { hovering = $0 }
        .onWindowVisibilityChange { onScreen = $0 }
        .help(session.micOn ? "Stop (Space)" : "Start talking (Space)")
        .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
        .animation(.easeOut(duration: 0.2), value: session.micOn)
    }
}
