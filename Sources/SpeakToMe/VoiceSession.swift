import AVFoundation
import FluidAudio
import Foundation
import Observation

/// The conversation loop:
/// mic → VAD → (you pause) → Parakeet → oMLX stream → sentence chunks → Kokoro → speaker.
/// The reply is drafted during your pause and released once the pause is long enough.
/// If you start talking while the assistant is thinking or speaking, it stops (barge-in).
///
/// Views observe it property by property (`@Observable`), so a reply streaming in only
/// redraws the text that shows it, not every view that knows about the session.
@MainActor
@Observable
final class VoiceSession {
    /// One session for the main window, the floating orb, the menu bar and the hotkey.
    static let shared = VoiceSession()

    enum Phase: Equatable {
        case loading(String)
        case ready
        case listening
        case hearing
        case transcribing
        case thinking
        case speaking
        case failed(String)
    }

    struct Line: Identifiable, Codable {
        var id = UUID()
        let role: String
        var text: String
        var interrupted = false
        /// Small print under the message: tools used, screen shared.
        var note: String?
    }

    struct VisionUnavailable: LocalizedError {
        let model: String
        var errorDescription: String? {
            "\(model) can't see images. Pick a vision model (like gemma-4-26b-a4b) to ask about your screen."
        }
    }

    /// Attach a screenshot to the next message (the eye button).
    var attachScreenNext = false

    var currentModelSeesImages: Bool {
        models.first { $0.id == modelID }?.isVision ?? false
    }

    var phase: Phase = .loading("Starting…") {
        didSet { if phase != oldValue { followEchoCancellation() } }
    }
    var lines: [Line] = []
    var savedConversations: [ConversationStore.Summary] = []
    private var conversationID = UUID()
    private var conversationCreated = Date()
    private let store = ConversationStore()
    var models: [OMLXClient.Model] = []
    var lastLatencyMs: Int?
    /// What you're saying right now, re-transcribed every half second while you talk.
    var liveText: String?
    /// The reply being written right now. Tokens land here (~15 times a second) rather
    /// than in `lines`, so only the views showing this text redraw; the line itself is
    /// updated when a round of the reply is complete.
    private(set) var streamingText = ""
    /// The line `streamingText` belongs to.
    private(set) var streamingLineID: UUID?
    /// Mic problems are shown here instead of `.failed`, so Start stays usable for a retry.
    var micNotice: String?

    var modelID = StoredSetting.value("model", default: "") { didSet { StoredSetting.store(modelID, "model") } }
    var voice = StoredSetting.value("voice", default: "af_heart") { didSet { StoredSetting.store(voice, "voice") } }
    /// Supertonic-3 voice ("F1"…"M5") for replies that aren't in English.
    var languageVoice = StoredSetting.value("languageVoice", default: MultilingualVoices.defaultVoice) { didSet { StoredSetting.store(languageVoice, "languageVoice") } }
    var speed = StoredSetting.value("speed", default: 1.05) { didSet { StoredSetting.store(speed, "speed") } }
    var endOfTurnMs = StoredSetting.value("endOfTurnMs", default: 600) { didSet { StoredSetting.store(endOfTurnMs, "endOfTurnMs") } }
    /// 0…1: how quiet you can be and still start a turn. See `speechGate`.
    var micSensitivity = StoredSetting.value("micSensitivity", default: VoiceSession.defaultMicSensitivity) { didSet { StoredSetting.store(micSensitivity, "micSensitivity") } }
    var systemPrompt = StoredSetting.value("systemPrompt", default: VoiceSession.defaultPrompt) { didSet { StoredSetting.store(systemPrompt, "systemPrompt") } }
    /// Off, `systemPrompt` is sent exactly as written, with none of the app's rules added.
    var addsPromptRules = StoredSetting.value("addsPromptRules", default: true) { didSet { StoredSetting.store(addsPromptRules, "addsPromptRules") } }
    /// Keep the chosen model pinned in oMLX so it's never unloaded (no 10 s+ reloads).
    /// Off by default: on a 24 GB Mac a pinned model can leave no room for any other.
    var keepModelLoaded = StoredSetting.value("keepModelLoaded", default: false) { didSet { StoredSetting.store(keepModelLoaded, "keepModelLoaded") } }
    /// Text-only replies: nothing is spoken aloud.
    var muteReplies = StoredSetting.value("muteReplies", default: false) { didSet { StoredSetting.store(muteReplies, "muteReplies") } }
    /// Reply in whatever language you speak (detected per message).
    var matchLanguage = StoredSetting.value("matchLanguage", default: true) { didSet { StoredSetting.store(matchLanguage, "matchLanguage") } }
    /// Let the model search the web, check the time and open apps/pages.
    var useTools = StoredSetting.value("useTools", default: true) { didSet { StoredSetting.store(useTools, "useTools") } }
    var soundCues = StoredSetting.value("soundCues", default: true) { didSet { StoredSetting.store(soundCues, "soundCues") } }
    /// Talk over replies without headphones. macOS turns down other apps' audio
    /// (YouTube, music) while it's active, so it's only on while a reply is under way.
    var echoCancellation = StoredSetting.value("echoCancellation", default: true) { didSet { StoredSetting.store(echoCancellation, "echoCancellation") } }
    /// F5-TTS Russian: 8 is fast and clear, more is slower and a little cleaner.
    var f5Steps = StoredSetting.value("f5Steps", default: 8) { didSet { StoredSetting.store(f5Steps, "f5Steps") } }
    /// F5-TTS Russian: mark word stress first, as it was trained to read.
    var f5MarksStress = StoredSetting.value("f5MarksStress", default: true) { didSet { StoredSetting.store(f5MarksStress, "f5MarksStress") } }
    /// The model may use SSML for pauses and speed, and we perform it. Off, any tags are just dropped.
    var expressiveVoice = StoredSetting.value("expressiveVoice", default: false) { didSet { StoredSetting.store(expressiveVoice, "expressiveVoice") } }
    var myVoiceStatus: String?
    private(set) var myVoiceBusy = false
    /// The language of the conversation so far; sticks when a message is too short to tell.
    private(set) var language = "en"
    /// True while the microphone is on (a voice conversation is running).
    private(set) var micOn = false
    /// The conversation stays on, but it can't hear you (and you can't interrupt it).
    var micMuted = false {
        didSet {
            audio.micMuted = micMuted
            if micMuted { liveText = nil }
        }
    }

