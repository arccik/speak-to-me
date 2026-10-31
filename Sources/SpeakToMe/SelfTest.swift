import AVFoundation
import Foundation

/// `SpeakToMe --selftest [model]` runs the whole pipeline without a microphone:
/// Kokoro speaks a question → Parakeet transcribes it → oMLX answers → Kokoro speaks
/// the first sentence. Prints the time each stage takes, then exits.
enum SelfTest {
    static func run(model requested: String?) async {
        @Sendable func log(_ s: String) { print(s); fflush(stdout) }
        do {
            let client = OMLXClient.fromSettings()
            let models = try await client.chatModels()
            guard let model = requested ?? models.first(where: { $0.id.contains("gemma-4-26b-a4b") })?.id ?? models.first?.id
            else { log("No chat models in oMLX"); exit(1) }
            log("oMLX: \(client.baseURL.absoluteString), model: \(model)")

            var clock = Date()
            func lap() -> Int { defer { clock = Date() }; return Int(Date().timeIntervalSince(clock) * 1000) }

            let warm = Task { try await client.warmUp(model: model) }
            let speech = try await SpeechModels.load(voice: "af_heart") { log("  \($0)") }
            log("speech models ready: \(lap()) ms")
            try await warm.value
            log("LLM loaded: \(lap()) ms")

            let question = "What is the tallest mountain in Europe, and how high is it?"
            let spoken24k = try await speech.speak(question, using: SpeechSetup(voice: "am_adam"))
            let spoken16k = Resampler.convert(spoken24k, from: 24_000, to: 16_000)
            log("synthesized test question (\(spoken16k.count / 16) ms of audio): \(lap()) ms")

            // From here on is what you feel after you stop talking.
            let text = try await speech.transcribe(spoken16k)
            let stt = lap()
            log("STT  \(stt) ms  → \"\(text)\"")

            var chunker = SentenceChunker()
            var first: String?
            var reply = ""
            var ttft = 0
            for try await event in client.streamChat(
                model: model,
                messages: [.init(role: "system", content: await VoiceSession.defaultPrompt), .init(role: "user", content: text)])
            {
                guard case .text(let token) = event else { continue }
                if reply.isEmpty { ttft = lap() }
                reply += token
                if first == nil, let s = chunker.push(token).first { first = s; break }
            }
            let firstSentenceMs = ttft + lap()
            log("LLM  first token \(ttft) ms, first sentence \(firstSentenceMs) ms → \"\(first ?? reply)\"")

            let audio = try await speech.speak(first ?? reply, using: SpeechSetup(speed: 1.05))
            let tts = lap()
            log("TTS  \(tts) ms → \(audio.count / 24) ms of audio")
            let pipeline = stt + firstSentenceMs + tts
            let setting = UserDefaults.standard.integer(forKey: "endOfTurnMs")
            // The listener works in 256 ms VAD steps, so waits round up to whole steps.
            let wait = Int((Double(setting == 0 ? 600 : setting) / 256).rounded(.up)) * 256
            log("PIPELINE \(pipeline) ms; end-of-turn wait \(wait) ms")
            log("TOTAL without drafting ≈ \(wait + pipeline) ms, with drafting ≈ \(max(wait, 256 + pipeline)) ms (from end of speech to first audio)")
            exit(0)
        } catch {
            log("SELFTEST FAILED: \(error)")
            exit(1)
        }
    }
}

