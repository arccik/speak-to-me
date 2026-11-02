# Third-party notices

## Ported code

`Sources/SpeakToMe/F5TTS.swift` is ported from [f5-tts-mlx](https://github.com/lucasnewman/f5-tts-mlx) and [vocos-mlx](https://github.com/lucasnewman/vocos-mlx), both under this licence:

```
MIT License

Copyright (c) 2024 Lucas Newman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Libraries

| Library | Licence |
|---|---|
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0 |
| [MLX Swift](https://github.com/ml-explore/mlx-swift) | MIT |

These are fetched by Swift Package Manager, along with their own dependencies. See `Package.resolved` for exact versions.

## Models and data

None of these are in this repository. The app downloads them to `~/Library/Application Support/SpeakToMe/Models` when needed, and their licences apply to your use of them. Licences are as stated on each model card when this was written, so check there for the current terms.

| Model or data | Used for | Licence |
|---|---|---|
| [Silero VAD](https://huggingface.co/FluidInference/silero-vad-coreml) | Detecting speech | MIT |
| [Parakeet TDT 0.6B v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) | Speech recognition | CC-BY-4.0 |
| [Kokoro 82M](https://huggingface.co/FluidInference/kokoro-82m-coreml) | English speech | Apache-2.0 |
| [PocketTTS](https://huggingface.co/FluidInference/pocket-tts-coreml) | Cloned English voice | CC-BY-4.0 |
| [Supertonic-3](https://huggingface.co/FluidInference/supertonic-3-coreml) | Speech in 31 languages | BigScience OpenRAIL-M |
| [F5-TTS Russian](https://huggingface.co/Misha24-10/F5-TTS_RUSSIAN) | Russian speech | **CC-BY-NC-4.0 (non-commercial)** |
| [Vocos mel 24 kHz](https://huggingface.co/lucasnewman/vocos-mel-24khz) | Vocoder for F5-TTS | MIT |
| [RUAccent dictionaries](https://huggingface.co/ruaccent/accentuator) | Russian word stress | MIT |

## Portrait

`Resources/persona.jpg` is cropped from "John Herschel" (1867) by Julia Margaret Cameron, in the public domain, from the Metropolitan Museum of Art's copy as restored by Adam Cuerden: [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Julia_Margaret_Cameron_-_John_Herschel_(Metropolitan_Museum_of_Art_copy,_restored).jpg).
