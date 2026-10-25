import SwiftUI

enum Theme {
    static let backgroundTop = RGBA.hex(0x10132A).color()
    static let backgroundBottom = RGBA.hex(0x0A0B18).color()
    static let surface = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.09)
    static let text = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let accent = RGBA.hex(0x46C8F0).color()
    static let violet = RGBA.hex(0x8E62F7).color()
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
                BottomBar()
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The orb takes centre stage until there's a conversation, then makes room for it.
    private var hero: some View {
        let compact = !session.lines.isEmpty
        return VStack(spacing: compact ? 6 : 14) {
            MistOrb(phase: session.phase, levels: session.levels)
                .frame(height: compact ? 190 : 290)
                .contentShape(Circle())
                .onTapGesture { if session.canToggle { session.toggle() } }
                .help(session.isActive ? "Stop" : "Start talking")
            StatusPill()
            GlowWaves(phase: session.phase, levels: session.levels)
                .frame(width: 260, height: compact ? 26 : 40)
                .opacity(session.isActive ? 1 : 0.35)
        }
        .padding(.bottom, 8)
        .animation(.spring(duration: 0.6, bounce: 0.15), value: compact)
    }
}

// MARK: - Backdrop

private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.backgroundTop, Theme.backgroundBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [RGBA.hex(0x2A3A8C).color(0.35), .clear],
                center: .init(x: 0.5, y: 0.2), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        HStack(spacing: 8) {
            Spacer()
            if let ms = session.lastLatencyMs {
                Label("\(ms) ms", systemImage: "bolt.fill")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Theme.surface, in: Capsule())
                    .help("From the moment you stop talking to the first word of the reply")
            }
            ModelMenu()
            SettingsLink {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 26, height: 26)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Settings (⌘,)")
        }
        .padding(.leading, 80) // keep clear of the window's traffic lights
        .padding(.trailing, 14)
        .padding(.top, 10)
        .frame(height: 44)
    }
}

private struct ModelMenu: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Menu {
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
                Image(systemName: "cpu")
                Text(session.modelID.isEmpty ? "Model" : session.modelID)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: 230)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Language model in oMLX")
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

// MARK: - Status

private struct StatusPill: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                if case .loading = session.phase {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                        .shadow(color: dotColor, radius: 4)
                }
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .tracking(2.2)
            }
            .foregroundStyle(Theme.text.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Theme.surface, in: Capsule())
            .overlay(Capsule().stroke(dotColor.opacity(0.35)))
            .animation(.easeOut(duration: 0.2), value: title)

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
            if session.lines.isEmpty {
                EmptyState()
            } else if Snapshots.isRendering {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    ForEach(session.lines) { MessageRow(line: $0, isLive: isLive($0)) }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(session.lines) { line in
                                MessageRow(line: line, isLive: isLive(line))
                                    .id(line.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: 12)),
                                        removal: .opacity))
                            }
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
                ForEach(["“Tell me a fun fact”", "“Plan my evening”", "“Explain black holes”"], id: \.self) {
                    Text($0)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Theme.surface, in: Capsule())
                }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 24)
    }
}

private struct MessageRow: View {
    let line: VoiceSession.Line
    let isLive: Bool

    var body: some View {
        switch line.role {
        case "user": user
        case "error": error
        default: assistant
        }
    }

    private var user: some View {
        HStack {
            Spacer(minLength: 60)
            Text(line.text)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    LinearGradient(colors: [RGBA.hex(0x3A4FB8).color(0.55), RGBA.hex(0x5B3FD8).color(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: BubbleShape())
                .overlay(BubbleShape().stroke(Color.white.opacity(0.1)))
        }
    }

    private var assistant: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(RadialGradient(colors: [.white, Theme.accent, Theme.violet],
                                     center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 9))
                .frame(width: 14, height: 14)
                .blur(radius: 0.4)
                .shadow(color: Theme.accent.opacity(0.6), radius: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 6) {
                if line.text.isEmpty {
                    TypingDots()
                } else {
                    (Text(line.text) + Text(isLive ? " ▍" : "").foregroundColor(Theme.accent))
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.text.opacity(line.interrupted ? 0.55 : 1))
                        .textSelection(.enabled)
                }
                if line.interrupted {
                    Label("Interrupted", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 30)
        }
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
    var body: some View {
        TimelineView(.animation) { timeline in
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
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        HStack(spacing: 0) {
            CircleButton(systemImage: "trash", help: "Clear conversation (⌘K)") { session.clearConversation() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(session.lines.isEmpty)
                .opacity(session.lines.isEmpty ? 0.35 : 1)
                .frame(width: 120, alignment: .leading)
            Spacer()
            MicButton()
            Spacer()
            Text(session.isActive ? "Space to stop" : "Space to start")
                .font(.caption)
                .foregroundStyle(Theme.secondary.opacity(0.8))
                .frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .padding(.top, 6)
    }
}

private struct CircleButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 40, height: 40)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().stroke(Theme.hairline))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct MicButton: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Button { session.toggle() } label: {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !session.isActive)) { _ in
                let level = Double(max(session.levels.mic, session.levels.speaker))
                ZStack {
                    if session.isActive {
                        Circle()
                            .stroke(Theme.accent.opacity(0.35), lineWidth: 2)
                            .scaleEffect(1.1 + level * 0.35)
                            .opacity(0.4 + level * 0.6)
                    }
                    Circle()
                        .fill(session.isActive
                              ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.violet],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.white.opacity(0.1)))
                        .overlay(Circle().stroke(Color.white.opacity(session.isActive ? 0.25 : 0.12)))
                        .shadow(color: session.isActive ? Theme.accent.opacity(0.45) : .clear, radius: 16)
                    Image(systemName: session.isActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(!session.canToggle)
        .opacity(session.canToggle ? 1 : 0.4)
        .help(session.isActive ? "Stop (Space)" : "Start talking (Space)")
        .animation(.easeOut(duration: 0.2), value: session.isActive)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Form {
            Section("Voice") {
                Picker("Voice", selection: $session.voice) {
                    ForEach(VoiceSession.voices, id: \.self) { Text(VoiceSession.voiceName($0)).tag($0) }
                }
                LabeledContent("Speaking speed") {
                    HStack {
                        Slider(value: $session.speed, in: 0.8...1.4, step: 0.05)
                        Text(String(format: "%.2f×", session.speed)).monospacedDigit().frame(width: 48)
                    }
                }
            }
            Section {
                LabeledContent("Reply after silence") {
                    Stepper("\(session.endOfTurnMs) ms", value: $session.endOfTurnMs, in: 256...2048, step: 128)
                }
            } header: {
                Text("Turn-taking")
            } footer: {
                Text("Shorter feels snappier; longer gives you time to think mid-sentence.")
            }
            Section("Personality") {
                TextEditor(text: $session.systemPrompt)
                    .font(.body)
                    .frame(minHeight: 120)
                Button("Reset to default") { session.systemPrompt = VoiceSession.defaultPrompt }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
