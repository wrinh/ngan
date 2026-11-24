// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `Sound & Pitch: To PointProcess (cc)` and
// `Sound: To PointProcess (periodic, cc)...`: glottal pulse extraction
// ported from fon/Pitch_to_PointProcess.cpp.

///|
/// Find the time (s) of the absolute extremum (largest |x(t)|) of
/// `samples` in `[tmin, tmax]`, refined with 3-point parabolic
/// interpolation.
fn find_abs_extremum(
  samples : FixedArray[Double],
  sample_rate : Double,
  tmin : Double,
  tmax : Double,
) -> Double {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 {
    return 0.5 * (tmin + tmax)
  }
  let mut i_min = @math.floor_int(tmin * sample_rate - 0.5)
  let mut i_max = @math.ceil_int(tmax * sample_rate - 0.5)
  if i_min < 0 {
    i_min = 0
  }
  if i_min >= nx {
    i_min = nx - 1
  }
  if i_max < 0 {
    i_max = 0
  }
  if i_max >= nx {
    i_max = nx - 1
  }
  if i_max < i_min {
    let tmp = i_min
    i_min = i_max
    i_max = tmp
  }
  let mut best_hi = i_min
  let mut best_lo = i_min
  let mut max_v = samples[i_min]
  let mut min_v = samples[i_min]
  for i in (i_min + 1)..<=i_max {
    let v = samples[i]
    if v > max_v {
      max_v = v
      best_hi = i
    }
    if v < min_v {
      min_v = v
      best_lo = i
    }
  }
  // Parabolic refinement of maximum.
  let mut t_hi = (best_hi.to_double() + 0.5) / sample_rate
  let mut v_hi = max_v
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
        t_hi = (best_hi.to_double() + 0.5 + delta) / sample_rate
        v_hi = y0 - 0.25 * (ym - yp) * delta
      }
    }
  }
  // Parabolic refinement of minimum.
  let mut t_lo = (best_lo.to_double() + 0.5) / sample_rate
  let mut v_lo = min_v
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
        t_lo = (best_lo.to_double() + 0.5 + delta) / sample_rate
        v_lo = y0 - 0.25 * (ym - yp) * delta
      }
    }
  }
  if @math.abs(v_hi) >= @math.abs(v_lo) {
    t_hi
  } else {
    t_lo
  }
}

