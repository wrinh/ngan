// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To Pitch (ac)...`: Boersma (1993) autocorrelation pitch tracker.
// Ported from fon/Sound_to_Pitch.cpp (AC_HANNING method) and
// fon/Pitch.cpp (path finder).

///|
/// One path-finder hypothesis for a pitch frame.
priv struct PitchCand {
  voiced : Bool
  freq : Double // Hz; meaningful only when voiced
  log2_freq : Double // log2(freq); meaningful only when voiced
  strength : Double // refined window-normalized periodicity
}

///|
/// Boersma (1993) eq. (22): the continuous version of a sampled
/// autocorrelation, reconstructed with a Hanning-tapered `sin(x)/x`
/// interpolation over +-N samples where
/// `N = min(max_depth, half_window - 1 - floor(x))`. The autocorrelation is
/// even, so `r[-k] = r[k]`; at integer arguments the interpolation is
/// exact (every sinc argument except zero is integral).
///
/// Uses `sin(pi * (l + n - 1)) = (-1)^(n-1) * sin(pi * l)` together with a
/// 2nd-order Chebyshev cosine recurrence and 2x loop unrolling to eliminate
/// all per-tap libm trig calls and sign multiplications.
fn interp_lag(
  r : FixedArray[Double],
  x : Double,
  halfwin~ : Int32,
  max_depth~ : Int32,
) -> Double {
  let nl = @math.floor(x).to_int()
  let l = x - nl.to_double()
  let rr = 1.0 - l
  let r_len = r.length()
  if l < 1.0e-12 {
    let aidx = if nl < 0 { -nl } else { nl }
    return if aidx < r_len { r[aidx] } else { 0.0 }
  }
  if rr < 1.0e-12 {
    let np1 = nl + 1
    let aidx = if np1 < 0 { -np1 } else { np1 }
    return if aidx < r_len { r[aidx] } else { 0.0 }
  }
  let mut n_max = halfwin - 1 - nl
  if n_max > max_depth {
    n_max = max_depth
  }
  if n_max < 1 {
    n_max = 1
  }
  let n_max_d = n_max.to_double()
  let scale = 0.5 * @math.sin(@math.PI * l) / @math.PI
  let mut acc = 0.0
  // Left side: samples nl, nl-1, ..., nl+1-N at distance d = l + n - 1.
  let step_l = @math.PI / (l + n_max_d)
  let two_cs = 2.0 * @math.cos(step_l)
  let mut c_cur = @math.cos(l * step_l)
  let mut c_next = @math.cos((l + 1.0) * step_l)
  let mut d = l
  if nl >= 0 && nl < r_len {
    let n_pos = if n_max < nl + 1 { n_max } else { nl + 1 }
    let mut idx = nl
    let pairs = n_pos / 2
    for _ in 0..<pairs {
      let a = r[idx] * (1.0 + c_cur)
      let c2 = two_cs * c_next - c_cur
      let b = r[idx - 1] * (1.0 + c_next)
      let d1 = d + 1.0
      acc += (a * d1 - b * d) / (d * d1)
      c_cur = c2
      c_next = two_cs * c2 - c_next
      idx -= 2
      d += 2.0
    }
    let mut sign = 1.0
    if n_pos % 2 == 1 {
      acc += r[idx] * (1.0 + c_cur) / d
      let c2 = two_cs * c_next - c_cur
      c_cur = c_next
      c_next = c2
      d += 1.0
      sign = -1.0
    }
    let rem = n_max - n_pos
    if rem > 0 {
      let n_neg = if rem < r_len - 1 { rem } else { r_len - 1 }
      let mut aidx = 1
      for _ in 0..<n_neg {
        acc += sign * r[aidx] * (1.0 + c_cur) / d
        aidx += 1
        sign = -sign
        d += 1.0
        let c2 = two_cs * c_next - c_cur
        c_cur = c_next
        c_next = c2
      }
    }
  } else {
    let mut sign = 1.0
    for n in 1..<=n_max {
      let idx = nl + 1 - n
      let aidx = if idx < 0 { -idx } else { idx }
      if aidx < r_len {
        acc += sign * r[aidx] * (1.0 + c_cur) / d
      }
      sign = -sign
      d += 1.0
      let c2 = two_cs * c_next - c_cur
      c_cur = c_next
      c_next = c2
    }
  }
  // Right side: samples nl+1, ..., nl+N at distance d = (1 - l) + n - 1.
  let step_r = @math.PI / (rr + n_max_d)
  let two_csr = 2.0 * @math.cos(step_r)
  c_cur = @math.cos(rr * step_r)
  c_next = @math.cos((rr + 1.0) * step_r)
  d = rr
  if nl + 1 >= 0 && nl + 1 < r_len {
    let avail = r_len - 1 - nl
    let n_right = if n_max < avail { n_max } else { avail }
    let mut idx = nl + 1
    let pairs = n_right / 2
    for _ in 0..<pairs {
      let a = r[idx] * (1.0 + c_cur)
      let c2 = two_csr * c_next - c_cur
      let b = r[idx + 1] * (1.0 + c_next)
      let d1 = d + 1.0
      acc += (a * d1 - b * d) / (d * d1)
      c_cur = c2
      c_next = two_csr * c2 - c_next
      idx += 2
      d += 2.0
    }
    if n_right % 2 == 1 {
      acc += r[idx] * (1.0 + c_cur) / d
    }
  } else {
    let mut sign = 1.0
    for n in 1..<=n_max {
      let idx = nl + n
      if idx >= 0 && idx < r_len {
        acc += sign * r[idx] * (1.0 + c_cur) / d
      }
      sign = -sign
      d += 1.0
      let c2 = two_csr * c_next - c_cur
      c_cur = c_next
      c_next = c2
    }
  }
  acc * scale
}

