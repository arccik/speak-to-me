# Speak to Me

A native macOS app for talking to your local AI with your voice. You speak, it answers out loud, and you can interrupt it mid-sentence just by talking. Everything runs on this Mac.

## How it works

```
mic ─▶ echo cancel ─▶ Silero VAD ─▶ Parakeet v3 ─▶ oMLX (your LLM, streaming, tools) ─▶ sentence splitter ─▶ Kokoro ─▶ speaker
        (Apple)        (Neural Engine)  (Neural Engine)       (GPU)                                       (helper process)
```

| Stage | Tech | Why |
|---|---|---|
| Audio in/out | `AVAudioEngine` with voice processing | Apple's echo canceller removes the assistant's own voice from the mic, so you can interrupt without headphones |
| Turn detection | Silero VAD (Core ML, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) | Knows when you start talking (barge-in) and when you've finished |
| Speech → text | Parakeet TDT 0.6B v3 (Core ML) | ~50 ms per utterance on the Neural Engine, 25 languages, leaves the GPU to the LLM |
| Thinking | Any chat model in **oMLX** (`/v1/chat/completions`, streamed) | Uses the models you already have; thinking mode is switched off for speed |
| Text → speech | Kokoro 82M (FluidAudio ANE v3) in a helper process | ~130 ms per sentence; isolated because Core ML crashes on some inputs on macOS 27 |

### Latency tricks

- **Drafting:** after 256 ms of silence the app already transcribes, asks the model and synthesizes the reply, but holds the audio. If you keep quiet for the full end-of-turn wait it plays at once; if you speak again the draft is thrown away. Saves ~0.5 s per reply.
- **Sentence streaming:** the reply is spoken sentence by sentence as the model writes it; the first sentence is cut at a comma.
- **Live transcript:** your words appear while you talk (Parakeet re-runs every ~0.5 s).

Measured on an M5 with `gemma-4-26b-a4b-it-4bit`: about 1.2 s from the end of your speech to the first spoken word, including the 0.77 s silence wait. Dense models are much slower (`gemma-4-12B`: ~3.3 s).

### F5-TTS Russian

