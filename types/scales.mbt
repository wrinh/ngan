// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Psychoacoustic frequency scale conversions (matching Praat's NUM2.cpp
// formulas) and PitchTier query / scale conversion helpers.

///|
/// Convert frequency in Hz to semitones relative to `reference_hz`
/// (Praat default 100 Hz): `12 * log2(hz / reference_hz)`.
/// Returns `0.0` when `hz <= 0.0` or `reference_hz <= 0.0`.
pub fn hz_to_semitones(hz : Double, reference_hz~ : Double = 100.0) -> Double {
  if hz > 0.0 && reference_hz > 0.0 {
    12.0 * @math.log2(hz / reference_hz)
  } else {
    0.0
  }
}

///|
/// Convert semitones relative to `reference_hz` back to Hz:
/// `reference_hz * 2^(semitones / 12)`.
pub fn semitones_to_hz(
  semitones : Double,
  reference_hz~ : Double = 100.0,
) -> Double {
  if reference_hz > 0.0 {
    reference_hz * @math.exp(semitones / 12.0 * @math.LN2)
  } else {
    0.0
  }
}

///|
/// Convert frequency in Hz to Praat's ERB-rate scale (`NUMhertzToErb`):
/// `11.17 * ln((hz + 312) / (hz + 14680)) + 43`.
pub fn hz_to_erb(hz : Double) -> Double {
  if hz < 0.0 {
    0.0
  } else {
    11.17 * @math.ln((hz + 312.0) / (hz + 14680.0)) + 43.0
  }
}

///|
/// Convert Praat's ERB-rate value back to frequency in Hz.
pub fn erb_to_hz(erb : Double) -> Double {
  let a = @math.exp((erb - 43.0) / 11.17)
  if a >= 1.0 {
    0.0
  } else {
    (14680.0 * a - 312.0) / (1.0 - a)
  }
}

///|
/// Convert frequency in Hz to Praat's Mel scale (`NUMhertzToMel`):
/// `550 * ln(1 + hz / 550)`.
pub fn hz_to_mel(hz : Double) -> Double {
  if hz < 0.0 {
    0.0
  } else {
    550.0 * @math.ln(1.0 + hz / 550.0)
  }
}

///|
/// Convert Praat's Mel scale value back to frequency in Hz:
/// `550 * (exp(mel / 550) - 1)`.
pub fn mel_to_hz(mel : Double) -> Double {
  550.0 * (@math.exp(mel / 550.0) - 1.0)
}

///|
/// Convert frequency in Hz to Praat's Bark scale (`NUMhertzToBark`):
/// `7 * ln(hz / 650 + sqrt(1 + (hz / 650)^2))`.
pub fn hz_to_bark(hz : Double) -> Double {
  if hz < 0.0 {
    0.0
  } else {
    let r = hz / 650.0
    7.0 * @math.ln(r + (1.0 + r * r).sqrt())
  }
}

///|
/// Convert Praat's Bark scale value back to frequency in Hz
/// (`NUMbarkToHertz`): `325 * (exp(bark / 7) - exp(-bark / 7))`.
pub fn bark_to_hz(bark : Double) -> Double {
  if bark < 0.0 {
    0.0
  } else {
    let e = @math.exp(bark / 7.0)
    325.0 * (e - 1.0 / e)
  }
}

///|
/// Interpolate pitch frequency (Hz) at time `t` (matching Praat's
/// `Pitch_getValueAtTime` linear interpolation between adjacent voiced
/// frames). Returns `None` outside the domain or in unvoiced intervals.
pub fn PitchTier::value_at(self : PitchTier, t : Double) -> Double? {
  let n = self.frames.length()
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
    return self.frames[0].frequency
  }
  if i1 >= n {
    return self.frames[n - 1].frequency
  }
  let frac = rf - i0.to_double()
  match (self.frames[i0].frequency, self.frames[i1].frequency) {
    (Some(f0), Some(f1)) => Some(f0 + frac * (f1 - f0))
    (Some(f0), None) => if frac < 0.5 { Some(f0) } else { None }
    (None, Some(f1)) => if frac >= 0.5 { Some(f1) } else { None }
    (None, None) => None
  }
}

///|
/// Mean fundamental frequency (Hz) over voiced frames within
/// `[tmin, tmax]` (or over the whole tier when `tmax <= tmin`), matching
/// Praat `Pitch: Get mean... Hertz`.
pub fn PitchTier::mean(
  self : PitchTier,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
) -> Double? {
  let use_all = tmax <= tmin
  let mut sum = 0.0
  let mut count = 0
  for fr in self.frames {
    if use_all || (fr.time >= tmin && fr.time <= tmax) {
      if fr.frequency is Some(f0) {
        sum += f0
        count += 1
      }
    }
  }
  if count > 0 {
    Some(sum / count.to_double())
  } else if !use_all {
    self.value_at(0.5 * (tmin + tmax))
  } else {
    None
  }
}

///|
/// Convert every voiced frame of `PitchTier` to semitones relative to
/// `reference_hz`, preserving `None` for unvoiced frames.
pub fn PitchTier::to_semitones(
  self : PitchTier,
  reference_hz~ : Double = 100.0,
) -> Array[Double?] {
  let out : Array[Double?] = Array::make(self.frames.length(), None)
  for i, fr in self.frames {
    if fr.frequency is Some(f) {
      out[i] = Some(hz_to_semitones(f, reference_hz~))
    }
  }
  out
}

///|
/// Convert every voiced frame of `PitchTier` to Praat ERB-rate,
/// preserving `None` for unvoiced frames.
pub fn PitchTier::to_erb(self : PitchTier) -> Array[Double?] {
  let out : Array[Double?] = Array::make(self.frames.length(), None)
  for i, fr in self.frames {
    if fr.frequency is Some(f) {
      out[i] = Some(hz_to_erb(f))
    }
  }
  out
}

///|
/// Convert every voiced frame of `PitchTier` to Praat Mel, preserving
/// `None` for unvoiced frames.
pub fn PitchTier::to_mel(self : PitchTier) -> Array[Double?] {
  let out : Array[Double?] = Array::make(self.frames.length(), None)
  for i, fr in self.frames {
    if fr.frequency is Some(f) {
      out[i] = Some(hz_to_mel(f))
    }
  }
  out
}

///|
/// Convert every voiced frame of `PitchTier` to Praat Bark, preserving
/// `None` for unvoiced frames.
pub fn PitchTier::to_bark(self : PitchTier) -> Array[Double?] {
  let out : Array[Double?] = Array::make(self.frames.length(), None)
  for i, fr in self.frames {
    if fr.frequency is Some(f) {
      out[i] = Some(hz_to_bark(f))
    }
  }
  out
}