///|
/// Refine an integer peak of the normalized autocorrelation using
/// tightly-bracketed Brent maximization on `[tau - 1, tau + 1]` (matching
/// Praat's `NUMimproveMaximum`), seeded from the free exact value at integer
/// `tau` and the 3-point parabolic estimate `tau + delta_init`. Returns
/// `(peak value, exact lag)`.
fn refine_peak(
  r : FixedArray[Double],
  tau : Int32,
  delta_init : Double,
  halfwin~ : Int32,
  max_depth~ : Int32,
) -> (Double, Double) {
  let cgold = 0.3819660112501051
  let tol = 1.0e-8
  let zeps = 1.0e-12
  let tau_d = tau.to_double()
  let mut a = tau_d - 1.0
  let mut b = tau_d + 1.0
  // Free exact evaluation at integer tau: interp_lag(r, tau) == r[tau].
  let ft = -r[tau]
  // First evaluation at parabolic estimate (clamped strictly inside (a, b)).
  let mut x1 = tau_d + delta_init
  if @math.abs(x1 - tau_d) < 1.0e-4 {
    x1 = tau_d + (if delta_init >= 0.0 { 0.02 } else { -0.02 })
  }
  if x1 <= a + 1.0e-5 {
    x1 = a + 1.0e-5
  } else if x1 >= b - 1.0e-5 {
    x1 = b - 1.0e-5
  }
  let f1 = -interp_lag(r, x1, halfwin~, max_depth~)
  // Order (x, fx) <= (w, fw) and pick a nearby 3rd point x2 to establish a
  // tight bracket around the peak before entering Brent's parabolic loop.
  let mut x = tau_d
  let mut fx = ft
  let mut w = x1
  let mut fw = f1
  if f1 < ft {
    x = x1
    fx = f1
    w = tau_d
    fw = ft
    if x > tau_d {
      a = tau_d
    } else {
      b = tau_d
    }
  } else if x1 > tau_d {
    b = x1
  } else {
    a = x1
  }
  let mut x2 = if f1 < ft {
    let step = x1 - tau_d
    let ext = if @math.abs(step) < 0.05 {
      if step >= 0.0 {
        0.05
      } else {
        -0.05
      }
    } else {
      0.5 * step
    }
    x1 + ext
  } else {
    tau_d - 0.5 * (x1 - tau_d)
  }
  if x2 <= a + 1.0e-5 {
    x2 = 0.5 * (a + x)
  } else if x2 >= b - 1.0e-5 {
    x2 = 0.5 * (x + b)
  }
  let f2 = -interp_lag(r, x2, halfwin~, max_depth~)
  let mut v = x2
  let mut fv = f2
  if f2 < fx {
    if x2 >= x {
      a = x
    } else {
      b = x
    }
    v = w
    fv = fw
    w = x
    fw = fx
    x = x2
    fx = f2
  } else {
    if x2 < x {
      if x2 > a {
        a = x2
      }
    } else if x2 < b {
      b = x2
    }
    if f2 < fw {
      v = w
      fv = fw
      w = x2
      fw = f2
    }
  }
  let mut e = b - a
  let mut d = x - w
  for _ in 0..<60 {
    let xm = 0.5 * (a + b)
    let tol1 = tol * @math.abs(x) + zeps
    let tol2 = 2.0 * tol1
    if @math.abs(x - xm) <= tol2 - 0.5 * (b - a) {
      break
    }
    let mut use_golden = true
    if @math.abs(e) > tol1 {
      let r_p = (x - w) * (fx - fv)
      let mut q_p = (x - v) * (fx - fw)
      let mut p_p = (x - v) * q_p - (x - w) * r_p
      q_p = 2.0 * (q_p - r_p)
      if q_p > 0.0 {
        p_p = -p_p
      } else {
        q_p = -q_p
      }
      let etemp = e
      e = d
      if @math.abs(p_p) < @math.abs(0.5 * q_p * etemp) &&
        p_p > q_p * (a - x) &&
        p_p < q_p * (b - x) {
        d = p_p / q_p
        let u_try = x + d
        if u_try - a < tol2 || b - u_try < tol2 {
          d = if xm - x >= 0.0 { tol1 } else { -tol1 }
        }
        use_golden = false
      }
    }
    if use_golden {
      e = if x >= xm { a - x } else { b - x }
      d = cgold * e
    }
    let u = if @math.abs(d) >= tol1 {
      x + d
    } else if d >= 0.0 {
      x + tol1
    } else {
      x - tol1
    }
    let fu = -interp_lag(r, u, halfwin~, max_depth~)
    if fu <= fx {
      if u >= x {
        a = x
      } else {
        b = x
      }
      v = w
      fv = fw
      w = x
      fw = fx
      x = u
      fx = fu
    } else {
      if u < x {
        a = u
      } else {
        b = u
      }
      if fu <= fw || w == x {
        v = w
        fv = fw
        w = u
        fw = fu
      } else if fu <= fv || v == x || v == w {
        v = u
        fv = fu
      }
    }
  }
  (-fx, x)
}

