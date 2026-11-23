// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To PowerCepstrogram...` and `PowerCepstrogram: Get CPPS...`
// (Smoothed Cepstral Peak Prominence), ported from dwtools/Cepstrum.cpp
// and dwtools/Sound_and_Cepstrum.cpp.

///|
fn empty_power_cepstrogram() -> @types.PowerCepstrogram {
  {
    t1: 0.0,
    dt: 0.0,
    number_of_time_frames: 0,
    q1: 0.0,
    dq: 0.0,
    number_of_quefrency_bins: 0,
    power: FixedArray::make(0, 0.0),
  }
}

///|
/// Compute a Praat-compatible `PowerCepstrogram` from `samples`.
///
/// Resamples to `2 * min(maximum_frequency, fs / 2)`, applies optional
/// first-order pre-emphasis (`pre_emphasis_from`), windows each frame
/// with a Gaussian window spanning `6 / pitch_floor` s (effective length
/// `3 / pitch_floor`), and computes the squared real cepstrum of the log
/// power spectrum via forward + inverse FFT.
pub fn power_cepstrogram(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pitch_floor~ : Double = 60.0,
  time_step~ : Double = 0.002,
  maximum_frequency~ : Double = 5000.0,
  pre_emphasis_from~ : Double = 50.0,
) -> @types.PowerCepstrogram {
  let nx = samples.length()
  if nx == 0 ||
    sample_rate <= 0.0 ||
    pitch_floor <= 0.0 ||
    time_step <= 0.0 ||
    maximum_frequency <= 0.0 {
    return empty_power_cepstrogram()
  }
  let nyquist_in = 0.5 * sample_rate
  let fmax = @math.dmin(maximum_frequency, nyquist_in)
  let target_fs = 2.0 * fmax
  let same_rate = @math.abs(sample_rate - target_fs) < 1.0e-9 * sample_rate
  let data : FixedArray[Double] = if same_rate {
    let copy = FixedArray::make(nx, 0.0)
    for i in 0..<nx {
      copy[i] = samples[i]
    }
    copy
  } else {
    @dsp.sinc_resample(samples, ratio=target_fs / sample_rate)
  }
  let fs = if same_rate { sample_rate } else { target_fs }
  let n = data.length()
  if n < 4 {
    return empty_power_cepstrogram()
  }
  if pre_emphasis_from > 0.0 {
    let alpha = @math.exp(-2.0 * @math.PI * pre_emphasis_from / fs)
    let mut i = n - 1
    while i >= 1 {
      data[i] -= alpha * data[i - 1]
      i -= 1
    }
  }
  let w_phys = 6.0 / pitch_floor
  let halfnsamp = @math.floor_int(w_phys * fs) / 2
  let nwin = halfnsamp * 2
  if halfnsamp < 2 || nwin < 4 {
    return empty_power_cepstrogram()
  }
  let dur = n.to_double() / fs
  guard short_term_analysis(dur, nwin.to_double() / fs, time_step) is Some(sa) else {
    return empty_power_cepstrogram()
  }
  let (nframes, t1) = sa
  let win = @dsp.gaussian_window(nwin)
  let mut windowssq = 0.0
  for i in 0..<nwin {
    windowssq += win[i] * win[i]
  }
  if windowssq <= 0.0 {
    return empty_power_cepstrogram()
  }
  let min_q_samples = @math.ceil_int(2.0 * fs / pitch_floor) + 4
  let min_len = if nwin > min_q_samples { nwin } else { min_q_samples }
  let raw_nfft = @dsp.next_pow2(min_len)
  let nfft = if raw_nfft < 512 { 512 } else { raw_nfft }
  let half_nfft = nfft / 2
  let nq = half_nfft + 1
  let dq = 1.0 / fs
  let plan = @dsp.FftPlan::new(nfft)
  let re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let log_re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let log_im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let power : FixedArray[Double] = FixedArray::make(nq * nframes, 0.0)
  let psd_scale = 1.0 / (windowssq * fs * nfft.to_double())
  for iframe in 0..<nframes {
    let t = t1 + iframe.to_double() * time_step
    let lo = low_index(t, fs)
    let start = lo + 1 - halfnsamp
    let mut mean = 0.0
    let mut count = 0
    for k in 0..<nwin {
      let idx = start + k
      if idx >= 0 && idx < n {
        mean += data[idx]
        count += 1
      }
    }
    if count > 0 {
      mean /= count.to_double()
    }
    for k in 0..<nwin {
      let idx = start + k
      let v = if idx >= 0 && idx < n { data[idx] - mean } else { 0.0 }
      re[k] = v * win[k]
      im[k] = 0.0
    }
    for k in nwin..<nfft {
      re[k] = 0.0
      im[k] = 0.0
    }
    plan.transform(re, im, inverse=false)
    for k in 0..<=half_nfft {
      let p = (re[k] * re[k] + im[k] * im[k]) * psd_scale
      let lp = @math.ln(if p > 1.0e-30 { p } else { 1.0e-30 })
      log_re[k] = lp
      log_im[k] = 0.0
      if k > 0 && k < half_nfft {
        log_re[nfft - k] = lp
        log_im[nfft - k] = 0.0
      }
    }
    plan.transform(log_re, log_im, inverse=true)
    for q in 0..<nq {
      let c = log_re[q]
      power[q * nframes + iframe] = c * c
    }
  }
  {
    t1,
    dt: time_step,
    number_of_time_frames: nframes,
    q1: 0.0,
    dq,
    number_of_quefrency_bins: nq,
    power,
  }
}

