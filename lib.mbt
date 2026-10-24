// ngan — a Praat-compatible acoustic analysis engine in pure MoonBit,
// compiled to WebAssembly GC.
//
// This root package is the public facade: it re-exports the shared result
// types and the per-analysis entry points, and adds the simple positional
// ABI from the engine specification plus a combined `analyze_all`.
//
// Map to Praat commands:
// - `intensity`       <-> `To Intensity...`
// - `pitch`           <-> `To Pitch (ac)...`
// - `formants`        <-> `To Formant (burg)...`

///|
pub using @types {
  type PitchFrame,
  type FormantValue,
  type FormantFrame,
  type IntensityTier,
  type PitchTier,
  type FormantTier,
  type AcousticAnalysisResult,
}

///|
pub using @analysis {intensity, pitch, formants}

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
