import AppKit
import ScreenCaptureKit

/// Lets the assistant see your screen: "what's on my screen?", "read this error"…
enum ScreenVision {
    enum VisionError: LocalizedError {
        case noPermission
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noPermission:
                return "To let me see your screen, turn on Speak to Me in System Settings → Privacy & Security → Screen & System Audio Recording, then ask again."
            case .noDisplay:
                return "Couldn't find a display to capture."
            }
        }
    }

    /// Phrases that mean "look at my screen", in a few languages.
    private static let triggers = [
        "my screen", "the screen", "on screen", "this screen", "look at this", "look at that", "what do you see",
        "what am i looking at", "this window", "this page", "this error", "read this", "see this",
        "экран", "екран", "ekran", "pantalla", "écran", "bildschirm",
    ]

    static func wantsScreen(_ text: String) -> Bool {
        let lower = text.lowercased()
        return triggers.contains { lower.contains($0) }
    }

    /// JPEG of the main display, without this app's own windows, at most 1600 px wide.
    static func capture() async throws -> Data {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw VisionError.noPermission
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw VisionError.noDisplay }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = min(1, 1600 / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else {
            throw VisionError.noDisplay
        }
        return jpeg
    }
}