///|
fn fit_linear_ols(xs : Array[Double], ys : Array[Double]) -> (Double, Double)? {
  let n = xs.length()
  if n < 2 {
    return None
  }
  let mut sx = 0.0
  let mut sy = 0.0
  let mut sxx = 0.0
  let mut sxy = 0.0
  for i in 0..<n {
    let x = xs[i]
    let y = ys[i]
    sx += x
    sy += y
    sxx += x * x
    sxy += x * y
  }
  let nf = n.to_double()
  let denom = nf * sxx - sx * sx
  if @math.abs(denom) <= 1.0e-30 {
    return Some((sy / nf, 0.0))
  }
  let b = (nf * sxy - sx * sy) / denom
  let a = (sy - b * sx) / nf
  Some((a, b))
}

///|
fn median_abs(vals : Array[Double]) -> Double {
  let n = vals.length()
  if n == 0 {
    return 0.0
  }
  let copy : Array[Double] = []
  for v in vals {
    copy.push(@math.abs(v))
  }
  copy.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  if n % 2 == 1 {
    copy[n / 2]
  } else {
    0.5 * (copy[n / 2 - 1] + copy[n / 2])
  }
}

///|
fn fit_linear_robust(
  xs : Array[Double],
  ys : Array[Double],
) -> (Double, Double)? {
  guard fit_linear_ols(xs, ys) is Some((a0, b0)) else { return None }
  let n = xs.length()
  let mut a = a0
  let mut b = b0
  let res : Array[Double] = Array::make(n, 0.0)
  for _ in 0..<5 {
    for i in 0..<n {
      res[i] = ys[i] - (a + b * xs[i])
    }
    let mad = median_abs(res)
    let scale = mad / 0.6745
    if scale <= 1.0e-9 {
      break
    }
    let cutoff = 4.685 * scale
    let mut sw = 0.0
    let mut swx = 0.0
    let mut swy = 0.0
    let mut swxx = 0.0
    let mut swxy = 0.0
    for i in 0..<n {
      let u = @math.abs(res[i]) / cutoff
      if u < 1.0 {
        let t = 1.0 - u * u
        let w = t * t
        let x = xs[i]
        let y = ys[i]
        sw += w
        swx += w * x
        swy += w * y
        swxx += w * x * x
        swxy += w * x * y
      }
    }
    let denom = sw * swxx - swx * swx
    if sw <= 1.0e-12 || @math.abs(denom) <= 1.0e-30 {
      break
    }
    b = (sw * swxy - swx * swy) / denom
    a = (swy - b * swx) / sw
  }
  Some((a, b))
}

