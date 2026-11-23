// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `PointProcess: Get jitter (...)` and
// `PointProcess & Sound: Get shimmer (...)`, ported from
// fon/PointProcess.cpp and fon/PointProcess_and_Sound.cpp.

///|
fn period_ratio_ok(p1 : Double, p2 : Double, max_factor : Double) -> Bool {
  p1 > 0.0 && p2 > 0.0 && p1 <= p2 * max_factor && p2 <= p1 * max_factor
}

///|
/// Compute all five standard Praat jitter measures (`local`, `local,
/// absolute`, `rap`, `ppq5`, `ddp`) from a `PointProcess` within
/// `[tmin, tmax]` (or over the whole domain when `tmax <= tmin`).
pub fn jitter(
  pp : @types.PointProcess,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  shortest_period~ : Double = 0.0001,
  longest_period~ : Double = 0.02,
  max_period_factor~ : Double = 1.3,
) -> @types.JitterMetrics {
  let empty : @types.JitterMetrics = {
    local_rel: None,
    local_abs: None,
    rap: None,
    ppq5: None,
    ddp: None,
  }
  guard pp.mean_period(
      tmin~,
      tmax~,
      shortest_period~,
      longest_period~,
      max_period_factor~,
    )
    is Some(mean_p) else {
    return empty
  }
  if mean_p <= 0.0 {
    return empty
  }
  let use_all = tmax <= tmin
  let sel : Array[Double] = []
  for i in 0..<pp.points.length() {
    let t = pp.points[i]
    if use_all || (t >= tmin && t <= tmax) {
      sel.push(t)
    }
  }
  if sel.length() < 3 {
    return empty
  }
  let m = sel.length() - 1
  let periods : FixedArray[Double] = FixedArray::make(m, 0.0)
  let p_valid : FixedArray[Bool] = FixedArray::make(m, false)
  for i in 0..<m {
    let p = sel[i + 1] - sel[i]
    periods[i] = p
    p_valid[i] = p >= shortest_period && p <= longest_period
  }
  let pair_ok : FixedArray[Bool] = FixedArray::make(m - 1, false)
  for k in 0..<(m - 1) {
    pair_ok[k] = p_valid[k] &&
      p_valid[k + 1] &&
      period_ratio_ok(periods[k], periods[k + 1], max_period_factor)
  }
  // Local jitter (2-point).
  let mut sum_local = 0.0
  let mut cnt_local = 0
  for k in 0..<(m - 1) {
    if pair_ok[k] {
      sum_local += @math.abs(periods[k + 1] - periods[k])
      cnt_local += 1
    }
  }
  let local_abs = if cnt_local > 0 {
    Some(sum_local / cnt_local.to_double())
  } else {
    None
  }
  let local_rel = match local_abs {
    Some(v) => Some(v / mean_p)
    None => None
  }
  // RAP (3-point) and DDP (= 3 * RAP).
  let mut sum_rap = 0.0
  let mut cnt_rap = 0
  if m >= 3 {
    for k in 0..<(m - 2) {
      if pair_ok[k] && pair_ok[k + 1] {
        let avg3 = (periods[k] + periods[k + 1] + periods[k + 2]) / 3.0
        sum_rap += @math.abs(periods[k + 1] - avg3)
        cnt_rap += 1
      }
    }
  }
  let rap = if cnt_rap > 0 {
    Some(sum_rap / (cnt_rap.to_double() * mean_p))
  } else {
    None
  }
  let ddp = match rap {
    Some(r) => Some(3.0 * r)
    None => None
  }
  // PPQ5 (5-point).
  let mut sum_ppq5 = 0.0
  let mut cnt_ppq5 = 0
  if m >= 5 {
    for k in 0..<(m - 4) {
      if pair_ok[k] && pair_ok[k + 1] && pair_ok[k + 2] && pair_ok[k + 3] {
        let avg5 = (
            periods[k] +
            periods[k + 1] +
            periods[k + 2] +
            periods[k + 3] +
            periods[k + 4]
          ) /
          5.0
        sum_ppq5 += @math.abs(periods[k + 2] - avg5)
        cnt_ppq5 += 1
      }
    }
  }
  let ppq5 = if cnt_ppq5 > 0 {
    Some(sum_ppq5 / (cnt_ppq5.to_double() * mean_p))
  } else {
    None
  }
  { local_rel, local_abs, rap, ppq5, ddp, }
}

