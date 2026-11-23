// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// PowerCepstrogram result type matching Praat's `PowerCepstrogram`.

///|
/// Time-quefrency grid of linear power cepstrum values (Praat's
/// `PowerCepstrogram`): frames at `t1 + i * dt`, quefrency bins at
/// `q1 + j * dq` (seconds). `power` is flattened quefrency-major:
/// `index = q_bin * number_of_time_frames + frame`.
pub(all) struct PowerCepstrogram {
  t1 : Double
  dt : Double
  number_of_time_frames : Int32
  q1 : Double
  dq : Double
  number_of_quefrency_bins : Int32
  power : FixedArray[Double]
}

///|
/// Bilinearly interpolated linear cepstral power at `(t, q)`, or `None`
/// outside the grid.
pub fn PowerCepstrogram::power_at(
  self : PowerCepstrogram,
  t~ : Double,
  q~ : Double,
) -> Double? {
  let ntime = self.number_of_time_frames
  let nq = self.number_of_quefrency_bins
  if ntime < 1 || nq < 1 || self.dt <= 0.0 || self.dq <= 0.0 {
    return None
  }
  let rt = (t - self.t1) / self.dt
  let rq = (q - self.q1) / self.dq
  if rt < 0.0 || rt > (ntime - 1).to_double() {
    return None
  }
  if rq < 0.0 || rq > (nq - 1).to_double() {
    return None
  }
  let f0i = rt.floor().to_int()
  let q0i = rq.floor().to_int()
  let fx = rt - f0i.to_double()
  let fy = rq - q0i.to_double()
  let f1i = if f0i + 1 <= ntime - 1 { f0i + 1 } else { f0i }
  let q1i = if q0i + 1 <= nq - 1 { q0i + 1 } else { q0i }
  let p00 = self.power[q0i * ntime + f0i]
  let p10 = self.power[q1i * ntime + f0i]
  let p01 = self.power[q0i * ntime + f1i]
  let p11 = self.power[q1i * ntime + f1i]
  let at_f0 = p00 * (1.0 - fy) + p10 * fy
  let at_f1 = p01 * (1.0 - fy) + p11 * fy
  Some(at_f0 * (1.0 - fx) + at_f1 * fx)
}

///|
/// Bilinearly interpolated cepstral power in dB (`10 * log10(max(p, 1e-30))`)
/// at `(t, q)`, or `None` outside the grid.
pub fn PowerCepstrogram::db_at(
  self : PowerCepstrogram,
  t~ : Double,
  q~ : Double,
) -> Double? {
  match self.power_at(t~, q~) {
    Some(p) => {
      let safe = if p > 1.0e-30 { p } else { 1.0e-30 }
      Some(10.0 * @math.log10(safe))
    }
    None => None
  }
}
