# @wrinh/ngan

Praat-compatible acoustic analysis & TD-PSOLA synthesis engine (`To Intensity...`, `To Pitch (ac/cc/filtered ac)...`, `To Formant (burg)...`, `Formant: Track...`, `To Spectrogram...`, `To MelSpectrogram...`, `To BarkSpectrogram...`, `To MFCC...`, `To PowerCepstrogram...`, `Get CPPS...`, `To Harmonicity...`, jitter/shimmer & voice breaks, LTAS, `.TextGrid` segment summarization, and TD-PSOLA `Manipulation`) compiled from pure [MoonBit](https://www.moonbitlang.com/) to **WebAssembly GC** (zero external runtime dependencies).

Includes out-of-the-box TypeScript types, a **Web Worker wrapper** (`createNganWorker`), **overlap-save chunked & streaming long-audio analysis** (`analyzeLongAudio` / `streamLongAudio` + `onProgress`), a Web Audio API decoding/resampling bridge (`decodeAudio`), and real-time microphone streaming powered by an `AudioWorklet` + WASM-side O(1) circular ring buffer.

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
  pitch: { pitchFloor: 50, pitchCeiling: 800, method: 'filtered_ac' },
  formants: { maxNumFormants: 5, maxFormantFreq: 5500, track: true },
  spectrogram: true,
});

console.log('Pitch frames:', result.pitch.frames);
console.log('Formant frames:', result.formants.frames);

if (result.spectrogram) {
  const dbGrid = spectrogramToDbMatrix(result.spectrogram, -60);
  console.log('Spectrogram bands x frames:', dbGrid.length);
}
```

## Web Worker & Long-Audio Chunked Analysis (`createNganWorker`)

Offload heavy acoustic analysis or multi-minute / multi-hour recordings onto a background thread with overlap-save chunking (avoiding chunk-boundary window and Viterbi edge artifacts), progress callbacks, and cancellation:

```ts
import { createNganWorker } from '@wrinh/ngan';

const worker = await createNganWorker();
const controller = new AbortController();

// 1. Chunked analysis with progress callbacks and stitched full-recording tiers
const analysis = await worker.analyzeLongAudio(longSamples, sampleRate, {
  chunkDurationSeconds: 20,
  overlapDurationSeconds: 0.5,
  pitch: { method: 'filtered_ac' },
  formants: { track: true },
  melSpectrogram: true,
  mfcc: { numberOfCoefficients: 12 },
  signal: controller.signal,
  onProgress(p) {
    console.log(
      `${p.percent.toFixed(1)}% (${p.chunkIndex + 1}/${p.totalChunks}) · ` +
        `ETA ${(p.estimatedRemainingMs / 1000).toFixed(1)}s`,
    );
  },
  onChunk(chunk) {
    console.log(`Chunk [${chunk.startTime}s..${chunk.endTime}s] ready`);
  },
});

// 2. Or stream chunks incrementally with for-await-of
for await (const chunk of worker.streamLongAudio(longSamples, sampleRate, {
  chunkDurationSeconds: 10,
  spectrogram: true,
})) {
  renderChunk(chunk);
}

// Direct single-call RPCs also run off the main thread:
const cpps = await worker.analyzeCpps(samples, sampleRate);
const shifted = await worker.manipulatePsola(samples, sampleRate, {
  pitchShiftSemitones: 3,
  durationFactor: 1.15,
});

await worker.terminate();
```

`analyzeLongAudio()` and `streamLongAudio()` are also available directly on `NganEngine` for main-thread or custom-worker usage.

## CPPS, MFCC, Mel/Bark Spectrograms, Voice Report & TD-PSOLA

```ts
// PowerCepstrogram + Smoothed Cepstral Peak Prominence (CPPS)
const { cppsDb } = ngan.analyzeCpps(samples, sampleRate);

// Mel / Bark filter-bank spectrograms and MFCC
const melSpec = ngan.analyzeMelSpectrogram(samples, sampleRate);
const barkSpec = ngan.analyzeBarkSpectrogram(samples, sampleRate);
const mfcc = ngan.analyzeMfcc(samples, sampleRate, { numberOfCoefficients: 12 });

// Full Praat Voice Report (jitter, shimmer, HNR, unvoiced fraction, voice breaks)
const voice = ngan.analyzeVoiceReport(samples, sampleRate);
console.log(
  voice.fractionLocallyUnvoiced,
  voice.numberOfVoiceBreaks,
  voice.degreeOfVoiceBreaks,
);

// TD-PSOLA pitch & duration manipulation
const manipulated = ngan.manipulatePsola(samples, sampleRate, {
  pitchPoints: [
    { time: 0.0, frequency: 180 },
    { time: 0.5, frequency: 240 },
  ],
  durationFactor: 1.25,
});
```

## Real-Time Microphone Streaming (`AudioWorklet` + Ring Buffer)

```ts
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

const snapshot = mic.session.analyzeRecentHistory(3.0, { spectrogram: true });
await mic.stop();
```

## License

**GPL-3.0-or-later** — derived from Praat's GPL-licensed sources.
