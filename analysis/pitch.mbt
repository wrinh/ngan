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
  strength : Double // refined window-normalized periodicity
}

///|
/// Boersma (1993) eq. (22): the continuous version of a sampled
/// autocorrelation, reconstructed with a Hanning-tapered `sin(x)/x`
/// interpolation over +-N samples where
/// `N = min(500, half_window - 1 - floor(x))`. The autocorrelation is
/// even, so `r[-k] = r[k]`; at integer arguments the interpolation is
/// exact (every sinc argument except zero is integral).
fn interp_lag(r : FixedArray[Double], x : Double, halfwin~ : Int32) -> Double {
  let nl = @math.floor(x).to_int()
  let l = x - nl.to_double()
  let rr = 1.0 - l
  let mut n_max = halfwin - 1 - nl
  if n_max > 500 {
    n_max = 500
  }
  if n_max < 1 {
    n_max = 1
  }
  let n_max_d = n_max.to_double()
  let mut acc = 0.0
  // Left side: samples nl, nl-1, ..., nl+1-N at distance l + n - 1.
  for n in 1..<=n_max {
    let d = l + n.to_double() - 1.0
    let pd = @math.PI * d
    let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
    let taper = 0.5 + 0.5 * @math.cos(@math.PI * d / (l + n_max_d))
    let idx = nl + 1 - n
    let aidx = if idx < 0 { -idx } else { idx }
    if aidx < r.length() {
      acc += r[aidx] * s * taper
    }
  }
  // Right side: samples nl+1, ..., nl+N at distance r + n - 1.
  for n in 1..<=n_max {
    let d = rr + n.to_double() - 1.0
    let pd = @math.PI * d
    let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
    let taper = 0.5 + 0.5 * @math.cos(@math.PI * d / (rr + n_max_d))
    let idx = nl + n
    if idx < r.length() {
      acc += r[idx] * s * taper
    }
  }
  acc
}

