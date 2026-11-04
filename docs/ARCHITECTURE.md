# Architecture

```
mic ─▶ echo cancel ─▶ Silero VAD ─▶ Parakeet v3 ─▶ oMLX (your LLM, streaming, tools) ─▶ sentence splitter ─▶ speech model ─▶ speaker
        (Apple)        (Neural Engine)  (Neural Engine)       (GPU)                                        (helper process)
```

| Stage | Tech | Why |
|---|---|---|
| Audio in/out | `AVAudioEngine` with voice processing | Apple's echo canceller removes the assistant's own voice from the mic, so you can interrupt without headphones |
| Turn detection | Silero VAD (Core ML, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) | Knows when you start talking (barge-in) and when you've finished |
| Speech → text | Parakeet TDT 0.6B v3 (Core ML) | ~50 ms per utterance on the Neural Engine, 25 languages, leaves the GPU to the LLM |
| Thinking | Any chat model in **oMLX** (`/v1/chat/completions`, streamed) | Uses the models you already have; thinking mode is switched off for speed |
| Text → speech | Your choice per language group, see `SpeechEngines.swift` | Kokoro takes ~130 ms per sentence, in a helper process |

## Latency tricks

- **Drafting:** after 256 ms of silence the app already transcribes, asks the model and synthesizes the reply, but holds the audio. If you keep quiet for the full end-of-turn wait it plays at once; if you speak again the draft is thrown away. Saves ~0.5 s per reply.
- **Sentence streaming:** the reply is spoken sentence by sentence as the model writes it; the first sentence is cut at a comma.
- **Live transcript:** your words appear while you talk (Parakeet re-runs every ~0.5 s).

Measured on an M5 with `gemma-4-26b-a4b-it-4bit`: about 1.2 s from the end of your speech to the first spoken word, including the 0.77 s silence wait. Dense models are much slower (`gemma-4-12B`: ~3.3 s).

## Why a helper process for the voice

Kokoro crashes inside Apple's Core ML CPU backend (libBNNS) for certain inputs on macOS 27 (a fixed phoneme-token count). The crash can't be caught, so the voice runs in a child process (`SpeakToMe --tts-worker`). If it dies, a pre-loaded standby takes over and the sentence is retried with one punctuation token more or less, which sounds the same. Recovery costs ~0.3 s instead of crashing the app.

## F5-TTS Russian

Everything else speaks through Core ML; [F5-TTS Russian](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN) (CC-BY-NC-4.0, so non-commercial) has no Core ML build, so it runs on MLX, on the GPU, in its own helper process (`--f5-worker`). Choosing it downloads about 1.4 GB.

- **Voice:** it imitates a short clip, either made with the chosen Supertonic-3 voice or cloned in Settings (`F5VoiceLibrary.swift`; Parakeet writes the transcript, which you can correct).
- **Text:** numbers are spelled out first because it reads digits badly, and word stress is marked from [RUAccent](https://github.com/Den4ikAI/ruaccent)'s dictionary. Its neural models aren't used, so homographs and unknown words stay unmarked unless you fix them in Settings.
- **Memory:** the helper peaks at about 3 GB and exits as soon as another model is chosen.
- **Failures:** if it's still downloading or it fails, the next model says the sentence.
- **Speed:** at the Fastest setting it generates about 6.5 s of speech in about 1 s when idle, and it takes longer while sharing the GPU with the language model.

`swift build` can't compile MLX's Metal shaders, so `scripts/build-mlx-shaders.sh` does (once, about 15 minutes, 193 MB), and `build-app.sh` puts them next to the executable. To run a debug build with F5-TTS, copy `.build/mlx.metallib` next to the binary.

## Tests and diagnostics

```bash
bash scripts/test-speech-text.sh
```
Fast, deterministic speech-text regression tests with no model downloads or server.
Checks thinking tags at every token split, long sentence streaming, abbreviations,
CJK punctuation and prosody carried across chunks.

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
| `--f5clonetest <sample> <dir>` | An audio file through the same steps as adding a voice, then F5-TTS speaking in it and in the built-in voice; writes WAVs to `dir` |
| `--replytest <model> [engine]` | Where the wait goes in a Russian spoken reply, with the language model and voice running together |
| `--f5switchtest` | Through the real session: choose F5-TTS Russian, time it idle and while oMLX writes, kill its helper, switch away and check the helper is gone |
| `--clonetest <dir>` | Clones a voice from a Kokoro-made sample; writes `sample.wav` and `cloned.wav` |
| `--snapshot <dir>` | Renders the window in several states to PNGs |
| `--micdiag` (via `open … --args`) | Checks mic permission and that the audio engine starts |

Run these from the app bundle and they use your real settings; a few change a setting and restore it afterwards.

## Code map

Everything is in `Sources/SpeakToMe`.

- `VoiceSession.swift`: the conversation loop: turn-taking, drafts, barge-in, tools, languages, saved chats, your voice
- `AudioIO.swift`: mic (16 kHz) and playback (24 kHz) on one engine with echo cancellation; live levels
- `SpeechEngines.swift`: the speech models you can choose, per language group, and their fallbacks
- `SpeechModels.swift`: loads VAD and Parakeet; speaks with the chosen model
- `F5TTS.swift`: F5-TTS and its Vocos vocoder, ported to MLX Swift (inference only)
- `F5Voice.swift`: F5-TTS Russian's download, reference clip and helper process
- `F5VoiceLibrary.swift`: cloned voices for F5-TTS, and preparing their clips
- `RussianStress.swift`: stress marks from RUAccent's dictionary, searched on disk
- `TTSWorker.swift`: the crash-isolated voice helper process (Kokoro + PocketTTS) with a hot standby
- `OMLXClient.swift`: model list, streaming chat with images and tool calls, model pinning
- `Tools.swift`: web search, page reading, time, opening apps and pages
- `SentenceChunker.swift`: splits the streamed reply into speakable pieces and strips markdown
- `ContentView.swift` (window, chat), `SettingsView.swift`, `Visuals.swift`, `FaceEngine.swift`, `FaceRenderer.swift` and `MistControls.swift` (the face: lips from the voice, expression, shader, and the mist behind the controls)
- `ScreenVision.swift`, `Languages.swift`, `SoundCues.swift`, `HotKey.swift`, `MiniOrb.swift`, `ConversationStore.swift`
- `SelfTest.swift`, `Snapshots.swift`, `MicDiagnostics.swift`, `Bench.swift`: the test modes above
