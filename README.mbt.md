# ngan

[English](README.md) · [简体中文](README.zh-CN.md)

[![CI](https://github.com/wrinh/ngan/actions/workflows/ci.yml/badge.svg)](https://github.com/wrinh/ngan/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/@wrinh/ngan.svg?logo=npm)](https://www.npmjs.com/package/@wrinh/ngan)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![MoonBit WasmGC](https://img.shields.io/badge/MoonBit-WasmGC-purple.svg)](https://www.moonbitlang.com/)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen.svg)](npm/package.json)

**ngan [ŋan]** (「[言](https://xtext.kkn.moe/?q=%E8%A8%80&mode=default)」) is a [Praat](https://www.fon.hum.uva.nl/praat/)-compatible acoustic analysis and TD-PSOLA speech manipulation engine written in pure [MoonBit](https://www.moonbitlang.com/), compiled to **WebAssembly GC**. It ports Praat's core acoustic analyzers and manipulation algorithms from scratch with zero dependencies beyond `moonbitlang/core`, enabling browser, Worker, and Node.js applications to obtain Praat-grade numbers without shipping a 20 MB Emscripten build of the C++ original.

## Implemented Praat Commands

| ngan entry point | Praat command | Algorithm |
| --- | --- | --- |
| `@ngan.intensity` | `To Intensity...` | Kaiser-20 windowed mean power, dB SPL re 2e-5 Pa |
| `@ngan.pitch_ac` | `To Pitch (ac)...` | Boersma (1993) autocorrelation + Viterbi path finder |
| `@ngan.pitch_cc` | `To Pitch (cc)...` | Forward cross-correlation (`FCC_NORMAL`) + Viterbi path finder |
| `@ngan.pitch_filtered_ac` | `To Pitch (filtered ac)...` | Praat 6.4+ Gaussian-attenuated autocorrelation + Viterbi path finder |
| `@ngan.harmonicity_ac` / `harmonicity_cc` | `To Harmonicity (ac/cc)...` | HNR (dB) via Gaussian-window AC / cross-correlation |
| `@ngan.point_process_cc` | `To PointProcess (periodic, cc)...` | Cross-correlation glottal pulse extraction |
| `@ngan.jitter` / `shimmer` / `voice_breaks` / `voice_report` | `Voice report...` | Local/RAP/PPQ5/DDP jitter, local/dB/APQ3/5/11/DDA shimmer, unvoiced fraction & voice breaks |
| `@ngan.formants` | `To Formant (burg)...` | Gaussian window + Burg LPC + polynomial roots |
| `@ngan.track_formants` | `Formant: Track...` | Viterbi dynamic-programming formant trajectory tracker |
| `@ngan.spectrogram` | `To Spectrogram...` | Gaussian-windowed FFT power spectrogram (Pa²/Hz) |
| `@ngan.mel_spectrogram` / `bark_spectrogram` | `To MelSpectrogram...` / `To BarkSpectrogram...` | Mel triangular & Bark Sekey–Hanson auditory filterbanks (dB SPL) |
| `@ngan.mfcc` / `mel_spectrogram_to_mfcc` | `To MFCC...` | Orthonormal DCT-II over Mel filterbank energies |
| `@ngan.power_cepstrogram` / `cpps` | `To PowerCepstrogram...` / `Get CPPS...` | Squared real cepstrum + 2D smoothing + robust/OLS tilt regression CPPS (dB) |
| `@ngan.ltas` / `spectrogram_to_ltas` | `To Ltas...` | Long-Term Average Spectrum (dB/Hz), band means & slope |
| `@ngan.center_of_gravity` / `spectral_tilt` | `Get centre of gravity...` | Spectral centroid, spectral slope, H1–H2, Iseli et al. H1\*–H2\*, H1–A1..A3 |
| `hz_to_semitones` / `erb` / `mel` / `bark` | `hertzToSemitones/Erb/Mel/Bark` | Praat psychoacoustic frequency scale conversions |
| `@ngan.parse_textgrid` / `analyze_textgrid_segments` | `.TextGrid` + interval queries | Long/Short/Chronological TextGrid parser + F0, F1–F3, intensity & 20%–50%–80% segment summaries |
| `@ngan.to_manipulation` / `resynthesize_psola` | `To Manipulation` / OLA resynthesis | TD-PSOLA pitch contour & duration-tier manipulation |

Behavior is ported line-by-line from the Praat sources (`fon/Sound_to_Intensity.cpp`, `fon/Sound_to_Pitch.cpp`, `fon/Pitch.cpp`, `fon/Sound_to_Formant.cpp`, `fon/Sound_and_Spectrogram.cpp`, `dwtools/Cepstrum.cpp`, `dwtools/MFCC.cpp`, `dwsys/NUM2.cpp`): identical windows, identical normalizations, identical frame layouts, and identical decision rules — see [*Praat parity notes*](#praat-parity-notes) below.

## Quick start (MoonBit)

```bash
moon check --target all               # typecheck native & wasm-gc
moon test                             # run all unit, whitebox, blackbox & README doc tests
moon run cmd/main                     # CLI demo: synthesize a vowel, analyze it
moon build --target wasm-gc --release # produce _build/wasm-gc/release/build/web/web.wasm
```

The CLI demo prints (synthetic two-formant vowel, 219.2 Hz voicing, 16 kHz):

```text
intensity frames: 117, mid-frame 107.3 dB SPL
pitch: 97/97 voiced frames, mean f0 219.17 Hz
formants: 152 frames, mean F1 566 Hz, mean F2 1519 Hz
spectrogram: 496 frames x 160 bands, peak band 406.25 Hz
```

## MoonBit Usage

The root package is the public facade. The simple positional ABI:

```moonbit nocheck
pub fn analyze_intensity(samples : FixedArray[Double], sample_rate : Double, min_pitch : Double) -> IntensityTier

pub fn analyze_pitch(samples : FixedArray[Double], sample_rate : Double, pitch_floor : Double, pitch_ceiling : Double) -> PitchTier

pub fn analyze_pitch_filtered_ac(samples : FixedArray[Double], sample_rate : Double, pitch_floor : Double, pitch_ceiling : Double) -> PitchTier

pub fn analyze_formants(samples : FixedArray[Double], sample_rate : Double, max_formants : Int32, max_formant_freq : Double) -> FormantTier

pub fn analyze_spectrogram(samples : FixedArray[Double], sample_rate : Double, window_length : Double, maximum_frequency : Double, time_step : Double, frequency_step : Double) -> Spectrogram

pub fn analyze_cpps(samples : FixedArray[Double], sample_rate : Double) -> Double?

pub fn analyze_mfcc(samples : FixedArray[Double], sample_rate : Double, number_of_coefficients : Int32) -> Mfcc

pub fn analyze_all(...) -> AcousticAnalysisResult
```

A full analysis of a 220 Hz sine (this example is executed as a test by `moon test`):

```mbt check
///|
test {
  let fs = 16000.0
  let n = 16000
  let samples : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    samples[i] = @math.sin(2.0 * @math.PI * 220.0 * i.to_double() / fs)
  }
  let result = @ngan.analyze_all(samples, fs, 100.0, 75.0, 600.0, 5, 5500.0)
  // Intensity of a unit-amplitude sine: 10 log10(0.5 / 4e-10) dB SPL.
  inspect(
    result.intensity_values[result.intensity_values.length() / 2],
    content=(
      #|90.96910013304635
    ),
  )
  // Pitch of a perfectly periodic signal is recovered to well below 0.1%.
  guard result.pitch_frames[result.pitch_frames.length() / 2].frequency
    is Some(f0) else {
    fail("a pure sine must be voiced")
  }
  inspect(
    f0,
    content=(
      #|219.9996057850048
    ),
  )
}
```

Segment-level summarization from a Praat `.TextGrid` (F0, F1–F3, intensity, and 20%–50%–80% trajectory points):

```mbt check
///|
test {
  let fs = 16000.0
  let samples : FixedArray[Double] = FixedArray::make(16000, 0.0)
  for i in 0..<16000 {
    samples[i] = @math.sin(2.0 * @math.PI * 220.0 * i.to_double() / fs)
  }
  let tg_src =
    #|File type = "ooTextFile"
    #|Object class = "TextGrid"
    #|xmin = 0
    #|xmax = 1.0
    #|tiers? <exists>
    #|size = 1
    #|item []:
    #|    item [1]:
    #|        class = "IntervalTier"
    #|        name = "vowels"
    #|        xmin = 0
    #|        xmax = 1.0
    #|        intervals: size = 1
    #|        intervals [1]:
    #|            xmin = 0.2
    #|            xmax = 0.8
    #|            text = "a"
  let segs = @ngan.analyze_textgrid_segments(
    samples,
    sample_rate=fs,
    tg_src,
    tier_name="vowels",
  )
  assert_eq(segs.length(), 1)
  assert_eq(segs[0].trajectory.length(), 3)
  assert_true(segs[0].f0_mean is Some(_))
  assert_true(segs[0].intensity_mean is Some(_))
}
```

Every analyzer also has a fully parameterized form with labeled, defaulted arguments mirroring the Praat dialog boxes:

```moonbit nocheck
@ngan.pitch_filtered_ac(
  samples,
  sample_rate~ = 16000.0,
  pitch_floor~ = 50.0,
  pitch_ceiling~ = 800.0,
  very_accurate~ = false,
  attenuation_at_top~ = 0.03,
  voicing_threshold~ = 0.50,
  silence_threshold~ = 0.09,
  octave_cost~ = 0.055,
  octave_jump_cost~ = 0.35,
  voiced_unvoiced_cost~ = 0.14,
)
```

### Result types

```moonbit nocheck
///|
pub(all) struct PitchFrame {
  time : Double
  frequency : Double?
  strength : Double
} // None = unvoiced

///|
pub(all) struct FormantValue {
  frequency : Double
  bandwidth : Double
} // Hz

///|
pub(all) struct FormantFrame {
  time : Double
  formants : Array[FormantValue]
} // F1 < F2 < ...

///|
pub(all) struct IntensityTier {
  t1 : Double
  dt : Double
  values : FixedArray[Double]
} // dB SPL
```

Wasm-GC struct references cross the JS boundary without JSON copies: hand the engine a `FixedArray[Double]` of PCM samples and read back the typed results.

## JavaScript / TypeScript SDK (`@wrinh/ngan` in `npm/`)

An npm-ready TypeScript wrapper lives in [`npm/`](npm/README.md) (`@wrinh/ngan`) with zero runtime dependencies, full `.d.ts` types, a Web Audio API decoding/resampling bridge (`decodeAudio`), an out-of-the-box Web Worker client (`createNganWorker`) with overlap-save chunked long-audio analysis (`analyzeLongAudio` / `streamLongAudio` + `onProgress`), and real-time microphone streaming powered by an `AudioWorklet` + WASM-side O(1) ring buffer (`startMicrophoneStream` / `createStreamSession`).

> **Runtime requirements**: WebAssembly GC + `wasm:js-string` builtins (Chrome 130+, Firefox 134+, Safari 18.4+, or Node.js 22+).

```ts
import { createNgan, createNganWorker, decodeAudio } from '@wrinh/ngan';

// 1. Direct synchronous analysis on decoded audio
const ngan = await createNgan();
const { samples, sampleRate } = await decodeAudio(audioFile, { targetSampleRate: 16000 });
const result = ngan.analyzeAll(samples, sampleRate, {
  pitch: { method: 'filtered_ac' },
  spectrogram: true,
});
const { cppsDb } = ngan.analyzeCpps(samples, sampleRate);
const voice = ngan.analyzeVoiceReport(samples, sampleRate);
const shifted = ngan.manipulatePsola(samples, sampleRate, {
  pitchShiftSemitones: 3,
  durationFactor: 1.2,
});

// 2. Off-thread Web Worker + overlap-save chunked long-audio analysis
const worker = await createNganWorker();
const longResult = await worker.analyzeLongAudio(samples, sampleRate, {
  chunkDurationSeconds: 20,
  overlapDurationSeconds: 0.5,
  pitch: { method: 'filtered_ac' },
  formants: { track: true },
  mfcc: true,
  onProgress: (p) => console.log(`${p.percent.toFixed(1)}%`),
});
await worker.terminate();

// 3. Real-time microphone streaming via AudioWorklet + WASM ring buffer
const mic = await ngan.startMicrophoneStream({
  sampleRate: 16000,
  onFrame(frame) {
    console.log(frame.time, frame.pitch.frequency, frame.formants, frame.intensityDb);
  },
});
```

Build and test the npm SDK locally (requires Node.js 22+):

```bash
npm --prefix npm install
npm --prefix npm run build
npm --prefix npm test
```

## Package layout

```text
ngan
├── moon.mod / moon.pkg   # module + root facade package
├── lib.mbt               # analyze_intensity / analyze_pitch / analyze_formants / analyze_all / ...
├── types/                # shared result types + Semitone/ERB/Mel/Bark conversions
├── math/                 # Complex, Bessel I0, Durand-Kerner polynomial roots, libm re-exports
├── dsp/                  # radix-2 FFT, cross-correlation, Kaiser/Hann/Gaussian windows, sinc resampler, Burg LPC
├── analysis/             # intensity, pitch (ac/cc/filtered ac), harmonicity, point_process, jitter/shimmer & voice breaks, formants & tracking, spectrogram, cepstrum/CPPS, Mel/Bark/MFCC, TD-PSOLA, ltas, spectral_features, segment_summary
├── textgrid/             # Praat .TextGrid parser & serializer (Long, Short, Chronological)
├── web/                  # WASM-GC FFI boundary (web.mbt) powering @wrinh/ngan
├── npm/                  # TypeScript npm SDK, Web Worker wrapper, chunked analysis & AudioWorklet streaming
└── cmd/main              # demo executable
```

## Praat parity notes

Where the original engine specification and the Praat sources disagree, ngan follows **Praat's behavior**, specifically:

- **Kaiser-20 intensity window**: Praat's shape factor is `beta = 2 pi^2 + 0.5` (≈ 20.24, sidelobes below −100 dB) over a *physical* window of `6.4 / min_pitch` s; the `3.2 / min_pitch` figure is the *effective* length.
- **Energy weighting**: `sum w (x - mean)^2 / sum w` with the *unweighted* window mean subtracted (Praat), not `sum w^2 x^2 / sum w^2`.
- **Pitch window**: Praat's periodic Hann `0.5 - 0.5 cos(2 pi (i + 1) / (N + 1))`; the local mean is measured over ±1 longest *period*, not over the window.
- **Autocorrelation normalization**: `rx = (ra(tau)/ra(0)) / (rw(tau)/rw(0))` — both the sound and the window autocorrelations are normalized at zero lag, then peak refinement maximizes the Hanning-tapered sinc interpolation of Boersma (1993) eq. (22) via Brent's method (`min(70, halfWindow - 1 - tau)` taps for `AC_HANNING` / `FCC_NORMAL` matching Praat's `SINC70`, and up to `min(500, halfWindow - 1 - tau)` taps for `AC_GAUSS`).
- **Filtered AC pitch (Praat 6.4+)**: applies Praat's Gaussian frequency-domain attenuation filter (`attenuation_at_top` at `pitch_ceiling`) prior to autocorrelation, with Praat 6.4+ default thresholds (`50–800 Hz`, `voicing_threshold = 0.50`, `silence_threshold = 0.09`, `octave_cost = 0.055`) and optional 6-period Gaussian `very_accurate` mode.
- **Unvoiced hypothesis**: Praat's silence-aware strength `voicing_threshold + max(0, 2 - intensity / (silence_threshold / (1 + voicing_threshold)))`, and jump / switch costs scaled by `0.01 / dt`.
- **Formant poles**: only the 50 Hz DC/Nyquist safety margins are applied; poles outside the unit circle are reflected back in (Praat's `Roots_fixIntoUnitCircle`).
- **Frames**: analyzers use Praat's `Sampled_shortTermAnalysis` — `floor((duration - window) / dt) + 1` frames fitted symmetrically, first frame at `mid - 0.5 * n * dt + 0.5 * dt`.
- **Spectrogram** (`To Spectrogram...`): Gaussian window spanning `2 * window_length` with Praat's exact `(exp(-48 p^2) - exp(-12)) / (1 - exp(-12))` shape, 8x oversampling limits, frequency steps snapped to whole FFT bins, band power `sum |X_k|^2 / sum w^2 / bin_width` in Pa²/Hz, and first band centred at `0.5 * (df - fft_bin_width)`.
- **PowerCepstrogram & CPPS**: resamples to `2 * min(maximum_frequency, fs / 2)`, applies pre-emphasis, computes the squared real cepstrum of the log power spectrum via FFT/IFFT, optionally subtracts tilt before 2D boxcar smoothing, fits straight or exponential-decay baseline via OLS or Tukey biweight robust regression, and refines the cepstral peak parabolically.
- **Mel / Bark Spectrograms & MFCC**: Mel triangular filterbank on `550 * ln(1 + f / 550)`, Bark Sekey & Hanson (1984) filterbank on `7 * ln(f/650 + sqrt(1 + (f/650)^2))`, and orthonormal DCT-II coefficients.
- **Resampling**: Praat zeroes the spectrum above the target Nyquist and interpolates with a 50-tap sinc; ngan uses an equivalent Kaiser-12 band-limited sinc (32 zero crossings), never linear interpolation.
- **Cross-correlation pitch, HNR & Voice Report**: `pitch_cc` uses `1 / pitch_floor` forward cross-correlation (`FCC_NORMAL`); `harmonicity_ac` uses Praat's 4.5-effective / 9.0-physical Gaussian window; `point_process_cc`, `jitter`, `shimmer`, and `voice_breaks` compute local/RAP/PPQ5/DDP jitter, local/dB/APQ3/APQ5/APQ11/DDA shimmer, locally unvoiced frame fraction, voice break count, and degree of voice breaks.
- **TD-PSOLA Manipulation**: piecewise-linear `DurationTier` time-warp integration + pitch-synchronous 2-period Hanning overlap-add over voiced pulse runs and 5 ms COLA Hanning synthesis over unvoiced spans.

## Accuracy & Browser Benchmark

The test suite (`moon test`, 57 tests; `npm --prefix npm test`, 10 tests) pins behavior against analytically known answers and end-to-end Worker/AudioWorklet pipelines.

Below are direct side-by-side measurements comparing post-optimization `@wrinh/ngan` (`182.5 KiB` / `186,860 B` `ngan.wasm`) in **Headless Microsoft Edge 158 (V8 WasmGC)** against **Praat 7.0** native C++ on identical 16 kHz mono WAV signals (`vowel_1_5s.wav` = 1.5 s gliding vowel; `speech_5s.wav` = 5.0 s multi-segment voiced audio with two 0.3 s unvoiced breaks; `long_30s.wav` = 30.0 s tiled signal):

- **Cold load & compile (`ngan.wasm`)**: `createNgan()` default URL load `3.9 ms` (`compileOnlyMs: 2.0 ms`), total `fetch` + `init` `5.8–7.2 ms`; `createNganWorker()` spawn + init `17.9 ms`.
- **30 s Worker chunked `analyzeLongAudio`** (`10 s` chunks, `0.5 s` overlap, Intensity + Pitch AC + Formants + `onProgress`): median `219.8 ms` (**RTF 0.00733**, **136.5× faster than real time**).

### `speech_5s.wav` (5.0 s, 16 kHz, 80,000 samples) — Timing & Numerical Parity

| Command / Method | `ngan` Median (ms) | Praat 7.0 Mean (ms) | `ngan` Result | Praat 7.0 Result | Difference |
| --- | ---: | ---: | --- | --- | --- |
| `To Intensity...` | `1.90` | `1.44` | 618 frames, `77.9963 dB` | 618 frames, `77.9963 dB` | `-0.00003 dB` |
| `To Pitch (ac)...` | `12.15` | `2.25` | 439/497 voiced, `196.0066 Hz` | 439/497 voiced, `196.0066 Hz` | `-0.000001 Hz` |
| `To Pitch (cc)...` | `37.15` | `9.81` | 1312/1493 voiced, `195.9314 Hz` | 1312/1493 voiced, `195.9294 Hz` | `+0.0020 Hz` |
| `To Pitch (filtered ac)...` | `22.10` | `7.08` | 291/330 voiced, `196.0429 Hz` | 291/330 voiced, `196.0429 Hz` | `+0.000001 Hz` |
| `To Formant (burg)...` | `15.80` | `20.25` | 793 frames, F1 `625.75` / F2 `1581.65 Hz` | 793 frames, F1 `628.27` / F2 `1591.01 Hz` | `-2.52` / `-9.36 Hz` |
| `To Spectrogram...` | `9.75` | `1.81` | `2496 × 160` (zero-JSON FFI) | — | — |
| `To Harmonicity (ac)...` | `77.90` | `24.06` | 431/489 defined, `20.6725 dB` | 431/489 defined, `20.6725 dB` | `+0.0000002 dB` |
| `Voice report...` | `89.30` | `18.08` | 2 breaks (`12.168%`), jitter `0.591%`, shimmer `1.326%` | 2 breaks (`12.168%`), jitter `0.589%`, shimmer `1.797%` | breaks exact, jitter `+0.001%`, shimmer `-0.47%` |
| `To PowerCepstrogram` + `Get CPPS` | `281.10` | `529.64` | `19.996 dB` | `19.256 dB` | `+0.740 dB` |
| `To MelSpectrogram...` | `4.25` | `9.07` | `994 × 15` (zero-JSON FFI) | — | — |
| `To BarkSpectrogram...` | `5.15` | `92.54` | `994 × 22` (**18.0× faster than Praat**) | — | — |
| `To MFCC...` | `7.85` | `9.69` | 994 frames (orthonormal DCT-II) | 994 frames (Praat DCT scaling) | exact frame grid |
| `To Manipulation` + OLA (`+4 st`) | `17.00` | `9.52` | `5.000 s`, F0 `246.923 Hz` | `5.000 s`, F0 `246.950 Hz` | `-0.027 Hz` (`0.01%`) |

*(Note: `ngan` beats native C++ Praat 7.0 on Formants, CPPS, MFCC, MelSpectrogram, and BarkSpectrogram in single-threaded Edge WasmGC; `VoiceReport` runs `Pitch` + `PointProcess` + `Harmonicity` together; `MFCC` uses orthonormal `sqrt(1/N)` / `sqrt(2/N)` DCT-II scaling.)*

### `@wrinh/ngan` vs `praat-wasm` v6.4.6200 (Headless Edge 158)

Direct head-to-head browser comparison against `praat-wasm` (Emscripten C++ build of Praat) on the same Edge 158 engine:

- **Artifact & Cold Startup**:
  - **WASM size**: `ngan.wasm` `186,860 B` (`182.5 KiB`) vs `praat.wasm` `24,665,614 B` (`23.52 MiB`) (**132.0× smaller**).
  - **Local cold load + init**: `ngan` `5.80 ms` vs `praat-wasm` `226.00 ms` (**39.0× faster startup**); `createNganWorker()` initializes in `17.9–35.3 ms` (`praat-wasm` worker failed with `Error: Worker error`).

| Operation (`speech_5s.wav`, 5.0 s / 16 kHz) | `ngan` Median (ms) | `praat-wasm` Median (ms) | Speedup (`praat-wasm / ngan`) |
| --- | ---: | ---: | ---: |
| `To Intensity...` | `1.70` | `26.00` | **15.29× faster** |
| `To Pitch (ac)...` | `12.25` | `18.25` | **1.49× faster** |
| `To Pitch (cc)...` | `36.00` | `1048.50` | **29.13× faster** |
| `To Pitch (filtered ac)...` | `20.10` | `31.50` | **1.57× faster** |
| `To Formant (burg)...` | `15.55` | `241.25` | **15.51× faster** |
| `To Spectrogram...` | `9.05` | `35.85` | **3.96× faster** |
| `To Harmonicity (ac)...` | `68.00` | `147.30` | **2.17× faster** |
| `Voice report...` | `85.60` | `1343.70` | **15.70× faster** |
| `To PowerCepstrogram` + `Get CPPS` | `277.50` | `12,648.50` | **45.58× faster** |
| `To MelSpectrogram...` | `4.15` | `69.35` | **16.71× faster** |
| `To BarkSpectrogram...` | `4.90` | `277.10` | **56.55× faster** |
| `To MFCC...` | `7.80` | `98.45` | **12.62× faster** |
| `To Manipulation` + OLA (`+4 st`) | `15.60` | `144.45` | **9.26× faster** |

## License

**GPL-3.0-or-later** — see [LICENSE](LICENSE).

ngan's analysis modules (`analysis/*.mbt` and the window formulas in `dsp/window.mbt`) are derived from Praat's GPL-licensed C++ sources, so ngan is a derivative work of Praat and inherits the GPL. Everything else is distributed under the same license for simplicity. ngan is not affiliated with or endorsed by the Praat project; Praat is (c) Paul Boersma and David Weenink, see <https://www.fon.hum.uva.nl/praat/>.
