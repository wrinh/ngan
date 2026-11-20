// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Higher-order spectral features:
// - Praat `Spectrum: Get centre of gravity...` (`center_of_gravity`)
// - Per-frame Spectrogram Center of Gravity and Spectral Slope
// - Harmonic voice quality & tilt (`H1-H2`, Iseli et al. 2007
//   formant-corrected `H1*-H2*`, `H1-A1..A3`, and spectral slope).

///|
/// Praat `Spectrum: Get centre of gravity...` over `[fmin, fmax]` (full
/// `[0, Nyquist]` when `fmax <= fmin`):
/// `sum f * |S(f)|^power / sum |S(f)|^power`.
///
/// Defaults to `power = 2.0` (power-weighted spectral centroid). Returns
/// `None` when the signal is empty, silent, or no FFT bins fall in
/// range.
pub fn center_of_gravity(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  power~ : Double = 2.0,
  fmin~ : Double = 0.0,
  fmax~ : Double = 0.0,
) -> Double? {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || power <= 0.0 {
    return None
  }
  let raw_nfft = @dsp.next_pow2(nx)
  let nfft = if raw_nfft < 2 { 2 } else { raw_nfft }
  let half = nfft / 2
  let re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  for i in 0..<nx {
    re[i] = samples[i]
  }
  let plan = @dsp.FftPlan::new(nfft)
  plan.transform(re, im, inverse=false)
  let nyquist = 0.5 * sample_rate
  let lo = if fmax <= fmin { 0.0 } else { fmin }
  let hi = if fmax <= fmin { nyquist } else { @math.dmin(fmax, nyquist) }
  let df = sample_rate / nfft.to_double()
  let mut sum_fw = 0.0
  let mut sum_w = 0.0
  for k in 0..<=half {
    let f = k.to_double() * df
    if f < lo || f > hi {
      continue
    }
    let mag2 = re[k] * re[k] + im[k] * im[k]
    let base_w = if power == 2.0 {
      mag2
    } else if power == 1.0 {
      mag2.sqrt()
    } else if mag2 > 0.0 {
      @math.pow(mag2, 0.5 * power)
    } else {
      0.0
    }
    let trap = if k == 0 || k == half { 0.5 } else { 1.0 }
    let w = base_w * trap
    sum_fw += f * w
    sum_w += w
  }
  if sum_w > 0.0 {
    Some(sum_fw / sum_w)
  } else {
    None
  }
}

///|
/// Per-frame Center of Gravity (Hz) from a `Spectrogram` over `[fmin,
/// fmax]` (all bands when `fmax <= fmin`), weighted by `power_density^(power / 2)`.
pub fn spectrogram_center_of_gravity(
  sg : @types.Spectrogram,
  power~ : Double = 2.0,
  fmin~ : Double = 0.0,
  fmax~ : Double = 0.0,
) -> @types.SpectralFeatureTier {
  let nt = sg.number_of_time_frames
  let nb = sg.number_of_frequency_bands
  if nt < 1 || nb < 1 || power <= 0.0 {
    return { t1: 0.0, dt: 0.0, values: FixedArray::make(0, 0.0), }
  }
  let use_all = fmax <= fmin
  let values : FixedArray[Double] = FixedArray::make(nt, 0.0)
  for fr in 0..<nt {
    let mut sum_fw = 0.0
    let mut sum_w = 0.0
    for b in 0..<nb {
      let f = sg.f1 + b.to_double() * sg.df
      if use_all || (f >= fmin && f <= fmax) {
        let p = sg.power[b * nt + fr]
        if p > 0.0 {
          let w = if power == 2.0 {
            p
          } else if power == 1.0 {
            p.sqrt()
          } else {
            @math.pow(p, 0.5 * power)
          }
          sum_fw += f * w
          sum_w += w
        }
      }
    }
    if sum_w > 0.0 {
      values[fr] = sum_fw / sum_w
    }
  }
  { t1: sg.t1, dt: sg.dt, values, }
}

