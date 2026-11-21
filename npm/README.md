# @wrinh/ngan

Praat-compatible acoustic analysis engine (`To Intensity...`, `To Pitch (ac/cc)...`, `To Formant (burg)...`, `Formant: Track...`, `To Spectrogram...`, `To Harmonicity...`, jitter/shimmer, LTAS, `.TextGrid` segment summarization) compiled from pure [MoonBit](https://www.moonbitlang.com/) to **WebAssembly GC** (~150 KB, zero external dependencies).

Includes out-of-the-box TypeScript types, a Web Audio API decoding/resampling bridge, and a real-time microphone streaming controller powered by an `AudioWorklet` + WASM-side O(1) circular ring buffer.

> **Browser / Runtime requirements**: WebAssembly GC with `wasm:js-string` builtins (Chrome 130+, Firefox 134+, Safari 18.4+, or Node.js 22+).

## Installation

```bash
npm install @wrinh/ngan
```

## Quick Start (Batch & Web Audio File Decoding)

```ts
import { createNgan, decodeAudio, spectrogramToDbMatrix } from '@wrinh/ngan';

const ngan = await createNgan();

// Decode & resample any browser File / Blob / ArrayBuffer to 16 kHz mono via Web Audio API
const { samples, sampleRate } = await decodeAudio(file, {
  targetSampleRate: 16000,
});

const result = ngan.analyzeAll(samples, sampleRate, {
  pitch: { pitchFloor: 75, pitchCeiling: 600, method: 'ac' },
  formants: { maxNumFormants: 5, maxFormantFreq: 5500, track: true },
  spectrogram: true,
});

console.log('Mean intensity frames:', result.intensity.values.length);
console.log('Pitch frames:', result.pitch.frames);
console.log('Formant frames:', result.formants.frames);

if (result.spectrogram) {
  const dbGrid = spectrogramToDbMatrix(result.spectrogram, -60);
  console.log('Spectrogram bands x frames:', dbGrid.length);
}
```

## Real-Time Microphone Streaming (`AudioWorklet` + Ring Buffer)

```ts
import { createNgan } from '@wrinh/ngan';

const ngan = await createNgan();

const mic = await ngan.startMicrophoneStream({
  sampleRate: 16000,
  historyDurationSeconds: 5.0,
  windowDurationSeconds: 0.08,
  hopDurationSeconds: 0.025,
  onFrame(frame) {
    console.log(
      `t=${frame.time.toFixed(2)}s`,
      `F0=${frame.pitch.frequency?.toFixed(1) ?? '--'} Hz`,
      `F1=${frame.formants[0]?.frequency.toFixed(0) ?? '--'} Hz`,
      `dB=${frame.intensityDb?.toFixed(1) ?? '--'}`,
    );
  },
});

// Later, run a full offline-grade Praat spectrogram + Viterbi analysis
// directly on the recent ring-buffer history without re-copying samples:
const snapshot = mic.session.analyzeRecentHistory(3.0, { spectrogram: true });

await mic.stop();
```

### Using the Ring Buffer Session Directly (Custom Workers / Custom Audio Pipelines)

```ts
const session = ngan.createStreamSession({
  sampleRate: 16000,
  historyDurationSeconds: 5.0,
  windowDurationSeconds: 0.08,
  hopDurationSeconds: 0.025,
  onFrame: (frame) => updateUI(frame),
});

// Feed PCM chunks (e.g. Float32Array from a WebSocket or AudioWorklet)
session.pushSamples(chunk);
```

## Voice Quality, Spectral Analysis & `.TextGrid` Summarization

```ts
const voice = ngan.analyzeVoiceReport(samples, sampleRate);
console.log(voice.jitter, voice.shimmer, voice.meanHnrDb);

const spectral = ngan.analyzeSpectral(samples, sampleRate);
console.log(spectral.centerOfGravityHz, spectral.ltas);

const segments = ngan.analyzeTextGridSegments(samples, sampleRate, textGridText);
```

## License

**GPL-3.0-or-later** — derived from Praat's GPL-licensed sources.
