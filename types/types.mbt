// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

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

///|
/// Linearly interpolated intensity lookup at time `t` (dB SPL), clamping
/// half-frame margins to the boundary frames. Returns `None` when empty or
/// outside `[t1 - 0.5 * dt, t1 + (n - 0.5) * dt]`.
pub fn IntensityTier::value_at_linear(
  self : IntensityTier,
  t : Double,
) -> Double? {
  let n = self.values.length()
  if n == 0 || self.dt <= 0.0 {
    return None
  }
  let rf = (t - self.t1) / self.dt
  if rf < -0.5 || rf > (n - 1).to_double() + 0.5 {
    return None
  }
  let i0 = @math.floor_int(rf)
  let i1 = i0 + 1
  if i0 < 0 {
    return Some(self.values[0])
  }
  if i1 >= n {
    return Some(self.values[n - 1])
  }
  let frac = rf - i0.to_double()
  Some(self.values[i0] + frac * (self.values[i1] - self.values[i0]))
}

///|
/// Mean intensity (dB SPL) over `[tmin, tmax]` (or over the whole tier
/// when `tmax <= tmin`), matching Praat `Intensity: Get mean...`.
/// When `energy` is `true` (default), averages linear energy `10^(dB/10)`
/// before converting back to dB; otherwise averages dB values directly.
pub fn IntensityTier::mean(
  self : IntensityTier,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  energy~ : Bool = true,
) -> Double? {
  let n = self.values.length()
  if n == 0 {
    return None
  }
  let use_all = tmax <= tmin
  let mut sum = 0.0
  let mut count = 0
  for i in 0..<n {
    let t = self.t1 + i.to_double() * self.dt
    if use_all || (t >= tmin && t <= tmax) {
      let v = self.values[i]
      if energy {
        sum += @math.pow(10.0, v / 10.0)
      } else {
        sum += v
      }
      count += 1
    }
  }
  if count == 0 {
    if !use_all {
      return self.value_at_linear(0.5 * (tmin + tmax))
    }
    return None
  }
  if energy {
    let mean_e = sum / count.to_double()
    if mean_e <= 1.0e-30 {
      Some(-300.0)
    } else {
      Some(10.0 * @math.log10(mean_e))
    }
  } else {
    Some(sum / count.to_double())
  }
}

///|
fn formant_tier_interp_at(
  tier : FormantTier,
  formant_number : Int32,
  t : Double,
  pick : (FormantValue) -> Double,
) -> Double? {
  let n = tier.frames.length()
  if n == 0 || tier.dt <= 0.0 || formant_number < 1 {
    return None
  }
  let rf = (t - tier.t1) / tier.dt
  if rf < -0.5 || rf > (n - 1).to_double() + 0.5 {
    return None
  }
  let idx = formant_number - 1
  fn frame_val(fr : FormantFrame) -> Double? {
    if idx < fr.formants.length() {
      Some(pick(fr.formants[idx]))
    } else {
      None
    }
  }
  let i0 = @math.floor_int(rf)
  let i1 = i0 + 1
  if i0 < 0 {
    return frame_val(tier.frames[0])
  }
  if i1 >= n {
    return frame_val(tier.frames[n - 1])
  }
  let frac = rf - i0.to_double()
  match (frame_val(tier.frames[i0]), frame_val(tier.frames[i1])) {
    (Some(v0), Some(v1)) => Some(v0 + frac * (v1 - v0))
    (Some(v0), None) => if frac < 0.5 { Some(v0) } else { None }
    (None, Some(v1)) => if frac >= 0.5 { Some(v1) } else { None }
    (None, None) => None
  }
}

///|
/// Linearly interpolated frequency (Hz) for 1-based `formant_number`
/// (`1` = F1, `2` = F2, ...) at time `t`, matching Praat
/// `Formant: Get value at time... Linear`.
pub fn FormantTier::value_at(
  self : FormantTier,
  formant_number : Int32,
  t : Double,
) -> Double? {
  formant_tier_interp_at(self, formant_number, t, fv => fv.frequency)
}

