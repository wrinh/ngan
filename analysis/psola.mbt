// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat-style TD-PSOLA pitch and duration manipulation (`To Manipulation`
// and `Get resynthesis (overlap-add)`).

///|
/// Build a `Manipulation` object from `samples`: extracts pitch contour via
/// `pitch`, glottal pulses via `sound_and_pitch_to_point_process_cc`, and
/// populates editable `pitch_points` and identity `duration_points`.
pub fn to_manipulation(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.01,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
) -> @types.Manipulation {
  let nx = samples.length()
  let dur = if sample_rate > 0.0 { nx.to_double() / sample_rate } else { 0.0 }
  let pt = pitch(
    samples,
    sample_rate~,
    time_step~,
    pitch_floor~,
    pitch_ceiling~,
  )
  let pp = sound_and_pitch_to_point_process_cc(samples, sample_rate~, pitch=pt)
  let pitch_points : Array[@types.PitchPoint] = []
  for fr in pt.frames {
    if fr.frequency is Some(f) {
      pitch_points.push({ time: fr.time, frequency: f, })
    }
  }
  let duration_points : Array[@types.DurationPoint] = [
    { time: 0.0, relative_duration: 1.0, },
  ]
  {
    sample_rate,
    tmin: 0.0,
    tmax: dur,
    pulses: pp,
    pitch_points,
    duration_points,
  }
}

///|
fn interp_pitch_points(pts : Array[@types.PitchPoint], t : Double) -> Double? {
  let n = pts.length()
  if n == 0 {
    return None
  }
  if t <= pts[0].time {
    return Some(pts[0].frequency)
  }
  if t >= pts[n - 1].time {
    return Some(pts[n - 1].frequency)
  }
  let mut lo = 0
  let mut hi = n - 1
  while hi - lo > 1 {
    let mid = (lo + hi) / 2
    if pts[mid].time <= t {
      lo = mid
    } else {
      hi = mid
    }
  }
  let dt = pts[hi].time - pts[lo].time
  if dt <= 1.0e-12 {
    return Some(pts[lo].frequency)
  }
  let frac = (t - pts[lo].time) / dt
  Some(pts[lo].frequency + frac * (pts[hi].frequency - pts[lo].frequency))
}

///|
fn interp_duration_rate(
  pts : Array[@types.DurationPoint],
  t : Double,
  duration_factor : Double,
) -> Double {
  let raw = if pts.length() == 0 {
    1.0
  } else if t <= pts[0].time {
    pts[0].relative_duration
  } else if t >= pts[pts.length() - 1].time {
    pts[pts.length() - 1].relative_duration
  } else {
    let mut lo = 0
    let mut hi = pts.length() - 1
    while hi - lo > 1 {
      let mid = (lo + hi) / 2
      if pts[mid].time <= t {
        lo = mid
      } else {
        hi = mid
      }
    }
    let dt = pts[hi].time - pts[lo].time
    if dt <= 1.0e-12 {
      pts[lo].relative_duration
    } else {
      let frac = (t - pts[lo].time) / dt
      pts[lo].relative_duration +
      frac * (pts[hi].relative_duration - pts[lo].relative_duration)
    }
  }
  let scaled = raw * duration_factor
  if scaled < 0.1 {
    0.1
  } else if scaled > 10.0 {
    10.0
  } else {
    scaled
  }
}

///|
priv struct TimeWarpMap {
  step : Double
  n_grid : Int32
  tau : FixedArray[Double]
}

///|
fn build_time_warp_map(
  dur : Double,
  duration_points : Array[@types.DurationPoint],
  duration_factor : Double,
) -> TimeWarpMap {
  let step = 0.002
  let n_steps = @math.ceil_int(dur / step)
  let n_grid = if n_steps < 1 { 2 } else { n_steps + 1 }
  let tau : FixedArray[Double] = FixedArray::make(n_grid, 0.0)
  let mut r_prev = interp_duration_rate(duration_points, 0.0, duration_factor)
  for k in 1..<n_grid {
    let t_cur = @math.dmin(k.to_double() * step, dur)
    let t_prev = (k - 1).to_double() * step
    let dt = t_cur - t_prev
    let r_cur = interp_duration_rate(duration_points, t_cur, duration_factor)
    tau[k] = tau[k - 1] + 0.5 * (r_prev + r_cur) * dt
    r_prev = r_cur
  }
  { step, n_grid, tau, }
}