///|
/// Collect up to `keep_limit` strongest voiced pitch candidates from local
/// maxima of `rx` in `[minimum_lag, lag_limit)`. Uses parabolic peak heights
/// to prioritize candidates and skip sinc refinement on low-scoring peaks
/// that cannot enter the top `keep_limit` slots.
fn collect_voiced_candidates(
  rx : FixedArray[Double],
  minimum_lag : Int32,
  lag_limit : Int32,
  halfwin~ : Int32,
  max_depth~ : Int32,
  sample_rate~ : Double,
  voicing_threshold~ : Double,
  pitch_floor~ : Double,
  octave_cost~ : Double,
  keep_limit~ : Int32,
) -> Array[PitchCand] {
  // (is_short_lag, upper_score, lg, delta)
  let raw_peaks : Array[(Bool, Double, Int32, Double)] = []
  let thresh = 0.5 * voicing_threshold
  let log2_floor = @math.log2(pitch_floor)
  let log2_floor_over_fs = @math.log2(pitch_floor / sample_rate)
  let mut lg = minimum_lag
  while lg < lag_limit {
    let r0 = rx[lg]
    if r0 > thresh && r0 > rx[lg - 1] && r0 >= rx[lg + 1] {
      let rm = rx[lg - 1]
      let rp = rx[lg + 1]
      let dr = 0.5 * (rp - rm)
      let d2r = r0 - rm + (r0 - rp)
      if d2r > 0.0 {
        let delta = dr / d2r
        if delta > -1.0 && delta < 1.0 {
          let r_par_raw = r0 + 0.5 * dr * delta
          // Sharp peaks near half-integer lags (e.g. broadband pulse trains)
          // have sinc(0.5) = 2/pi ~ 0.637 at adjacent integer lags, so 3-point
          // parabolic interpolation can underestimate the true sinc peak by up
          // to ~0.5 * d2r at |delta| = 0.5 (and 0 at delta = 0). Scaling by
          // 1.2 * |delta| * d2r gives a tight curvature-aware upper bound that
          // never drops sharp half-integer peaks while pruning low sidelobes.
          let r_est = r_par_raw + 1.2 * @math.abs(delta) * d2r
          let r_upper = if r_est > 1.0 { 1.0 } else { r_est }
          let lag_opt = if octave_cost > 0.0 {
            lg.to_double() - 0.5
          } else {
            lg.to_double() + delta
          }
          let upper_score = if octave_cost == 0.0 {
            r_upper
          } else {
            r_upper - octave_cost * (log2_floor_over_fs + @math.log2(lag_opt))
          }
          // Short lags (< 8 samples) are always prioritized and never pruned
          // because Nyquist-adjacent peaks can have small discrete curvature.
          raw_peaks.push((lg < 8, upper_score, lg, delta))
        }
      }
    }
    lg += 1
  }
  let n_raw = raw_peaks.length()
  if n_raw > keep_limit {
    raw_peaks.sort_by(fn(p, q) {
      if p.0 != q.0 {
        if p.0 {
          -1
        } else {
          1
        }
      } else if p.1 > q.1 {
        -1
      } else if p.1 < q.1 {
        1
      } else {
        0
      }
    })
  }
  // Keep top `keep_limit` refined candidates in descending `score` order.
  // Each entry is (score, strength, freq, log2_freq).
  let top : Array[(Double, Double, Double, Double)] = []
  let margin = 0.15
  for i in 0..<n_raw {
    let (is_short, upper_score, peak_lg, delta) = raw_peaks[i]
    if !is_short && top.length() >= keep_limit {
      let cutoff = top[keep_limit - 1].0
      if upper_score < cutoff - margin {
        break
      }
    }
    let (r_val, lag) = refine_peak(rx, peak_lg, delta, halfwin~, max_depth~)
    if r_val > 0.0 && lag > 1.0 {
      let strength = if r_val > 1.0 { 1.0 / r_val } else { r_val }
      let freq = sample_rate / lag
      let log2_freq = @math.log2(freq)
      let score = if octave_cost == 0.0 {
        strength
      } else {
        strength - octave_cost * (log2_floor - log2_freq)
      }
      // Insertion into sorted top-k list (keep_limit is small, typically 1..15).
      if top.length() < keep_limit {
        top.push((score, strength, freq, log2_freq))
        let mut k = top.length() - 1
        while k > 0 && top[k].0 > top[k - 1].0 {
          let tmp = top[k - 1]
          top[k - 1] = top[k]
          top[k] = tmp
          k -= 1
        }
      } else if score > top[keep_limit - 1].0 {
        top[keep_limit - 1] = (score, strength, freq, log2_freq)
        let mut k = keep_limit - 1
        while k > 0 && top[k].0 > top[k - 1].0 {
          let tmp = top[k - 1]
          top[k - 1] = top[k]
          top[k] = tmp
          k -= 1
        }
      }
    }
  }
  let cands : Array[PitchCand] = [
    { voiced: false, freq: 0.0, log2_freq: 0.0, strength: 0.0, },
  ]
  for c in top {
    cands.push({ voiced: true, freq: c.2, log2_freq: c.3, strength: c.1, })
  }
  cands
}