///|
/// Peak-to-peak amplitude of `samples` on `[t_a, t_b]` with 3-point
/// parabolic refinement of both maximum and minimum.
fn peak_to_peak_amplitude(
  samples : FixedArray[Double],
  sample_rate : Double,
  t_a : Double,
  t_b : Double,
) -> Double {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || t_b <= t_a {
    return 0.0
  }
  let mut i_lo = @math.floor_int(t_a * sample_rate - 0.5)
  let mut i_hi = @math.ceil_int(t_b * sample_rate - 0.5)
  if i_lo < 0 {
    i_lo = 0
  }
  if i_hi >= nx {
    i_hi = nx - 1
  }
  if i_hi <= i_lo {
    return 0.0
  }
  let mut best_hi = i_lo
  let mut best_lo = i_lo
  let mut y_max = samples[i_lo]
  let mut y_min = samples[i_lo]
  for i in (i_lo + 1)..<=i_hi {
    let v = samples[i]
    if v > y_max {
      y_max = v
      best_hi = i
    }
    if v < y_min {
      y_min = v
      best_lo = i
    }
  }
  if best_hi > 0 && best_hi < nx - 1 {
    let ym = samples[best_hi - 1]
    let y0 = samples[best_hi]
    let yp = samples[best_hi + 1]
    if ym <= y0 && yp <= y0 {
      let d2 = ym - 2.0 * y0 + yp
      if d2 < 0.0 {
        let mut delta = 0.5 * (ym - yp) / d2
        if delta < -0.5 {
          delta = -0.5
        } else if delta > 0.5 {
          delta = 0.5
        }
        y_max = y0 - 0.25 * (ym - yp) * delta
      }
    }
  }
  if best_lo > 0 && best_lo < nx - 1 {
    let ym = samples[best_lo - 1]
    let y0 = samples[best_lo]
    let yp = samples[best_lo + 1]
    if ym >= y0 && yp >= y0 {
      let d2 = ym - 2.0 * y0 + yp
      if d2 > 0.0 {
        let mut delta = 0.5 * (ym - yp) / d2
        if delta < -0.5 {
          delta = -0.5
        } else if delta > 0.5 {
          delta = 0.5
        }
        y_min = y0 - 0.25 * (ym - yp) * delta
      }
    }
  }
  y_max - y_min
}

