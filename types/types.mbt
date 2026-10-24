// Shared result data structures for the ngan acoustic analysis engine.
//
// Frame time convention: every analyzer tiles the sound with frames of
// spacing `dt` starting at time zero, and frame `i` is centered at
// `t1 + i * dt` with `t1 = 0.5 * dt`.

///|
/// One pitch measurement. `frequency` is `None` when the Viterbi path
/// chose the unvoiced hypothesis for this frame.
pub(all) struct PitchFrame {
  time : Double
  frequency : Double?
  /// Raw periodicity strength in [0, 1]; 0 for unvoiced frames.
  strength : Double
}

///|
/// One resonance: frequency in Hz and bandwidth in Hz.
pub(all) struct FormantValue {
  frequency : Double
  bandwidth : Double
}

///|
/// Formant measurements for one frame, sorted by ascending frequency
/// (F1, F2, F3, ...).
pub(all) struct FormantFrame {
  time : Double
  formants : Array[FormantValue]
}

///|
/// Evenly sampled intensity contour in dB SPL (reference pressure
/// 2e-5 Pa).
pub(all) struct IntensityTier {
  /// Time of the first frame in seconds.
  t1 : Double
  /// Frame spacing in seconds.
  dt : Double
  /// Intensity in dB for each frame.
  values : FixedArray[Double]
}

///|
/// Evenly sampled pitch track.
pub(all) struct PitchTier {
  t1 : Double
  dt : Double
  frames : Array[PitchFrame]
}

///|
/// Evenly sampled formant track.
pub(all) struct FormantTier {
  t1 : Double
  dt : Double
  frames : Array[FormantFrame]
}

///|
/// Combined result of one full acoustic analysis run.
pub(all) struct AcousticAnalysisResult {
  intensity_times : FixedArray[Double]
  intensity_values : FixedArray[Double]
  pitch_frames : Array[PitchFrame]
  formant_frames : Array[FormantFrame]
}

///|
/// Nearest-frame intensity lookup. Returns `None` when the tier is empty
/// or `t` falls outside its domain.
pub fn IntensityTier::value_at(self : IntensityTier, t : Double) -> Double? {
  let n = self.values.length()
  if n == 0 || self.dt <= 0.0 {
    return None
  }
  let idx = ((t - self.t1) / self.dt + 0.5).floor().to_int()
  if idx < 0 || idx >= n {
    return None
  }
  Some(self.values[idx])
}
