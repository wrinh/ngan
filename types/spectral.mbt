// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Long-Term Average Spectrum (Ltas) and higher-order spectral feature
// result types.

///|
/// Long-Term Average Spectrum (Praat `Ltas`): uniformly spaced bins
/// centred at `f1 + i * df` in dB/Hz relative to 2e-5 Pa.
pub(all) struct Ltas {
  f1 : Double
  df : Double
  values : FixedArray[Double]
}

///|
/// Look up the LTAS bin value (dB/Hz) containing frequency `f` (Hz).
/// Returns `None` if the LTAS is empty or `f` falls outside its domain.
pub fn Ltas::value_at(self : Ltas, f : Double) -> Double? {
  let n = self.values.length()
  if n == 0 || self.df <= 0.0 {
    return None
  }
  let f_start = self.f1 - 0.5 * self.df
  let f_end = self.f1 + (n.to_double() - 0.5) * self.df
  if f < f_start || f > f_end {
    return None
  }
  let mut idx = @math.floor_int((f - f_start) / self.df)
  if idx < 0 {
    idx = 0
  } else if idx >= n {
    idx = n - 1
  }
  Some(self.values[idx])
}

///|
/// Mean spectral density (dB/Hz) over `[fmin, fmax]` (or over the whole
/// LTAS when `fmax <= fmin`). When `energy` is `true` (Praat default),
/// averages linear energy `10^(dB/10)` weighted by bin overlap before
/// converting back to dB; otherwise averages dB values directly.
pub fn Ltas::mean(
  self : Ltas,
  fmin~ : Double = 0.0,
  fmax~ : Double = 0.0,
  energy~ : Bool = true,
) -> Double? {
  let n = self.values.length()
  if n == 0 || self.df <= 0.0 {
    return None
  }
  let dom_lo = self.f1 - 0.5 * self.df
  let dom_hi = self.f1 + (n.to_double() - 0.5) * self.df
  let lo = if fmax <= fmin { dom_lo } else { fmin }
  let hi = if fmax <= fmin { dom_hi } else { fmax }
  let mut sum_val = 0.0
  let mut sum_w = 0.0
  for i in 0..<n {
    let b_lo = self.f1 + (i.to_double() - 0.5) * self.df
    let b_hi = self.f1 + (i.to_double() + 0.5) * self.df
    let o_lo = @math.dmax(b_lo, lo)
    let o_hi = @math.dmin(b_hi, hi)
    if o_hi > o_lo {
      let w = o_hi - o_lo
      if energy {
        sum_val += w * @math.pow(10.0, self.values[i] / 10.0)
      } else {
        sum_val += w * self.values[i]
      }
      sum_w += w
    }
  }
  if sum_w <= 0.0 {
    return None
  }
  if energy {
    let mean_e = sum_val / sum_w
    if mean_e <= 1.0e-30 {
      Some(-300.0)
    } else {
      Some(10.0 * @math.log10(mean_e))
    }
  } else {
    Some(sum_val / sum_w)
  }
}

///|
/// Praat `Ltas: Get slope...`: difference in dB between the mean level
/// of the high band and the low band (`mean(high) - mean(low)`).
/// Typically negative for human speech due to spectral tilt.
pub fn Ltas::slope(
  self : Ltas,
  fmin_low~ : Double = 0.0,
  fmax_low~ : Double = 1000.0,
  fmin_high~ : Double = 1000.0,
  fmax_high~ : Double = 4000.0,
  energy~ : Bool = true,
) -> Double? {
  match
    (
      self.mean(fmin=fmin_low, fmax=fmax_low, energy~),
      self.mean(fmin=fmin_high, fmax=fmax_high, energy~),
    ) {
    (Some(lo), Some(hi)) => Some(hi - lo)
    _ => None
  }
}

///|
/// Evenly sampled scalar spectral feature tier (such as per-frame
/// Center of Gravity in Hz or spectral slope in dB/kHz).
pub(all) struct SpectralFeatureTier {
  t1 : Double
  dt : Double
  values : FixedArray[Double]
}

///|
/// Nearest-frame lookup for `SpectralFeatureTier`. Returns `None` when
/// empty or `t` falls outside the domain.
pub fn SpectralFeatureTier::value_at(
  self : SpectralFeatureTier,
  t : Double,
) -> Double? {
  let n = self.values.length()
  if n == 0 || self.dt <= 0.0 {
    return None
  }
  let idx = @math.floor_int((t - self.t1) / self.dt + 0.5)
  if idx < 0 || idx >= n {
    return None
  }
  Some(self.values[idx])
}

///|
/// Voice quality / spectral tilt measurements at one frame:
/// harmonic amplitudes `h1`, `h2` (dB), `h1_minus_h2`, formant-corrected
/// `h1_minus_h2_corrected` (`H1*-H2*` via Iseli et al. 2007),
/// harmonic-to-formant amplitudes `h1_minus_a1..a3`, and `spectral_slope`
/// (dB/kHz).
pub(all) struct SpectralTiltFrame {
  time : Double
  f0 : Double?
  h1 : Double?
  h2 : Double?
  h1_minus_h2 : Double?
  h1_minus_h2_corrected : Double?
  h1_minus_a1 : Double?
  h1_minus_a2 : Double?
  h1_minus_a3 : Double?
  spectral_slope : Double?
}

///|
/// Evenly sampled spectral tilt and harmonic voice-quality contour.
pub(all) struct SpectralTiltTier {
  t1 : Double
  dt : Double
  frames : Array[SpectralTiltFrame]
}
