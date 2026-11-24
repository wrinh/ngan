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
  let rplan = @dsp.RealFftPlan::new(nfft)
  let frame_buf : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let log_spec : FixedArray[Double] = FixedArray::make(nq, 0.0)
  let cep_out : FixedArray[Double] = FixedArray::make(nq, 0.0)
  let power : FixedArray[Double] = FixedArray::make(nq * nframes, 0.0)
  let psd_scale = 1.0 / (windowssq * fs * nfft.to_double())
  for iframe in 0..<nframes {
    let t = t1 + iframe.to_double() * time_step
    let lo = low_index(t, fs)
    let start = lo + 1 - halfnsamp
    let mut mean = 0.0
    if start >= 0 && start + nwin <= n {
      for k in 0..<nwin {
        mean += data[start + k]
      }
      mean /= nwin.to_double()
      for k in 0..<nwin {
        frame_buf[k] = (data[start + k] - mean) * win[k]
      }
    } else {
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
        frame_buf[k] = v * win[k]
      }
    }
    rplan.forward_power(frame_buf, nwin, log_spec)
    for k in 0..<=half_nfft {
      let p = log_spec[k] * psd_scale
      log_spec[k] = @math.ln(if p > 1.0e-30 { p } else { 1.0e-30 })
    }
    rplan.inverse_real_even(log_spec, cep_out, nq)
    for q in 0..<nq {
      let c = cep_out[q]
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
/// In-place Hoare quickselect: places the `k`-th smallest element of
/// `a[0..<n]` at `a[k]`, with all `a[0..<k] <= a[k]`.
fn quickselect(a : FixedArray[Double], n : Int32, k : Int32) -> Double {
  let mut lo = 0
  let mut hi = n - 1
  while lo < hi {
    let mid = (lo + hi) / 2
    // Median-of-three pivot selection for O(N) performance on sorted/noisy inputs.
    if a[mid] < a[lo] {
      let t = a[lo]
      a[lo] = a[mid]
      a[mid] = t
    }
    if a[hi] < a[lo] {
      let t = a[lo]
      a[lo] = a[hi]
      a[hi] = t
    }
    if a[mid] < a[hi] {
      let t = a[mid]
      a[mid] = a[hi]
      a[hi] = t
    }
    let pivot = a[hi]
    let mut i = lo
    let mut j = hi - 1
    while true {
      while i <= j && a[i] < pivot {
        i += 1
      }
      while j >= i && a[j] > pivot {
        j -= 1
      }
      if i >= j {
        break
      }
      let t = a[i]
      a[i] = a[j]
      a[j] = t
      i += 1
      j -= 1
    }
    let t = a[i]
    a[i] = a[hi]
    a[hi] = t
    if k == i {
      return a[k]
    } else if k < i {
      hi = i - 1
    } else {
      lo = i + 1
    }
  }
  a[k]
}

///|
fn median_abs_buf(
  vals : FixedArray[Double],
  n : Int32,
  scratch : FixedArray[Double],
) -> Double {
  if n == 0 {
    return 0.0
  }
  for i in 0..<n {
    scratch[i] = @math.abs(vals[i])
  }
  let mid = n / 2
  let hi_val = quickselect(scratch, n, mid)
  if n % 2 == 1 {
    hi_val
  } else {
    let mut lo_val = scratch[0]
    for i in 1..<mid {
      if scratch[i] > lo_val {
        lo_val = scratch[i]
      }
    }
    0.5 * (lo_val + hi_val)
  }
}

///|
fn fit_linear_precomputed(
  xs : FixedArray[Double],
  ys : FixedArray[Double],
  n : Int32,
  sx : Double,
  ols_denom : Double,
  robust : Bool,
  res : FixedArray[Double],
  scratch : FixedArray[Double],
) -> (Double, Double)? {
  if n < 2 {
    return None
  }
  let mut sy = 0.0
  let mut sxy = 0.0
  for i in 0..<n {
    let y = ys[i]
    sy += y
    sxy += xs[i] * y
  }
  let nf = n.to_double()
  let mut a = 0.0
  let mut b = 0.0
  if @math.abs(ols_denom) <= 1.0e-30 {
    a = sy / nf
    b = 0.0
  } else {
    b = (nf * sxy - sx * sy) / ols_denom
    a = (sy - b * sx) / nf
  }
  if !robust {
    return Some((a, b))
  }
  for _ in 0..<5 {
    for i in 0..<n {
      res[i] = ys[i] - (a + b * xs[i])
    }
    let mad = median_abs_buf(res, n, scratch)
    let scale = mad / 0.6745
    if scale <= 1.0e-9 {
      break
    }
    let inv_cutoff = 1.0 / (4.685 * scale)
    let mut sw = 0.0
    let mut swx = 0.0
    let mut swy = 0.0
    let mut swxx = 0.0
    let mut swxy = 0.0
    for i in 0..<n {
      let u = @math.abs(res[i]) * inv_cutoff
      if u < 1.0 {
        let t = 1.0 - u * u
        let w = t * t
        let x = xs[i]
        let y = ys[i]
        let wx = w * x
        sw += w
        swx += wx
        swy += w * y
        swxx += wx * x
        swxy += wx * y
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
/// Subtraction-free O(N) boxcar mean over `[max(0, i - half), min(n - 1, i + half)]`
/// for a 1D slice. Uses a direct loop for small half-widths (`half <= 16`, the
/// common CPPS case) and van Herk / Gil-Werman block prefix+suffix sums for
/// larger windows, avoiding the catastrophic cancellation of cumulative
/// prefix-sum subtraction when values span many orders of magnitude.
fn boxcar_smooth_1d(
  line : FixedArray[Double],
  n : Int32,
  half : Int32,
  pref : FixedArray[Double],
  suff : FixedArray[Double],
  dst : FixedArray[Double],
) -> Unit {
  if half <= 16 {
    for i in 0..<n {
      let lo = if i - half < 0 { 0 } else { i - half }
      let hi = if i + half >= n { n - 1 } else { i + half }
      let mut sum = 0.0
      for k in lo..<=hi {
        sum += line[k]
      }
      dst[i] = sum / (hi - lo + 1).to_double()
    }
    return
  }
  let w = 2 * half + 1
  for i in 0..<n {
    pref[i] = if i % w == 0 { line[i] } else { pref[i - 1] + line[i] }
  }
  let mut i = n - 1
  while i >= 0 {
    suff[i] = if i == n - 1 || (i + 1) % w == 0 {
      line[i]
    } else {
      suff[i + 1] + line[i]
    }
    i -= 1
  }
  for idx in 0..<n {
    let lo = if idx - half < 0 { 0 } else { idx - half }
    let hi = if idx + half >= n { n - 1 } else { idx + half }
    let sum = if lo / w == hi / w {
      if lo % w == 0 {
        pref[hi]
      } else {
        suff[lo]
      }
    } else {
      suff[lo] + pref[hi]
    }
    dst[idx] = sum / (hi - lo + 1).to_double()
  }
}

///|
/// Smooth a quefrency-major `PowerCepstrogram` grid along time
/// (`time_half` frames) and quefrency (`q_half` bins) using subtraction-free
/// boxcar averaging matching Praat's `PowerCepstrogram_smooth`.
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
    if half_t <= 16 {
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
      let line : FixedArray[Double] = FixedArray::make(nt, 0.0)
      let pref : FixedArray[Double] = FixedArray::make(nt, 0.0)
      let suff : FixedArray[Double] = FixedArray::make(nt, 0.0)
      let dst : FixedArray[Double] = FixedArray::make(nt, 0.0)
      for q in 0..<nq {
        let row = q * nt
        for t in 0..<nt {
          line[t] = src[row + t]
        }
        boxcar_smooth_1d(line, nt, half_t, pref, suff, dst)
        for t in 0..<nt {
          tmp[row + t] = dst[t]
        }
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
  let col : FixedArray[Double] = FixedArray::make(nq, 0.0)
  let pref_q : FixedArray[Double] = FixedArray::make(
    if half_q > 16 {
      nq
    } else {
      0
    },
    0.0,
  )
  let suff_q : FixedArray[Double] = FixedArray::make(
    if half_q > 16 {
      nq
    } else {
      0
    },
    0.0,
  )
  let dst_q : FixedArray[Double] = FixedArray::make(nq, 0.0)
  for t in 0..<nt {
    for q in 0..<nq {
      col[q] = tmp[q * nt + t]
    }
    boxcar_smooth_1d(col, nq, half_q, pref_q, suff_q, dst_q)
    for q in 0..<nq {
      out[q * nt + t] = dst_q[q]
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
  // Precompute per-quefrency x values and fit indices once for all frames.
  let q_x_all : FixedArray[Double] = FixedArray::make(nq, 0.0)
  let q_valid_exp : FixedArray[Bool] = FixedArray::make(nq, false)
  let fit_idx_arr : Array[Int32] = []
  for q in 0..<nq {
    let qv = cepstrogram.q1 + q.to_double() * cepstrogram.dq
    if exp_decay {
      if qv > 0.0 {
        q_x_all[q] = @math.ln(qv)
        q_valid_exp[q] = true
      }
    } else {
      q_x_all[q] = qv
      q_valid_exp[q] = true
    }
    if qv >= fit_q_min && qv <= fit_q_max && (!exp_decay || qv > 0.0) {
      fit_idx_arr.push(q)
    }
  }
  let n_fit = fit_idx_arr.length()
  let fit_indices : FixedArray[Int32] = FixedArray::make(n_fit, 0)
  let fit_xs : FixedArray[Double] = FixedArray::make(n_fit, 0.0)
  let mut fit_sx = 0.0
  let mut fit_sxx = 0.0
  for i in 0..<n_fit {
    let q = fit_idx_arr[i]
    fit_indices[i] = q
    let xv = q_x_all[q]
    fit_xs[i] = xv
    fit_sx += xv
    fit_sxx += xv * xv
  }
  let ols_denom = n_fit.to_double() * fit_sxx - fit_sx * fit_sx
  let fit_ys : FixedArray[Double] = FixedArray::make(n_fit, 0.0)
  let fit_res : FixedArray[Double] = FixedArray::make(n_fit, 0.0)
  let fit_scratch : FixedArray[Double] = FixedArray::make(n_fit, 0.0)
  let work : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
  for i in 0..<(nq * nt) {
    work[i] = cepstrogram.power[i]
  }
  let col_db : FixedArray[Double] = FixedArray::make(nq, 0.0)
  let db_scale = 10.0 / @math.LN10
  let inv_db_scale = @math.LN10 / 10.0
  if subtract_tilt_before_smoothing {
    for t in 0..<nt {
      for q in 0..<nq {
        let p = work[q * nt + t]
        col_db[q] = db_scale * @math.ln(if p > 1.0e-30 { p } else { 1.0e-30 })
      }
      for i in 0..<n_fit {
        fit_ys[i] = col_db[fit_indices[i]]
      }
      if fit_linear_precomputed(
          fit_xs, fit_ys, n_fit, fit_sx, ols_denom, robust, fit_res, fit_scratch,
        )
        is Some((a, b)) {
        for q in 0..<nq {
          let trend = if exp_decay && !q_valid_exp[q] {
            a
          } else {
            a + b * q_x_all[q]
          }
          let detrended_db = col_db[q] - trend
          work[q * nt + t] = @math.exp(detrended_db * inv_db_scale)
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
      col_db[q] = db_scale * @math.ln(if p > 1.0e-30 { p } else { 1.0e-30 })
    }
    for i in 0..<n_fit {
      fit_ys[i] = col_db[fit_indices[i]]
    }
    guard fit_linear_precomputed(
        fit_xs, fit_ys, n_fit, fit_sx, ols_denom, robust, fit_res, fit_scratch,
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
