// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Voice quality, glottal pulse, and perturbation data structures.

///|
/// Evenly sampled Harmonics-to-Noise Ratio (HNR) contour in dB.
/// `None` marks unvoiced or silent frames (Praat's `--undefined--`).
pub(all) struct HarmonicityTier {
  t1 : Double
  dt : Double
  values : Array[Double?]
}

///|
/// Nearest-frame HNR lookup in dB. Returns `None` outside the tier
/// domain or when the frame is unvoiced/undefined.
pub fn HarmonicityTier::value_at(self : HarmonicityTier, t : Double) -> Double? {
  let n = self.values.length()
  if n == 0 || self.dt <= 0.0 {
    return None
  }
  let idx = @math.floor_int((t - self.t1) / self.dt + 0.5)
  if idx < 0 || idx >= n {
    return None
  }
  self.values[idx]
}

///|
/// Average HNR in dB over voiced frames within `[tmin, tmax]` (or over
/// the entire tier when `tmax <= tmin`). Returns `None` if no voiced
/// frames fall in range.
pub fn HarmonicityTier::mean(
  self : HarmonicityTier,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
) -> Double? {
  let use_all = tmax <= tmin
  let mut sum = 0.0
  let mut count = 0
  for i, v in self.values {
    let t = self.t1 + i.to_double() * self.dt
    if use_all || (t >= tmin && t <= tmax) {
      if v is Some(hnr) {
        sum += hnr
        count += 1
      }
    }
  }
  if count > 0 {
    Some(sum / count.to_double())
  } else {
    None
  }
}

///|
/// Sequence of glottal pulse / point-process timestamps in seconds,
/// matching Praat's `PointProcess` object.
pub(all) struct PointProcess {
  tmin : Double
  tmax : Double
  points : FixedArray[Double]
}

///|
/// Number of points in the `PointProcess`.
pub fn PointProcess::length(self : PointProcess) -> Int32 {
  self.points.length()
}

///|
/// Average valid glottal period in seconds within `[tmin, tmax]` (or
/// over the whole `PointProcess` when `tmax <= tmin`), matching Praat's
/// `PointProcess: Get mean period...`.
pub fn PointProcess::mean_period(
  self : PointProcess,
  tmin~ : Double = 0.0,
  tmax~ : Double = 0.0,
  shortest_period~ : Double = 0.0001,
  longest_period~ : Double = 0.02,
  max_period_factor~ : Double = 1.3,
) -> Double? {
  let use_all = tmax <= tmin
  let sel : Array[Double] = []
  for i in 0..<self.points.length() {
    let p = self.points[i]
    if use_all || (p >= tmin && p <= tmax) {
      sel.push(p)
    }
  }
  if sel.length() < 2 {
    return None
  }
  let m = sel.length() - 1
  let periods : FixedArray[Double] = FixedArray::make(m, 0.0)
  for i in 0..<m {
    periods[i] = sel[i + 1] - sel[i]
  }
  if m == 1 {
    let p0 = periods[0]
    if p0 >= shortest_period && p0 <= longest_period {
      return Some(p0)
    } else {
      return None
    }
  }
  fn in_range(p : Double) -> Bool {
    p >= shortest_period && p <= longest_period
  }
  fn ratio_ok(a : Double, b : Double) -> Bool {
    a > 0.0 &&
    b > 0.0 &&
    a <= b * max_period_factor &&
    b <= a * max_period_factor
  }
  let mut sum = 0.0
  let mut count = 0
  for k in 0..<m {
    let pk = periods[k]
    if !in_range(pk) {
      continue
    }
    let left_ok = k > 0 &&
      in_range(periods[k - 1]) &&
      ratio_ok(periods[k - 1], pk)
    let right_ok = k + 1 < m &&
      in_range(periods[k + 1]) &&
      ratio_ok(pk, periods[k + 1])
    if left_ok || right_ok {
      sum += pk
      count += 1
    }
  }
  if count > 0 {
    Some(sum / count.to_double())
  } else {
    None
  }
}

///|
/// Standard Praat cycle-to-cycle frequency perturbation (jitter) metrics.
/// Relative quantities (`local_rel`, `rap`, `ppq5`, `ddp`) are
/// dimensionless fractions (multiply by 100 for percentage);
/// `local_abs` is in seconds.
pub(all) struct JitterMetrics {
  local_rel : Double?
  local_abs : Double?
  rap : Double?
  ppq5 : Double?
  ddp : Double?
}

///|
/// Standard Praat cycle-to-cycle amplitude perturbation (shimmer)
/// metrics. `local_rel`, `apq3`, `apq5`, `apq11`, and `dda` are
/// dimensionless fractions (multiply by 100 for percentage); `local_db`
/// is in decibels.
pub(all) struct ShimmerMetrics {
  local_rel : Double?
  local_db : Double?
  apq3 : Double?
  apq5 : Double?
  apq11 : Double?
  dda : Double?
}