///|
fn fit_cepstral_tilt(
  db_col : FixedArray[Double],
  q1 : Double,
  dq : Double,
  q_min : Double,
  q_max : Double,
  exponential_decay : Bool,
  robust : Bool,
) -> (Double, Double)? {
  let nq = db_col.length()
  let xs : Array[Double] = []
  let ys : Array[Double] = []
  for i in 0..<nq {
    let q = q1 + i.to_double() * dq
    if q >= q_min && q <= q_max {
      if exponential_decay {
        if q > 0.0 {
          xs.push(@math.ln(q))
          ys.push(db_col[i])
        }
      } else {
        xs.push(q)
        ys.push(db_col[i])
      }
    }
  }
  if robust {
    fit_linear_robust(xs, ys)
  } else {
    fit_linear_ols(xs, ys)
  }
}

///|
/// Smooth a quefrency-major `PowerCepstrogram` grid in place along time
/// (`time_half` frames) and quefrency (`q_half` bins) using a boxcar
/// average matching Praat's `PowerCepstrogram_smooth`.
fn smooth_cepstral_grid(
  src : FixedArray[Double],
  nq : Int32,
  nt : Int32,
  n_smooth_t : Int32,
  n_smooth_q : Int32,
) -> FixedArray[Double] {
  let tmp : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
  let half_t = n_smooth_t / 2
  if half_t > 0 {
    for q in 0..<nq {
      let row = q * nt
      for t in 0..<nt {
        let lo = if t - half_t < 0 { 0 } else { t - half_t }
        let hi = if t + half_t >= nt { nt - 1 } else { t + half_t }
        let mut sum = 0.0
        for k in lo..<=hi {
          sum += src[row + k]
        }
        tmp[row + t] = sum / (hi - lo + 1).to_double()
      }
    }
  } else {
    for i in 0..<(nq * nt) {
      tmp[i] = src[i]
    }
  }
  let half_q = n_smooth_q / 2
  if half_q <= 0 {
    return tmp
  }
  let out : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
  for t in 0..<nt {
    for q in 0..<nq {
      let lo = if q - half_q < 0 { 0 } else { q - half_q }
      let hi = if q + half_q >= nq { nq - 1 } else { q + half_q }
      let mut sum = 0.0
      for k in lo..<=hi {
        sum += tmp[k * nt + t]
      }
      out[q * nt + t] = sum / (hi - lo + 1).to_double()
    }
  }
  out
}