///|
/// Per-frame spectral slope (dB/kHz) from a `Spectrogram`, fitted by
/// ordinary least-squares regression of `10 * log10(power)` against
/// frequency in kHz over `[fmin, fmax]` (all bands when `fmax <= fmin`).
pub fn spectrogram_spectral_slope(
  sg : @types.Spectrogram,
  fmin~ : Double = 50.0,
  fmax~ : Double = 4000.0,
) -> @types.SpectralFeatureTier {
  let nt = sg.number_of_time_frames
  let nb = sg.number_of_frequency_bands
  if nt < 1 || nb < 1 {
    return { t1: 0.0, dt: 0.0, values: FixedArray::make(0, 0.0), }
  }
  let use_all = fmax <= fmin
  let values : FixedArray[Double] = FixedArray::make(nt, 0.0)
  for fr in 0..<nt {
    let mut n = 0.0
    let mut sx = 0.0
    let mut sy = 0.0
    let mut sxx = 0.0
    let mut sxy = 0.0
    for b in 0..<nb {
      let f = sg.f1 + b.to_double() * sg.df
      if use_all || (f >= fmin && f <= fmax) {
        let p = sg.power[b * nt + fr]
        let p_safe = if p > 1.0e-30 { p } else { 1.0e-30 }
        let x = f / 1000.0
        let y = 10.0 * @math.log10(p_safe)
        n += 1.0
        sx += x
        sy += y
        sxx += x * x
        sxy += x * y
      }
    }
    let denom = n * sxx - sx * sx
    if n >= 2.0 && denom > 1.0e-30 {
      values[fr] = (n * sxy - sx * sy) / denom
    }
  }
  { t1: sg.t1, dt: sg.dt, values, }
}

///|
/// Locate the strongest spectral peak inside `[f_lo, f_hi]` with 3-point
/// parabolic refinement on `log10(pw)`, returning peak level in dB
/// relative to `norm_sq`.
fn peak_db_in_band(
  pw : FixedArray[Double],
  df_fft : Double,
  f_lo : Double,
  f_hi : Double,
  norm_sq : Double,
) -> Double? {
  let n = pw.length()
  if n == 0 || df_fft <= 0.0 || norm_sq <= 0.0 || f_hi < f_lo {
    return None
  }
  let mut k_lo = @math.floor_int(f_lo / df_fft)
  let mut k_hi = @math.ceil_int(f_hi / df_fft)
  if k_lo < 0 {
    k_lo = 0
  }
  if k_hi >= n {
    k_hi = n - 1
  }
  if k_hi < k_lo {
    return None
  }
  let mut k_best = k_lo
  let mut p_best = pw[k_lo]
  for k in (k_lo + 1)..<=k_hi {
    if pw[k] > p_best {
      p_best = pw[k]
      k_best = k
    }
  }
  if p_best <= 1.0e-300 {
    return None
  }
  let mut peak_log10 = @math.log10(p_best)
  if k_best > 0 && k_best < n - 1 {
    let pm = pw[k_best - 1]
    let pp = pw[k_best + 1]
    if pm > 1.0e-300 && pp > 1.0e-300 {
      let ym = @math.log10(pm)
      let y0 = peak_log10
      let yp = @math.log10(pp)
      if ym <= y0 && yp <= y0 {
        let d2 = ym - 2.0 * y0 + yp
        if d2 < 0.0 {
          let mut delta = 0.5 * (ym - yp) / d2
          if delta < -0.5 {
            delta = -0.5
          } else if delta > 0.5 {
            delta = 0.5
          }
          peak_log10 = y0 - 0.25 * (ym - yp) * delta
        }
      }
    }
  }
  Some(10.0 * (peak_log10 - @math.log10(norm_sq)))
}

///|
/// Iseli, Shue & Alwan (2007) single-formant vocal-tract transfer
/// magnitude correction in dB at frequency `f` due to pole `(fk, bk)`.
fn iseli_formant_boost_db(
  f : Double,
  fk : Double,
  bk : Double,
  fs : Double,
) -> Double {
  if f <= 0.0 || fk <= 0.0 || bk <= 0.0 || fs <= 0.0 {
    return 0.0
  }
  let r = @math.exp(-@math.PI * bk / fs)
  let r2 = r * r
  let w = 2.0 * @math.PI * f / fs
  let wk = 2.0 * @math.PI * fk / fs
  let num_base = 1.0 - 2.0 * r * @math.cos(wk) + r2
  let num = num_base * num_base
  let den = (1.0 - 2.0 * r * @math.cos(w - wk) + r2) *
    (1.0 - 2.0 * r * @math.cos(w + wk) + r2)
  if num > 1.0e-300 && den > 1.0e-300 {
    10.0 * @math.log10(num / den)
  } else {
    0.0
  }
}