///|
/// Praat's path-finder transition cost between two candidates.
fn transition_cost(
  c1 : PitchCand,
  c2 : PitchCand,
  octave_jump_cost~ : Double,
  voiced_unvoiced_cost~ : Double,
) -> Double {
  if c1.voiced && c2.voiced {
    octave_jump_cost * @math.abs(c1.log2_freq - c2.log2_freq)
  } else if c1.voiced != c2.voiced {
    voiced_unvoiced_cost
  } else {
    0.0
  }
}

///|
/// Run Praat's Viterbi pitch path search over per-frame candidate pools
/// and return the winning `PitchTier`. Uses an O(N * C) direct scan
/// when both transition costs are zero (as in `harmonicity_ac` and
/// `harmonicity_cc`).
fn solve_viterbi_pitch(
  all_cands : Array[Array[PitchCand]],
  all_unvoiced : FixedArray[Double],
  t1 : Double,
  dt : Double,
  pitch_ceiling~ : Double,
  octave_cost~ : Double,
  octave_jump_cost~ : Double,
  voiced_unvoiced_cost~ : Double,
) -> @types.PitchTier {
  let nframes = all_cands.length()
  let frames : Array[@types.PitchFrame] = []
  if nframes == 0 {
    return { t1, dt, frames, }
  }
  let log2_ceiling = @math.log2(pitch_ceiling)
  let chosen : FixedArray[Int32] = FixedArray::make(nframes, 0)
  if octave_jump_cost == 0.0 && voiced_unvoiced_cost == 0.0 {
    for fi in 0..<nframes {
      let cands = all_cands[fi]
      let mut best_j = 0
      let mut best_score = all_unvoiced[fi]
      for j2 in 1..<cands.length() {
        let score = cands[j2].strength -
          octave_cost * (log2_ceiling - cands[j2].log2_freq)
        if score > best_score {
          best_score = score
          best_j = j2
        }
      }
      chosen[fi] = best_j
    }
  } else {
    let paths : Array[FixedArray[Int32]] = []
    let mut prev_dp : FixedArray[Double] = FixedArray::make(0, 0.0)
    let octave_jump_cost_scaled = octave_jump_cost * 0.01 / dt
    let voiced_unvoiced_cost_scaled = voiced_unvoiced_cost * 0.01 / dt
    for fi in 0..<nframes {
      let cands = all_cands[fi]
      let nc = cands.length()
      let dp : FixedArray[Double] = FixedArray::make(nc, 0.0)
      let back : FixedArray[Int32] = FixedArray::make(nc, 0)
      if fi == 0 {
        for j2 in 0..<nc {
          dp[j2] = if cands[j2].voiced {
            cands[j2].strength -
            octave_cost * (log2_ceiling - cands[j2].log2_freq)
          } else {
            all_unvoiced[fi]
          }
        }
      } else {
        let prev_cands = all_cands[fi - 1]
        for j2 in 0..<nc {
          let local_cost = if cands[j2].voiced {
            cands[j2].strength -
            octave_cost * (log2_ceiling - cands[j2].log2_freq)
          } else {
            all_unvoiced[fi]
          }
          let mut best = prev_dp[0] -
            transition_cost(
              prev_cands[0],
              cands[j2],
              octave_jump_cost=octave_jump_cost_scaled,
              voiced_unvoiced_cost=voiced_unvoiced_cost_scaled,
            )
          let mut best_k = 0
          for k in 1..<prev_dp.length() {
            let v = prev_dp[k] -
              transition_cost(
                prev_cands[k],
                cands[j2],
                octave_jump_cost=octave_jump_cost_scaled,
                voiced_unvoiced_cost=voiced_unvoiced_cost_scaled,
              )
            if v > best {
              best = v
              best_k = k
            }
          }
          dp[j2] = best + local_cost
          back[j2] = best_k
        }
      }
      paths.push(back)
      prev_dp = dp
    }
    let mut best_j = 0
    for j in 1..<prev_dp.length() {
      if prev_dp[j] > prev_dp[best_j] {
        best_j = j
      }
    }
    chosen[nframes - 1] = best_j
    let mut i = nframes - 1
    while i > 0 {
      chosen[i - 1] = paths[i][chosen[i]]
      i -= 1
    }
  }
  for i in 0..<nframes {
    let c = all_cands[i][chosen[i]]
    let f = if c.voiced { Some(c.freq) } else { None }
    frames.push({
      time: t1 + i.to_double() * dt,
      frequency: f,
      strength: @math.clamp01(c.strength),
    })
  }
  { t1, dt, frames, }
}

