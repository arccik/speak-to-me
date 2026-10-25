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

### Why a helper process for the voice

Kokoro crashes inside Apple's Core ML CPU backend (libBNNS) for certain inputs on macOS 27 (a fixed phoneme-token count). The crash can't be caught, so the voice runs in a child process (`SpeakToMe --tts-worker`). If it dies, a pre-loaded standby takes over and the sentence is retried with one punctuation token more or less, which sounds the same. Recovery costs ~0.3 s instead of crashing the app.

## Features

- **Talk or type.** The message box works with or without the mic; the speaker button mutes spoken replies.
- **⌥Space from any app** toggles listening and shows a **floating orb** (drag it anywhere, right-click for options). There's also a menu bar icon.
- **Conversations are saved** automatically and the last one reopens on launch; the clock button lists past chats.
- **Answers in your language.** The language you speak is detected; English uses Kokoro, other languages use macOS system voices (install better ones in System Settings → Accessibility → Spoken Content → Manage Voices).
- **Sees your screen** when you ask "what's on my screen?" or turn on the eye button (needs a vision model like gemma-4 and Screen Recording permission).
- **Tools:** web search and page reading (oMLX's built-in DuckDuckGo search), the current time, opening apps and web pages. Draft replies never open anything until they're final.
- **Your own voice:** record 12 s in Settings (or pick a file) and English replies use a PocketTTS clone of it.
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
| `--clonetest <dir>` | Clones a voice from a Kokoro-made sample; writes `sample.wav` and `cloned.wav` |
| `--snapshot <dir>` | Renders the window in several states to PNGs |
| `--micdiag` (via `open … --args`) | Checks mic permission and that the audio engine starts |

## Code map

- `VoiceSession.swift`: the conversation loop: turn-taking, drafts, barge-in, tools, languages, saved chats, your voice
- `AudioIO.swift`: mic (16 kHz) and playback (24 kHz) on one engine with echo cancellation; live levels
- `SpeechModels.swift`: loads VAD and Parakeet; routes speech to Kokoro, your voice or macOS voices
- `TTSWorker.swift`: the crash-isolated voice helper process (Kokoro + PocketTTS) with a hot standby
- `OMLXClient.swift`: model list, streaming chat with images and tool calls, model pinning
- `Tools.swift`: web search, page reading, time, opening apps and pages
- `ScreenVision.swift`, `Languages.swift`, `SoundCues.swift`, `HotKey.swift`, `MiniOrb.swift`, `ConversationStore.swift`
- `Visuals.swift` (mist orb, glow waves), `ContentView.swift` (window, chat, settings)
- `SentenceChunker.swift`: splits the streamed reply into speakable pieces and strips markdown
- `SelfTest.swift`, `Snapshots.swift`, `MicDiagnostics.swift`: the test modes above
