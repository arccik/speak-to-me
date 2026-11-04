# Voice pipeline review — 4 November 2026

The existing pipeline already overlaps transcription, generation and synthesis through
speculative drafts. Keeping that overlap is more useful than simply increasing speech speed.

## Changes implemented

- Fixed thinking-tag filtering. A complete `<think>…</think>` block arriving in one token
  previously lost its closing tag and all following speech. Tags split between tokens
  could also leak into speech. The filter now retains only a possible tag prefix and
  discards hidden content as it arrives.
- Added a word-boundary fallback at 140 characters for the opening speech chunk and
  260 for subsequent chunks. Long sentences can begin synthesis before punctuation
  arrives. Natural punctuation still takes priority as it is encountered. These
  thresholds need listening tests: shorter chunks can change a model's intonation.
- Kept common titles and initials with the following words, and recognized Chinese/
  Japanese sentence punctuation without requiring trailing whitespace.
- Propagated cancellation to the speech consumer during the entire generation loop,
  including tool execution. Added cancellation checks before transcription, voice
  requests, SSML segments, crash retries and fallback voices. An inference already
  executing inside a model/helper can still finish; its canceled result is discarded.

## Validation

- `bash scripts/test-speech-text.sh`: passed.
- `swift build --skip-update`: passed, with an MLX bundle build-system warning.
- `git diff --check`: passed.
- No microphone, listening comparison or end-to-end latency benchmark was performed.
  These changes do not establish a numerical latency gain or improved model fidelity.

## Next measurements to prioritize

1. Record time to audio actually starting. `lastLatencyMs` currently ends when samples
   are handed to `AudioIO.play`, before engine rebuilds or queued playback complete.
2. Compare recorded output for the same prompts and voices, especially joins between
   chunks. Include English, Russian, long answers and interruptions.
3. Measure partial transcription during long utterances: the entire utterance is
   re-transcribed every two VAD chunks, so cost grows with how long the user speaks.
4. Measure helper queue delay after canceling an expensive F5 request before deciding
   whether interrupting inference warrants a dedicated worker protocol change.

The rebuilt application has not been installed or launched; the existing app bundle
continues to use its previous binary until rebuilt with `scripts/build-app.sh`.
