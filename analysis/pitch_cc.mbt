// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To Pitch (cc)...`: forward cross-correlation pitch tracker
// (`FCC_NORMAL` method in fon/Sound_to_Pitch.cpp).

///|
/// Shared forward cross-correlation pitch/harmonicity core.
///
/// Each frame correlates a rectangular `periods_per_window / pitch_floor`
/// template window `u` against shifted windows `v[tau..tau+n_tpl]` via
/// `cross_correlation_fft` normalized by `sqrt(sum(u^2) * sum(v^2))`,
/// refines local maxima with Hanning-tapered sinc interpolation, and
/// tracks the optimal path via `solve_viterbi_pitch`.
fn pitch_cc_core(
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
  let n_tpl = @math.floor_int(periods_per_window * sample_rate / pitch_floor)
  if n_tpl < 4 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let mut minimum_lag = @math.floor_int(sample_rate / pitch_ceiling)
  if minimum_lag < 2 {
    minimum_lag = 2
  }
  let maximum_lag = @math.floor_int(sample_rate / pitch_floor) + 2
  if maximum_lag < minimum_lag + 2 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let max_r_lag = maximum_lag + 32
  let m_len = n_tpl + max_r_lag
  let dur = nx.to_double() / sample_rate
  let window_dur = (periods_per_window + 1.0) / pitch_floor
  guard short_term_analysis(dur, window_dur, dt) is Some(sa) else {
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
  let nsamp_period = @math.floor_int(sample_rate / pitch_floor)
  let halfnsamp_period = nsamp_period / 2 + 1
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
  let nfft = @dsp.next_pow2(m_len)
  let plan = @dsp.FftPlan::new(nfft)
  let fft_re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let fft_im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let u : FixedArray[Double] = FixedArray::make(n_tpl, 0.0)
  let v : FixedArray[Double] = FixedArray::make(m_len, 0.0)
  let sq : FixedArray[Double] = FixedArray::make(m_len + 1, 0.0)
  let cc : FixedArray[Double] = FixedArray::make(max_r_lag + 1, 0.0)
  let rx : FixedArray[Double] = FixedArray::make(max_r_lag + 1, 0.0)
  let all_cands : Array[Array[PitchCand]] = []
  let all_unvoiced : FixedArray[Double] = FixedArray::make(nframes, 0.0)
  let keep_limit = if octave_jump_cost == 0.0 && voiced_unvoiced_cost == 0.0 {
    1
  } else {
    maxn - 1
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
    // Local peak around the frame centre (for the silence threshold).
    let mut p_start = lo + 1 - halfnsamp_period
    if p_start < 0 {
      p_start = 0
    }
    let mut p_end = lo + halfnsamp_period
    if p_end > nx - 1 {
      p_end = nx - 1
    }
    let mut local_peak = 0.0
    for j in p_start..<=p_end {
      let val = @math.abs(samples[j] - mean)
      if val > local_peak {
        local_peak = val
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
    // Fill signal window and prefix-sum of squares.
    let start = lo + 1 - (n_tpl + maximum_lag) / 2
    sq[0] = 0.0
    if start >= 0 && start + m_len <= nx {
      for k in 0..<m_len {
        let val = samples[start + k] - mean
        v[k] = val
        sq[k + 1] = sq[k] + val * val
      }
    } else {
      for k in 0..<m_len {
        let idx = start + k
        let val = if idx >= 0 && idx < nx { samples[idx] - mean } else { 0.0 }
        v[k] = val
        sq[k + 1] = sq[k] + val * val
      }
    }
    for k in 0..<n_tpl {
      u[k] = v[k]
    }
    @dsp.cross_correlation_fft_buf(
      plan,
      u,
      n_tpl,
      v,
      m_len,
      cc,
      max_lag=max_r_lag,
      fft_re,
      fft_im,
    )
    rx[0] = 1.0
    let e_u = sq[n_tpl]
    if e_u > 1.0e-300 {
      let inv_sqrt_eu = 1.0 / e_u.sqrt()
      for tau in 1..<=max_r_lag {
        let e_v = sq[tau + n_tpl] - sq[tau]
        if e_v > 1.0e-300 {
          let inv_denom = inv_sqrt_eu / e_v.sqrt()
          rx[tau] = cc[tau] * inv_denom
        } else {
          rx[tau] = 0.0
        }
      }
    } else {
      for tau in 1..<=max_r_lag {
        rx[tau] = 0.0
      }
    }
    all_cands.push(
      collect_voiced_candidates(
        rx,
        minimum_lag,
        maximum_lag,
        halfwin=max_r_lag,
        max_depth=70,
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
/// Pitch analysis with the parameters of Praat's `To Pitch (cc)...`
/// (forward cross-correlation, `FCC_NORMAL` method).
///
/// Uses a shorter `1 / pitch_floor` template window (`time_step`
/// defaults to `0.25 / pitch_floor`) than `pitch_ac` (`To Pitch (ac)...`),
/// making it better suited to voice perturbation analysis (jitter /
/// shimmer / point-process pulse extraction) and creaky or hoarse
/// phonation.
pub fn pitch_cc(
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
  pitch_cc_core(
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
    periods_per_window=1.0,
    auto_raise_candidates=true,
  )
}
