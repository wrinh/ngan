// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Segment-level acoustic summarization over TextGrid interval tiers:
// computes F0 statistics, F1–F3 means, intensity mean/max, and
// normalized trajectory points (default 20%–50%–80%).

///|
fn is_blank_label(s : String) -> Bool {
  for c in s {
    if c != ' ' && c != '\t' && c != '\r' && c != '\n' {
      return false
    }
  }
  true
}

///|
fn summarize_segment_f0(
  pitch : @types.PitchTier,
  xmin : Double,
  xmax : Double,
  mid : Double,
) -> (Double?, Double?, Double?, Double?, Double) {
  let voiced_f0 : Array[Double] = []
  let mut total_frames = 0
  let mut sum = 0.0
  let mut min_f = 0.0
  let mut max_f = 0.0
  for fr in pitch.frames {
    if fr.time >= xmin && fr.time <= xmax {
      total_frames += 1
      if fr.frequency is Some(f) {
        if voiced_f0.length() == 0 {
          min_f = f
          max_f = f
        } else {
          if f < min_f {
            min_f = f
          }
          if f > max_f {
            max_f = f
          }
        }
        voiced_f0.push(f)
        sum += f
      }
    }
  }
  if total_frames == 0 {
    return match pitch.value_at(mid) {
      Some(f) => (Some(f), Some(f), Some(f), None, 1.0)
      None => (None, None, None, None, 0.0)
    }
  }
  let n_voiced = voiced_f0.length()
  let vf = n_voiced.to_double() / total_frames.to_double()
  if n_voiced == 0 {
    return (None, None, None, None, 0.0)
  }
  let mean = sum / n_voiced.to_double()
  let sd : Double? = if n_voiced >= 2 {
    let mut ss = 0.0
    for f in voiced_f0 {
      let d = f - mean
      ss += d * d
    }
    Some((ss / (n_voiced - 1).to_double()).sqrt())
  } else {
    None
  }
  (Some(mean), Some(min_f), Some(max_f), sd, vf)
}

///|
fn segment_formant_mean(
  formants : @types.FormantTier,
  formant_number : Int32,
  xmin : Double,
  xmax : Double,
  mid : Double,
) -> Double? {
  if formant_number < 1 {
    return None
  }
  let idx = formant_number - 1
  let mut sum = 0.0
  let mut count = 0
  for fr in formants.frames {
    if fr.time >= xmin && fr.time <= xmax {
      if idx < fr.formants.length() {
        sum += fr.formants[idx].frequency
        count += 1
      }
    }
  }
  if count > 0 {
    Some(sum / count.to_double())
  } else {
    formants.value_at(formant_number, mid)
  }
}

///|
fn summarize_segment_intensity(
  intensity : @types.IntensityTier,
  xmin : Double,
  xmax : Double,
  mid : Double,
  energy_intensity : Bool,
) -> (Double?, Double?) {
  let n = intensity.values.length()
  let mut sum = 0.0
  let mut max_v = 0.0
  let mut count = 0
  for i in 0..<n {
    let t = intensity.t1 + i.to_double() * intensity.dt
    if t >= xmin && t <= xmax {
      let v = intensity.values[i]
      if count == 0 || v > max_v {
        max_v = v
      }
      if energy_intensity {
        sum += @math.pow(10.0, v / 10.0)
      } else {
        sum += v
      }
      count += 1
    }
  }
  if count == 0 {
    let v = intensity.value_at_linear(mid)
    return (v, v)
  }
  let mean_db = if energy_intensity {
    let mean_e = sum / count.to_double()
    if mean_e <= 1.0e-30 {
      -300.0
    } else {
      10.0 * @math.log10(mean_e)
    }
  } else {
    sum / count.to_double()
  }
  (Some(mean_db), Some(max_v))
}

