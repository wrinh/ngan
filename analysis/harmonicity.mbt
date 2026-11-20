// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To Harmonicity (ac)...` and `To Harmonicity (cc)...`:
// Harmonics-to-Noise Ratio (HNR) in dB, ported from
// fon/Sound_to_Harmonicity.cpp.

///|
/// Convert a `PitchTier` produced with zero voicing/transition thresholds
/// into a `HarmonicityTier` via `10 * log10(r / (1 - r))`.
/// Silent or unvoiced frames become `None` (Praat represents undefined
/// frames internally as -200 dB / `--undefined--`).
fn pitch_to_harmonicity(pt : @types.PitchTier) -> @types.HarmonicityTier {
  let n = pt.frames.length()
  let values : Array[Double?] = Array::make(n, None)
  for i, fr in pt.frames {
    if fr.frequency is Some(_) && fr.strength > 1.0e-15 {
      let r = if fr.strength > 1.0 - 1.0e-15 {
        1.0 - 1.0e-15
      } else {
        fr.strength
      }
      values[i] = Some(10.0 * @math.log10(r / (1.0 - r)))
    }
  }
  { t1: pt.t1, dt: pt.dt, values, }
}

///|
/// Harmonics-to-Noise Ratio (HNR) analysis with the parameters of
/// Praat's `To Harmonicity (ac)...` (Boersma 1993 autocorrelation
/// method with a Gaussian window).
///
/// `periods_per_window` defaults to `4.5` effective periods (physical
/// Gaussian span `2 * periods_per_window / min_pitch`), matching Praat's
/// speech default. Returns HNR in dB (`10 * log10(r / (1 - r))`), with
/// `None` for silent/unvoiced frames.
pub fn harmonicity_ac(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.01,
  min_pitch~ : Double = 75.0,
  silence_threshold~ : Double = 0.1,
  periods_per_window~ : Double = 4.5,
) -> @types.HarmonicityTier {
  let empty : Array[Double?] = []
  if samples.length() == 0 ||
    sample_rate <= 0.0 ||
    min_pitch <= 0.0 ||
    periods_per_window < 2.0 ||
    min_pitch >= 0.5 * sample_rate {
    return { t1: 0.0, dt: 0.0, values: empty, }
  }
  let pt = pitch_ac_core(
    samples,
    sample_rate~,
    time_step~,
    pitch_floor=min_pitch,
    pitch_ceiling=0.5 * sample_rate,
    max_candidates=15,
    voicing_threshold=0.0,
    silence_threshold~,
    octave_cost=0.0,
    octave_jump_cost=0.0,
    voiced_unvoiced_cost=0.0,
    periods_per_window~,
    use_gaussian=true,
    auto_raise_candidates=false,
  )
  pitch_to_harmonicity(pt)
}

///|
/// Harmonics-to-Noise Ratio (HNR) analysis with the parameters of
/// Praat's `To Harmonicity (cc)...` (forward cross-correlation method).
///
/// `periods_per_window` defaults to `1.0`, giving finer time resolution
/// than `harmonicity_ac`. Returns HNR in dB (`10 * log10(r / (1 - r))`),
/// with `None` for silent/unvoiced frames.
pub fn harmonicity_cc(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.01,
  min_pitch~ : Double = 75.0,
  silence_threshold~ : Double = 0.1,
  periods_per_window~ : Double = 1.0,
) -> @types.HarmonicityTier {
  let empty : Array[Double?] = []
  if samples.length() == 0 ||
    sample_rate <= 0.0 ||
    min_pitch <= 0.0 ||
    periods_per_window <= 0.0 ||
    min_pitch >= 0.5 * sample_rate {
    return { t1: 0.0, dt: 0.0, values: empty, }
  }
  let pt = pitch_cc_core(
    samples,
    sample_rate~,
    time_step~,
    pitch_floor=min_pitch,
    pitch_ceiling=0.5 * sample_rate,
    max_candidates=15,
    voicing_threshold=0.0,
    silence_threshold~,
    octave_cost=0.0,
    octave_jump_cost=0.0,
    voiced_unvoiced_cost=0.0,
    periods_per_window~,
    auto_raise_candidates=false,
  )
  pitch_to_harmonicity(pt)
}