///|
fn TimeWarpMap::orig_to_synth(self : TimeWarpMap, t : Double) -> Double {
  if t <= 0.0 {
    return 0.0
  }
  let rf = t / self.step
  let max_idx = self.n_grid - 1
  if rf >= max_idx.to_double() {
    return self.tau[max_idx]
  }
  let i0 = @math.floor_int(rf)
  let frac = rf - i0.to_double()
  self.tau[i0] + frac * (self.tau[i0 + 1] - self.tau[i0])
}

///|
fn TimeWarpMap::synth_to_orig(
  self : TimeWarpMap,
  t_syn : Double,
  dur : Double,
) -> Double {
  if t_syn <= 0.0 {
    return 0.0
  }
  let max_idx = self.n_grid - 1
  if t_syn >= self.tau[max_idx] {
    return dur
  }
  let mut lo = 0
  let mut hi = max_idx
  while hi - lo > 1 {
    let mid = (lo + hi) / 2
    if self.tau[mid] <= t_syn {
      lo = mid
    } else {
      hi = mid
    }
  }
  let span = self.tau[hi] - self.tau[lo]
  let frac = if span > 1.0e-12 { (t_syn - self.tau[lo]) / span } else { 0.0 }
  let t = (lo.to_double() + frac) * self.step
  @math.dmin(t, dur)
}

///|
fn sample_linear(
  samples : FixedArray[Double],
  nx : Int32,
  sample_rate : Double,
  t : Double,
) -> Double {
  let rf = t * sample_rate - 0.5
  if rf < -0.5 || rf > (nx - 1).to_double() + 0.5 {
    return 0.0
  }
  let i0 = @math.floor_int(rf)
  let i1 = i0 + 1
  let v0 = if i0 >= 0 && i0 < nx { samples[i0] } else { 0.0 }
  let v1 = if i1 >= 0 && i1 < nx { samples[i1] } else { 0.0 }
  let frac = rf - i0.to_double()
  v0 + frac * (v1 - v0)
}

///|
fn ola_hanning_grain(
  samples : FixedArray[Double],
  nx : Int32,
  out : FixedArray[Double],
  w_acc : FixedArray[Double],
  n_out : Int32,
  sample_rate : Double,
  t_src : Double,
  t_syn : Double,
  half_w : Double,
) -> Unit {
  if half_w <= 0.0 {
    return
  }
  let mut i_lo = @math.ceil_int((t_syn - half_w) * sample_rate - 0.5)
  let mut i_hi = @math.floor_int((t_syn + half_w) * sample_rate - 0.5)
  if i_lo < 0 {
    i_lo = 0
  }
  if i_hi >= n_out {
    i_hi = n_out - 1
  }
  for idx in i_lo..<=i_hi {
    let t_sample_syn = (idx.to_double() + 0.5) / sample_rate
    let offset = t_sample_syn - t_syn
    let rel = offset / half_w
    if rel > -1.0 && rel < 1.0 {
      let w = 0.5 * (1.0 + @math.cos(@math.PI * rel))
      let v = sample_linear(samples, nx, sample_rate, t_src + offset)
      out[idx] += v * w
      w_acc[idx] += w
    }
  }
}

///|
fn synthesize_unvoiced_span(
  samples : FixedArray[Double],
  nx : Int32,
  out : FixedArray[Double],
  w_acc : FixedArray[Double],
  n_out : Int32,
  sample_rate : Double,
  warp : TimeWarpMap,
  dur : Double,
  t_u_start : Double,
  t_u_end : Double,
) -> Unit {
  if t_u_end <= t_u_start {
    return
  }
  let s_start = warp.orig_to_synth(t_u_start)
  let s_end = warp.orig_to_synth(t_u_end)
  let hop = 0.005
  let half_w = 0.005
  let mut t_syn = s_start
  while t_syn <= s_end + 1.0e-9 {
    let t_orig = warp.synth_to_orig(t_syn, dur)
    ola_hanning_grain(
      samples, nx, out, w_acc, n_out, sample_rate, t_orig, t_syn, half_w,
    )
    t_syn += hop
  }
}