extension SelfTest {
    /// `SpeakToMe --ttsstress [count]`: hammers the voice helper and reports crashes/recoveries.
    static func stressTTS(count: Int) async {
        let custom = ProcessInfo.processInfo.environment["SPEAKTOME_SENTENCES"]?.components(separatedBy: "|")
        let sentences = custom ?? [
            "The tallest mountain in Europe is Mount Elbrus.",
            "It rises about five thousand six hundred metres above sea level.",
            "Sure, here's a quick idea for dinner tonight.",
            "Honestly, I think that's a great question!",
            "Black holes form when massive stars collapse under their own gravity.",
            "Let me think about that for a second.",
        ]
        let worker = TTSWorker(voice: "af_heart")
        do { try await worker.start() } catch { print("start failed: \(error)"); exit(1) }
        var times: [Int] = []
        var failures = 0
        for i in 0..<count {
            let t = Date()
            do {
                _ = try await worker.speak(sentences[i % sentences.count], voice: "af_heart", speed: 1.05)
                times.append(Int(Date().timeIntervalSince(t) * 1000))
            } catch {
                failures += 1
                print("sentence \(i) failed: \(error.localizedDescription) — \(sentences[i % sentences.count])")
            }
        }
        let sorted = times.sorted()
        print("sentences \(count), worker restarts \(await worker.restarts), failures \(failures)")
        if !sorted.isEmpty {
            print("ms per sentence: median \(sorted[sorted.count / 2]), p90 \(sorted[sorted.count * 9 / 10]), max \(sorted.last!)")
        }
        await worker.stop()
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --langtest [dir]`: per language, detection, then the macOS voice and
    /// Supertonic-3 side by side: synthesis time and what Parakeet hears back. With a
    /// folder, also writes each as a WAV to compare by ear.
    static func languages(writingTo dir: String?) async {
        let samples = [
            "Jaka jest najwyższa góra w Europie?",
            "Какая самая высокая гора в Европе? Это Эльбрус, высотой пять тысяч шестьсот сорок два метра.",
            "Яка найвища гора в Європі?",
            "Quelle est la plus haute montagne d'Europe ?",
            "Welcher ist der höchste Berg Europas?",
        ]
        let speech: SpeechModels
        do { speech = try await SpeechModels.load(voice: "af_heart") { print("  \($0)") } } catch {
            print("load failed: \(error)"); exit(1)
        }
        func check(_ name: String, _ lang: String, _ audio: [Float], ms: Int) async {
            let heard = (try? await speech.transcribe(Resampler.convert(audio, from: 24_000, to: 16_000))) ?? "?"
            print("  \(name): \(audio.count / 24) ms audio in \(ms) ms  →  \(heard)")
            if let dir {
                try? WAV.data(audio, sampleRate: 24_000)
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(lang)-\(name).wav"))
            }
        }
        for text in samples {
            let lang = LanguageDetector.detect(text) ?? "?"
            print("\(lang)  \(text)")
            var t = Date()
            let system = await SystemVoice.speak(text, language: lang, speed: 1)
            let voice = SystemVoice.bestVoice(for: lang)
            await check("macos-\(voice?.name ?? "none")", lang, system, ms: Int(Date().timeIntervalSince(t) * 1000))
            for name in ["F1", "M1"] {
                t = Date()
                let neural = (try? await speech.multilingual.speak(text, language: lang, voice: name, speed: 1.05)) ?? []
                await check("supertonic-\(name)", lang, neural, ms: Int(Date().timeIntervalSince(t) * 1000))
            }
        }
        await speech.tts.stop()
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --speechtest`: every model choice for every language group, switched on
    /// one running set of models, with what Parakeet hears back. With a folder, also
    /// writes each as a WAV to compare by ear.
    static func speechModels(writingTo dir: String?) async {
        let lines: [SpeechSlot: (language: String, text: String)] = [
            .english: ("en", "The tallest mountain in Europe is Mount Elbrus."),
            .russian: ("ru", "Самая высокая гора в Европе это Эльбрус."),
            .other: ("pl", "Najwyższą górą w Europie jest Elbrus."),
        ]
        let speech: SpeechModels
        do { speech = try await SpeechModels.load(voice: "af_heart") { print("  \($0)") } } catch {
            print("load failed: \(error)"); exit(1)
        }
        let myVoice = await VoiceSession.myVoiceFile.path
        let clonedVoice = FileManager.default.fileExists(atPath: myVoice) ? myVoice : nil
        var failures = 0
        for slot in SpeechSlot.allCases {
            guard let line = lines[slot] else { continue }
            for engine in slot.engines {
                let setup = SpeechSetup(engines: [slot: engine], clonedVoice: clonedVoice)
                do {
                    try await speech.prepare(engine, using: setup)
                    let t = Date()
                    let audio = try await speech.speak(line.text, language: line.language, using: setup)
                    let ms = Int(Date().timeIntervalSince(t) * 1000)
                    let heard = try await speech.transcribe(Resampler.convert(audio, from: 24_000, to: 16_000))
                    print("\(slot.title) → \(engine.name): \(audio.count / 24) ms audio in \(ms) ms  →  \(heard)")
                    if let dir {
                        try? WAV.data(audio, sampleRate: 24_000)
                            .write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(slot.rawValue)-\(engine.rawValue).wav"))
                    }
                } catch {
                    failures += 1
                    print("\(slot.title) → \(engine.name): FAILED \(error.localizedDescription)")
                }
            }
        }
        // A model that can't speak the language falls through to the next.
        let route = SpeechSetup(engines: [.other: .macOS]).route(for: "pl").map(\.name).joined(separator: " → ")
        print("route for Polish with macOS chosen: \(route)")
        // The choice survives a restart: written by one read, read back from storage.
        let saved = SpeechSlot.russian.stored
        SpeechSlot.russian.stored = .macOS
        print("stored choice round trip: \(SpeechSlot.russian.stored == .macOS ? "ok" : "FAILED")")
        SpeechSlot.russian.stored = saved
        await speech.tts.stop()
        exit(failures == 0 ? 0 : 1)
    }
}

extension SelfTest {
    /// `SpeakToMe --chattest`: drives the real conversation loop with typed messages
    /// (replies muted, so nothing plays) and prints the transcript, tool notes included.
    @MainActor
    static func chat() async {
        let session = VoiceSession.shared
        let defaults = UserDefaults.standard
        let savedMute = defaults.object(forKey: "muteReplies")
        session.muteReplies = true
        await session.boot()
        guard session.phase == .ready else { print("boot failed: \(session.phase)"); exit(1) }
        session.newConversation()
        for message in ["What time is it?", "What's the weather in London right now?", "Tell me a joke in one sentence.", "Jak się masz?"] {
            let t = Date()
            session.send(message)
            while session.phase != .ready { try? await Task.sleep(for: .milliseconds(50)) }
            print("[\(Int(Date().timeIntervalSince(t) * 1000)) ms] \(message)")
        }
        for line in session.lines {
            print("  \(line.role): \(line.text.prefix(160))\(line.note.map { "   [\($0)]" } ?? "")")
        }
        print("language now: \(session.language)")
        session.deleteConversationForTest()
        if let savedMute { defaults.set(savedMute, forKey: "muteReplies") } else { defaults.removeObject(forKey: "muteReplies") }
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --clonetest <dir>`: clones a voice from a Kokoro-made sample and
    /// writes the sample and the cloned speech to <dir> so you can listen.
    static func cloneVoice(to dir: String) async {
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let worker = TTSWorker(voice: "am_adam")
        do {
            try await worker.start()
            var sample: [Float] = []
            for line in ["Hi, this is a short recording of my voice for testing.",
                         "I like long walks, strong coffee, and quiet mornings by the sea.",
                         "Today I am going to read a few sentences so the computer can learn how I sound."] {
                sample += try await worker.speak(line, voice: "am_adam", speed: 1) + [Float](repeating: 0, count: 6_000)
            }
            let sampleURL = folder.appendingPathComponent("sample.wav")
            try WAV.data(sample, sampleRate: 24_000).write(to: sampleURL)
            print("sample: \(sample.count / 24) ms")

            var t = Date()
            let voiceURL = folder.appendingPathComponent("voice.bin")
            try await worker.clone(sample: sampleURL, to: voiceURL)
            print("cloned in \(Int(Date().timeIntervalSince(t) * 1000)) ms (includes first-time download)")

            var out: [Float] = []
            for text in ["The tallest mountain in Europe is Mount Elbrus.", "Sure, here's a quick idea for dinner.", "Let me look that up."] {
                t = Date()
                let audio = try await worker.speak(text, voice: "am_adam", speed: 1, clonedVoice: voiceURL.path)
                print("cloned voice: \(Int(Date().timeIntervalSince(t) * 1000)) ms for \(audio.count / 24) ms of audio")
                out += audio + [Float](repeating: 0, count: 6_000)
            }
            try WAV.data(out, sampleRate: 24_000).write(to: folder.appendingPathComponent("cloned.wav"))
        } catch {
            print("CLONE TEST FAILED: \(error.localizedDescription)")
        }
        await worker.stop()
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --f5switchtest`: through the real session, chooses F5-TTS Russian, times it
    /// while oMLX is busy writing a reply, then chooses another model and checks the memory
    /// comes back. Nothing plays.
    @MainActor
    static func f5Switching() async {
        func helpers() -> Int {
            let pgrep = Process(), pipe = Pipe()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", "\(ProcessInfo.processInfo.processIdentifier)", "-f", "f5-worker"]
            pgrep.standardOutput = pipe
            try? pgrep.run()
            pgrep.waitUntilExit()
            return pipe.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A).count
        }
        let session = VoiceSession.shared
        await session.boot()
        guard let speech = session.speechForTest else { print("boot failed: \(session.phase)"); exit(1) }
        let chosenBefore = session.speechEngines[.russian] ?? .supertonic

        session.setEngine(.f5Russian, for: .russian)
        var t = Date()
        while true {
            switch session.state(of: .f5Russian) {
            case .ready: break
            case .failed(let message): print("FAILED: \(message)"); exit(1)
            default:
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            break
        }
        print("chosen, ready in \(Int(Date().timeIntervalSince(t) * 1000)) ms, helpers running: \(helpers())")

        let setup = SpeechSetup(engines: [.russian: .f5Russian])
        if let stress = RussianStress(folder: F5RussianVoice.folder) {
            print(stress.marked("Москва, ещё и всё ЕЩЕ: на двери висит замок, город Ростов-на-Дону и 1 слово-хамелеон."))
        }
        let lines = [
            "Привет, рада тебя слышать.",
            "Москва является столицей России, и в ней живёт больше двенадцати миллионов человек.",
            "В 2024 году я прошла 42 километра.",
        ]
        func say(_ label: String) async {
            for line in lines {
                t = Date()
                let audio = (try? await speech.speak(line, language: "ru", using: setup)) ?? []
                let ms = Int(Date().timeIntervalSince(t) * 1000)
                let heard = (try? await speech.transcribe(Resampler.convert(audio, from: 24_000, to: 16_000))) ?? "?"
                print("\(label): \(audio.count / 24) ms audio in \(ms) ms  →  \(heard)")
            }
        }
        await say("idle")
        let client = OMLXClient.fromSettings(), model = session.modelID
        let busy = Task {
            let prompt = "Расскажи подробно историю Москвы, не меньше трёхсот слов."
            for try await _ in client.streamChat(model: model, messages: [.init(role: "user", content: prompt)]) {}
        }
        await say("while oMLX writes")
        busy.cancel()

        // A crash costs a reload, not the conversation.
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-9", "-P", "\(ProcessInfo.processInfo.processIdentifier)", "-f", "f5-worker"]
        try? pkill.run()
        pkill.waitUntilExit()
        try? await Task.sleep(for: .milliseconds(300))
        print("killed, helpers running: \(helpers())")
        t = Date()
        let recovered = (try? await speech.speak(lines[0], language: "ru", using: setup)) ?? []
        print("after the crash: \(recovered.count / 24) ms audio in \(Int(Date().timeIntervalSince(t) * 1000)) ms, helpers running: \(helpers())")

        session.setEngine(chosenBefore == .f5Russian ? .supertonic : chosenBefore, for: .russian)
        try? await Task.sleep(for: .seconds(1))
        print("switched away, helpers running: \(helpers())")
        session.setEngine(chosenBefore, for: .russian)
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --f5test <modelDir> <referenceWav> <referenceText> <outDir>`: the F5-TTS port
    /// alone, with a fixed seed so its output can be compared to another implementation's.
    static func f5(modelDir: String, reference: String, referenceText: String, out: String) {
        do {
            let folder = URL(fileURLWithPath: modelDir)
            var t = Date()
            let model = try F5TTS(
                checkpoint: folder.appendingPathComponent("model_v1.safetensors"),
                vocabulary: folder.appendingPathComponent("vocab.txt"),
                vocoder: folder.appendingPathComponent("vocos.safetensors"))
            let samples = WAV.samples(try Data(contentsOf: URL(fileURLWithPath: reference)))
            let voice = model.reference(samples: samples, text: referenceText)
            print("loaded in \(Int(Date().timeIntervalSince(t) * 1000)) ms, reference \(voice.mel.shape)")
            let lines = [
                ("plain", "Москва является столицей России, и в ней живёт больше двенадцати миллионов человек."),
                ("short", "Да, конечно."),
                ("mid", "Самая известная достопримечательность города, это Красная площадь."),
                ("hard", "Вчера мы с друзьями ездили за город, жарили шашлыки и слушали музыку."),
                ("tech", "Искусственный интеллект быстро развивается, но ему всё ещё нужны хорошие данные."),
            ]
            _ = try model.speak("Да.", reference: voice, seed: 42)
            for (name, text) in lines {
                t = Date()
                let audio = try model.speak(text, reference: voice, seed: 42)
                print("\(name): \(audio.count / 24) ms audio in \(Int(Date().timeIntervalSince(t) * 1000)) ms")
                try WAV.data(audio, sampleRate: F5TTS.sampleRate)
                    .write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).wav"))
                if let stress = RussianStress(folder: folder) {
                    let marked = model.reference(samples: samples, text: F5RussianVoice.markedReferenceText)
                    let spoken = stress.marked(text)
                    print("  \(spoken)")
                    try WAV.data(try model.speak(spoken, reference: marked, seed: 42), sampleRate: F5TTS.sampleRate)
                        .write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name)-stress.wav"))
                }
            }
            exit(0)
        } catch {
            print("F5 TEST FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
