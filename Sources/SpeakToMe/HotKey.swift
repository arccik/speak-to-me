import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key plus modifiers, in Carbon terms so it can be registered system-wide.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …).
    var modifiers: UInt32
    /// What the key prints, captured when it was recorded ("Space", "O", "F5").
    var key: String

    static let optionSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "Space")
    static let controlOptionSpace = KeyCombo(
        keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey), key: "Space")

    /// "⌃⌥Space", in Apple's modifier order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Nil for a key press that can't be a global shortcut (no modifier, unless it's a function key).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        let code = Int(event.keyCode)
        let name = Self.specialKeys[code]
        let isFunctionKey = name?.hasPrefix("F") == true && name!.count > 1
        // Shift alone would swallow capital letters everywhere.
        guard mods & ~shiftKey != 0 || isFunctionKey else { return nil }
        guard let label = name ?? event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty,
              label.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        self.init(keyCode: UInt32(code), modifiers: UInt32(mods), key: label)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]
}

/// System-wide shortcuts via Carbon's hot-key API, which needs no Accessibility
/// permission (unlike global key monitors).
@MainActor
enum GlobalHotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [UInt32: EventHotKeyRef] = [:]
    private static var installed = false

    /// Registers (or replaces, or with nil removes) shortcut `id`. Returns false if the
    /// system wouldn't take it, usually because another app already owns it.
    @discardableResult
    static func register(id: UInt32, _ combo: KeyCombo?, action: @escaping () -> Void) -> Bool {
        installHandler()
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        handlers[id] = action
        guard let combo else { return true }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5354_4D45), id: id) // "STME"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    /// Pauses every shortcut, so a recorder can capture the combo it's bound to.
    static func suspend(_ suspended: Bool) {
        if suspended {
            for ref in refs.values { UnregisterEventHotKey(ref) }
            refs.removeAll()
        } else {
            Shortcuts.shared.registerAll()
        }
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() } }
            return noErr
        }, 1, &eventType, nil, nil)
    }
}

/// The app's two global shortcuts, saved in UserDefaults and kept registered.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    enum Action: UInt32, CaseIterable {
        case talk = 1, floatingOrb = 2

        var defaultsKey: String { self == .talk ? "hotKeyTalk" : "hotKeyOrb" }
        var fallback: KeyCombo { self == .talk ? .optionSpace : .controlOptionSpace }
    }

    @Published private(set) var talk: KeyCombo?
    @Published private(set) var floatingOrb: KeyCombo?
    /// Set when the system refused a shortcut, shown next to its recorder.
    @Published private(set) var conflict: Action?

    private var actions: [Action: () -> Void] = [:]

    private init() {
        talk = Self.load(.talk)
        floatingOrb = Self.load(.floatingOrb)
    }

    func combo(for action: Action) -> KeyCombo? {
        action == .talk ? talk : floatingOrb
    }

    func install(_ action: Action, perform: @escaping () -> Void) {
        actions[action] = perform
        register(action)
    }

    func set(_ combo: KeyCombo?, for action: Action) {
        switch action {
        case .talk: talk = combo
        case .floatingOrb: floatingOrb = combo
        }
        let data = combo.flatMap { try? JSONEncoder().encode($0) } ?? Data("none".utf8)
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
        register(action)
    }

    func reset(_ action: Action) { set(action.fallback, for: action) }

    func registerAll() { Action.allCases.forEach(register) }

    private func register(_ action: Action) {
        guard let perform = actions[action] else { return }
        let ok = GlobalHotKey.register(id: action.rawValue, combo(for: action), action: perform)
        if !ok { conflict = action } else if conflict == action { conflict = nil }
    }

    /// Never set: the default. "none": deliberately cleared.
    private static func load(_ action: Action) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return action.fallback }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }
}

/// Click, then press the new shortcut. Esc cancels, Delete clears it.
struct ShortcutRecorder: View {
    let action: Shortcuts.Action
    @ObservedObject private var shortcuts = Shortcuts.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                HStack(spacing: 6) {
                    if recording {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("Press keys…").foregroundStyle(.secondary)
                    } else if let combo = shortcuts.combo(for: action) {
                        Text(combo.display).font(.system(.body, design: .rounded).weight(.medium))
                    } else {
                        Text("Record shortcut").foregroundStyle(.secondary)
                    }
                }
                .frame(minWidth: 120)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(recording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(hovering ? 0.1 : 0.06),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(recording ? Color.accentColor : Color.primary.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(recording ? "Press a shortcut, Esc to cancel, Delete to clear" : "Click to record a new shortcut")

            if shortcuts.combo(for: action) != nil, !recording {
                Button { shortcuts.set(nil, for: action) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Turn this shortcut off")
            }
            if shortcuts.combo(for: action) != action.fallback, !recording {
                Button { shortcuts.reset(action) } label: {
                    Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to \(action.fallback.display)")
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        GlobalHotKey.suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                stopRecording()
            case kVK_Delete where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                shortcuts.set(nil, for: action)
                stopRecording()
            default:
                guard let combo = KeyCombo(event: event) else { NSSound.beep(); return nil }
                shortcuts.set(combo, for: action)
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalHotKey.suspend(false)
    }
}