///|
/// Refine an integer peak of the normalized autocorrelation with
/// golden-section search of its continuous (interpolated) version on
/// `[tau - 1, tau + 1]` (Praat uses Brent's method here). Returns
/// `(peak value, exact lag)`.
fn refine_peak(
  r : FixedArray[Double],
  tau : Int32,
  halfwin~ : Int32,
) -> (Double, Double) {
  fn eval(x : Double) -> Double {
    interp_lag(r, x, halfwin~)
  }
  let phi = 0.6180339887498949
  let mut a = tau.to_double() - 1.0
  let mut b = tau.to_double() + 1.0
  let mut c = b - phi * (b - a)
  let mut d = a + phi * (b - a)
  let mut fc = eval(c)
  let mut fd = eval(d)
  for _ in 0..<50 {
    if fc > fd {
      b = d
      d = c
      fd = fc
      c = b - phi * (b - a)
      fc = eval(c)
    } else {
      a = c
      c = d
      fc = fd
      d = a + phi * (b - a)
      fd = eval(d)
    }
  }
  let xm = (a + b) / 2.0
  (eval(xm), xm)
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
    octave_jump_cost * @math.abs(@math.log2(c1.freq / c2.freq))
  } else if c1.voiced != c2.voiced {
    voiced_unvoiced_cost
  } else {
    0.0
  }
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
pub fn pitch(
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
  let empty : Array[@types.PitchFrame] = []
  let nx = samples.length()
  if nx == 0 ||
    sample_rate <= 0.0 ||
    pitch_floor <= 0.0 ||
    pitch_ceiling <= pitch_floor {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let dt = if time_step > 0.0 { time_step } else { 3.0 / pitch_floor / 4.0 }
  // Even window length, like Praat: halfnsamp = nsamp/2 - 1.
  let nw_raw = @math.floor_int(3.0 / pitch_floor * sample_rate)
  let halfnsamp = nw_raw / 2 - 1
  if halfnsamp < 2 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let nwin = halfnsamp * 2
  let win = @dsp.hanning_window(nwin)
  let halfwin = nwin / 2
  // Lags: Praat's minimumLag / maximumLag / brent_ixmax.
  let mut minimum_lag = @math.floor_int(sample_rate / pitch_ceiling)
  if minimum_lag < 2 {
    minimum_lag = 2
  }
  let mut maximum_lag = @math.floor_int(nwin.to_double() / 3.0) + 2
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
  let auto_raise = @math.floor_int(pitch_ceiling / pitch_floor)
  if maxn < auto_raise {
    maxn = auto_raise
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
  // FFT plan and the window's normalized autocorrelation (constant).
  let nfft = @dsp.next_pow2(nwin * 3 / 2)
  let plan = @dsp.FftPlan::new(nfft)
  let wac : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  @dsp.autocorrelation_fft(plan, win, nwin, wac, max_lag=brent_ixmax + 1)
  for i in 1..<=(brent_ixmax + 1) {
    if wac[0] > 0.0 {
      wac[i] /= wac[0]
    }
  }
  wac[0] = 1.0
  let frame : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let ra : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  let rx : FixedArray[Double] = FixedArray::make(brent_ixmax + 2, 0.0)
  // Viterbi state.
  let all_cands : Array[Array[PitchCand]] = []
  let all_unvoiced : FixedArray[Double] = FixedArray::make(nframes, 0.0)
  let paths : Array[FixedArray[Int32]] = []
  let mut prev_dp : FixedArray[Double] = FixedArray::make(0, 0.0)
  let octave_jump_cost_scaled = octave_jump_cost * 0.01 / dt
  let voiced_unvoiced_cost_scaled = voiced_unvoiced_cost * 0.01 / dt
  for fi in 0..<nframes {
    let t = t1 + fi.to_double() * dt
    let lo = low_index(t, sample_rate)
    // Local mean over one longest period on both sides.
    let m_start = lo + 1 - nsamp_period
    let m_end = lo + nsamp_period
    let mut mean = 0.0
    let mut mcount = 0
    let mut j = m_start
    while j <= m_end {
      if j >= 0 && j < nx {
        mean += samples[j]
        mcount += 1
      }
      j += 1
    }
    if mcount > 0 {
      mean /= mcount.to_double()
    }
    // Hann-windowed, mean-subtracted frame (fully inside the sound).
    let start = lo + 1 - halfnsamp
    for k in 0..<nwin {
      let idx = start + k
      let v = if idx >= 0 && idx < nx {
        samples[idx] - mean
      } else {
        0.0 - mean
      }
      frame[k] = v * win[k]
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
    j = p_start
    while j <= p_end {
      let v = @math.abs(frame[j])
      if v > local_peak {
        local_peak = v
      }
      j += 1
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
    @dsp.autocorrelation_fft(plan, frame, nwin, ra, max_lag=brent_ixmax + 1)
    rx[0] = 1.0
    if ra[0] > 1.0e-300 {
      for tau in 1..<=(brent_ixmax + 1) {
        if wac[tau] > 1.0e-10 {
          rx[tau] = ra[tau] / (ra[0] * wac[tau])
        } else {
          rx[tau] = 0.0
        }
      }
    } else {
      for tau in 1..<=(brent_ixmax + 1) {
        rx[tau] = 0.0
      }
    }
    // Collect voiced candidates from local maxima.
    let voiced : Array[(Double, Double, Int32)] = [] // (strength, freq, ipeak)
    let mut lg = minimum_lag
    while lg < maximum_lag && lg < brent_ixmax {
      if rx[lg] > 0.5 * voicing_threshold &&
        rx[lg] > rx[lg - 1] &&
        rx[lg] >= rx[lg + 1] {
        // Parabolic first estimate, then refine frequency and strength.
        let dr = 0.5 * (rx[lg + 1] - rx[lg - 1])
        let d2r = rx[lg] - rx[lg - 1] + (rx[lg] - rx[lg + 1])
        if d2r > 0.0 {
          let delta = dr / d2r
          if delta > -1.0 && delta < 1.0 {
            let (r_val, lag) = refine_peak(rx, lg, halfwin~)
            if r_val > 0.0 && lag > 1.0 {
              let mut strength = r_val
              if strength > 1.0 {
                strength = 1.0 / strength
              }
              voiced.push((strength, sample_rate / lag, lg))
            }
          }
        }
      }
      lg += 1
    }
    // Keep the strongest `maxn - 1` candidates, favouring high
    // frequencies (octave cost) like Praat's slot competition.
    voiced.sort_by(fn(p, q) {
      let sp = p.0 - octave_cost * @math.log2(pitch_floor / p.1)
      let sq = q.0 - octave_cost * @math.log2(pitch_floor / q.1)
      if sp > sq {
        -1
      } else if sp < sq {
        1
      } else {
        0
      }
    })
    while voiced.length() > maxn - 1 {
      ignore(voiced.pop())
    }
    let cands : Array[PitchCand] = [
      { voiced: false, freq: 0.0, strength: 0.0, },
    ]
    for c in voiced {
      cands.push({ voiced: true, freq: c.1, strength: c.0, })
    }
    all_cands.push(cands)
    // Viterbi step over local deltas minus transition costs.
    let nc = cands.length()
    let dp : FixedArray[Double] = FixedArray::make(nc, 0.0)
    let back : FixedArray[Int32] = FixedArray::make(nc, 0)
    if fi == 0 {
      for j2 in 0..<nc {
        dp[j2] = if cands[j2].voiced {
          cands[j2].strength -
          octave_cost * @math.log2(pitch_ceiling / cands[j2].freq)
        } else {
          all_unvoiced[fi]
        }
      }
    } else {
      let prev_cands = all_cands[all_cands.length() - 2]
      for j2 in 0..<nc {
        let local_cost = if cands[j2].voiced {
          cands[j2].strength -
          octave_cost * @math.log2(pitch_ceiling / cands[j2].freq)
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
  // Backtrack the globally optimal path.
  let frames : Array[@types.PitchFrame] = []
  let mut best_j = 0
  for j in 1..<prev_dp.length() {
    if prev_dp[j] > prev_dp[best_j] {
      best_j = j
    }
  }
  let chosen : FixedArray[Int32] = FixedArray::make(nframes, 0)
  chosen[nframes - 1] = best_j
  let mut i = nframes - 1
  while i > 0 {
    chosen[i - 1] = paths[i][chosen[i]]
    i -= 1
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
