// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for the spectrogram analysis (`approx` comes from
// analysis_wbtest.mbt in the same package).

///|
test "spectrogram of a 1000 hz sine at 16 khz" {
  // Defaults: 0.005 s effective Gaussian window (0.01 s physical),
  // time step max(0.002, 0.00282/8) = 0.002 s, frequency step raised to
  // 44.31 Hz then snapped to one 31.25 Hz FFT bin (nsampFFT = 512).
  let fs = 16000.0
  let n = 16000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = @math.sin(2.0 * @math.PI * 1000.0 * i.to_double() / fs)
  }
  let sg = spectrogram(x, sample_rate=fs)
  assert_true(
    sg.number_of_time_frames >= 494 && sg.number_of_time_frames <= 496,
  )
  assert_true(approx(sg.dt, 0.002, 1.0e-12))
  assert_true(sg.t1 > 0.0 && sg.t1 < 0.01)
  assert_eq(sg.number_of_frequency_bands, 160)
  assert_true(approx(sg.df, 31.25, 1.0e-9))
  assert_true(approx(sg.f1, 0.0, 1.0e-9))
  // The mid frame must peak in the band centred at 1000 Hz.
  let mid = sg.number_of_time_frames / 2
  let mut best_band = 0
  let mut best_power = -1.0
  for band in 0..<sg.number_of_frequency_bands {
    let p = sg.power[band * sg.number_of_time_frames + mid]
    if p > best_power {
      best_power = p
      best_band = band
    }
  }
  let peak_f = sg.f1 + best_band.to_double() * sg.df
  assert_true(approx(peak_f, 1000.0, sg.df))
  // A Gaussian window suppresses the 2000 Hz region by orders of
  // magnitude.
  guard sg.power_at(t=0.5, f=1000.0) is Some(p1) else {
    fail("power at 1000 Hz undefined")
  }
  guard sg.power_at(t=0.5, f=2000.0) is Some(p2) else {
    fail("power at 2000 Hz undefined")
  }
  assert_true(p1 > 50.0 * p2)
}

///|
test "spectrogram clamps the ceiling to nyquist" {
  // fs = 8000 Hz with the 5000 Hz default -> 4000 Hz ceiling.
  let fs = 8000.0
  let n = 8000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = @math.sin(2.0 * @math.PI * 500.0 * i.to_double() / fs)
  }
  let sg = spectrogram(x, sample_rate=fs)
  // nsampFFT = 256 -> bin width 31.25 Hz, 128 bands below 4000 Hz.
  assert_eq(sg.number_of_frequency_bands, 128)
  assert_true(approx(sg.df, 31.25, 1.0e-9))
  let top = sg.f1 + (sg.number_of_frequency_bands - 1).to_double() * sg.df
  assert_true(approx(top, 4000.0 - 31.25, 1.0e-9))
  let mid = sg.number_of_time_frames / 2
  let mut best_band = 0
  let mut best_power = -1.0
  for band in 0..<sg.number_of_frequency_bands {
    let p = sg.power[band * sg.number_of_time_frames + mid]
    if p > best_power {
      best_power = p
      best_band = band
    }
  }
  let peak_f = sg.f1 + best_band.to_double() * sg.df
  assert_true(approx(peak_f, 500.0, sg.df))
  assert_true(sg.max_power() > 0.0)
  // Out-of-grid queries are undefined, in-grid queries interpolate.
  assert_true(sg.power_at(t=0.5, f=500.0) is Some(_))
  assert_true(sg.power_at(t=-1.0, f=500.0) is None)
  assert_true(sg.power_at(t=99.0, f=500.0) is None)
  assert_true(sg.power_at(t=0.5, f=-5.0) is None)
  assert_true(sg.power_at(t=0.5, f=5000.0) is None)
}

///|
test "spectrogram grid values are positive for a chirp-free signal" {
  let fs = 16000.0
  let n = 4000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = 0.5 * @math.sin(2.0 * @math.PI * 300.0 * i.to_double() / fs) +
      0.25 * @math.sin(2.0 * @math.PI * 2500.0 * i.to_double() / fs)
  }
  let sg = spectrogram(x, sample_rate=fs)
  assert_true(sg.number_of_time_frames > 50)
  let mut nonpositive = 0
  for i in 0..<sg.power.length() {
    if sg.power[i] <= 0.0 {
      nonpositive += 1
    }
  }
  assert_eq(nonpositive, 0)
  // The two partials dominate their bands (300 -> band 9, 2500 -> band 80).
  let mid = sg.number_of_time_frames / 2
  fn band_power(
    sg : @types.Spectrogram,
    band : Int32,
    frame : Int32,
  ) -> Double {
    sg.power[band * sg.number_of_time_frames + frame]
  }
  let p300 = band_power(sg, 9, mid)
  let p2500 = band_power(sg, 80, mid)
  let pmid = band_power(sg, 45, mid)
  assert_true(p300 > 20.0 * pmid)
  assert_true(p2500 > 5.0 * pmid)
}