Everything else speaks through Core ML; [F5-TTS Russian](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN) (CC-BY-NC-4.0, so non-commercial) has no Core ML build, so it runs on MLX, on the GPU, in its own helper process (`--f5-worker`). Choosing it downloads about 1.4 GB. It imitates a short clip made with the chosen Supertonic-3 voice, numbers are spelled out first because it reads digits badly, and word stress is marked from [RUAccent](https://github.com/Den4ikAI/ruaccent)'s dictionary (MIT; its neural models aren't used, so homographs and unknown words stay unmarked). The helper (about 3 GB at its peak) exits as soon as another model is chosen. If it's still downloading or it fails, the next model says the sentence.

`swift build` can't compile MLX's Metal shaders, so `scripts/build-mlx-shaders.sh` does (once, about 15 minutes, 193 MB), and `build-app.sh` puts them next to the executable. That needs Xcode's Metal Toolchain and F5-TTS needs macOS 26.2 or later:

```bash
xcodebuild -downloadComponent MetalToolchain
```

To run a debug build with F5-TTS, copy `.build/mlx.metallib` next to the binary.

### Why a helper process for the voice

Kokoro crashes inside Apple's Core ML CPU backend (libBNNS) for certain inputs on macOS 27 (a fixed phoneme-token count). The crash can't be caught, so the voice runs in a child process (`SpeakToMe --tts-worker`). If it dies, a pre-loaded standby takes over and the sentence is retried with one punctuation token more or less, which sounds the same. Recovery costs ~0.3 s instead of crashing the app.

## Features

- **Talk or type.** The message box works with or without the mic; the speaker button mutes spoken replies.
- **⌥Space from any app** toggles listening and shows a **floating orb** (drag it anywhere, right-click for options). There's also a menu bar icon.
- **Conversations are saved** automatically and the last one reopens on launch; the clock button lists past chats.
- **Answers in your language.** The language you speak is detected, and Settings → Voice → Speech models picks the model for English, Russian and other languages: Kokoro or your voice for English, Supertonic-3 or a macOS system voice for the rest, plus F5-TTS Russian for Russian (install better ones in System Settings → Accessibility → Spoken Content → Manage Voices).
- **Sees your screen** when you ask "what's on my screen?" or turn on the eye button (needs a vision model like gemma-4 and Screen Recording permission).
- **Tools:** web search and page reading (oMLX's built-in DuckDuckGo search), the current time, opening apps and web pages. Draft replies never open anything until they're final.
- **Your own voice:** record 12 s in Settings (or pick a file) and choose "My voice" for English to use a PocketTTS clone of it.
- **Keep model loaded** (off by default): pins the model in oMLX so it's never unloaded. On a 24 GB Mac a pinned model can leave no room for another, so only turn it on if this is the only model you use.
- Soft sound cues when the mic turns on and off.

## Requirements

- Apple Silicon Mac, macOS 15+, Xcode (for `swift`)
- [oMLX](https://github.com/jundot/omlx) running. The app reads host, port and API key from `~/.omlx/settings.json`, so no keys are stored in this repo.

## Build and run

```bash
scripts/build-app.sh
```

```bash
open build/SpeakToMe.app
```

`scripts/build-app.sh --install` also copies it to `/Applications`. The script signs with your Apple Development certificate when you have one, so macOS remembers the microphone permission across rebuilds.

On first launch FluidAudio downloads Parakeet v3, Silero VAD and Kokoro (about 1 GB, compiled once) into `~/Library/Application Support/SpeakToMe/Models`. Cloning your voice downloads PocketTTS the first time. FluidVoice's Core ML copies can't be reused: they're an older build that current FluidAudio rejects.

## Using it

- **Space** (when not typing), the mic button or the orb starts/stops listening. **⌥Space** works from any app.
- It replies after your pause (Settings → Turn-taking). Talk over it to interrupt.
- **⌘N** starts a new conversation.
- Pick the model at the top. Mixture-of-experts models (`gemma-4-26b-a4b`) reply fastest; dense 12B+ models feel slow in conversation.
- The ⚡ number is the time from when you stopped talking to the first word of the reply.

## Tests and diagnostics

```bash
build/SpeakToMe.app/Contents/MacOS/SpeakToMe --selftest [model]
```
Whole voice pipeline without a mic (Kokoro speaks a question → Parakeet → oMLX → Kokoro), with per-stage timings.

```bash
build/SpeakToMe.app/Contents/MacOS/SpeakToMe --chattest
```
Drives the real conversation loop with typed messages (time, web search, a joke, Polish), replies muted.

| Flag | What it does |
|---|---|
| `--ttsstress [n]` | Synthesizes n sentences through the voice helper and reports crashes/recoveries (`SPEAKTOME_KOKORO=v3gpu\|legacy` to compare routes, `SPEAKTOME_SENTENCES="a\|b"` for custom text) |
| `--langtest` | Language detection and macOS voice per language |
| `--speechtest [dir]` | Every speech model choice per language group on one running instance, with what Parakeet hears back; writes WAVs to `dir` |
| `--f5test <modelDir> <ref.wav> <refText> <dir>` | F5-TTS alone with a fixed seed, to compare with another implementation; writes WAVs to `dir` |
| `--f5switchtest` | Through the real session: choose F5-TTS Russian, time it idle and while oMLX writes, kill its helper, switch away and check the helper is gone |
| `--clonetest <dir>` | Clones a voice from a Kokoro-made sample; writes `sample.wav` and `cloned.wav` |
| `--snapshot <dir>` | Renders the window in several states to PNGs |
| `--micdiag` (via `open … --args`) | Checks mic permission and that the audio engine starts |

## Code map

- `VoiceSession.swift`: the conversation loop: turn-taking, drafts, barge-in, tools, languages, saved chats, your voice
- `AudioIO.swift`: mic (16 kHz) and playback (24 kHz) on one engine with echo cancellation; live levels
- `SpeechEngines.swift`: the speech models you can choose, per language group, and their fallbacks
- `SpeechModels.swift`: loads VAD and Parakeet; speaks with the chosen model
- `F5TTS.swift`: F5-TTS and its Vocos vocoder, ported to MLX Swift (inference only)
- `RussianStress.swift`: stress marks from RUAccent's dictionary, searched on disk
- `F5Voice.swift`: F5-TTS Russian's download, reference clip and helper process
- `TTSWorker.swift`: the crash-isolated voice helper process (Kokoro + PocketTTS) with a hot standby
- `OMLXClient.swift`: model list, streaming chat with images and tool calls, model pinning
- `Tools.swift`: web search, page reading, time, opening apps and pages
- `ScreenVision.swift`, `Languages.swift`, `SoundCues.swift`, `HotKey.swift`, `MiniOrb.swift`, `ConversationStore.swift`
- `Visuals.swift` (mist orb, glow waves), `ContentView.swift` (window, chat, settings)
- `SentenceChunker.swift`: splits the streamed reply into speakable pieces and strips markdown
- `SelfTest.swift`, `Snapshots.swift`, `MicDiagnostics.swift`: the test modes above