///|
/// Compute per-frame harmonic voice-quality and spectral-tilt indicators
/// (`H1`, `H2`, `H1-H2`, Iseli et al. 2007 formant-corrected `H1*-H2*`,
/// `H1-A1`, `H1-A2`, `H1-A3`, and OLS `spectral_slope` in dB/kHz) aligned
/// to `pitch.frames`.
pub fn spectral_tilt(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pitch~ : @types.PitchTier,
  formants~ : @types.FormantTier? = None,
  window_length~ : Double = 0.025,
  slope_fmin~ : Double = 50.0,
  slope_fmax~ : Double = 4000.0,
) -> @types.SpectralTiltTier {
  let nx = samples.length()
  let nframes = pitch.frames.length()
  if nx == 0 || sample_rate <= 0.0 || nframes == 0 || window_length <= 0.0 {
    return { t1: 0.0, dt: 0.0, frames: [], }
  }
  let nyquist = 0.5 * sample_rate
  let frames : Array[@types.SpectralTiltFrame] = []
  let mut cached_nfft = 0
  let mut cached_plan : @dsp.FftPlan = @dsp.FftPlan::new(2)
  let mut cached_nwin = 0
  let mut cached_win : FixedArray[Double] = FixedArray::make(0, 0.0)
  let mut cached_norm_sq = 0.0
  for fi in 0..<nframes {
    let pfr = pitch.frames[fi]
    let t = pfr.time
    let w_dur = match pfr.frequency {
      Some(f0) =>
        if f0 > 0.0 {
          @math.dmax(window_length, 3.5 / f0)
        } else {
          window_length
        }
      None => window_length
    }
    let mut nwin = @math.floor_int(w_dur * sample_rate)
    if nwin > nx {
      nwin = nx
    }
    if nwin < 16 {
      nwin = if nx < 16 { nx } else { 16 }
    }
    if nwin != cached_nwin {
      cached_nwin = nwin
      cached_win = @dsp.hanning_window(nwin)
      let mut sum_w = 0.0
      for k in 0..<nwin {
        sum_w += cached_win[k]
      }
      cached_norm_sq = 0.25 * sum_w * sum_w
    }
    let raw_nfft = @dsp.next_pow2(2 * nwin)
    let nfft = if raw_nfft < 2048 { 2048 } else { raw_nfft }
    if nfft != cached_nfft {
      cached_nfft = nfft
      cached_plan = @dsp.FftPlan::new(nfft)
    }
    let centre = @math.round_int(t * sample_rate - 0.5)
    let mut start = centre - nwin / 2
    if start < 0 {
      start = 0
    }
    if start + nwin > nx {
      start = nx - nwin
    }
    let mut mean = 0.0
    for k in 0..<nwin {
      mean += samples[start + k]
    }
    mean /= nwin.to_double()
    let re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
    let im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
    for k in 0..<nwin {
      re[k] = (samples[start + k] - mean) * cached_win[k]
    }
    cached_plan.transform(re, im, inverse=false)
    let half = nfft / 2
    let pw : FixedArray[Double] = FixedArray::make(half + 1, 0.0)
    let mut max_pw = 0.0
    for k in 0..<=half {
      let p = re[k] * re[k] + im[k] * im[k]
      pw[k] = p
      if p > max_pw {
        max_pw = p
      }
    }
    if max_pw <= 1.0e-300 || cached_norm_sq <= 0.0 {
      frames.push({
        time: t,
        f0: pfr.frequency,
        h1: None,
        h2: None,
        h1_minus_h2: None,
        h1_minus_h2_corrected: None,
        h1_minus_a1: None,
        h1_minus_a2: None,
        h1_minus_a3: None,
        spectral_slope: None,
      })
      continue
    }
    let df_fft = sample_rate / nfft.to_double()
    // OLS spectral slope over [slope_fmin, min(slope_fmax, nyquist)].
    let s_lo = slope_fmin
    let s_hi = @math.dmin(slope_fmax, nyquist)
    let mut rn = 0.0
    let mut sx = 0.0
    let mut sy = 0.0
    let mut sxx = 0.0
    let mut sxy = 0.0
    if s_hi > s_lo {
      let mut k_lo = @math.ceil_int(s_lo / df_fft)
      if k_lo < 0 {
        k_lo = 0
      }
      let mut k_hi = @math.floor_int(s_hi / df_fft)
      if k_hi > half {
        k_hi = half
      }
      if k_hi >= k_lo {
        for k in k_lo..<=k_hi {
          let f = k.to_double() * df_fft
          let x = f / 1000.0
          let ratio = pw[k] / cached_norm_sq
          let y = 10.0 *
            @math.log10(if ratio > 1.0e-30 { ratio } else { 1.0e-30 })
          rn += 1.0
          sx += x
          sy += y
          sxx += x * x
          sxy += x * y
        }
      }
    }
    let s_denom = rn * sxx - sx * sx
    let spectral_slope = if rn >= 2.0 && s_denom > 1.0e-30 {
      Some((rn * sxy - sx * sy) / s_denom)
    } else {
      None
    }
    // Harmonic measurements on voiced frames.
    guard pfr.frequency is Some(f0) else {
      frames.push({
        time: t,
        f0: None,
        h1: None,
        h2: None,
        h1_minus_h2: None,
        h1_minus_h2_corrected: None,
        h1_minus_a1: None,
        h1_minus_a2: None,
        h1_minus_a3: None,
        spectral_slope,
      })
      continue
    }
    if f0 <= 0.0 || f0 >= nyquist {
      frames.push({
        time: t,
        f0: Some(f0),
        h1: None,
        h2: None,
        h1_minus_h2: None,
        h1_minus_h2_corrected: None,
        h1_minus_a1: None,
        h1_minus_a2: None,
        h1_minus_a3: None,
        spectral_slope,
      })
      continue
    }
    let delta = @math.dmax(0.1 * f0, 1.5 * df_fft)
    let h1 = peak_db_in_band(pw, df_fft, f0 - delta, f0 + delta, cached_norm_sq)
    let h2 = if 2.0 * f0 < nyquist {
      peak_db_in_band(
        pw,
        df_fft,
        2.0 * f0 - delta,
        2.0 * f0 + delta,
        cached_norm_sq,
      )
    } else {
      None
    }
    let h1_minus_h2 = match (h1, h2) {
      (Some(v1), Some(v2)) => Some(v1 - v2)
      _ => None
    }
    let mut h1_minus_h2_corrected : Double? = None
    let mut h1_minus_a1 : Double? = None
    let mut h1_minus_a2 : Double? = None
    let mut h1_minus_a3 : Double? = None
    fn formant_diff(
      idx : Int32,
      ff : @types.FormantFrame,
      v1 : Double,
    ) -> Double? {
      if ff.formants.length() > idx && ff.formants[idx].frequency < nyquist {
        let fn_k = ff.formants[idx].frequency
        let bw_k = @math.dmax(0.2 * fn_k, f0)
        if peak_db_in_band(
            pw,
            df_fft,
            @math.dmax(df_fft, fn_k - bw_k),
            @math.dmin(nyquist - df_fft, fn_k + bw_k),
            cached_norm_sq,
          )
          is Some(ak) {
          return Some(v1 - ak)
        }
      }
      None
    }
    if formants is Some(ft) && ft.frames.length() > 0 && ft.dt > 0.0 {
      let f_idx = @math.floor_int((t - ft.t1) / ft.dt + 0.5)
      if f_idx >= 0 && f_idx < ft.frames.length() {
        let ff = ft.frames[f_idx]
        if h1 is Some(v1) {
          h1_minus_a1 = formant_diff(0, ff, v1)
          h1_minus_a2 = formant_diff(1, ff, v1)
          h1_minus_a3 = formant_diff(2, ff, v1)
          if h2 is Some(v2) && ff.formants.length() >= 2 {
            let f1 = ff.formants[0].frequency
            let b1 = ff.formants[0].bandwidth
            let f2 = ff.formants[1].frequency
            let b2 = ff.formants[1].bandwidth
            let corr_h1 = v1 -
              iseli_formant_boost_db(f0, f1, b1, sample_rate) -
              iseli_formant_boost_db(f0, f2, b2, sample_rate)
            let corr_h2 = v2 -
              iseli_formant_boost_db(2.0 * f0, f1, b1, sample_rate) -
              iseli_formant_boost_db(2.0 * f0, f2, b2, sample_rate)
            h1_minus_h2_corrected = Some(corr_h1 - corr_h2)
          }
        }
      }
    }
    frames.push({
      time: t,
      f0: Some(f0),
      h1,
      h2,
      h1_minus_h2,
      h1_minus_h2_corrected,
      h1_minus_a1,
      h1_minus_a2,
      h1_minus_a3,
      spectral_slope,
    })
  }
  { t1: pitch.t1, dt: pitch.dt, frames, }
}