    /// Where things settle after a reply: listening if the mic is on, otherwise idle.
    private var restPhase: Phase { micOn ? .listening : .ready }
    /// The model this app pinned, so we only ever unpin our own pin.
    private var pinnedByApp: String {
        get { UserDefaults.standard.string(forKey: "pinnedByApp") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedByApp") }
    }

    static let defaultPrompt = """
        You are a friendly, quick-witted voice assistant having a spoken conversation. \
        Answer in one to three short, natural sentences unless asked for more detail. \
        Never use markdown, lists, headings, code blocks or emoji: everything you write is read aloud.
        """

    static let expressivePrompt = """
         You can shape how your voice sounds with exactly these tags: <break time="500ms"/> for a pause, and \
        <prosody rate="slow">words</prosody> for speed (slow or fast). \
        Use them only where they add feeling, usually not at all in a short plain answer, and never mention them.
        """

    static let defaultMicSensitivity = 0.5

    /// What it takes to start a turn at a given sensitivity: the chunk's loudness (on the
    /// 0…1 scale of `AudioLevels.rms`) and Silero's speech probability. The default keeps
    /// the probability at 0.5, as before, with a gate at about -43 dB under it; fully
    /// sensitive drops the gate and accepts 0.35, least sensitive needs -34 dB and 0.65.
    nonisolated static func speechGate(sensitivity: Double) -> (level: Float, probability: Float) {
        let s = Float(min(1, max(0, sensitivity)))
        return (level: 0.36 * (1 - s), probability: 0.65 - 0.3 * s)
    }

    static let toolsPrompt = " You can search the web, read pages, check the time and open apps or web pages with your tools; use them whenever they help, and summarise results briefly in speech."
    static let matchLanguagePrompt = " Always reply in the same language the user speaks to you in."

    /// What the model is sent: your personality, then the rules the app needs for the
    /// settings that are on. An empty personality falls back to the default one.
    static func composeSystemPrompt(_ personality: String, expressive: Bool, tools: Bool, matchLanguage: Bool,
                                    addsRules: Bool = true) -> String {
        let trimmed = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = trimmed.isEmpty ? defaultPrompt : trimmed
        guard addsRules else { return prompt }
        if expressive { prompt += expressivePrompt }
        if tools { prompt += toolsPrompt }
        if matchLanguage { prompt += matchLanguagePrompt }
        return prompt
    }

    /// Read afresh for every request, so an edit in Settings applies to the next reply.
    var fullSystemPrompt: String {
        Self.composeSystemPrompt(systemPrompt, expressive: expressiveVoice, tools: useTools, matchLanguage: matchLanguage,
                                 addsRules: addsPromptRules)
    }

    /// Switches between writing the whole prompt and letting the app add its rules,
    /// carrying the text over so nothing is lost or doubled.
    func setWritesWholePrompt(_ whole: Bool) {
        guard whole == addsPromptRules else { return }
        if whole {
            systemPrompt = fullSystemPrompt
        } else {
            var text = systemPrompt
            for rule in [Self.expressivePrompt, Self.toolsPrompt, Self.matchLanguagePrompt] {
                text = text.replacingOccurrences(of: rule, with: "")
            }
            systemPrompt = text
        }
        addsPromptRules = !whole
    }

    static let voices = [
        "af_heart", "af_bella", "af_nicole", "af_sarah", "af_sky", "af_nova",
        "am_adam", "am_michael", "am_eric", "am_liam", "am_onyx",
        "bf_emma", "bf_isabella", "bm_george", "bm_lewis", "bm_daniel",
    ]

    /// "af_heart" → "Heart · American female".
    static func voiceName(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let tag = parts.first, tag.count == 2 else { return id }
        let accent = tag.first == "b" ? "British" : "American"
        let gender = tag.last == "m" ? "male" : "female"
        return "\(parts[1].capitalized) · \(accent) \(gender)"
    }

    var canToggle: Bool {
        switch phase {
        case .loading, .failed: return false
        default: return true
        }
    }

    var isActive: Bool {
        switch phase {
        case .listening, .hearing, .transcribing, .thinking, .speaking: return true
        default: return false
        }
    }

    private var client = OMLXClient.fromSettings()
    private var reconnectTask: Task<Void, Never>?
    var serverAddress: String { client.baseURL.absoluteString }
    private let audio = AudioIO()
    var levels: AudioLevels { audio.levels }
    private var speech: SpeechModels?
    private var listenerTask: Task<Void, Never>?
    private var turn: Turn?
    private var micStream: AsyncStream<[Float]>.Continuation?
    private var history: [OMLXClient.Message] = []

    // MARK: - Setup

    private var booted = false

    /// The window can be closed and reopened; load everything only the first time.
    func bootOnce() async {
        guard !booted else { return }
        booted = true
        await boot()
    }

    func boot() async {
        savedConversations = store.list()
        if let latest = savedConversations.first { openConversation(latest.id) }
        await connect()
    }

    /// Connects to oMLX and loads the speech models. Also what Try Again runs after a failure.
    func connect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        client = OMLXClient.fromSettings() // the port or key may have changed since the last try
        do {
            phase = .loading("Connecting to oMLX…")
            models = try await client.chatModels()
            if !models.contains(where: { $0.id == modelID }) {
                modelID = Self.pickDefault(models)?.id ?? ""
            }
        } catch {
            phase = .failed("Can't reach oMLX at \(client.baseURL.absoluteString). Is the oMLX app running? Speak to Me will connect as soon as it is.\n\(error.localizedDescription)")
            waitForServer()
            return
        }
        do {
            let warm = Task { [client, modelID] in try? await client.warmUp(model: modelID) }
            Task { await updatePin() }
            speech = try await SpeechModels.load(voice: voice) { message in
                Task { @MainActor in self.phase = .loading(message) }
            }
            for engine in enginesToPrepare { prepareEngine(engine) }
            enginesToPrepare = []
            // It's slow to load, so it's ready before the first reply rather than during it.
            if speechEngines[.russian] == .f5Russian, SpeechEngine.f5Russian.isInstalled { prepareEngine(.f5Russian) }
            phase = .loading("Loading \(modelID) in oMLX…")
            await warm.value
            phase = .ready
        } catch {
            phase = .failed("Couldn't load the speech models: \(error.localizedDescription)")
        }
    }

