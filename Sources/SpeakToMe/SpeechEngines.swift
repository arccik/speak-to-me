import Foundation

/// A text-to-speech model the app can speak with. To add one: add a case here, offer it
/// in `SpeechSlot.engines`, and teach `SpeechModels.synthesize` and `prepare` to run it.
enum SpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case kokoro, myVoice, supertonic, f5Russian, macOS

    var id: String { rawValue }

    var name: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .myVoice: return "My voice (PocketTTS)"
        case .supertonic: return "Supertonic-3"
        case .f5Russian: return "F5-TTS Russian"
        case .macOS: return "macOS voice"
        }
    }

    /// One line for Settings: what to expect from it.
    var summary: String {
        switch self {
        case .kokoro: return "Fast, on-device English."
        case .myVoice: return "English in a voice you've recorded. A little slower than the built-in voices."
        case .supertonic: return "Fast, with 31 languages. The voice is shared by every language that uses it."
        case .f5Russian: return "Can speak in a cloned voice. Takes a second or two per sentence and about 3 GB of memory while chosen. For non-commercial use."
        case .macOS: return "Your Mac's own voices. Add better ones in System Settings → Accessibility → Spoken Content."
        }
    }

    /// What's there once downloaded; nil when there's nothing to fetch on demand.
    private var installedPath: String? {
        switch self {
        case .kokoro, .macOS: return nil
        case .myVoice: return "Models/pocket-tts"
        case .supertonic: return "supertonic-3"
        case .f5Russian: return F5RussianVoice.installedMarker
        }
    }

    var downloadSize: String? {
        switch self {
        case .kokoro, .macOS: return nil
        case .myVoice: return "about 550 MB"
        case .supertonic: return "about 160 MB"
        case .f5Russian: return "about 1.4 GB"
        }
    }

    var isInstalled: Bool {
        guard let installedPath else { return true }
        let path = SpeechModels.modelsRoot.appendingPathComponent(installedPath).path
        return FileManager.default.fileExists(atPath: path)
    }
}

/// The languages that each get their own choice of model in Settings.
enum SpeechSlot: String, CaseIterable, Identifiable, Sendable {
    case english, russian, other

    var id: String { rawValue }

    init(language: String) {
        switch language {
        case "en": self = .english
        case "ru": self = .russian
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .english: return "English"
        case .russian: return "Russian"
        case .other: return "Other languages"
        }
    }

    var engines: [SpeechEngine] {
        switch self {
        case .english: return [.kokoro, .myVoice]
        case .russian: return [.supertonic, .f5Russian, .macOS]
        case .other: return [.supertonic, .macOS]
        }
    }

    /// Tried in order after the chosen model, for a model that fails or can't speak the
    /// language. Kokoro is always last: an odd accent beats silence.
    var fallbacks: [SpeechEngine] {
        switch self {
        case .english: return [.kokoro]
        case .russian, .other: return [.supertonic, .macOS, .kokoro]
        }
    }

    private var storageKey: String { "speechEngine.\(rawValue)" }

    var stored: SpeechEngine {
        get {
            if let raw = UserDefaults.standard.string(forKey: storageKey),
               let engine = SpeechEngine(rawValue: raw), engines.contains(engine) {
                return engine
            }
            // Before this setting existed, "use my voice" was a toggle.
            if self == .english, UserDefaults.standard.bool(forKey: "useMyVoice") { return .myVoice }
            return engines[0]
        }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: storageKey) }
    }
}

/// Everything needed to speak a sentence, captured at the start of a reply.
struct SpeechSetup: Sendable {
    var engines: [SpeechSlot: SpeechEngine] = [:]
    /// Kokoro's voice.
    var voice = "af_heart"
    /// Supertonic-3's voice.
    var languageVoice = MultilingualVoices.defaultVoice
    var speed: Float = 1
    /// Perform SSML in replies (pauses, rate, pitch) rather than just speaking the words.
    var expressive = true
    /// The voice file PocketTTS speaks with, when one has been recorded.
    var clonedVoice: String?
    /// F5-TTS's solver steps: more is slower and cleaner.
    var f5Steps = 8
    /// Mark F5-TTS's text with where words are stressed (RUAccent's dictionary).
    var f5MarksStress = true
    /// The voice F5-TTS imitates, instead of a clip of `languageVoice`.
    var f5Voice: F5ClonedVoice?
    /// Lowercase words and how they should be stressed ("замок": "зам+ок").
    var f5Pronunciations: [String: String] = [:]

    /// The chosen model for `language`, then what to try if it can't.
    func route(for language: String) -> [SpeechEngine] {
        let slot = SpeechSlot(language: language)
        var route = [engines[slot] ?? slot.engines[0]]
        for engine in slot.fallbacks where !route.contains(engine) { route.append(engine) }
        return route
    }
}
