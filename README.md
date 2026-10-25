# Speak to Me

A native macOS app for talking to your local AI with your voice. You speak, it answers out loud, and you can interrupt it mid-sentence just by talking. Everything runs on this Mac.

## How it works

```
mic ─▶ echo cancel ─▶ Silero VAD ─▶ Parakeet v3 ─▶ oMLX (your LLM, streaming) ─▶ sentence splitter ─▶ Kokoro ─▶ speaker
        (Apple)        (Neural Engine)  (Neural Engine)       (GPU)                                    (ANE + GPU)
```

| Stage | Tech | Why |
|---|---|---|
| Audio in/out | `AVAudioEngine` with voice processing | Apple's echo canceller removes the assistant's own voice from the mic, so you can interrupt without headphones |
| Turn detection | Silero VAD (Core ML, via [FluidAudio](https://github.com/FluidInference/FluidAudio)) | Knows when you start talking (barge-in) and when you've finished |
| Speech → text | Parakeet TDT 0.6B v3 (Core ML) | ~100× real time on the Neural Engine, 25 languages, leaves the GPU to the LLM |
| Thinking | Any chat model in **oMLX** (`/v1/chat/completions`, streamed) | Uses the models you already have; thinking mode is switched off for speed |
| Text → speech | Kokoro 82M, FluidAudio's ANE v3 pipeline | ~50 ms per sentence on M5, natural voices |

Latency trick: the reply is spoken sentence by sentence as the LLM writes it (the first sentence is even cut at a comma), so you hear the start of the answer long before the model has finished.

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

Use `scripts/build-app.sh --install` to also copy it to `/Applications`. Allow microphone access when macOS asks.

On first launch FluidAudio downloads Parakeet v3, Silero VAD and the Kokoro voice (about 1 GB in total, compiled once, a few minutes) into `~/Library/Application Support/SpeakToMe/Models`. FluidVoice's Core ML copies can't be reused: they're an older build that current FluidAudio rejects.

## Using it

- **Space** or click the orb to start/stop the conversation.
- Just talk. It replies after ~0.6 s of silence (adjustable in Settings, `⌘,`).
- Talk over it to interrupt.
- Pick the LLM at the top. Smaller or mixture-of-experts models (e.g. `gemma-4-26b-a4b`) reply fastest; 27B dense models feel slow in conversation.
- The number top-right is the time from when you stopped talking to the first word of the reply (excluding the silence wait).

## Self-test

Runs the whole pipeline without a microphone and prints per-stage timings:

```bash
build/SpeakToMe.app/Contents/MacOS/SpeakToMe --selftest
```

Pass a model id after `--selftest` to try a different LLM.

## Code map

- `AudioIO.swift`: mic capture (16 kHz) and playback (24 kHz) on one engine with echo cancellation
- `VoiceSession.swift`: the conversation loop, turn-taking and barge-in
- `SpeechModels.swift`: loads VAD, Parakeet and Kokoro
- `OMLXClient.swift`: oMLX model list and streaming chat
- `SentenceChunker.swift`: splits the streamed reply into speakable pieces and strips markdown
- `ContentView.swift`: UI and settings