    /// Checks quietly for oMLX coming up, so the error stays on screen until it does.
    private func waitForServer() {
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard (try? await OMLXClient.fromSettings().chatModels()) != nil, !Task.isCancelled else { continue }
                self?.reconnectTask = nil // connect() would otherwise cancel the task it's running in
                await self?.connect()
                return
            }
        }
    }

    /// Prefer a fast mixture-of-experts or small model; big dense models make replies laggy.
    private static func pickDefault(_ models: [OMLXClient.Model]) -> OMLXClient.Model? {
        let preferred = ["gemma-4-26b-a4b", "a3b", "a4b", "9b", "8b", "4b", "12b"]
        for hint in preferred {
            if let match = models.first(where: { $0.id.lowercased().contains(hint) }) { return match }
        }
        return models.min { $0.sizeBytes < $1.sizeBytes }
    }

    func modelChanged() {
        let client = client, modelID = modelID
        Task { try? await client.warmUp(model: modelID) }
        Task { await updatePin() }
    }

    /// Pins the current model (and unpins one we pinned before), or removes our pin.
    func updatePin() async {
        let target = keepModelLoaded ? modelID : ""
        guard target != pinnedByApp else { return }
        do {
            if !pinnedByApp.isEmpty { try await client.setPinned(false, model: pinnedByApp) }
            if !target.isEmpty { try await client.setPinned(true, model: target) }
            pinnedByApp = target
        } catch {
            micNotice = "Couldn't pin the model in oMLX: \(error.localizedDescription)"
        }
    }

    // MARK: - Speech models

    enum EngineState: Equatable {
        case notDownloaded, loading, ready
        case downloading(Double)
        case failed(String)
    }

    /// Which model speaks each language group. Read at the start of every reply, so a
    /// change applies from the next reply on.
    private(set) var speechEngines = Dictionary(uniqueKeysWithValues: SpeechSlot.allCases.map { ($0, $0.stored) })
    /// Only what's been asked for this run; everything else is judged by what's on disk.
    private var engineStates: [SpeechEngine: EngineState] = [:]
    /// Chosen while the speech models were still loading.
    private var enginesToPrepare: Set<SpeechEngine> = []

    func state(of engine: SpeechEngine) -> EngineState {
        engineStates[engine] ?? (engine.isInstalled ? .ready : .notDownloaded)
    }

    func setEngine(_ engine: SpeechEngine, for slot: SpeechSlot) {
        speechEngines[slot] = engine
        slot.stored = engine
        prepareEngine(engine)
        releaseUnusedF5()
    }

    /// F5-TTS holds a gigabyte or two for as long as its helper runs.
    private func releaseUnusedF5() {
        guard let speech, !speechEngines.values.contains(.f5Russian) else { return }
        engineStates[.f5Russian] = nil
        Task { await speech.f5Russian.stop() }
    }

    /// Downloads and loads `engine` in the background, reporting through `state(of:)`.
    func prepareEngine(_ engine: SpeechEngine) {
        guard let speech else { enginesToPrepare.insert(engine); return }
        switch engineStates[engine] {
        case .loading, .downloading, .ready: return
        case .notDownloaded, .failed, nil: break
        }
        engineStates[engine] = engine.isInstalled ? .loading : .downloading(0)
        let setup = speechSetup
        Task {
            do {
                try await speech.prepare(engine, using: setup) { fraction in
                    Task { @MainActor [weak self = self] in
                        guard case .downloading = self?.engineStates[engine] else { return }
                        self?.engineStates[engine] = fraction < 1 ? .downloading(fraction) : .loading
                    }
                }
                engineStates[engine] = .ready
                // Switched away while it was still on its way.
                if engine == .f5Russian { releaseUnusedF5() }
            } catch {
                engineStates[engine] = .failed(error.localizedDescription)
            }
        }
    }

    var speechForTest: SpeechModels? { speech }

    /// For Snapshots: shows a model mid-download without storing or fetching anything.
    func showEngineForSnapshot(_ engine: SpeechEngine, for slot: SpeechSlot, state: EngineState) {
        speechEngines[slot] = engine
        engineStates[engine] = state
    }

    private var speechSetup: SpeechSetup {
        SpeechSetup(
            engines: speechEngines, voice: voice, languageVoice: languageVoice, speed: Float(speed),
            expressive: expressiveVoice, clonedVoice: hasMyVoice ? Self.myVoiceFile.path : nil, f5Steps: f5Steps, f5MarksStress: f5MarksStress,
            f5Voice: selectedF5Voice, f5Pronunciations: f5Pronunciations)
    }

    // MARK: - F5-TTS voices

    /// Voices cloned for F5-TTS Russian.
    private(set) var f5Voices = F5VoiceLibrary.load()
    /// The one in use; empty for a clip of the Supertonic-3 voice.
    var f5VoiceID = StoredSetting.value("f5VoiceID", default: "") { didSet { StoredSetting.store(f5VoiceID, "f5VoiceID") } }
    var f5VoiceStatus: String?
    private(set) var f5VoiceBusy = false
    /// How words should be stressed, overruling the dictionary ("замок": "зам+ок").
    private(set) var f5Pronunciations = StoredSetting.value("f5Pronunciations", default: [String: String]()) {
        didSet { StoredSetting.store(f5Pronunciations, "f5Pronunciations") }
    }

    var selectedF5Voice: F5ClonedVoice? { f5Voices.first { $0.id == f5VoiceID } }

    static let f5VoiceScript = "Привет! Я записываю свой голос, чтобы помощник мог говорить как я. "
        + "Сегодня хороший день, и я никуда не спешу."

    /// Records 8 s from the mic and adds it as a voice.
    func recordF5Voice() async {
        guard !f5VoiceBusy else { return }
        if micOn { stop() }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            f5VoiceStatus = Self.deniedNotice
            return
        }
        f5VoiceBusy = true
        defer { f5VoiceBusy = false }
        let recording = FileManager.default.temporaryDirectory.appendingPathComponent("f5-voice-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: recording) }
        do {
            // The recorder hears almost nothing while voice processing is still winding down.
            if audio.isRunning {
                audio.stop()
                f5VoiceStatus = "Getting the microphone ready…"
                try? await Task.sleep(for: .seconds(2))
            }
            let recorder = try AVAudioRecorder(url: recording, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            SoundCues.play(.start)
            try? await Task.sleep(for: .milliseconds(350)) // don't record the chime
            recorder.record(forDuration: 8)
            for remaining in stride(from: 8, to: 0, by: -1) {
                f5VoiceStatus = "Recording… \(remaining) s left. Read the text above aloud."
                try? await Task.sleep(for: .seconds(1))
            }
            while recorder.isRecording { try? await Task.sleep(for: .milliseconds(100)) }
            SoundCues.play(.stop)
        } catch {
            f5VoiceStatus = "Couldn't record: \(error.localizedDescription)"
            return
        }
        await addF5Voice(from: recording, name: "Recording \(f5Voices.count + 1)")
    }

    func importF5Voice(from url: URL) async {
        guard !f5VoiceBusy else { return }
        f5VoiceBusy = true
        defer { f5VoiceBusy = false }
        await addF5Voice(from: url, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Prepares the clip, writes down what it says with Parakeet, and starts using it.
    private func addF5Voice(from file: URL, name: String) async {
        guard let speech else { f5VoiceStatus = "Still loading, try again in a moment."; return }
        f5VoiceStatus = "Listening to the clip…"
        do {
            let clip = try await Task.detached { try F5VoiceLibrary.clip(from: file) }.value
            let transcript = try await speech.transcribe(Resampler.convert(clip, from: Double(F5TTS.sampleRate), to: 16_000))
            guard transcript.contains(where: \.isLetter) else {
                f5VoiceStatus = "No speech found in that clip."
                return
            }
            let voice = F5ClonedVoice(id: UUID().uuidString, name: name, transcript: transcript)
            try FileManager.default.createDirectory(at: F5VoiceLibrary.folder, withIntermediateDirectories: true)
            try WAV.data(clip, sampleRate: F5TTS.sampleRate).write(to: voice.clip, options: .atomic)
            f5Voices.append(voice)
            F5VoiceLibrary.save(f5Voices)
            f5VoiceID = voice.id
            f5VoiceStatus = "Added. Check the words below match what's said."
        } catch {
            f5VoiceStatus = "Couldn't add that voice: \(error.localizedDescription)"
        }
    }

    func updateF5Voice(_ id: String, name: String? = nil, transcript: String? = nil) {
        guard let index = f5Voices.firstIndex(where: { $0.id == id }) else { return }
        if let name { f5Voices[index].name = name }
        if let transcript { f5Voices[index].transcript = transcript }
        F5VoiceLibrary.save(f5Voices)
    }

    func deleteF5Voice(_ id: String) {
        guard let voice = f5Voices.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: voice.clip)
        f5Voices.removeAll { $0.id == id }
        F5VoiceLibrary.save(f5Voices)
        if f5VoiceID == id { f5VoiceID = "" }
        f5VoiceStatus = nil
    }

    /// `form` marks the stressed vowel, as in "зам+ок".
    func addPronunciation(_ form: String) {
        let form = form.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let word = form.replacingOccurrences(of: "+", with: "")
        guard !word.isEmpty, form.contains("+") else { return }
        f5Pronunciations[word] = form
    }

    func removePronunciation(_ word: String) {
        f5Pronunciations[word] = nil
    }

    /// For Snapshots: a voice to show without storing anything.
    func showF5VoiceForSnapshot(_ voice: F5ClonedVoice) {
        f5Voices = [voice]
        f5VoiceStatus = "Added. Check the words below match what's said."
    }

    // MARK: - Your own voice

    static var myVoiceFolder: URL { SpeechModels.appRoot.appendingPathComponent("MyVoice", isDirectory: true) }
    static var myVoiceFile: URL { myVoiceFolder.appendingPathComponent("voice.bin") }
    var hasMyVoice: Bool {
        _ = myVoiceChanges // the file isn't observable; this is
        return FileManager.default.fileExists(atPath: Self.myVoiceFile.path)
    }
    private var myVoiceChanges = 0

    static let voiceScript = "Hi! I'm recording my voice so my assistant can speak like me. "
        + "I like long walks, good coffee and quiet mornings. "
        + "Today I'll read a few calm, natural sentences, at my normal speed."

    /// Records ~12 s from the mic, then learns the voice from it.
    func recordMyVoice() async {
        guard !myVoiceBusy else { return }
        if micOn { stop() }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            myVoiceStatus = Self.deniedNotice
            return
        }
        myVoiceBusy = true
        defer { myVoiceBusy = false }
        let sample = Self.myVoiceFolder.appendingPathComponent("sample.wav")
        do {
            try FileManager.default.createDirectory(at: Self.myVoiceFolder, withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: sample, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ])
            SoundCues.play(.start)
            try? await Task.sleep(for: .milliseconds(350)) // don't record the chime
            recorder.record(forDuration: 12)
            for remaining in stride(from: 12, to: 0, by: -1) {
                myVoiceStatus = "Recording… \(remaining) s left. Read the text above aloud."
                try? await Task.sleep(for: .seconds(1))
            }
            while recorder.isRecording { try? await Task.sleep(for: .milliseconds(100)) }
            SoundCues.play(.stop)
        } catch {
            myVoiceStatus = "Couldn't record: \(error.localizedDescription)"
            return
        }
        await learnMyVoice(from: sample)
    }

    func importMyVoice(from url: URL) async {
        guard !myVoiceBusy else { return }
        myVoiceBusy = true
        defer { myVoiceBusy = false }
        await learnMyVoice(from: url)
    }

    private func learnMyVoice(from sample: URL) async {
        guard let speech else { myVoiceStatus = "Still loading, try again in a moment."; return }
        myVoiceStatus = "Learning your voice… (the first time downloads the voice model, ~1 min)"
        do {
            try FileManager.default.createDirectory(at: Self.myVoiceFolder, withIntermediateDirectories: true)
            try await speech.tts.clone(sample: sample, to: Self.myVoiceFile)
            myVoiceChanges += 1
            setEngine(.myVoice, for: .english)
            myVoiceStatus = "Done! Replies in English now use your voice."
        } catch {
            myVoiceStatus = "Couldn't learn the voice: \(error.localizedDescription)"
        }
    }

    func deleteMyVoice() {
        try? FileManager.default.removeItem(at: Self.myVoiceFolder)
        if speechEngines[.english] == .myVoice { setEngine(.kokoro, for: .english) }
        myVoiceStatus = nil
        myVoiceChanges += 1
    }

    // MARK: - Conversation on/off

    func toggle() {
        micOn ? stop() : start()
    }

    /// Sends a typed message. Works with or without the mic on; the reply is spoken
    /// unless replies are muted.
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, speech != nil else { return }
        if assistantBusy || audio.isPlaying { interrupt() } else { discardDraft() }
        if !muteReplies, !audio.isRunning {
            configureAudioCallbacks()
            audio.start(withMic: false)
        }
        let turn = Turn(speechEndedAt: Date())
        turn.committed = true
        self.turn = turn
        phase = .thinking
        turn.task = Task { await run(turn, samples: nil, typed: text) }
    }

    private func configureAudioCallbacks() {
        audio.onPlaybackDrained = { [weak self] in
            Task { @MainActor in self?.playbackDrained() }
        }
    }

    func start() {
        guard speech != nil else { return }
        micNotice = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startListening()
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) {
                    startListening()
                } else {
                    micNotice = Self.deniedNotice
                }
            }
        default:
            micNotice = Self.deniedNotice
        }
    }

    static let deniedNotice =
        "Microphone access is off. Turn on Speak to Me in System Settings → Privacy & Security → Microphone, then press Start."

    private func startListening() {
        guard let speech else { return }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .bufferingNewest(200))
        micStream = continuation
        audio.onMicSamples = { continuation.yield($0) }
        configureAudioCallbacks()
        if audio.isRunning { audio.stop() } // playback-only engine from a typed message
        // The engine comes up in the background; show "listening" straight away and
        // take it back if the microphone can't start.
        audio.start(echoCancellation: echoCancellation) { [weak self] error in
            guard let self, let error, micOn else { return }
            micOn = false // no "mic off" chime: the error sound says it
            stop()
            micNotice = "Couldn't start the microphone: \(error.localizedDescription)"
            SoundCues.play(.error)
        }
        micOn = true
        phase = .listening
        SoundCues.play(.start)
        listenerTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.listen(stream: stream, vad: speech.vad, session: self)
        }
    }

    func stop() {
        liveText = nil
        turn?.task?.cancel()
        turn = nil
        listenerTask?.cancel()
        micStream?.finish()
        audio.stop()
        if micOn { SoundCues.play(.stop) }
        micOn = false
        micMuted = false
        phase = .ready
    }

    /// True while a reply is being worked out or spoken.
    var isReplying: Bool { assistantBusy }

    /// Cuts the current reply short but keeps the conversation (and the mic) going.
    func stopReply() {
        guard assistantBusy || audio.isPlaying else { return }
        interrupt()
        liveText = nil
        phase = restPhase
    }

    /// Speaks a message again, whatever the mute setting.
    func readAloud(_ text: String) {
        guard let speech, !text.isEmpty else { return }
        if assistantBusy || audio.isPlaying { interrupt() } else { discardDraft() }
        if !audio.isRunning {
            configureAudioCallbacks()
            audio.start(withMic: false)
        }
        // Committed so audio plays straight away; never revealed, so nothing lands in the history.
        let turn = Turn(speechEndedAt: Date())
        turn.committed = true
        turn.spoke = true
        self.turn = turn
        phase = .thinking
        let setup = speechSetup, turnLanguage = language
        turn.task = Task {
            var chunker = SentenceChunker()
            for sentence in chunker.push(text) + chunker.finish() {
                let sentenceLanguage = matchLanguage ? LanguageDetector.detect(SSML.plain(sentence)) ?? turnLanguage : "en"
                guard let samples = try? await speech.speak(sentence, language: sentenceLanguage, using: setup),
                      !Task.isCancelled
                else { if Task.isCancelled { return } else { continue } }
                play(samples, for: turn)
            }
            turn.generating = false
            if self.turn === turn, !audio.isPlaying {
                self.turn = nil
                phase = restPhase
            }
        }
    }

    /// There's an answer to your last message that can be asked for again.
    var canRetry: Bool {
        lines.contains { $0.role == "user" } && lines.last?.role != "user"
    }

    /// Throws away the last reply and asks again.
    func retryLast() {
        guard canRetry, let i = lines.lastIndex(where: { $0.role == "user" }) else { return }
        let text = lines[i].text
        cancelTurn()
        lines.removeSubrange(i...)
        while let last = history.popLast(), last.role != "user" {}
        send(text)
    }

    /// Starts a fresh conversation; the current one stays in the history list.
    func newConversation() {
        cancelTurn()
        saveConversation()
        lines.removeAll()
        history.removeAll()
        conversationID = UUID()
        conversationCreated = Date()
        phase = restPhase
    }

    func openConversation(_ id: UUID) {
        guard let conversation = store.load(id) else { return }
        cancelTurn()
        saveConversation()
        conversationID = conversation.id
        conversationCreated = conversation.created
        // Older saves can hold SSML the model wrote; showing it, or sending it back, only encourages it.
        lines = conversation.lines.map { line in
            var line = line
            if line.role == "assistant" { line.text = SentenceChunker.visible(line.text) }
            return line
        }
        // The model only needs the spoken exchange, not error notes.
        history = lines
            .filter { $0.role == "user" || $0.role == "assistant" }
            .map { OMLXClient.Message(role: $0.role, content: $0.text) }
        // At launch this runs while models load; don't clobber that status.
        if case .loading = phase {} else { phase = restPhase }
    }

    func deleteConversation(_ id: UUID) {
        store.delete(id)
        if id == conversationID {
            lines.removeAll()
            history.removeAll()
            conversationID = UUID()
            conversationCreated = Date()
        }
        savedConversations.removeAll { $0.id == id }
    }

    func deleteAllConversations() {
        cancelTurn()
        for item in savedConversations { store.delete(item.id) }
        savedConversations.removeAll()
        deleteConversation(conversationID)
        if case .loading = phase {} else { phase = restPhase }
    }

    /// Starts an unsaved conversation with these lines, leaving the open one untouched (used by `--uibench`).
    func beginTestConversation(lines: [Line]) {
        cancelTurn()
        conversationID = UUID()
        conversationCreated = Date()
        self.lines = lines
        history = lines.map { OMLXClient.Message(role: $0.role, content: $0.text) }
        phase = restPhase
    }

    /// Removes the current conversation without saving (used by `--chattest`).
    func deleteConversationForTest() {
        deleteConversation(conversationID)
    }

    private func saveConversation() {
        guard lines.contains(where: { $0.role == "user" }) else { return }
        let conversation = ConversationStore.Conversation(
            id: conversationID, created: conversationCreated, updated: Date(), lines: lines)
        store.save(conversation)
        // Update the list in place rather than re-reading every saved conversation from disk.
        savedConversations.removeAll { $0.id == conversation.id }
        if let summary = ConversationStore.summary(of: conversation) { savedConversations.insert(summary, at: 0) }
    }

    private func cancelTurn() {
        turn?.task?.cancel()
        turn = nil
        audio.stopPlayback()
        liveText = nil
        endStreaming()
    }

    // MARK: - Listening (runs off the main thread)

    /// Silero works on 256 ms chunks. We keep a little audio from before speech
    /// starts so the first syllable isn't clipped.
    ///
    /// Turn-taking: after one silent chunk we start a draft reply (`userPaused`); if
    /// you speak again it's thrown away (`userResumed`); once the silence lasts the
    /// full end-of-turn time the draft becomes the real reply (`userFinished`).
    private nonisolated static func listen(stream: AsyncStream<[Float]>, vad: VadManager, session: VoiceSession?) async {
        let chunkSize = VadManager.chunkSize
        let chunkMs = 256
        var pending: [Float] = []
        var preRoll: [[Float]] = []
        var utterance: [Float] = []
        var inSpeech = false
        var speechChunks = 0
        var silenceMs = 0
        var drafting = false
        var chunksSincePartial = 0
        let draftAfterMs = chunkMs
        var vadState = VadStreamState.initial()

        for await samples in stream {
            pending += samples
            while pending.count >= chunkSize {
                if Task.isCancelled { return }
                let chunk = Array(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)

                // We only use the speech probability; our own turn-taking logic sits below.
                guard let result = try? await vad.processStreamingChunk(chunk, state: vadState) else { continue }
                vadState = result.state
                let probability = result.probability
                let (assistantBusy, endMs, sensitivity) = await MainActor.run { () -> (Bool, Int, Double) in
                    return (session?.assistantBusy ?? false, session?.endOfTurnMs ?? 600,
                            session?.micSensitivity ?? defaultMicSensitivity)
                }

                if !inSpeech {
                    preRoll.append(chunk)
                    if preRoll.count > 2 { preRoll.removeFirst() }
                    // While the assistant talks, require more evidence so echo residue can't interrupt it.
                    let needed = assistantBusy ? 2 : 1
                    let gate = speechGate(sensitivity: sensitivity)
                    let level = chunk.withUnsafeBufferPointer { AudioLevels.rms($0) }
                    let heard = probability > gate.probability + (assistantBusy ? 0.2 : 0) && level >= gate.level
                    speechChunks = heard ? speechChunks + 1 : 0
                    if speechChunks >= needed {
                        inSpeech = true
                        silenceMs = 0
                        utterance = preRoll.flatMap { $0 }
                        preRoll.removeAll()
                        await session?.userStartedSpeaking()
                    }
                } else {
                    utterance += chunk
                    chunksSincePartial += 1
                    if chunksSincePartial >= 2 {
                        chunksSincePartial = 0
                        await session?.updateLiveText(utterance)
                    }
                    if probability < 0.35 {
                        silenceMs += chunkMs
                    } else if probability >= 0.5 {
                        silenceMs = 0
                        if drafting {
                            drafting = false
                            await session?.userResumed()
                        }
                    }
                    let speechEnded = Date().addingTimeInterval(-Double(silenceMs) / 1000)
                    if silenceMs >= endMs {
                        inSpeech = false
                        drafting = false
                        speechChunks = 0
                        let audio = utterance
                        utterance = []
                        await session?.userFinished(audio, endedAt: speechEnded)
                    } else if silenceMs >= draftAfterMs, !drafting {
                        // A short pause: start working on the reply now, in case it's the end.
                        drafting = true
                        await session?.userPaused(utterance, endedAt: speechEnded)
                    }
                }
            }
        }
    }

    /// Echo cancellation stays on while you're talking back and forth, and lets go after a long quiet spell.
    private func followEchoCancellation() {
        switch phase {
        case .transcribing, .thinking, .speaking: audio.prepareEchoCancellation()
        case .hearing: audio.holdEchoCancellation()
        case .listening: audio.relaxEchoCancellation()
        default: break
        }
    }

    private var assistantBusy: Bool {
        phase == .thinking || phase == .speaking || phase == .transcribing
    }

    private func userStartedSpeaking() {
        if assistantBusy || audio.isPlaying { interrupt() }
        phase = .hearing
        liveText = ""
    }

    private var liveTextTask: Task<Void, Never>?

    /// Keeps only one partial transcription in flight; Parakeet takes ~50 ms for a few seconds of audio.
    private func updateLiveText(_ samples: [Float]) {
        guard liveTextTask == nil, let speech, liveText != nil else { return }
        liveTextTask = Task {
            let text = try? await speech.transcribe(samples)
            liveTextTask = nil
            if liveText != nil, let text, !text.isEmpty { liveText = text }
        }
    }

    /// Barge-in: stop the assistant, keeping what it already said in the history.
    private func interrupt() {
        audio.stopPlayback()
        guard let turn else { return }
        turn.task?.cancel()
        if turn.committed, turn.revealed {
            showReply(turn, now: true)
            if turn.generating { history.append(.init(role: "assistant", content: SentenceChunker.visible(turn.reply))) }
            if let i = turn.lineIndex, lines.indices.contains(i) { lines[i].interrupted = true }
            saveConversation()
        }
        self.turn = nil
    }

    // MARK: - Turns

    private func userPaused(_ samples: [Float], endedAt: Date) {
        discardDraft()
        guard samples.count > Self.minUtteranceSamples else { return }
        startTurn(samples: samples, endedAt: endedAt, committed: false)
    }

    private func userResumed() {
        discardDraft()
    }

    private func userFinished(_ samples: [Float], endedAt: Date) {
        if let turn, !turn.committed {
            commit(turn)
            return
        }
        guard samples.count > Self.minUtteranceSamples else {
            liveText = nil
            phase = .listening
            return
        }
        startTurn(samples: samples, endedAt: endedAt, committed: true)
    }

    /// Ignore coughs and clicks shorter than ~0.4 s.
    private static let minUtteranceSamples = 6_400

    private func discardDraft() {
        guard let turn, !turn.committed else { return }
        turn.task?.cancel()
        self.turn = nil
    }

    private func startTurn(samples: [Float], endedAt: Date, committed: Bool) {
        let turn = Turn(speechEndedAt: endedAt)
        turn.committed = committed
        self.turn = turn
        if committed { phase = .transcribing }
        turn.task = Task { await run(turn, samples: samples, typed: nil) }
    }

    /// The draft is now the real reply: show it and release any audio it already made.
    private func commit(_ turn: Turn) {
        turn.committed = true
        guard let text = turn.userText else {
            phase = .transcribing
            return
        }
        guard !text.isEmpty else { return finishEmpty(turn) }
        reveal(turn)
        if !turn.generating { finalize(turn) }
    }

    private func run(_ turn: Turn, samples: [Float]?, typed: String?) async {
        guard let speech else { return }
        do {
            let text: String
            if let typed { text = typed } else { text = try await speech.transcribe(samples ?? []) }
            try Task.checkCancellation()
            turn.userText = text.count > 1 ? text : ""
            guard text.count > 1 else {
                if turn.committed { finishEmpty(turn) }
                return
            }
            if matchLanguage, let detected = LanguageDetector.detect(text) { language = detected }
            // Loads while the model thinks, so the reply's first sentence isn't held up.
            if matchLanguage, let engine = speechSetup.route(for: language).first { prepareEngine(engine) }
            var images: [Data] = []
            if attachScreenNext || ScreenVision.wantsScreen(text) {
                guard currentModelSeesImages else { throw VisionUnavailable(model: modelID) }
                images = [try await ScreenVision.capture()]
                turn.sharedScreen = true
            }
            let messages = [OMLXClient.Message(role: "system", content: fullSystemPrompt)] + history.suffix(20)
                + [.init(role: "user", content: text, images: images)]
            if turn.committed { reveal(turn) }
            try await generate(turn, messages: messages, speech: speech)
            turn.generating = false
            if turn.committed { finalize(turn) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            turn.generating = false
            if turn.committed {
                lines.append(Line(role: "error", text: error.localizedDescription))
                SoundCues.play(.error)
                finalize(turn)
            } else {
                // Surface it if and when the draft gets committed.
                turn.failure = error
            }
        }
    }

    /// Streams the reply from oMLX and speaks it sentence by sentence, running any
    /// tools the model asks for in between. Drafts keep their audio in `heldAudio`
    /// until committed.
    private func generate(_ turn: Turn, messages initial: [OMLXClient.Message], speech: SpeechModels) async throws {
        var messages = initial
        let (sentences, sentenceSink) = AsyncStream<String>.makeStream()
        let setup = speechSetup, muted = muteReplies
        let turnLanguage = matchLanguage ? language : "en"
        let ttsTask = Task {
            for await sentence in sentences {
                if Task.isCancelled { return }
                if muted { continue }
                // Per-sentence detection catches a reply that switches language; short ones follow the turn.
                let sentenceLanguage = LanguageDetector.detect(SSML.plain(sentence)) ?? turnLanguage
                guard let samples = try? await speech.speak(
                        sentence, language: matchLanguage ? sentenceLanguage : "en", using: setup),
                      !Task.isCancelled
                else { if Task.isCancelled { return } else { continue } }
                if turn.committed { play(samples, for: turn) } else { turn.heldAudio.append(samples) }
            }
        }

        var chunker = SentenceChunker()
        try await withTaskCancellationHandler {
            do {
                for round in 0..<4 {
                    var calls: [OMLXClient.ToolCall] = []
                    var roundText = ""
                    let tools = useTools && round < 3 ? Tools.definitions : []
                    for try await event in client.streamChat(model: modelID, messages: messages, tools: tools) {
                        try Task.checkCancellation()
                        switch event {
                        case .text(let token):
                            turn.reply += token
                            roundText += token
                            showReply(turn)
                            for sentence in chunker.push(token) { sentenceSink.yield(sentence) }
                        case .toolCall(let call):
                            calls.append(call)
                        }
                    }
                    showReply(turn, now: true)
                    guard !calls.isEmpty else { break }

                    for sentence in chunker.finish() { sentenceSink.yield(sentence) }
                    chunker = SentenceChunker()
                    if turn.reply.isEmpty, let filler = calls.lazy.compactMap(Tools.filler).first,
                       turnLanguage == "en" || !matchLanguage {
                        sentenceSink.yield(filler)
                    }
                    messages.append(.init(role: "assistant", content: SentenceChunker.visible(roundText), toolCalls: calls))
                    for call in calls {
                        // Opening apps or pages can't be undone, so a draft waits until it's the real reply.
                        while Tools.hasSideEffects(call) && !turn.committed {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        turn.notes.append(Tools.label(for: call))
                        if let i = turn.lineIndex, lines.indices.contains(i) { lines[i].note = turn.notes.joined(separator: " · ") }
                        let result = await Tools.run(call, client: client)
                        try Task.checkCancellation()
                        messages.append(.init(role: "tool", content: result, toolCallID: call.id))
                    }
                }
                for sentence in chunker.finish() { sentenceSink.yield(sentence) }
                sentenceSink.finish()
                await ttsTask.value
                try Task.checkCancellation()
            } catch {
                sentenceSink.finish()
                ttsTask.cancel()
                throw error
            }
        } onCancel: {
            sentenceSink.finish()
            ttsTask.cancel()
        }
    }

    /// Tokens stream in dozens of times a second, so the reply on screen is refreshed at
    /// most ~15 times a second, through `streamingText`. `force` writes it into the line.
    private func showReply(_ turn: Turn, now force: Bool = false) {
        guard let i = turn.lineIndex, lines.indices.contains(i) else { return }
        let now = Date()
        guard force || now.timeIntervalSince(turn.lastShown) >= 1.0 / 15 else { return }
        turn.lastShown = now
        let text = SentenceChunker.visible(turn.reply)
        if force {
            if lines[i].text != text { lines[i].text = text }
            endStreaming()
        } else {
            if streamingLineID != lines[i].id { streamingLineID = lines[i].id }
            if streamingText != text { streamingText = text }
        }
    }

    private func endStreaming() {
        if streamingLineID != nil { streamingLineID = nil }
        if !streamingText.isEmpty { streamingText = "" }
    }

    /// What a line says right now, including a reply that's still streaming in.
    func currentText(of line: Line) -> String {
        line.id == streamingLineID ? streamingText : line.text
    }

    /// Puts the turn on screen and into the history, and plays anything already synthesized.
    private func reveal(_ turn: Turn) {
        guard !turn.revealed, let text = turn.userText else { return }
        turn.revealed = true
        liveText = nil
        lines.append(Line(role: "user", text: text, note: turn.sharedScreen ? "Shared your screen" : nil))
        if turn.sharedScreen { attachScreenNext = false }
        history.append(.init(role: "user", content: turn.sharedScreen ? text + " [screenshot attached]" : text))
        lines.append(Line(role: "assistant", text: SentenceChunker.visible(turn.reply),
                          note: turn.notes.isEmpty ? nil : turn.notes.joined(separator: " · ")))
        turn.lineIndex = lines.count - 1
        if let failure = turn.failure {
            lines.append(Line(role: "error", text: failure.localizedDescription))
        }
        phase = .thinking
        for samples in turn.heldAudio { play(samples, for: turn) }
        turn.heldAudio.removeAll()
    }

    private func play(_ samples: [Float], for turn: Turn) {
        guard self.turn === turn else { return }
        if !turn.spoke {
            turn.spoke = true
            lastLatencyMs = Int(Date().timeIntervalSince(turn.speechEndedAt) * 1000)
        }
        phase = .speaking
        audio.play(samples)
    }

    private func finalize(_ turn: Turn) {
        guard turn.revealed, !turn.finalized else { return }
        turn.finalized = true
        showReply(turn, now: true)
        history.append(.init(role: "assistant", content: SentenceChunker.visible(turn.reply)))
        saveConversation()
        if self.turn === turn, !audio.isPlaying {
            self.turn = nil
            phase = restPhase
        }
    }

    private func finishEmpty(_ turn: Turn) {
        liveText = nil
        if self.turn === turn { self.turn = nil }
        phase = restPhase
    }

    private func playbackDrained() {
        guard phase == .speaking else { return }
        if let turn, turn.generating { return } // just a gap between sentences
        turn = nil
        phase = restPhase
    }
}

/// One assistant reply. It starts as a draft the moment you pause and only becomes
/// real ("committed") if you stay quiet for the whole end-of-turn wait. A draft
/// transcribes, thinks and synthesizes, but holds its audio back.
@MainActor
private final class Turn {
    let speechEndedAt: Date
    var committed = false
    var userText: String?
    var reply = ""
    var heldAudio: [[Float]] = []
    var lineIndex: Int?
    var generating = true
    var revealed = false
    var finalized = false
    var spoke = false
    var sharedScreen = false
    /// When the reply on screen was last refreshed.
    var lastShown = Date.distantPast
    /// What tools did, shown under the reply.
    var notes: [String] = []
    var failure: Error?
    var task: Task<Void, Never>?

    init(speechEndedAt: Date) {
        self.speechEndedAt = speechEndedAt
    }
}

extension SentenceChunker {
    /// The reply as shown on screen: thinking and SSML removed, otherwise untouched.
    static func visible(_ text: String) -> String {
        let s = text.contains("<think>")
            ? text.replacingOccurrences(of: #"<think>[\s\S]*?(</think>|$)"#, with: "", options: .regularExpression)
            : text
        return SSML.plain(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Settings live in UserDefaults under the same keys `@AppStorage` used.
private enum StoredSetting {
    static func value<T>(_ key: String, default value: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? value
    }

    static func store<T>(_ value: T, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