///|
/// Shared autocorrelation pitch/harmonicity core supporting both Praat's
/// AC_HANNING (`periods_per_window = 3.0`, `use_gaussian = false`) and
/// AC_GAUSS (`periods_per_window = 4.5` effective / `9.0` physical,
/// `use_gaussian = true`).
fn pitch_ac_core(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double,
  pitch_floor~ : Double,
  pitch_ceiling~ : Double,
  max_candidates~ : Int32,
  voicing_threshold~ : Double,
  silence_threshold~ : Double,
  octave_cost~ : Double,
  octave_jump_cost~ : Double,
  voiced_unvoiced_cost~ : Double,
  periods_per_window~ : Double,
  use_gaussian~ : Bool,
  auto_raise_candidates~ : Bool,
) -> @types.PitchTier {
  let empty : Array[@types.PitchFrame] = []
  let nx = samples.length()
  if nx == 0 ||
    sample_rate <= 0.0 ||
    pitch_floor <= 0.0 ||
    pitch_ceiling <= pitch_floor ||
    periods_per_window <= 0.0 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let dt = if time_step > 0.0 {
    time_step
  } else {
    periods_per_window / pitch_floor / 4.0
  }
  let physical_periods = if use_gaussian {
    2.0 * periods_per_window
  } else {
    periods_per_window
  }
  // Even window length, like Praat: halfnsamp = nsamp/2 - 1.
  let nw_raw = @math.floor_int(physical_periods / pitch_floor * sample_rate)
  let halfnsamp = nw_raw / 2 - 1
  if halfnsamp < 2 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let nwin = halfnsamp * 2
  let win = if use_gaussian {
    @dsp.gaussian_window(nwin)
  } else {
    @dsp.hanning_window(nwin)
  }
  let halfwin = nwin / 2
  // Lags: Praat's minimumLag / maximumLag / brent_ixmax.
  let mut minimum_lag = @math.floor_int(sample_rate / pitch_ceiling)
  if minimum_lag < 2 {
    minimum_lag = 2
  }
  let mut maximum_lag = @math.floor_int(nwin.to_double() / physical_periods) + 2
  if maximum_lag > nwin {
    maximum_lag = nwin
  }
  let brent_ixmax = halfwin
  if maximum_lag < minimum_lag + 2 || brent_ixmax < maximum_lag {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  // One longest period, used for the local mean and local peak.
  let nsamp_period = @math.floor_int(sample_rate / pitch_floor)
  let halfnsamp_period = nsamp_period / 2 + 1
  let dur = nx.to_double() / sample_rate
  guard short_term_analysis(dur, nwin.to_double() / sample_rate, dt) is Some(sa) else {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let (nframes, t1) = sa
  let mut maxn = if max_candidates > 2 { max_candidates } else { 2 }
  if auto_raise_candidates {
    let auto_raise = @math.floor_int(pitch_ceiling / pitch_floor)
    if maxn < auto_raise {
      maxn = auto_raise
    }
  }
  // Global absolute peak around the global mean (silence detection).
  let mut gmean = 0.0
  for i in 0..<nx {
    gmean += samples[i]
  }
  gmean /= nx.to_double()
  let mut global_peak = 0.0
  for i in 0..<nx {
    let v = @math.abs(samples[i] - gmean)
    if v > global_peak {
      global_peak = v
    }
  }
  if global_peak == 0.0 {
    // Absolute silence: every frame is voiceless.
    let frames : Array[@types.PitchFrame] = []
    for i in 0..<nframes {
      frames.push({
        time: t1 + i.to_double() * dt,
        frequency: None,
        strength: 0.0,
      })
    }
    return { t1, dt, frames, }
  }
  // Real-FFT plan and the window's normalized autocorrelation (constant).
  let nfft_raw = if use_gaussian {
    @dsp.next_pow2(nwin + brent_ixmax + 2)
  } else {
    @dsp.next_pow2(nwin * 3 / 2)
  }
  let nfft = if nfft_raw < 4 { 4 } else { nfft_raw }
  let rplan = @dsp.RealFftPlan::new(nfft)
  let wac : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  rplan.autocorrelation(win, nwin, wac, max_lag=brent_ixmax + 1)
  let inv_wac : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  inv_wac[0] = 1.0
  let wac0 = wac[0]
  if wac0 > 0.0 {
    for i in 1..<=(brent_ixmax + 1) {
      let wn = wac[i] / wac0
      if wn > 1.0e-10 {
        inv_wac[i] = 1.0 / wn
      }
    }
  }
  let frame : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let ra : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  let rx : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  let all_cands : Array[Array[PitchCand]] = []
  let all_unvoiced : FixedArray[Double] = FixedArray::make(nframes, 0.0)
  let keep_limit = if octave_jump_cost == 0.0 && voiced_unvoiced_cost == 0.0 {
    1
  } else {
    maxn - 1
  }
  let lag_limit = if maximum_lag < brent_ixmax {
    maximum_lag
  } else {
    brent_ixmax
  }
  for fi in 0..<nframes {
    let t = t1 + fi.to_double() * dt
    let lo = low_index(t, sample_rate)
    // Local mean over one longest period on both sides.
    let mut m_start = lo + 1 - nsamp_period
    let mut m_end = lo + nsamp_period
    if m_start < 0 {
      m_start = 0
    }
    if m_end >= nx {
      m_end = nx - 1
    }
    let mut mean = 0.0
    if m_end >= m_start {
      for j in m_start..<=m_end {
        mean += samples[j]
      }
      mean /= (m_end - m_start + 1).to_double()
    }
    // Windowed, mean-subtracted frame (fully inside the sound).
    let start = lo + 1 - halfnsamp
    if start >= 0 && start + nwin <= nx {
      for k in 0..<nwin {
        frame[k] = (samples[start + k] - mean) * win[k]
      }
    } else {
      for k in 0..<nwin {
        let idx = start + k
        let v = if idx >= 0 && idx < nx {
          samples[idx] - mean
        } else {
          0.0 - mean
        }
        frame[k] = v * win[k]
      }
    }
    // Local peak in the frame centre (for the silence threshold).
    let mut p_start = halfnsamp - halfnsamp_period
    if p_start < 0 {
      p_start = 0
    }
    let mut p_end = halfnsamp + halfnsamp_period
    if p_end > nwin - 1 {
      p_end = nwin - 1
    }
    let mut local_peak = 0.0
    for j in p_start..<=p_end {
      let v = @math.abs(frame[j])
      if v > local_peak {
        local_peak = v
      }
    }
    let frame_intensity = if local_peak > global_peak {
      1.0
    } else {
      local_peak / global_peak
    }
    let unvoiced_local = if silence_threshold > 0.0 {
      let x = 2.0 -
        frame_intensity / (silence_threshold / (1.0 + voicing_threshold))
      if x > 0.0 {
        voicing_threshold + x
      } else {
        voicing_threshold
      }
    } else {
      voicing_threshold
    }
    all_unvoiced[fi] = unvoiced_local
    // Autocorrelation of the windowed frame, normalized like Praat:
    // r[tau] = (ra(tau)/ra(0)) / windowR(tau).
    rplan.autocorrelation(frame, nwin, ra, max_lag=brent_ixmax + 1)
    rx[0] = 1.0
    if ra[0] > 1.0e-300 {
      let inv_ra0 = 1.0 / ra[0]
      for tau in 1..<=(brent_ixmax + 1) {
        rx[tau] = ra[tau] * inv_ra0 * inv_wac[tau]
      }
    } else {
      for tau in 1..<=(brent_ixmax + 1) {
        rx[tau] = 0.0
      }
    }
    all_cands.push(
      collect_voiced_candidates(
        rx,
        minimum_lag,
        lag_limit,
        halfwin~,
        max_depth=if use_gaussian { 500 } else { 70 },
        sample_rate~,
        voicing_threshold~,
        pitch_floor~,
        octave_cost~,
        keep_limit~,
      ),
    )
  }
  solve_viterbi_pitch(
    all_cands,
    all_unvoiced,
    t1,
    dt,
    pitch_ceiling~,
    octave_cost~,
    octave_jump_cost~,
    voiced_unvoiced_cost~,
  )
}

///|
/// Pitch analysis with the parameters of Praat's `To Pitch (ac)...`
/// (Boersma 1993, AC_HANNING method).
///
/// Each frame (spacing `time_step`, default `3 / pitch_floor / 4`)
/// subtracts the local mean measured over one longest period on both
/// sides, applies Praat's periodic Hann window of `3 / pitch_floor`
/// seconds, and computes the windowed autocorrelation via radix-2 FFT.
/// The normalized estimate is
/// `rx(tau) = (ra(tau)/ra(0)) / (rw(tau)/rw(0))` for lags up to half
/// the window. Local maxima above `0.5 * voicing_threshold` become
/// candidates: a parabolic first estimate, then the frequency and
/// strength are refined by maximizing the Hanning-tapered sinc
/// interpolation of eq. (22) (strengths above 1 are reflected around 1).
/// A Viterbi path search then maximizes, per frame, the local strength
/// `r - octave_cost * log2(ceiling / f0)` for voiced candidates or
/// `voicing_threshold + max(0, 2 - intensity / (silence_threshold /
/// (1 + voicing_threshold)))` for the unvoiced hypothesis, minus
/// transition costs (octave jumps `octave_jump_cost * |log2(f1/f2)|`,
/// voiced/unvoiced switches `voiced_unvoiced_cost`, both scaled by
/// `0.01 / dt` like Praat).
///
/// Frames are fitted symmetrically with fully interior windows (Praat's
/// shortTermAnalysis); the first frame is at
/// `t1 = mid - 0.5 * n * dt + 0.5 * dt`.
pub fn pitch_ac(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.0,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
  max_candidates~ : Int32 = 15,
  voicing_threshold~ : Double = 0.45,
  silence_threshold~ : Double = 0.03,
  octave_cost~ : Double = 0.01,
  octave_jump_cost~ : Double = 0.35,
  voiced_unvoiced_cost~ : Double = 0.14,
) -> @types.PitchTier {
  pitch_ac_core(
    samples,
    sample_rate~,
    time_step~,
    pitch_floor~,
    pitch_ceiling~,
    max_candidates~,
    voicing_threshold~,
    silence_threshold~,
    octave_cost~,
    octave_jump_cost~,
    voiced_unvoiced_cost~,
    periods_per_window=3.0,
    use_gaussian=false,
    auto_raise_candidates=true,
  )
}

///|
/// Gaussian frequency-domain low-pass filter matching Praat 6.4+
/// `To Pitch (filtered ac)...`, attenuating spectral magnitude at
/// `top_frequency` by `attenuation_at_top` (default 0.03):
/// `gain(f) = attenuation_at_top ^ ((f / top_frequency)^2)`.
fn lowpass_attenuation_fft(
  samples : FixedArray[Double],
  sample_rate : Double,
  top_frequency : Double,
  attenuation_at_top : Double,
) -> FixedArray[Double] {
  let nx = samples.length()
  if nx == 0 {
    return FixedArray::make(0, 0.0)
  }
  let out : FixedArray[Double] = FixedArray::make(nx, 0.0)
  if sample_rate <= 0.0 ||
    top_frequency <= 0.0 ||
    attenuation_at_top <= 0.0 ||
    attenuation_at_top >= 1.0 {
    for i in 0..<nx {
      out[i] = samples[i]
    }
    return out
  }
  let raw_nfft = @dsp.next_pow2(nx)
  let nfft = if raw_nfft < 4 { 4 } else { raw_nfft }
  let rplan = @dsp.RealFftPlan::new(nfft)
  let half = nfft / 2
  let gains : FixedArray[Double] = FixedArray::make(half + 1, 0.0)
  let df = sample_rate / nfft.to_double()
  let log_atten = @math.ln(attenuation_at_top)
  let inv_top = 1.0 / top_frequency
  for k in 0..<=half {
    let r = k.to_double() * df * inv_top
    let expo = log_atten * r * r
    if expo < -40.0 {
      break
    }
    gains[k] = @math.exp(expo)
  }
  rplan.filter_real(samples, nx, gains, out)
  out
}

///|
/// Pitch analysis with the parameters of Praat 6.4+
/// `To Pitch (filtered ac)...`.
///
/// Applies Praat's frequency-domain Gaussian attenuation filter prior
/// to autocorrelation (`attenuation_at_top` at `pitch_ceiling`), with
/// Praat 6.4+ default thresholds (`pitch_floor = 50`, `pitch_ceiling =
/// 800`, `voicing_threshold = 0.50`, `silence_threshold = 0.09`,
/// `octave_cost = 0.055`, `attenuation_at_top = 0.03`). When
/// `very_accurate` is `true`, switches to the 6-period Gaussian window.
pub fn pitch_filtered_ac(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.0,
  pitch_floor~ : Double = 50.0,
  pitch_ceiling~ : Double = 800.0,
  max_candidates~ : Int32 = 15,
  very_accurate~ : Bool = false,
  attenuation_at_top~ : Double = 0.03,
  voicing_threshold~ : Double = 0.50,
  silence_threshold~ : Double = 0.09,
  octave_cost~ : Double = 0.055,
  octave_jump_cost~ : Double = 0.35,
  voiced_unvoiced_cost~ : Double = 0.14,
) -> @types.PitchTier {
  if samples.length() == 0 ||
    sample_rate <= 0.0 ||
    pitch_floor <= 0.0 ||
    pitch_ceiling <= pitch_floor {
    return { t1: 0.0, dt: 0.0, frames: [], }
  }
  let filtered = lowpass_attenuation_fft(
    samples, sample_rate, pitch_ceiling, attenuation_at_top,
  )
  pitch_ac_core(
    filtered,
    sample_rate~,
    time_step~,
    pitch_floor~,
    pitch_ceiling~,
    max_candidates~,
    voicing_threshold~,
    silence_threshold~,
    octave_cost~,
    octave_jump_cost~,
    voiced_unvoiced_cost~,
    periods_per_window=if very_accurate { 6.0 } else { 3.0 },
    use_gaussian=very_accurate,
    auto_raise_candidates=true,
  )
}
