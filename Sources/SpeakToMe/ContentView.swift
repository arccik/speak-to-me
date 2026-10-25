import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Orb(phase: session.phase, level: session.micLevel)
                .frame(height: 220)
                .contentShape(Rectangle())
                .onTapGesture { session.toggle() }
            status
            transcript
            controls
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Model", selection: $session.modelID) {
                ForEach(session.models) { model in
                    Text("\(model.id)  ·  \(Self.gb(model.sizeBytes))").tag(model.id)
                }
            }
            .labelsHidden()
            .onChange(of: session.modelID) { session.modelChanged() }

            Spacer()
            if let ms = session.lastLatencyMs {
                Text("\(ms) ms")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Time from when you stopped talking to the first spoken word")
            }
            SettingsLink { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.top, 34)
    }

    private var status: some View {
        Text(session.micNotice ?? statusText)
            .font(.callout)
            .foregroundStyle(isError || session.micNotice != nil ? .red : .secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(minHeight: 40)
    }

    private var statusText: String {
        switch session.phase {
        case .loading(let message): return message
        case .ready: return "Tap the orb or press Space to start talking"
        case .listening: return "Listening…"
        case .hearing: return "Hearing you…"
        case .transcribing: return "Got it…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking — just talk to interrupt"
        case .failed(let message): return message
        }
    }

    private var isError: Bool {
        if case .failed = session.phase { return true }
        return false
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(session.lines) { line in
                        Bubble(line: line).id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: session.lines.last?.text) {
                if let id = session.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button(session.isActive ? "Stop" : "Start") { session.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!canToggle)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            Spacer()
            Button("Clear") { session.clearConversation() }
                .disabled(session.lines.isEmpty)
        }
        .padding(16)
    }

    private var canToggle: Bool {
        switch session.phase {
        case .loading, .failed: return false
        default: return true
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}

private struct Bubble: View {
    let line: VoiceSession.Line

    var body: some View {
        HStack {
            if line.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(line.text.isEmpty ? "…" : line.text)
                    .textSelection(.enabled)
                if line.interrupted {
                    Text("interrupted").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(line.role == "user" ? Color.white : Color.primary)
            if line.role != "user" { Spacer(minLength: 40) }
        }
    }

    private var background: Color {
        switch line.role {
        case "user": return .accentColor
        case "error": return .red.opacity(0.2)
        default: return Color.secondary.opacity(0.15)
        }
    }
}

/// A soft glowing circle that reacts to what the assistant is doing.
private struct Orb: View {
    let phase: VoiceSession.Phase
    let level: Float

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let pulse = pulse(at: t)
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .scaleEffect(1.0 + pulse * 0.45)
                    .blur(radius: 18)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [color.opacity(0.95), color.opacity(0.55)],
                            center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 90))
                    .scaleEffect(0.82 + pulse * 0.18)
                    .shadow(color: color.opacity(0.5), radius: 20)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 150, height: 150)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeOut(duration: 0.25), value: phase)
    }

    private func pulse(at t: Double) -> Double {
        switch phase {
        case .hearing, .listening: return Double(min(level, 1))
        case .speaking: return 0.35 + 0.25 * sin(t * 7) * sin(t * 2.3)
        case .thinking, .transcribing: return 0.15 + 0.12 * sin(t * 4)
        case .loading: return 0.08 * sin(t * 2)
        default: return 0
        }
    }

    private var color: Color {
        switch phase {
        case .listening, .hearing: return .teal
        case .thinking, .transcribing: return .indigo
        case .speaking: return .orange
        case .failed: return .red
        default: return .gray
        }
    }

    private var icon: String {
        switch phase {
        case .listening, .hearing: return "waveform"
        case .thinking, .transcribing: return "sparkles"
        case .speaking: return "speaker.wave.2.fill"
        case .failed: return "exclamationmark.triangle"
        case .loading: return "hourglass"
        case .ready: return "mic.fill"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var session: VoiceSession

    var body: some View {
        Form {
            Picker("Voice", selection: $session.voice) {
                ForEach(VoiceSession.voices, id: \.self) { Text($0).tag($0) }
            }
            LabeledContent("Speaking speed") {
                Slider(value: $session.speed, in: 0.8...1.4, step: 0.05)
                Text(String(format: "%.2f×", session.speed)).monospacedDigit().frame(width: 48)
            }
            LabeledContent("Reply after silence") {
                Stepper("\(session.endOfTurnMs) ms", value: $session.endOfTurnMs, in: 256...2048, step: 128)
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
