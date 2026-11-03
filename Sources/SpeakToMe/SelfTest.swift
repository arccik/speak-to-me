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
    /// `SpeakToMe --f5clonetest <sample> <dir>`: an audio file through the same steps as adding
    /// a voice in Settings, then F5-TTS speaking in it and in the built-in voice, with what
    /// Parakeet hears from each. Writes WAVs to <dir> and stores nothing in the library.
    static func f5Clone(sample: String, to dir: String) async {
        do {
            let speech = try await SpeechModels.load(voice: "af_heart") { _ in }
            let plain = SpeechSetup()
            try await speech.prepare(.f5Russian, using: plain)
            let clip = try F5VoiceLibrary.clip(from: URL(fileURLWithPath: sample))
            let transcript = try await speech.transcribe(Resampler.convert(clip, from: Double(F5TTS.sampleRate), to: 16_000))
            print("clip \(clip.count / 24) ms: \(transcript)")
            let folder = URL(fileURLWithPath: dir)
            let voice = F5ClonedVoice(id: "selftest-\(UUID().uuidString)", name: "test", transcript: transcript)
            try FileManager.default.createDirectory(at: F5VoiceLibrary.folder, withIntermediateDirectories: true)
            try WAV.data(clip, sampleRate: F5TTS.sampleRate).write(to: voice.clip)
            try WAV.data(clip, sampleRate: F5TTS.sampleRate).write(to: folder.appendingPathComponent("clip.wav"))
            let text = "Москва является столицей России, и на двери висит большой замок."
            for (name, setup) in [
                ("cloned", SpeechSetup(engines: [.russian: .f5Russian], f5Voice: voice, f5Pronunciations: ["замок": "зам+ок"])),
                ("builtin", SpeechSetup(engines: [.russian: .f5Russian])),
            ] {
                let t = Date()
                let audio = try await speech.speak(text, language: "ru", using: setup)
                let ms = Int(Date().timeIntervalSince(t) * 1000)
                let heard = try await speech.transcribe(Resampler.convert(audio, from: 24_000, to: 16_000))
                print("\(name): \(audio.count / 24) ms audio in \(ms) ms  →  \(heard)")
                try WAV.data(audio, sampleRate: 24_000).write(to: folder.appendingPathComponent("\(name).wav"))
            }
            if let stress = RussianStress(folder: F5RussianVoice.folder) {
                print(stress.marked(text, overrides: ["замок": "зам+ок"]))
            }
            try? FileManager.default.removeItem(at: voice.clip)
            await speech.f5Russian.stop()
            await speech.tts.stop()
            exit(0)
        } catch {
            print("F5 CLONE TEST FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}

extension SelfTest {
    /// `SpeakToMe --replytest <model> [engine]`: where the wait goes in a Russian spoken reply,
    /// with the language model and the voice running at the same time, as they do in a real
    /// conversation. Prints when each piece would be ready and any silence between them.
    static func replyTiming(model: String, engine: SpeechEngine) async {
        let speech: SpeechModels
        do { speech = try await SpeechModels.load(voice: "af_heart") { _ in } } catch {
            print("load failed: \(error)"); exit(1)
        }
        let setup = SpeechSetup(engines: [.russian: engine], speed: 1.15)
        try? await speech.prepare(engine, using: setup)
        let client = OMLXClient.fromSettings()
        try? await client.warmUp(model: model)
        let system = await VoiceSession.defaultPrompt + " Always reply in the same language the user speaks to you in."
        for question in ["Какая самая высокая гора в Европе?", "Расскажи коротко, почему небо голубое.", "Как дела? Что посоветуешь приготовить на ужин?"] {
            print("Q: \(question)")
            let spoken = (try? await speech.multilingual.speak(question, language: "ru", voice: "F1", speed: 1)) ?? []
            let start = Date()
            func now() -> Int { Int(Date().timeIntervalSince(start) * 1000) }
            let heard = (try? await speech.transcribe(Resampler.convert(spoken, from: 24_000, to: 16_000))) ?? question
            print("  transcribed at \(now()) ms")
            let (sentences, sink) = AsyncStream<String>.makeStream()
            let voice = Task {
                var playingUntil: Int?
                for await sentence in sentences {
                    let began = now()
                    let audio = (try? await speech.speak(sentence, language: "ru", using: setup)) ?? []
                    let ready = now(), length = audio.count / 24
                    let gap = playingUntil.map { max(0, ready - $0) }
                    if playingUntil == nil { print("  FIRST AUDIO at \(ready) ms") }
                    print("  voice \(ready - began) ms for \(length) ms of audio, silence before it \(gap ?? 0) ms: \(sentence.prefix(50))")
                    playingUntil = max(playingUntil ?? 0, ready) + length
                }
            }
            var chunker = SentenceChunker()
            var first = true, tokens = 0
            do {
                for try await event in client.streamChat(
                    model: model, messages: [.init(role: "system", content: system), .init(role: "user", content: heard)],
                    tools: Tools.definitions) {
                    guard case .text(let token) = event else { continue }
                    if first { print("  first word from the model at \(now()) ms"); first = false }
                    tokens += 1
                    for sentence in chunker.push(token) {
                        print("  sentence ready at \(now()) ms")
                        sink.yield(sentence)
                    }
                }
            } catch { print("  model failed: \(error.localizedDescription)") }
            for sentence in chunker.finish() { sink.yield(sentence) }
            print("  model finished at \(now()) ms, \(tokens) tokens")
            sink.finish()
            await voice.value
        }
        await speech.f5Russian.stop()
        await speech.tts.stop()
        exit(0)
    }
}

extension SelfTest {
    /// `SpeakToMe --speechtest`: every model choice for every language group, switched on
    /// one running set of models, with what Parakeet hears back. With a folder, also
    /// writes each as a WAV to compare by ear.
    /// `SpeakToMe --cliptest`: what could click or lag in each sentence of a Russian reply:
    /// how hard each clip starts and ends, and how long it takes to make. Plays nothing.
    static func clips() async {
        let speech: SpeechModels
        do { speech = try await SpeechModels.load(voice: "af_heart") { _ in } } catch {
            print("load failed: \(error)"); exit(1)
        }
        let sentences = ["Привет, рада тебя слышать.", "Самая высокая гора в Европе это Эльбрус.",
                         "Твой сигнал пробился сквозь туман, капитан.", "Да.", "Что тебе рассказать дальше?"]
        for engine in [SpeechEngine.f5Russian, .supertonic] {
            let setup = SpeechSetup(engines: [.russian: engine])
            do { try await speech.prepare(engine, using: setup) } catch { print("skip \(engine.rawValue): \(error)"); continue }
            for sentence in sentences {
                let start = Date()
                guard let audio = try? await speech.speak(sentence, language: "ru", using: setup), audio.count > 500 else { continue }
                let took = Date().timeIntervalSince(start)
                let seconds = Double(audio.count) / 24_000
                let mean = audio.reduce(0, +) / Float(audio.count)
                var jump: Float = 0
                for i in 1..<audio.count { jump = max(jump, abs(audio[i] - audio[i - 1])) }
                // A click: one sample-to-sample step far bigger than the steps around it.
                var clicks: [Double] = []
                var i = 120
                while i < audio.count - 120 {
                    let step = abs(audio[i] - audio[i - 1])
                    if step > 0.05 {
                        var sum: Float = 0
                        for j in (i - 120)..<(i + 120) where abs(j - i) > 3 { sum += abs(audio[j] - audio[j - 1]) }
                        if step > 8 * sum / 233 { clicks.append(Double(i) / 24_000); i += 240 }
                    }
                    i += 1
                }
                if let dir = ProcessInfo.processInfo.environment["CLIP_DIR"] {
                    try? WAV.data(audio, sampleRate: 24_000).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(engine.rawValue)-\(sentence.prefix(6)).wav"))
                }
                print("CLICKS \(engine.rawValue) \(clicks.count) at \(clicks.map { String(format: "%.3f", $0) }.joined(separator: " "))")
                print(String(format: "CLIP %@ made %.2fs for %.2fs of audio | first %.4f last %.4f | tail peak %.3f | biggest jump %.3f | peak %.3f | dc %.4f | %@",
                             engine.rawValue, took, seconds, abs(audio[0]), abs(audio[audio.count - 1]),
                             audio.suffix(240).map(abs).max() ?? 0, jump, audio.map(abs).max() ?? 0, mean, sentence))
            }
        }
        await audioSwitch()
        recordCost()
        exit(0)
    }

    /// How long the audio engine is gone when echo cancellation switches on and off.
    private static func audioSwitch() async {
        let audio = AudioIO()
        var begin = Date()
        let started = await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            DispatchQueue.main.async { audio.start(echoCancellation: true) { done.resume(returning: $0) } }
        }
        print(String(format: "SWITCH mic start took %.0f ms, error: %@, echo cancellation on: %@", Date().timeIntervalSince(begin) * 1000,
                     String(describing: started), audio.echoCancellationActive ? "yes" : "no"))
        // Back and forth, the way a conversation goes: nothing should need rebuilding.
        for round in 1...3 {
            begin = Date()
            await MainActor.run { audio.prepareEchoCancellation() }
            print(String(format: "SWITCH turn %d into a reply: %.0f ms, on: %@", round, Date().timeIntervalSince(begin) * 1000, audio.echoCancellationActive ? "yes" : "no"))
            await MainActor.run { audio.relaxEchoCancellation() }
            try? await Task.sleep(for: .seconds(4))
            print("SWITCH turn \(round) 4s after the reply, still on: \(audio.echoCancellationActive ? "yes" : "no")")
        }
        begin = Date()
        await MainActor.run { audio.relaxEchoCancellation(after: 0) }
        for _ in 0..<500 where audio.echoCancellationActive { try? await Task.sleep(for: .milliseconds(10)) }
        print(String(format: "SWITCH long quiet spell: let go after %.0f ms", Date().timeIntervalSince(begin) * 1000))
        await MainActor.run { audio.stop() }
    }

    /// What one frame of the face costs the GPU in the main window, mid-conversation.
    private static func recordCost() {
        guard let renderer = FaceRenderer.shared else { return }
        let engine = FaceEngine()
        let levels = AudioLevels()
        levels.speaker = 0.7
        var now = 0.0
        engine.step(phase: .ready, muted: false, levels: levels, now: now)
        for _ in 0..<1200 { now += 1.0 / 30; engine.step(phase: .speaking, muted: false, levels: levels, now: now) }
        let begin = Date()
        for _ in 0..<60 {
            _ = renderer.image(of: engine, layout: FaceLayout(style: .stage, hush: 270),
                               points: CGSize(width: 520, height: 800), scale: 2)
        }
        print(String(format: "FACE %.1f ms a frame at 520x800 @2x, offscreen, including reading it back", Date().timeIntervalSince(begin) * 1000 / 60))
    }

    /// `SpeakToMe --lipsynctest <audio file>`: runs real speech through the lips, as the speaker
    /// tap would, and reports how much of each mouth shape it gets. Plays nothing.
    static func lipSync(file path: String) {
        guard let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
              (try? audio.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0]
        else { print("LIPS can't read \(path)"); exit(1) }
        let rate = Float(audio.processingFormat.sampleRate)
        let chunk = Int(rate * 1024 / 48_000)
        let bands = VoiceBands(), levels = AudioLevels(), engine = FaceEngine()
        var now = 0.0, frames = 0, shut = 0, open = 0, round = 0, wide = 0, hiss = 0, changes = 0, lastShape = 0
        engine.step(phase: .ready, muted: false, levels: levels, now: now)
        for start in stride(from: 0, to: Int(buffer.frameLength) - chunk, by: chunk) {
            let samples = UnsafeBufferPointer(start: data + start, count: chunk)
            levels.speaker = AudioLevels.rms(samples)
            levels.speakerBands = bands.analyze(samples, sampleRate: rate)
            now += Double(chunk) / Double(rate)
            engine.step(phase: .speaking, muted: false, levels: levels, now: now)
            frames += 1
            if engine.jaw < 0.08 { shut += 1 }
            if engine.jaw > 0.35 { open += 1 }
            if engine.wide < -0.3 { round += 1 }
            if engine.wide > 0.3 { wide += 1 }
            if engine.teeth > 0.5 { hiss += 1 }
            let shape = engine.jaw < 0.08 ? 0 : engine.teeth > 0.5 ? 1 : engine.wide < -0.3 ? 2 : engine.wide > 0.3 ? 3 : 4
            if shape != lastShape { changes += 1; lastShape = shape }
        }
        func pct(_ n: Int) -> Int { n * 100 / max(frames, 1) }
        print("LIPS \(frames) frames, shut \(pct(shut))%, open \(pct(open))%, round \(pct(round))%, wide \(pct(wide))%, hiss \(pct(hiss))%, \(String(format: "%.1f", Double(changes) / now)) shape changes a second")
        recordCost()

        // Left alone, it dozes off by the time drawing stops.
        let sleeper = FaceEngine()
        let quiet = AudioLevels()
        var clock = 0.0
        sleeper.step(phase: .ready, muted: false, levels: quiet, now: clock)
        for _ in 0..<Int(FaceEngine.asleepAfter * 30) { clock += 1.0 / 30; sleeper.step(phase: .ready, muted: false, levels: quiet, now: clock) }
        print(String(format: "DOZE eyes open %.2f after %.0f s with nothing going on", sleeper.eye, FaceEngine.asleepAfter))
    }

    /// `SpeakToMe --ssmltest`: SSML in a reply never reaches the screen or the words spoken,
    /// and its pauses and rate change the audio, on every engine. Plays nothing.
    /// With a model name it only asks that model, with and without Expressive voice's prompt.
    static func ssml(model: String? = nil) async {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: Any = "") {
            print("\(ok ? "ok  " : "FAIL") \(name) \(detail)")
            if !ok { failures += 1 }
        }
        if let model {
            let client = OMLXClient.fromSettings()
            let questions = ["What is the tallest mountain in Europe?",
                             "Tell me a very short spooky story, in a mysterious voice.",
                             "Расскажи очень короткую страшную историю загадочным голосом."]
            let prompts = await [("off", VoiceSession.defaultPrompt), ("on", VoiceSession.defaultPrompt + VoiceSession.expressivePrompt)]
            for (name, prompt) in prompts {
                for question in questions {
                    var reply = ""
                    do {
                        let messages: [OMLXClient.Message] = [.init(role: "system", content: prompt), .init(role: "user", content: question)]
                        for try await event in client.streamChat(model: model, messages: messages, tools: []) {
                            if case .text(let token) = event { reply += token }
                        }
                    } catch { print("FAIL \(error)"); exit(1) }
                    print("--- expressive \(name): \(question)\nraw: \(reply)\nshown: \(SentenceChunker.visible(reply))\nsegments: \(SSML.segments(of: reply).count), markup: \(SSML.hasMarkup(reply))")
                }
            }
            exit(0)
        }
        let reply = """
            <speak>
              <prosody rate="slow" pitch="-2st">
                <break time="1s"/>
                Yes... I can hear you perfectly now.
                <break time="500ms"/>
                The shadows are finally starting to make sense.
              </prosody>
            </speak>
            """
        let shown = SentenceChunker.visible(reply)
        check("shown without tags", shown == "Yes... I can hear you perfectly now. The shadows are finally starting to make sense.", shown)
        check("half-arrived tag hidden", SentenceChunker.visible("Hello there <pros") == "Hello there", SentenceChunker.visible("Hello there <pros"))
        check("ordinary < survives", SentenceChunker.visible("Is 2 < 3? Yes.") == "Is 2 < 3? Yes.", SentenceChunker.visible("Is 2 < 3? Yes."))
        check("plain text untouched", !SSML.hasMarkup("Hello, how are you?"))

        // Token by token, the way a model streams it.
        var chunker = SentenceChunker()
        var pieces: [String] = []
        var rest = Substring(reply)
        while !rest.isEmpty {
            pieces += chunker.push(String(rest.prefix(3)))
            rest = rest.dropFirst(3)
        }
        pieces += chunker.finish()
        print("     pieces: \(pieces)")
        let segments = pieces.flatMap(SSML.segments(of:))
        print("     segments: \(segments)")
        let spokenWords = segments.compactMap { segment -> (String, Float)? in
            if case .words(let w, let r) = segment { return (w, r) }
            return nil
        }
        let pauses = segments.compactMap { segment -> Float? in
            if case .pause(let p) = segment { return p }
            return nil
        }
        check("both sentences kept their prosody across the cut",
              spokenWords.count == 2 && spokenWords.allSatisfy { $0.1 == 0.8 })
        check("both pauses found", pauses == [1, 0.5], pauses)
        check("no tag in the words", !spokenWords.contains { $0.0.contains("<") || $0.0.contains("prosody") })

        // As a real model wrote it: nothing closed, and a break that's half a closing tag.
        var unclosedChunker = SentenceChunker()
        let unclosed = #"<prosody rate="slow" pitch="-2st">The first sentence is here.</break time="500ms"/><prosody rate="slow" pitch="-2st">The second sentence is here. <prosody pitch="-3st">The third sentence is here."#
        let unclosedPieces = unclosedChunker.push(unclosed) + unclosedChunker.finish()
        let unclosedRates = unclosedPieces.flatMap(SSML.segments(of:)).compactMap { segment -> Float? in
            if case .words(_, let r) = segment { return r }
            return nil
        }
        check("unclosed tags don't pile up", !unclosedRates.isEmpty && unclosedRates.allSatisfy { $0 == 0.8 }, unclosedRates)

        let speech: SpeechModels
        do { speech = try await SpeechModels.load(voice: "af_heart") { _ in } } catch {
            print("load failed: \(error)"); exit(1)
        }
        let lines: [SpeechSlot: (language: String, text: String)] = [
            .english: ("en", "The shadows are finally starting to make sense."),
            .russian: ("ru", "Твой сигнал пробился сквозь туман, капитан."),
            .other: ("pl", "Najwyższą górą w Europie jest Elbrus."),
        ]
        for slot in SpeechSlot.allCases {
            guard let line = lines[slot] else { continue }
            for engine in slot.engines where engine != .myVoice {
                let setup = SpeechSetup(engines: [slot: engine])
                do {
                    try await speech.prepare(engine, using: setup)
                    let plain = try await speech.speak(line.text, language: line.language, using: setup)
                    let marked = "<speak><break time=\"1s\"/><prosody pitch=\"-2st\">\(line.text)</prosody></speak>"
                    let audio = try await speech.speak(marked, language: line.language, using: setup)
                    let lead = audio.prefix(24_000).allSatisfy { $0 == 0 }
                    var off = setup
                    off.expressive = false
                    let dropped = try await speech.speak(marked, language: line.language, using: off)
                    check("\(slot) \(engine.rawValue) off: no pause added", !dropped.prefix(24_000).allSatisfy { $0 == 0 })
                    let heard = try await speech.transcribe(Resampler.convert(audio, from: 24_000, to: 16_000))
                    let leaked = ["prosody", "speak", "pitch", "break time"].contains { heard.lowercased().contains($0) } && !line.text.lowercased().contains("speak")
                    let seconds = { (samples: [Float]) in String(format: "%.2fs", Double(samples.count) / 24_000) }
                    check("\(slot) \(engine.rawValue)", lead && !leaked, "plain \(seconds(plain)), marked \(seconds(audio)) (with 1s pause), heard: \(heard)")
                } catch {
                    print("skip \(slot) \(engine.rawValue): \(error)")
                }
            }
        }
        print(failures == 0 ? "SSML PASS" : "SSML FAIL \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

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