///|
/// Compute all six standard Praat shimmer measures (`local`, `local,
/// dB`, `apq3`, `apq5`, `apq11`, `dda`) from `samples` and a
/// `PointProcess` within `[tmin, tmax]` (or over the whole domain when
/// `tmax <= tmin`).
pub fn shimmer(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pp~ : @types.PointProcess,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  shortest_period~ : Double = 0.0001,
  longest_period~ : Double = 0.02,
  max_period_factor~ : Double = 1.3,
  max_amplitude_factor~ : Double = 1.6,
) -> @types.ShimmerMetrics {
  let empty : @types.ShimmerMetrics = {
    local_rel: None,
    local_db: None,
    apq3: None,
    apq5: None,
    apq11: None,
    dda: None,
  }
  if samples.length() == 0 || sample_rate <= 0.0 {
    return empty
  }
  let use_all = tmax <= tmin
  let sel : Array[Double] = []
  for i in 0..<pp.points.length() {
    let t = pp.points[i]
    if use_all || (t >= tmin && t <= tmax) {
      sel.push(t)
    }
  }
  if sel.length() < 3 {
    return empty
  }
  let m = sel.length() - 1
  let periods : FixedArray[Double] = FixedArray::make(m, 0.0)
  let amps : FixedArray[Double] = FixedArray::make(m, 0.0)
  let valid : FixedArray[Bool] = FixedArray::make(m, false)
  for k in 0..<m {
    let p = sel[k + 1] - sel[k]
    periods[k] = p
    if p >= shortest_period && p <= longest_period {
      let a = peak_to_peak_amplitude(samples, sample_rate, sel[k], sel[k + 1])
      amps[k] = a
      valid[k] = a > 0.0
    }
  }
  let pair_ok : FixedArray[Bool] = FixedArray::make(m - 1, false)
  for k in 0..<(m - 1) {
    pair_ok[k] = valid[k] &&
      valid[k + 1] &&
      period_ratio_ok(periods[k], periods[k + 1], max_period_factor) &&
      period_ratio_ok(amps[k], amps[k + 1], max_amplitude_factor)
  }
  // Shimmer (local) and Shimmer (local, dB).
  let mut sum_diff = 0.0
  let mut sum_amp = 0.0
  let mut sum_db = 0.0
  let mut cnt_local = 0
  for k in 0..<(m - 1) {
    if pair_ok[k] {
      sum_diff += @math.abs(amps[k + 1] - amps[k])
      sum_amp += 0.5 * (amps[k] + amps[k + 1])
      sum_db += @math.abs(20.0 * @math.log10(amps[k + 1] / amps[k]))
      cnt_local += 1
    }
  }
  let local_rel = if cnt_local > 0 && sum_amp > 0.0 {
    Some(sum_diff / sum_amp)
  } else {
    None
  }
  let local_db = if cnt_local > 0 {
    Some(sum_db / cnt_local.to_double())
  } else {
    None
  }
  // APQ3 and DDA (= 3 * APQ3).
  let mut sum_apq3 = 0.0
  let mut amp_apq3 = 0.0
  if m >= 3 {
    for k in 0..<(m - 2) {
      if pair_ok[k] && pair_ok[k + 1] {
        let avg3 = (amps[k] + amps[k + 1] + amps[k + 2]) / 3.0
        sum_apq3 += @math.abs(amps[k + 1] - avg3)
        amp_apq3 += amps[k + 1]
      }
    }
  }
  let apq3 = if amp_apq3 > 0.0 { Some(sum_apq3 / amp_apq3) } else { None }
  let dda = match apq3 {
    Some(a) => Some(3.0 * a)
    None => None
  }
  // APQ5.
  let mut sum_apq5 = 0.0
  let mut amp_apq5 = 0.0
  if m >= 5 {
    for k in 0..<(m - 4) {
      if pair_ok[k] && pair_ok[k + 1] && pair_ok[k + 2] && pair_ok[k + 3] {
        let avg5 = (
            amps[k] + amps[k + 1] + amps[k + 2] + amps[k + 3] + amps[k + 4]
          ) /
          5.0
        sum_apq5 += @math.abs(amps[k + 2] - avg5)
        amp_apq5 += amps[k + 2]
      }
    }
  }
  let apq5 = if amp_apq5 > 0.0 { Some(sum_apq5 / amp_apq5) } else { None }
  // APQ11.
  let mut sum_apq11 = 0.0
  let mut amp_apq11 = 0.0
  if m >= 11 {
    for k in 0..<(m - 10) {
      let mut all_ok = true
      for j in 0..<10 {
        if !pair_ok[k + j] {
          all_ok = false
          break
        }
      }
      if all_ok {
        let mut s = 0.0
        for j in 0..<11 {
          s += amps[k + j]
        }
        sum_apq11 += @math.abs(amps[k + 5] - s / 11.0)
        amp_apq11 += amps[k + 5]
      }
    }
  }
  let apq11 = if amp_apq11 > 0.0 { Some(sum_apq11 / amp_apq11) } else { None }
  { local_rel, local_db, apq3, apq5, apq11, dda, }
}

