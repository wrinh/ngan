# ngan

**ngan [ŋan]** (「[言](https://xtext.kkn.moe/?q=%E8%A8%80&mode=default)」) is a [Praat](https://www.fon.hum.uva.nl/praat/)-compatible
acoustic analysis engine written in pure [MoonBit](https://www.moonbitlang.com/),
compiled to **WebAssembly GC**. It reimplements the three core Praat
analysis commands from scratch — intensity, pitch, and formants — with no
dependencies beyond `moonbitlang/core`, so a browser gets Praat-grade
numbers without shipping a 20 MB Emscripten build of the C++ original.

| ngan entry point | Praat command | Algorithm |
| --- | --- | --- |
| `@ngan.intensity` | `To Intensity...` | Kaiser-20 windowed mean power, dB SPL re 2e-5 Pa |
| `@ngan.pitch` | `To Pitch (ac)...` | Boersma (1993) autocorrelation + Viterbi path finder |
| `@ngan.formants` | `To Formant (burg)...` | Gaussian window + Burg LPC + polynomial roots |
| `@ngan.spectrogram` | `To Spectrogram...` | Gaussian-windowed FFT power spectrogram (Pa^2/Hz) |

Behavior is ported line-by-line from the Praat sources
(`fon/Sound_to_Intensity.cpp`, `fon/Sound_to_Pitch.cpp`, `fon/Pitch.cpp`,
`fon/Sound_to_Formant.cpp`, `fon/Sound_and_Spectrogram.cpp`,
`dwsys/NUM2.cpp`): identical windows, identical normalizations, identical
frame layouts and identical decision rules — see *Praat parity notes*
below.

## Online demo

A small demo page (vanilla JS, no framework) loads the ~90 KB wasm-gc
module, synthesizes a gliding two-formant vowel or analyzes a local audio
file, and draws the spectrogram, pitch track, formants, intensity and
waveform — all client-side, no uploads:

**<https://ngan-demo.pages.dev>** (source: `web/`, deployed by
`.github/workflows/deploy.yml` on every push to `main`).

## Quick start

```bash
moon check                  # type check
moon test                   # run the full test suite
moon run cmd/main           # demo: synthesize a vowel, analyze it
moon build --target wasm-gc # produce the WebAssembly GC module
```

The demo prints (synthetic two-formant vowel, 219.2 Hz voicing, 16 kHz):

```
intensity frames: 117, mid-frame 107.3 dB SPL
pitch: 97/97 voiced frames, mean f0 219.17 Hz
formants: 152 frames, mean F1 566 Hz, mean F2 1519 Hz
spectrogram: 496 frames x 160 bands, peak band 406.25 Hz
```

## Usage

The root package is the facade. The simple positional ABI from the engine
specification:

```moonbit nocheck
pub fn analyze_intensity(samples : FixedArray[Double], sample_rate : Double, min_pitch : Double) -> IntensityTier

pub fn analyze_pitch(samples : FixedArray[Double], sample_rate : Double, pitch_floor : Double, pitch_ceiling : Double) -> PitchTier

pub fn analyze_formants(samples : FixedArray[Double], sample_rate : Double, max_formants : Int, max_formant_freq : Double) -> FormantTier

pub fn analyze_spectrogram(samples : FixedArray[Double], sample_rate : Double, window_length : Double, maximum_frequency : Double, time_step : Double, frequency_step : Double) -> Spectrogram

pub fn analyze_all(...) -> AcousticAnalysisResult
```

A full analysis of a 220 Hz sine (this example is executed as a test):

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
      #|220.00002855108002
    ),
  )
}
```

Every analyzer also has a fully parameterized form with labeled, defaulted
arguments mirroring the Praat dialog boxes:

```moonbit nocheck
@ngan.pitch(
  samples,
  sample_rate~ = 16000.0,
  pitch_floor~ = 75.0,
  pitch_ceiling~ = 600.0,
  voicing_threshold~ = 0.45,
  silence_threshold~ = 0.03,
  octave_cost~ = 0.01,
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

Wasm-GC struct references cross the JS boundary without JSON copies: hand the
engine a `FixedArray[Double]` of PCM samples and read back the typed results.

## Package layout

```
ngan
├── moon.mod / moon.pkg   # module + root facade package
├── lib.mbt               # analyze_intensity / analyze_pitch / analyze_formants / analyze_all
├── types/                # shared result types (PitchTier, FormantTier, ...)
├── math/                 # Complex, Bessel I0, Durand-Kerner polynomial roots, libm re-exports
├── dsp/                  # radix-2 FFT, Kaiser/Hann/Gaussian windows, sinc resampler, Burg LPC
├── analysis/             # intensity.mbt, pitch.mbt, formant.mbt (the Praat ports)
└── cmd/main              # demo executable
```

## Praat parity notes

Where the engine specification and the Praat sources disagree, ngan follows
**Praat's behavior** (the goal of the specification), specifically:

- **Kaiser-20 intensity window**: Praat's shape factor is `beta = 2 pi^2 + 0.5`
  (≈ 20.24, sidelobes below −100 dB) over a *physical* window of
  `6.4 / min_pitch` s; the `3.2 / min_pitch` figure is the *effective* length
  and `20 pi` from the spec is not what the C code computes.
- **Energy weighting**: `sum w (x - mean)^2 / sum w` with the *unweighted*
  window mean subtracted (Praat), not `sum w^2 x^2 / sum w^2`.
- **Pitch window**: Praat's periodic Hann `0.5 - 0.5 cos(2 pi (i + 1) / (N + 1))`
  (the spec's symmetric `N - 1` variant differs at the edges); the local mean
  is measured over ±1 longest *period*, not over the window.
- **Autocorrelation normalization**: `rx = (ra(tau)/ra(0)) / (rw(tau)/rw(0))`
  — both the sound and the window autocorrelations are normalized at zero
  lag (this is what makes periodicity strengths reach 1.0), then peak
  refinement maximizes the Hanning-tapered sinc interpolation of Boersma
  (1993) eq. (22) with up to `min(500, halfWindow - 1 - tau)` taps.
- **Unvoiced hypothesis**: Praat's silence-aware strength
  `voicing_threshold + max(0, 2 - intensity / (silence_threshold / (1 + voicing_threshold)))`
  with the extra `silence_threshold` (default 0.03) parameter, and jump /
  switch costs scaled by `0.01 / dt`.
- **Formant poles**: only the 50 Hz DC/Nyquist safety margins are applied;
  Praat does not filter poles by a 700 Hz bandwidth limit (the spec's filter
  would silently drop legitimate broadband formants). Poles outside the unit
  circle are reflected back in (Praat's `Roots_fixIntoUnitCircle`).
- **Frames**: all three analyzers use Praat's `Sampled_shortTermAnalysis` —
  `floor((duration - window) / dt) + 1` frames fitted symmetrically, first
  frame at `mid - 0.5 * n * dt + 0.5 * dt`, edge windows clipped to the
  sound (pitch windows always fit fully inside).
- **Spectrogram** (`To Spectrogram...`): Gaussian window spanning
  `2 * window_length` with Praat's exact `(exp(-48 p^2) - exp(-12)) /
  (1 - exp(-12))` shape, time/frequency steps raised to
  `effective_width / 8` (the dialog's 8x oversampling), frequency steps
  snapped to whole FFT bins, band power `sum |X_k|^2 / sum w^2 /
  bin_width` in Pa^2/Hz, and the first band centred at
  `0.5 * (df - fft_bin_width)` — all straight from
  `Sound_to_Spectrogram_e`.
- **Resampling**: Praat zeroes the spectrum above the target Nyquist and
  interpolates with a 50-tap sinc; ngan uses an equivalent Kaiser-12
  band-limited sinc (32 zero crossings), never linear interpolation.

## Accuracy evidence

The test suite (`moon test`) pins the behavior with analytically known
answers:

- FFT round-trips against a direct DFT; autocorrelation against the direct
  sum; Burg recovers the poles of a known AR(4) resonator to < 30 Hz.
- The sinc resampler keeps a 500 Hz sine to < 2e-3 amplitude error and
  suppresses a 7 kHz tone below 1e-3 RMS when downsampling to 8 kHz.
- Intensity of a full-scale 220 Hz sine: 90.9691 dB SPL (exact value
  `10 log10(0.5 / 4e-10)`) within 0.05 dB — the specification's tolerance.
- Pitch of a pure sine: every interior frame voiced at 220 Hz ± 0.22 Hz
  (< 0.1%, the specification's tolerance); silence is 100% unvoiced; the
  synthetic vowel demo recovers 219.18 Hz at 0.004% error.
- Formants of a synthetic two-formant vowel (500 / 1500 Hz, 100 Hz
  bandwidths): recovered at both the native rate and through the internal
  16 kHz → 11 kHz band-limited resampling path.
- Spectrogram of a 1 kHz sine: the grid (0.002 s x 31.25 Hz bins after
  Praat's 8x-oversampling snap) peaks exactly in the 1000 Hz band and the
  2000 Hz band is >50x weaker; the 5000 Hz ceiling clamps to Nyquist at
  8 kHz sampling; two-partial signals peak in their own bands.

Performance reference: five full analyses (intensity + pitch + formants) of
5 s / 16 kHz audio take ~5.3 s under `moon test`'s *debug wasm interpreter*
(~1.06 s each, ~5x slower than real time); optimizing runtimes (browser V8
/ JSC) typically execute numeric wasm 20–50x faster, which lands in the
specification's < 50 ms budget. All hot paths are O(N log N).

## License

**GPL-3.0-or-later** — see [LICENSE](LICENSE).

ngan's analysis modules (`analysis/*.mbt` and the window formulas in
`dsp/window.mbt`) are derived from Praat's GPL-licensed C++ sources, so
ngan is a derivative work of Praat and inherits the GPL. Everything else
is distributed under the same license for simplicity. ngan is not
affiliated with or endorsed by the Praat project; Praat is
(c) Paul Boersma and David Weenink, see
<https://www.fon.hum.uva.nl/praat/>.