///|
/// Summarize acoustic measurements (F0, F1–F3, intensity, and dynamic
/// trajectory points) across intervals of a single `IntervalTier`.
pub fn summarize_interval_tier(
  tier : @types.IntervalTier,
  pitch~ : @types.PitchTier,
  formants~ : @types.FormantTier,
  intensity~ : @types.IntensityTier,
  trajectory_points~ : ArrayView[Double] = [0.2, 0.5, 0.8],
  skip_empty~ : Bool = true,
  energy_intensity~ : Bool = true,
) -> Array[@types.SegmentSummary] {
  let out : Array[@types.SegmentSummary] = []
  for idx, iv in tier.intervals {
    if skip_empty && is_blank_label(iv.text) {
      continue
    }
    let xmin = iv.xmin
    let xmax = iv.xmax
    let duration = @math.dmax(0.0, xmax - xmin)
    let mid = 0.5 * (xmin + xmax)
    let (f0_mean, f0_min, f0_max, f0_sd, voiced_fraction) = summarize_segment_f0(
      pitch, xmin, xmax, mid,
    )
    let f1_mean = segment_formant_mean(formants, 1, xmin, xmax, mid)
    let f2_mean = segment_formant_mean(formants, 2, xmin, xmax, mid)
    let f3_mean = segment_formant_mean(formants, 3, xmin, xmax, mid)
    let (intensity_mean, intensity_max) = summarize_segment_intensity(
      intensity, xmin, xmax, mid, energy_intensity,
    )
    let trajectory : Array[@types.SegmentTrajectoryPoint] = []
    for p in trajectory_points {
      let t = xmin + p * duration
      trajectory.push({
        proportion: p,
        time: t,
        f0: pitch.value_at(t),
        f1: formants.value_at(1, t),
        f2: formants.value_at(2, t),
        f3: formants.value_at(3, t),
        intensity: intensity.value_at_linear(t),
      })
    }
    out.push({
      tier_name: tier.name,
      index: idx,
      label: iv.text,
      xmin,
      xmax,
      duration,
      f0_mean,
      f0_min,
      f0_max,
      f0_sd,
      voiced_fraction,
      f1_mean,
      f2_mean,
      f3_mean,
      intensity_mean,
      intensity_max,
      trajectory,
    })
  }
  out
}

///|
/// Summarize acoustic measurements across one named `IntervalTier` (when
/// `tier_name` is supplied) or all `IntervalTier`s in `tg`.
pub fn summarize_textgrid(
  tg : @types.TextGrid,
  pitch~ : @types.PitchTier,
  formants~ : @types.FormantTier,
  intensity~ : @types.IntensityTier,
  tier_name? : String,
  trajectory_points~ : ArrayView[Double] = [0.2, 0.5, 0.8],
  skip_empty~ : Bool = true,
  energy_intensity~ : Bool = true,
) -> Array[@types.SegmentSummary] {
  match tier_name {
    Some(name) =>
      match tg.interval_tier(name) {
        Some(tier) =>
          summarize_interval_tier(
            tier,
            pitch~,
            formants~,
            intensity~,
            trajectory_points~,
            skip_empty~,
            energy_intensity~,
          )
        None => []
      }
    None => {
      let out : Array[@types.SegmentSummary] = []
      for tier in tg.interval_tiers() {
        let segs = summarize_interval_tier(
          tier,
          pitch~,
          formants~,
          intensity~,
          trajectory_points~,
          skip_empty~,
          energy_intensity~,
        )
        for seg in segs {
          out.push(seg)
        }
      }
      out
    }
  }
}

///|
/// Run Praat-compatible intensity, pitch, and formant analysis on
/// `samples` and aggregate measurements over the intervals of `tg`.
pub fn analyze_segments(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  tg : @types.TextGrid,
  tier_name? : String,
  trajectory_points~ : ArrayView[Double] = [0.2, 0.5, 0.8],
  skip_empty~ : Bool = true,
  energy_intensity~ : Bool = true,
  min_pitch~ : Double = 100.0,
  pitch_floor~ : Double = 75.0,
  pitch_ceiling~ : Double = 600.0,
  max_num_formants~ : Int32 = 5,
  max_formant_freq~ : Double = 5500.0,
  use_formant_tracking~ : Bool = false,
) -> Array[@types.SegmentSummary] {
  let it = intensity(samples, sample_rate~, min_pitch~)
  let pt = pitch(samples, sample_rate~, pitch_floor~, pitch_ceiling~)
  let raw_ft = formants(
    samples,
    sample_rate~,
    max_num_formants~,
    max_formant_freq~,
  )
  let ft = if use_formant_tracking {
    let nt = if max_num_formants < 3 { max_num_formants } else { 3 }
    track_formants(raw_ft, num_tracks=nt)
  } else {
    raw_ft
  }
  summarize_textgrid(
    tg,
    pitch=pt,
    formants=ft,
    intensity=it,
    tier_name?,
    trajectory_points~,
    skip_empty~,
    energy_intensity~,
  )
}
