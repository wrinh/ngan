// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for `power_cepstrogram` and `cpps`.

///|
test "power_cepstrogram and cpps distinguish harmonic pulse train from noise" {
  let fs = 16000.0
  let n = 16000
  // Periodic glottal pulse train at 200 Hz (T0 = 0.005 s) through an all-pole filter.
  let r = @math.exp(-@math.PI * 100.0 / fs)
  let th = 2.0 * @math.PI * 500.0 / fs
  let a1 = -2.0 * r * @math.cos(th)
  let a2 = r * r
  let harmonic : FixedArray[Double] = FixedArray::make(n, 0.0)
  let mut phase = 0.0
  let mut since = 100
  for i in 0..<n {
    phase += 2.0 * @math.PI * 200.0 / fs
    if phase >= 2.0 * @math.PI {
      phase -= 2.0 * @math.PI
      since = 0
    } else {
      since += 1
    }
    let exc = @math.exp(-since.to_double() * 0.2) + 0.005 * prand(i)
    let p1 = if i >= 1 { a1 * harmonic[i - 1] } else { 0.0 }
    let p2 = if i >= 2 { a2 * harmonic[i - 2] } else { 0.0 }
    harmonic[i] = exc - p1 - p2
  }
  let pc_h = power_cepstrogram(harmonic, sample_rate=fs)
  assert_true(pc_h.number_of_time_frames > 100)
  assert_true(pc_h.number_of_quefrency_bins > 100)
  assert_true(pc_h.db_at(t=0.5, q=0.005) is Some(_))
  guard cpps(pc_h) is Some(cpps_h) else { fail("expected CPPS for harmonic") }
  assert_true(cpps_h > 8.0)

  // Pure noise has flat cepstrum and low CPPS.
  let noise : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    noise[i] = prand(i) * 0.5
  }
  let pc_n = power_cepstrogram(noise, sample_rate=fs)
  guard cpps(pc_n) is Some(cpps_n) else { fail("expected CPPS for noise") }
  assert_true(cpps_h > cpps_n + 4.0)
}