///|
/// Compute Smoothed Cepstral Peak Prominence (`CPPS`, in dB) from a
/// `PowerCepstrogram`, matching Praat's `PowerCepstrogram: Get CPPS...`.
pub fn cpps(
  cepstrogram : @types.PowerCepstrogram,
  subtract_tilt_before_smoothing~ : Bool = true,
  time_averaging_window~ : Double = 0.01,
  quefrency_averaging_window~ : Double = 0.001,
  peak_search_pitch_floor~ : Double = 60.0,
  peak_search_pitch_ceiling~ : Double = 330.0,
  tolerance~ : Double = 0.05,
  interpolation~ : String = "parabolic",
  tilt_line_quefrency_min~ : Double = 0.001,
  tilt_line_quefrency_max~ : Double = 0.0,
  line_type~ : String = "straight",
  fit_method~ : String = "robust",
) -> Double? {
  ignore(tolerance)
  let nt = cepstrogram.number_of_time_frames
  let nq = cepstrogram.number_of_quefrency_bins
  if nt < 1 ||
    nq < 3 ||
    cepstrogram.dt <= 0.0 ||
    cepstrogram.dq <= 0.0 ||
    peak_search_pitch_floor <= 0.0 ||
    peak_search_pitch_ceiling <= peak_search_pitch_floor {
    return None
  }
  let q_end = cepstrogram.q1 + (nq - 1).to_double() * cepstrogram.dq
  let fit_q_min = @math.dmax(tilt_line_quefrency_min, cepstrogram.dq)
  let fit_q_max = if tilt_line_quefrency_max > fit_q_min {
    @math.dmin(tilt_line_quefrency_max, q_end)
  } else {
    q_end
  }
  let exp_decay = line_type == "exponential_decay"
  let robust = fit_method != "least_squares"
  let work : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
  for i in 0..<(nq * nt) {
    work[i] = cepstrogram.power[i]
  }
  let col_db : FixedArray[Double] = FixedArray::make(nq, 0.0)
  if subtract_tilt_before_smoothing {
    for t in 0..<nt {
      for q in 0..<nq {
        let p = work[q * nt + t]
        col_db[q] = 10.0 * @math.log10(if p > 1.0e-30 { p } else { 1.0e-30 })
      }
      if fit_cepstral_tilt(
          col_db,
          cepstrogram.q1,
          cepstrogram.dq,
          fit_q_min,
          fit_q_max,
          exp_decay,
          robust,
        )
        is Some((a, b)) {
        for q in 0..<nq {
          let qv = cepstrogram.q1 + q.to_double() * cepstrogram.dq
          let x = if exp_decay && qv > 0.0 { @math.ln(qv) } else { qv }
          let trend = if exp_decay && qv <= 0.0 { a } else { a + b * x }
          let detrended_db = col_db[q] - trend
          work[q * nt + t] = @math.pow(10.0, detrended_db / 10.0)
        }
      }
    }
  }
  let n_smooth_t = if time_averaging_window > 0.0 {
    @math.round_int(time_averaging_window / cepstrogram.dt)
  } else {
    0
  }
  let n_smooth_q = if quefrency_averaging_window > 0.0 {
    @math.round_int(quefrency_averaging_window / cepstrogram.dq)
  } else {
    0
  }
  let smoothed = smooth_cepstral_grid(work, nq, nt, n_smooth_t, n_smooth_q)
  let q_search_min = 1.0 / peak_search_pitch_ceiling
  let q_search_max = 1.0 / peak_search_pitch_floor
  let mut i_lo = @math.ceil_int(
    (q_search_min - cepstrogram.q1) / cepstrogram.dq,
  )
  let mut i_hi = @math.floor_int(
    (q_search_max - cepstrogram.q1) / cepstrogram.dq,
  )
  if i_lo < 1 {
    i_lo = 1
  }
  if i_hi > nq - 2 {
    i_hi = nq - 2
  }
  if i_hi < i_lo {
    return None
  }
  let use_parabolic = interpolation != "none"
  let mut cpp_sum = 0.0
  let mut cpp_count = 0
  for t in 0..<nt {
    for q in 0..<nq {
      let p = smoothed[q * nt + t]
      col_db[q] = 10.0 * @math.log10(if p > 1.0e-30 { p } else { 1.0e-30 })
    }
    guard fit_cepstral_tilt(
        col_db,
        cepstrogram.q1,
        cepstrogram.dq,
        fit_q_min,
        fit_q_max,
        exp_decay,
        robust,
      )
      is Some((a, b)) else {
      continue
    }
    let mut i_best = i_lo
    let mut v_best = col_db[i_lo]
    for q in (i_lo + 1)..<=i_hi {
      if col_db[q] > v_best {
        v_best = col_db[q]
        i_best = q
      }
    }
    let mut q_peak = cepstrogram.q1 + i_best.to_double() * cepstrogram.dq
    let mut db_peak = v_best
    if use_parabolic && i_best > 0 && i_best < nq - 1 {
      let ym = col_db[i_best - 1]
      let y0 = col_db[i_best]
      let yp = col_db[i_best + 1]
      if ym <= y0 && yp <= y0 {
        let d2 = ym - 2.0 * y0 + yp
        if d2 < 0.0 {
          let mut delta = 0.5 * (ym - yp) / d2
          if delta < -0.5 {
            delta = -0.5
          } else if delta > 0.5 {
            delta = 0.5
          }
          q_peak = cepstrogram.q1 +
            (i_best.to_double() + delta) * cepstrogram.dq
          db_peak = y0 - 0.25 * (ym - yp) * delta
        }
      }
    }
    let x_peak = if exp_decay && q_peak > 0.0 {
      @math.ln(q_peak)
    } else {
      q_peak
    }
    cpp_sum += db_peak - (a + b * x_peak)
    cpp_count += 1
  }
  if cpp_count > 0 {
    Some(cpp_sum / cpp_count.to_double())
  } else {
    None
  }
}