///|
/// Step one glottal period from `t_cur` in direction `dir` (+1 right,
/// -1 left) by maximizing the mean-subtracted normalized
/// cross-correlation of one `period`-long segment across lags in
/// `[0.8 * period, 1.2 * period]`, returning `(t_next, peak_cc)`.
fn cc_step(
  samples : FixedArray[Double],
  nx : Int32,
  sample_rate : Double,
  t_cur : Double,
  period : Double,
  dir : Int32,
) -> (Double, Double)? {
  let mut half_l = @math.round_int(0.5 * period * sample_rate)
  if half_l < 1 {
    half_l = 1
  }
  let win_len = 2 * half_l + 1
  let i_cur = @math.round_int(t_cur * sample_rate - 0.5)
  let mut lag_min = @math.floor_int(0.8 * period * sample_rate)
  if lag_min < 1 {
    lag_min = 1
  }
  let mut lag_max = @math.ceil_int(1.2 * period * sample_rate)
  if lag_max <= lag_min {
    lag_max = lag_min + 1
  }
  // Mean-subtracted reference period centred at i_cur.
  let ref_base = i_cur - half_l
  let ref_buf : FixedArray[Double] = FixedArray::make(win_len, 0.0)
  let mut ref_sum = 0.0
  for k in 0..<win_len {
    let idx = ref_base + k
    let val = if idx >= 0 && idx < nx { samples[idx] } else { 0.0 }
    ref_buf[k] = val
    ref_sum += val
  }
  let ref_mean = ref_sum / win_len.to_double()
  let mut e_ref = 0.0
  for k in 0..<win_len {
    let v = ref_buf[k] - ref_mean
    ref_buf[k] = v
    e_ref += v * v
  }
  if e_ref <= 1.0e-300 {
    return None
  }
  // Evaluate normalized cross-correlation over [lag_min - 1, lag_max + 1].
  let lag_lo = if lag_min > 1 { lag_min - 1 } else { 1 }
  let lag_hi = lag_max + 1
  let n_lags = lag_hi - lag_lo + 1
  let c_arr : FixedArray[Double] = FixedArray::make(n_lags, -2.0)
  let win_len_d = win_len.to_double()
  for li in 0..<n_lags {
    let lag = lag_lo + li
    let t_base = i_cur + dir * lag - half_l
    if t_base + win_len <= 0 || t_base >= nx {
      continue
    }
    let mut dot = 0.0
    let mut t_sum = 0.0
    let mut t_sum2 = 0.0
    if t_base >= 0 && t_base + win_len <= nx {
      for k in 0..<win_len {
        let val = samples[t_base + k]
        dot += ref_buf[k] * val
        t_sum += val
        t_sum2 += val * val
      }
    } else {
      for k in 0..<win_len {
        let idx = t_base + k
        let val = if idx >= 0 && idx < nx { samples[idx] } else { 0.0 }
        dot += ref_buf[k] * val
        t_sum += val
        t_sum2 += val * val
      }
    }
    let e_t = t_sum2 - t_sum * t_sum / win_len_d
    if e_t > 1.0e-300 {
      let denom = (e_ref * e_t).sqrt()
      if denom > 1.0e-300 {
        c_arr[li] = dot / denom
      }
    }
  }
  // Locate the best integer lag inside [lag_min, lag_max].
  let start_li = lag_min - lag_lo
  let end_li = lag_max - lag_lo
  let mut best_li = start_li
  let mut best_c = c_arr[start_li]
  for li in (start_li + 1)..<=end_li {
    if c_arr[li] > best_c {
      best_c = c_arr[li]
      best_li = li
    }
  }
  if best_c <= -1.5 {
    return None
  }
  let best_lag = lag_lo + best_li
  let mut exact_lag = best_lag.to_double()
  let mut peak_cc = best_c
  if best_li > 0 && best_li < n_lags - 1 {
    let cm = c_arr[best_li - 1]
    let c0 = c_arr[best_li]
    let cp = c_arr[best_li + 1]
    if cm > -1.5 && cp > -1.5 && cm <= c0 && cp <= c0 {
      let d2 = cm - 2.0 * c0 + cp
      if d2 < 0.0 {
        let mut delta = 0.5 * (cm - cp) / d2
        if delta < -0.5 {
          delta = -0.5
        } else if delta > 0.5 {
          delta = 0.5
        }
        exact_lag = best_lag.to_double() + delta
        peak_cc = c0 - 0.25 * (cm - cp) * delta
      }
    }
  }
  if exact_lag < 1.0 {
    return None
  }
  Some((t_cur + dir.to_double() * exact_lag / sample_rate, peak_cc))
}

