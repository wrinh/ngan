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

///|
test "smooth_cepstral_grid avoids prefix-sum catastrophic cancellation" {
  // Regression test: huge DC spike at q=0 (1e18) must not wipe out small
  // values (1.0) at q >= 1, for both small (direct) and large (van Herk) windows.
  let nq = 60
  let nt = 50
  let src : FixedArray[Double] = FixedArray::make(nq * nt, 1.0)
  for t in 0..<nt {
    src[t] = 1.0e18
  }
  for q in 0..<nq {
    src[q * nt] = 1.0e18
  }
  for pair in [(5, 5), (37, 41), (99, 121)] {
    let (ns_t, ns_q) = pair
    let sm = smooth_cepstral_grid(src, nq, nt, ns_t, ns_q)
    let half_t = ns_t / 2
    let half_q = ns_q / 2
    // Verify against direct reference on an interior cell unaffected by row/col 0.
    let qt = nq - 1
    let tt = nt - 1
    if qt - half_q >= 1 && tt - half_t >= 1 {
      assert_true(approx(sm[qt * nt + tt], 1.0, 1.0e-12))
    }
    // Verify every cell matches direct boxcar smoothing on a well-scaled grid.
    let grid : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
    for i in 0..<(nq * nt) {
      grid[i] = 1.0 + 0.5 * prand(i)
    }
    let got = smooth_cepstral_grid(grid, nq, nt, ns_t, ns_q)
    // Direct reference: time then quefrency.
    let tmp : FixedArray[Double] = FixedArray::make(nq * nt, 0.0)
    for q in 0..<nq {
      for t in 0..<nt {
        let lo = if t - half_t < 0 { 0 } else { t - half_t }
        let hi = if t + half_t >= nt { nt - 1 } else { t + half_t }
        let mut s = 0.0
        for k in lo..<=hi {
          s += grid[q * nt + k]
        }
        tmp[q * nt + t] = s / (hi - lo + 1).to_double()
      }
    }
    for q in 0..<nq {
      for t in 0..<nt {
        let lo = if q - half_q < 0 { 0 } else { q - half_q }
        let hi = if q + half_q >= nq { nq - 1 } else { q + half_q }
        let mut s = 0.0
        for k in lo..<=hi {
          s += tmp[k * nt + t]
        }
        let want = s / (hi - lo + 1).to_double()
        assert_true(approx(got[q * nt + t], want, 1.0e-12))
      }
    }
  }
}

///|
test "median_abs_buf quickselect handles duplicates, constants, and even/odd lengths" {
  let scratch : FixedArray[Double] = FixedArray::make(16, 0.0)
  // All-equal array (even and odd)
  let eq_arr : FixedArray[Double] = FixedArray::make(10, -3.5)
  assert_true(approx(median_abs_buf(eq_arr, 10, scratch), 3.5, 1.0e-12))
  assert_true(approx(median_abs_buf(eq_arr, 9, scratch), 3.5, 1.0e-12))
  // Reverse-sorted with duplicates
  let dup : FixedArray[Double] = [5.0, -5.0, 4.0, -2.0, 2.0, -2.0, 1.0, 0.0]
  // Sorted abs: [0, 1, 2, 2, 2, 4, 5, 5] -> median = 2.0
  assert_true(approx(median_abs_buf(dup, 8, scratch), 2.0, 1.0e-12))
  // 2-element array
  let two : FixedArray[Double] = [-1.0, 3.0]
  assert_true(approx(median_abs_buf(two, 2, scratch), 2.0, 1.0e-12))
  // 1-element array
  assert_true(approx(median_abs_buf(two, 1, scratch), 1.0, 1.0e-12))
}