///|
fn psola_core(
  samples : FixedArray[Double],
  sample_rate : Double,
  pt : @types.PitchTier,
  pp : @types.PointProcess,
  pitch_points : Array[@types.PitchPoint],
  duration_points : Array[@types.DurationPoint],
  pitch_scale : Double,
  pitch_shift_semitones : Double,
  duration_factor : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_period_factor : Double,
) -> FixedArray[Double] {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || pitch_floor <= 0.0 {
    return FixedArray::make(0, 0.0)
  }
  let dur = nx.to_double() / sample_rate
  let sorted_pitch : Array[@types.PitchPoint] = []
  for p in pitch_points {
    if p.frequency > 0.0 {
      sorted_pitch.push(p)
    }
  }
  sorted_pitch.sort_by(fn(a, b) {
    if a.time < b.time {
      -1
    } else if a.time > b.time {
      1
    } else {
      0
    }
  })
  let sorted_dur : Array[@types.DurationPoint] = []
  for d in duration_points {
    sorted_dur.push(d)
  }
  sorted_dur.sort_by(fn(a, b) {
    if a.time < b.time {
      -1
    } else if a.time > b.time {
      1
    } else {
      0
    }
  })
  let warp = build_time_warp_map(dur, sorted_dur, duration_factor)
  let dur_out = warp.tau[warp.n_grid - 1]
  let n_out_raw = @math.round_int(dur_out * sample_rate)
  let n_out = if n_out_raw < 1 { 1 } else { n_out_raw }
  let out : FixedArray[Double] = FixedArray::make(n_out, 0.0)
  let w_acc : FixedArray[Double] = FixedArray::make(n_out, 0.0)
  let pitch_mult = pitch_scale * @math.pow(2.0, pitch_shift_semitones / 12.0)
  let f_lo = 0.5 * pitch_floor
  let f_hi = 2.0 * pitch_ceiling
  let max_period = max_period_factor / pitch_floor
  let min_period = if pitch_ceiling > 0.0 {
    0.7 / pitch_ceiling
  } else {
    0.0005
  }
  let np = pp.points.length()
  if np < 2 {
    synthesize_unvoiced_span(
      samples, nx, out, w_acc, n_out, sample_rate, warp, dur, 0.0, dur,
    )
  } else {
    // Partition pulses into contiguous voiced runs.
    let run_starts : Array[Int32] = []
    let run_ends : Array[Int32] = []
    let mut r_start = 0
    for i in 0..<(np - 1) {
      if pp.points[i + 1] - pp.points[i] > max_period {
        if i > r_start {
          run_starts.push(r_start)
          run_ends.push(i)
        }
        r_start = i + 1
      }
    }
    if np - 1 > r_start {
      run_starts.push(r_start)
      run_ends.push(np - 1)
    }
    // Estimate local source period per pulse.
    let t_src_arr : FixedArray[Double] = FixedArray::make(np, 1.0 / pitch_floor)
    for i in 0..<np {
      let has_left = i > 0 && pp.points[i] - pp.points[i - 1] <= max_period
      let has_right = i + 1 < np &&
        pp.points[i + 1] - pp.points[i] <= max_period
      let mut p_est = if has_left && has_right {
        0.5 * (pp.points[i + 1] - pp.points[i - 1])
      } else if has_left {
        pp.points[i] - pp.points[i - 1]
      } else if has_right {
        pp.points[i + 1] - pp.points[i]
      } else {
        1.0 / pitch_floor
      }
      if p_est < min_period {
        p_est = min_period
      }
      if p_est > max_period {
        p_est = max_period
      }
      t_src_arr[i] = p_est
    }
    let mut cursor = 0.0
    for r_idx in 0..<run_starts.length() {
      let i0 = run_starts[r_idx]
      let i1 = run_ends[r_idx]
      let v_start = @math.dmax(cursor, pp.points[i0] - 0.5 * t_src_arr[i0])
      let v_end = @math.dmin(dur, pp.points[i1] + 0.5 * t_src_arr[i1])
      if v_start > cursor {
        synthesize_unvoiced_span(
          samples, nx, out, w_acc, n_out, sample_rate, warp, dur, cursor, v_start,
        )
      }
      let s_start = warp.orig_to_synth(pp.points[i0])
      let s_end = warp.orig_to_synth(v_end)
      let mut t_syn = s_start
      let mut k_hint = i0
      let mut guard_steps = 0
      let max_steps = n_out + 16
      while t_syn <= s_end && guard_steps < max_steps {
        guard_steps += 1
        let t_orig = warp.synth_to_orig(t_syn, dur)
        while k_hint + 1 <= i1 &&
              @math.abs(pp.points[k_hint + 1] - t_orig) <=
              @math.abs(pp.points[k_hint] - t_orig) {
          k_hint += 1
        }
        while k_hint > i0 &&
              @math.abs(pp.points[k_hint - 1] - t_orig) <
              @math.abs(pp.points[k_hint] - t_orig) {
          k_hint -= 1
        }
        let half_w = t_src_arr[k_hint]
        ola_hanning_grain(
          samples,
          nx,
          out,
          w_acc,
          n_out,
          sample_rate,
          pp.points[k_hint],
          t_syn,
          half_w,
        )
        let base_f0 = match interp_pitch_points(sorted_pitch, t_orig) {
          Some(f) => f
          None =>
            match pt.value_at(t_orig) {
              Some(f) => f
              None => 1.0 / half_w
            }
        }
        let mut target_f0 = base_f0 * pitch_mult
        if target_f0 < f_lo {
          target_f0 = f_lo
        } else if target_f0 > f_hi {
          target_f0 = f_hi
        }
        t_syn += 1.0 / target_f0
      }
      cursor = v_end
    }
    if cursor < dur {
      synthesize_unvoiced_span(
        samples, nx, out, w_acc, n_out, sample_rate, warp, dur, cursor, dur,
      )
    }
  }
  for i in 0..<n_out {
    let w = w_acc[i]
    if w > 0.0 {
      let denom = if w > 0.15 { w } else { 0.15 }
      out[i] /= denom
    }
  }
  out
}