///|
/// Compute Praat Voice Report voicing continuity and voice break metrics:
/// - `fraction_locally_unvoiced`: proportion of pitch frames that are unvoiced
/// - `number_of_voice_breaks`: count of inter-pulse gaps exceeding `max_period_factor / pitch_floor`
/// - `degree_of_voice_breaks`: fraction of `[tmin, tmax]` outside contiguous voiced pulse runs.
pub fn voice_breaks(
  pitch : @types.PitchTier,
  pp : @types.PointProcess,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  pitch_floor~ : Double = 75.0,
  max_period_factor~ : Double = 1.25,
) -> @types.VoiceBreaks {
  let use_all = tmax <= tmin
  let (t_lo, t_hi) = if !use_all {
    (tmin, tmax)
  } else if pp.tmax > pp.tmin {
    (pp.tmin, pp.tmax)
  } else if pitch.frames.length() > 0 && pitch.dt > 0.0 {
    (
      pitch.t1 - 0.5 * pitch.dt,
      pitch.t1 + (pitch.frames.length().to_double() - 0.5) * pitch.dt,
    )
  } else {
    (0.0, 0.0)
  }
  let mut total_frames = 0
  let mut unvoiced_frames = 0
  for fr in pitch.frames {
    if use_all || (fr.time >= t_lo && fr.time <= t_hi) {
      total_frames += 1
      if fr.frequency is None {
        unvoiced_frames += 1
      }
    }
  }
  let fraction_locally_unvoiced = if total_frames > 0 {
    unvoiced_frames.to_double() / total_frames.to_double()
  } else {
    1.0
  }
  let dur = t_hi - t_lo
  if dur <= 0.0 {
    return {
      number_of_voice_breaks: 0,
      degree_of_voice_breaks: 0.0,
      fraction_locally_unvoiced,
    }
  }
  let max_period = if pitch_floor > 0.0 {
    max_period_factor / pitch_floor
  } else {
    0.016666666666666666
  }
  let sel : Array[Double] = []
  for i in 0..<pp.points.length() {
    let p = pp.points[i]
    if p >= t_lo && p <= t_hi {
      sel.push(p)
    }
  }
  if sel.length() < 2 {
    return {
      number_of_voice_breaks: 0,
      degree_of_voice_breaks: 1.0,
      fraction_locally_unvoiced,
    }
  }
  let mut num_breaks = 0
  let mut break_dur = 0.0
  for i in 0..<(sel.length() - 1) {
    let gap = sel[i + 1] - sel[i]
    if gap > max_period {
      num_breaks += 1
      break_dur += gap
    }
  }
  let leading = sel[0] - t_lo
  if leading > max_period {
    break_dur += leading
  }
  let trailing = t_hi - sel[sel.length() - 1]
  if trailing > max_period {
    break_dur += trailing
  }
  {
    number_of_voice_breaks: num_breaks,
    degree_of_voice_breaks: @math.clamp01(break_dur / dur),
    fraction_locally_unvoiced,
  }
}

///|
/// Compute the full Praat-style Voice Report combining pitch, pulses, HNR,
/// fraction of locally unvoiced frames, voice breaks, jitter, and shimmer.
pub fn voice_report(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
  max_period_factor~ : Double = 1.3,
  max_amplitude_factor~ : Double = 1.6,
  use_filtered_ac~ : Bool = false,
) -> @types.VoiceReport {
  let pt = if use_filtered_ac {
    pitch_filtered_ac(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
  } else {
    pitch(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
  }
  let pp = sound_and_pitch_to_point_process_cc(samples, sample_rate~, pitch=pt)
  let vb = voice_breaks(
    pt,
    pp,
    tmin~,
    tmax~,
    pitch_floor~,
    max_period_factor=1.25,
  )
  let shortest_period = if pitch_ceiling > 0.0 {
    0.8 / pitch_ceiling
  } else {
    0.0001
  }
  let longest_period = if pitch_floor > 0.0 { 1.25 / pitch_floor } else { 0.02 }
  let jit = jitter(
    pp,
    tmin~,
    tmax~,
    shortest_period~,
    longest_period~,
    max_period_factor~,
  )
  let shim = shimmer(
    samples,
    sample_rate~,
    pp~,
    tmin~,
    tmax~,
    shortest_period~,
    longest_period~,
    max_period_factor~,
    max_amplitude_factor~,
  )
  let hnr = harmonicity_ac(samples, sample_rate~, min_pitch=pitch_floor)
  {
    pulses: pp.points,
    mean_pitch_hz: pt.mean(),
    mean_hnr_db: hnr.mean(),
    fraction_locally_unvoiced: vb.fraction_locally_unvoiced,
    number_of_voice_breaks: vb.number_of_voice_breaks,
    degree_of_voice_breaks: vb.degree_of_voice_breaks,
    jitter: jit,
    shimmer: shim,
  }
}
