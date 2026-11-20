// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// ngan — a Praat-compatible acoustic analysis engine in pure MoonBit,
// compiled to WebAssembly GC.
//
// This root package is the public facade: it re-exports the shared result
// types and the per-analysis entry points, and adds the simple positional
// ABI from the engine specification plus a combined `analyze_all`.
//
// Map to Praat commands:
// - `intensity`          <-> `To Intensity...`
// - `pitch`              <-> `To Pitch (ac)...`
// - `pitch_cc`           <-> `To Pitch (cc)...`
// - `harmonicity_ac`     <-> `To Harmonicity (ac)...`
// - `harmonicity_cc`     <-> `To Harmonicity (cc)...`
// - `point_process_cc`   <-> `To PointProcess (periodic, cc)...`
// - `jitter` / `shimmer` <-> `Get jitter (...)` / `Get shimmer (...)`
// - `formants`           <-> `To Formant (burg)...`
// - `track_formants`     <-> `Formant: Track...`
// - `spectrogram`        <-> `To Spectrogram...`
// - `ltas`               <-> `To Ltas...`
// - `center_of_gravity`  <-> `Spectrum: Get centre of gravity...`

///|
pub using @types {
  type PitchFrame,
  type FormantValue,
  type FormantFrame,
  type IntensityTier,
  type PitchTier,
  type FormantTier,
  type Spectrogram,
  type AcousticAnalysisResult,
  type HarmonicityTier,
  type PointProcess,
  type JitterMetrics,
  type ShimmerMetrics,
  type Ltas,
  type SpectralFeatureTier,
  type SpectralTiltFrame,
  type SpectralTiltTier,
  hz_to_semitones,
  semitones_to_hz,
  hz_to_erb,
  erb_to_hz,
  hz_to_mel,
  mel_to_hz,
}

///|
pub using @analysis {
  intensity,
  pitch,
  pitch_cc,
  harmonicity_ac,
  harmonicity_cc,
  point_process_cc,
  sound_and_pitch_to_point_process_cc,
  jitter,
  shimmer,
  formants,
  track_formants,
  spectrogram,
  ltas,
  spectrogram_to_ltas,
  center_of_gravity,
  spectrogram_center_of_gravity,
  spectrogram_spectral_slope,
  spectral_tilt,
}

///|
/// Praat `To Intensity...` with defaults for everything except
/// `min_pitch` (default 100 Hz).
pub fn analyze_intensity(
  samples : FixedArray[Double],
  sample_rate : Double,
  min_pitch : Double,
) -> @types.IntensityTier {
  @analysis.intensity(samples, sample_rate~, min_pitch~)
}

///|
/// Praat `To Pitch (ac)...` with defaults for everything except the
/// pitch range (defaults 75 / 600 Hz).
pub fn analyze_pitch(
  samples : FixedArray[Double],
  sample_rate : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
) -> @types.PitchTier {
  @analysis.pitch(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
}

///|
/// Praat `To Formant (burg)...` with defaults for everything except the
/// formant count and ceiling (defaults 5 formants, 5500 Hz).
pub fn analyze_formants(
  samples : FixedArray[Double],
  sample_rate : Double,
  max_formants : Int32,
  max_formant_freq : Double,
) -> @types.FormantTier {
  @analysis.formants(
    samples,
    sample_rate~,
    max_num_formants=max_formants,
    max_formant_freq~,
  )
}

///|
/// Praat `To Spectrogram...` with defaults for everything except the
/// grid steps (defaults: 0.005 s Gaussian window, 5000 Hz ceiling,
/// 0.002 s time step, 20 Hz frequency step).
pub fn analyze_spectrogram(
  samples : FixedArray[Double],
  sample_rate : Double,
  window_length : Double,
  maximum_frequency : Double,
  time_step : Double,
  frequency_step : Double,
) -> @types.Spectrogram {
  @analysis.spectrogram(
    samples,
    sample_rate~,
    window_length~,
    maximum_frequency~,
    time_step~,
    frequency_step~,
  )
}

///|
/// Praat `To Pitch (cc)...` with defaults for everything except the
/// pitch range (defaults 75 / 600 Hz).
pub fn analyze_pitch_cc(
  samples : FixedArray[Double],
  sample_rate : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
) -> @types.PitchTier {
  @analysis.pitch_cc(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
}

///|
/// Praat `To Harmonicity (ac)...` with defaults for everything except
/// `min_pitch` (default 75 Hz).
pub fn analyze_harmonicity_ac(
  samples : FixedArray[Double],
  sample_rate : Double,
  min_pitch : Double,
) -> @types.HarmonicityTier {
  @analysis.harmonicity_ac(samples, sample_rate~, min_pitch~)
}

///|
/// Praat `To Harmonicity (cc)...` with defaults for everything except
/// `min_pitch` (default 75 Hz).
pub fn analyze_harmonicity_cc(
  samples : FixedArray[Double],
  sample_rate : Double,
  min_pitch : Double,
) -> @types.HarmonicityTier {
  @analysis.harmonicity_cc(samples, sample_rate~, min_pitch~)
}

///|
/// Praat `To Ltas...` with uniform bin width `bandwidth` (Hz).
pub fn analyze_ltas(
  samples : FixedArray[Double],
  sample_rate : Double,
  bandwidth : Double,
) -> @types.Ltas {
  @analysis.ltas(samples, sample_rate~, bandwidth~)
}

///|
/// Run intensity, pitch, and formant analysis in one pass and collect
/// everything into a single result set.
pub fn analyze_all(
  samples : FixedArray[Double],
  sample_rate : Double,
  min_pitch : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_formants : Int32,
  max_formant_freq : Double,
) -> @types.AcousticAnalysisResult {
  let it = analyze_intensity(samples, sample_rate, min_pitch)
  let pt = analyze_pitch(samples, sample_rate, pitch_floor, pitch_ceiling)
  let ft = analyze_formants(
    samples, sample_rate, max_formants, max_formant_freq,
  )
  let times : FixedArray[Double] = FixedArray::make(it.values.length(), 0.0)
  for i in 0..<times.length() {
    times[i] = it.t1 + i.to_double() * it.dt
  }
  {
    intensity_times: times,
    intensity_values: it.values,
    pitch_frames: pt.frames,
    formant_frames: ft.frames,
  }
}