///|
/// Linearly interpolated bandwidth (Hz) for 1-based `formant_number`
/// (`1` = F1, `2` = F2, ...) at time `t`, matching Praat
/// `Formant: Get bandwidth at time... Linear`.
pub fn FormantTier::bandwidth_at(
  self : FormantTier,
  formant_number : Int32,
  t : Double,
) -> Double? {
  formant_tier_interp_at(self, formant_number, t, fv => fv.bandwidth)
}

///|
/// Mean frequency (Hz) for 1-based `formant_number` (`1` = F1, `2` = F2,
/// ...) over `[tmin, tmax]` (or over the whole tier when `tmax <= tmin`).
pub fn FormantTier::mean(
  self : FormantTier,
  formant_number : Int32,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
) -> Double? {
  if formant_number < 1 {
    return None
  }
  let idx = formant_number - 1
  let use_all = tmax <= tmin
  let mut sum = 0.0
  let mut count = 0
  for fr in self.frames {
    if use_all || (fr.time >= tmin && fr.time <= tmax) {
      if idx < fr.formants.length() {
        sum += fr.formants[idx].frequency
        count += 1
      }
    }
  }
  if count > 0 {
    Some(sum / count.to_double())
  } else if !use_all {
    self.value_at(formant_number, 0.5 * (tmin + tmax))
  } else {
    None
  }
}

///|
/// Time-frequency grid of power spectral density values in Pa^2/Hz,
/// matching Praat's Spectrogram object: frames at `t1 + i * dt`,
/// frequency bands centred at `f1 + j * df`. The `power` array is
/// flattened band-major: index = band * number_of_time_frames + frame.
pub(all) struct Spectrogram {
  t1 : Double
  dt : Double
  number_of_time_frames : Int32
  /// Centre frequency of the first band (Hz).
  f1 : Double
  df : Double
  number_of_frequency_bands : Int32
  /// Power spectral density per band and frame (Pa^2/Hz).
  power : FixedArray[Double]
}

///|
/// Praat's Spectrogram "Get power at (time, frequency)"
/// (`Matrix_getValueAtXY`): bilinear interpolation in time and
/// frequency, `None` outside the grid.
pub fn Spectrogram::power_at(
  self : Spectrogram,
  t~ : Double,
  f~ : Double,
) -> Double? {
  let ntime = self.number_of_time_frames
  let nband = self.number_of_frequency_bands
  if ntime < 1 || nband < 1 || self.dt <= 0.0 || self.df <= 0.0 {
    return None
  }
  let rt = (t - self.t1) / self.dt
  let rf = (f - self.f1) / self.df
  if rt < 0.0 || rt > (ntime - 1).to_double() {
    return None
  }
  if rf < 0.0 || rf > (nband - 1).to_double() {
    return None
  }
  let f0i = rt.floor().to_int()
  let b0i = rf.floor().to_int()
  let fx = rt - f0i.to_double()
  let fy = rf - b0i.to_double()
  let f1i = if f0i + 1 <= ntime - 1 { f0i + 1 } else { f0i }
  let b1i = if b0i + 1 <= nband - 1 { b0i + 1 } else { b0i }
  let p00 = self.power[b0i * ntime + f0i]
  let p10 = self.power[b1i * ntime + f0i]
  let p01 = self.power[b0i * ntime + f1i]
  let p11 = self.power[b1i * ntime + f1i]
  let at_f0 = p00 * (1.0 - fy) + p10 * fy
  let at_f1 = p01 * (1.0 - fy) + p11 * fy
  Some(at_f0 * (1.0 - fx) + at_f1 * fx)
}

///|
/// The maximum power density over the whole grid (Praat's paint routines
/// reference their dynamic range to this).
pub fn Spectrogram::max_power(self : Spectrogram) -> Double {
  let mut best = 0.0
  for i in 0..<self.power.length() {
    if self.power[i] > best {
      best = self.power[i]
    }
  }
  best
}