///|
/// Praat `Sound & Pitch: To PointProcess (cc)`: extract glottal pulse
/// timestamps from `samples` guided by a `PitchTier`.
///
/// For each contiguous voiced interval, anchors the first pulse at the
/// absolute waveform extremum near the midpoint, then steps rightward
/// and leftward using normalized cross-correlation in `[0.8 T0, 1.2 T0]`,
/// pruning outer boundary pulses with correlation `< 0.3` and allowing
/// one boundary extension step when correlation `> 0.7`.
pub fn sound_and_pitch_to_point_process_cc(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pitch~ : @types.PitchTier,
) -> @types.PointProcess {
  let nx = samples.length()
  let dur = if sample_rate > 0.0 { nx.to_double() / sample_rate } else { 0.0 }
  if nx == 0 ||
    sample_rate <= 0.0 ||
    pitch.frames.length() == 0 ||
    pitch.dt <= 0.0 {
    return { tmin: 0.0, tmax: dur, points: FixedArray::make(0, 0.0), }
  }
  let nframes = pitch.frames.length()
  let all_points : Array[Double] = []
  let mut idx = 0
  while idx < nframes {
    if pitch.frames[idx].frequency is None {
      idx += 1
      continue
    }
    let run_start = idx
    while idx + 1 < nframes && pitch.frames[idx + 1].frequency is Some(_) {
      idx += 1
    }
    let run_end = idx
    idx += 1
    let t_left = @math.dmax(0.0, pitch.frames[run_start].time - 0.5 * pitch.dt)
    let t_right = @math.dmin(dur, pitch.frames[run_end].time + 0.5 * pitch.dt)
    if t_right <= t_left {
      continue
    }
    let t_mid = 0.5 * (t_left + t_right)
    let mid_frame_f = match pitch.frames[(run_start + run_end) / 2].frequency {
      Some(f) => f
      None => continue
    }
    let f_mid = match pitch.value_at(t_mid) {
      Some(f) => if f > 0.0 { f } else { mid_frame_f }
      None => mid_frame_f
    }
    if f_mid <= 0.0 {
      continue
    }
    let t0_mid = 1.0 / f_mid
    let a_lo = @math.dmax(t_left, t_mid - 0.5 * t0_mid)
    let a_hi = @math.dmin(t_right, t_mid + 0.5 * t0_mid)
    let t1 = find_abs_extremum(samples, sample_rate, a_lo, a_hi)
    // Rightward search from t1.
    let right_pts : Array[(Double, Double)] = []
    let mut t_cur = t1
    let mut guard_steps = 0
    let max_steps = @math.ceil_int((dur + 1.0) * sample_rate) + 16
    while t_cur < t_right && guard_steps < max_steps {
      guard_steps += 1
      let f_loc = match pitch.value_at(t_cur) {
        Some(f) => if f > 0.0 { f } else { f_mid }
        None => f_mid
      }
      let period = 1.0 / f_loc
      guard cc_step(samples, nx, sample_rate, t_cur, period, 1)
        is Some((t_next, peak_cc)) else {
        break
      }
      if t_next <= t_cur + 0.5 / sample_rate {
        break
      }
      if t_next <= t_right {
        right_pts.push((t_next, peak_cc))
        t_cur = t_next
      } else {
        if t_next <= dur && peak_cc > 0.7 {
          right_pts.push((t_next, peak_cc))
        }
        break
      }
    }
    // Prune outer right-boundary pulses with correlation < 0.3.
    while right_pts.length() > 0 && right_pts[right_pts.length() - 1].1 < 0.3 {
      ignore(right_pts.pop())
    }
    // Leftward search from t1.
    let left_pts : Array[(Double, Double)] = []
    t_cur = t1
    guard_steps = 0
    while t_cur > t_left && guard_steps < max_steps {
      guard_steps += 1
      let f_loc = match pitch.value_at(t_cur) {
        Some(f) => if f > 0.0 { f } else { f_mid }
        None => f_mid
      }
      let period = 1.0 / f_loc
      guard cc_step(samples, nx, sample_rate, t_cur, period, -1)
        is Some((t_prev, peak_cc)) else {
        break
      }
      if t_prev >= t_cur - 0.5 / sample_rate {
        break
      }
      if t_prev >= t_left {
        left_pts.push((t_prev, peak_cc))
        t_cur = t_prev
      } else {
        if t_prev >= 0.0 && peak_cc > 0.7 {
          left_pts.push((t_prev, peak_cc))
        }
        break
      }
    }
    // Prune outer left-boundary pulses with correlation < 0.3.
    while left_pts.length() > 0 && left_pts[left_pts.length() - 1].1 < 0.3 {
      ignore(left_pts.pop())
    }
    let mut k = left_pts.length() - 1
    while k >= 0 {
      all_points.push(left_pts[k].0)
      k -= 1
    }
    all_points.push(t1)
    for p in right_pts {
      all_points.push(p.0)
    }
  }
  all_points.sort_by(fn(a, b) { if a < b { -1 } else if a > b { 1 } else { 0 } })
  // Deduplicate pulses closer than one sample.
  let min_gap = 1.0 / sample_rate
  let dedup : Array[Double] = []
  for t in all_points {
    if t >= 0.0 && t <= dur {
      if dedup.length() == 0 || t - dedup[dedup.length() - 1] > min_gap {
        dedup.push(t)
      }
    }
  }
  let pts : FixedArray[Double] = FixedArray::make(dedup.length(), 0.0)
  for i in 0..<dedup.length() {
    pts[i] = dedup[i]
  }
  { tmin: 0.0, tmax: dur, points: pts, }
}

///|
/// Praat `Sound: To PointProcess (periodic, cc)...`: runs `pitch_cc`
/// and extracts glottal pulse timestamps via cross-correlation tracking.
pub fn point_process_cc(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
) -> @types.PointProcess {
  let pt = pitch_cc(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
  sound_and_pitch_to_point_process_cc(samples, sample_rate~, pitch=pt)
}
