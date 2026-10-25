import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut via Carbon's hot-key API, which needs no Accessibility
/// permission (unlike global key monitors).
enum GlobalHotKey {
    private static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    /// Registers ⌥Space. Calls `action` on the main thread each time it's pressed.
    static func registerOptionSpace(_ action: @escaping () -> Void) {
        guard ref == nil else { return }
        handler = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.handler?() }
            return noErr
        }, 1, &eventType, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x5354_4D45), id: 1) // "STME"
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}