///|
/// Resynthesize `samples` from an edited `Manipulation` object using
/// TD-PSOLA (Time-Domain Pitch-Synchronous Overlap-Add).
pub fn resynthesize_manipulation(
  samples : FixedArray[Double],
  manipulation : @types.Manipulation,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
  max_period_factor~ : Double = 1.3,
) -> FixedArray[Double] {
  let pt : @types.PitchTier = { t1: manipulation.tmin, dt: 0.01, frames: [], }
  psola_core(
    samples,
    manipulation.sample_rate,
    pt,
    manipulation.pulses,
    manipulation.pitch_points,
    manipulation.duration_points,
    1.0,
    0.0,
    1.0,
    pitch_floor,
    pitch_ceiling,
    max_period_factor,
  )
}

///|
/// Perform one-shot TD-PSOLA pitch and duration manipulation on `samples`.
///
/// Target pitch can be specified via piecewise-linear `pitch_points`
/// (or defaults to the analyzed pitch track), scaled by `pitch_scale`
/// and shifted by `pitch_shift_semitones`. Time-scale warping can be
/// specified via `duration_points` and/or global `duration_factor`.
pub fn resynthesize_psola(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  pitch_points~ : ArrayView[@types.PitchPoint] = [],
  duration_points~ : ArrayView[@types.DurationPoint] = [],
  pitch_scale~ : Double = 1.0,
  pitch_shift_semitones~ : Double = 0.0,
  duration_factor~ : Double = 1.0,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
) -> FixedArray[Double] {
  if samples.length() == 0 || sample_rate <= 0.0 {
    return FixedArray::make(0, 0.0)
  }
  let pt = pitch(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
  let pp = sound_and_pitch_to_point_process_cc(samples, sample_rate~, pitch=pt)
  let p_arr : Array[@types.PitchPoint] = []
  for p in pitch_points {
    p_arr.push(p)
  }
  let d_arr : Array[@types.DurationPoint] = []
  for d in duration_points {
    d_arr.push(d)
  }
  psola_core(
    samples, sample_rate, pt, pp, p_arr, d_arr, pitch_scale, pitch_shift_semitones,
    duration_factor, pitch_floor, pitch_ceiling, 1.3,
  )
}
