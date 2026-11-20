// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for LTAS, Center of Gravity, Spectral Slope, and
// Harmonic Tilt (H1-H2, H1*-H2*, H1-A1..A3).

///|
test "ltas and spectrogram_to_ltas on a 1050 hz sine" {
  let fs = 16000.0
  // 1050 Hz sits inside the [1000, 1100] Hz bin rather than on a boundary.
  let x = sine_fa(16000, fs, 1050.0, 1.0, 0.0)
  let lt = ltas(x, sample_rate=fs, bandwidth=100.0)
  assert_true(lt.values.length() == 80)
  // Average PSD in the 100 Hz bin holding a unit sine: 0.5 / 100 = 0.005 Pa^2/Hz
  // -> 10 * log10(0.005 / 4e-10) = 70.9691 dB/Hz.
  let mut best_b = 0
  let mut best_db = -1000.0
  for b in 0..<lt.values.length() {
    if lt.values[b] > best_db {
      best_db = lt.values[b]
      best_b = b
    }
  }
  let peak_f = lt.f1 + best_b.to_double() * lt.df
  assert_true(approx(peak_f, 1050.0, 1.0e-9))
  assert_true(approx(best_db, 70.96910013008056, 1.0))
  guard lt.slope(
      fmin_low=0.0,
      fmax_low=1500.0,
      fmin_high=1500.0,
      fmax_high=4000.0,
    )
    is Some(sl) else {
    fail("expected LTAS slope")
  }
  assert_true(sl < -30.0)

  let sg = spectrogram(x, sample_rate=fs)
  let s_lt = spectrogram_to_ltas(sg, bandwidth=100.0)
  let mut s_best_b = 0
  let mut s_best_db = -1000.0
  for b in 0..<s_lt.values.length() {
    if s_lt.values[b] > s_best_db {
      s_best_db = s_lt.values[b]
      s_best_b = b
    }
  }
  let s_peak_f = s_lt.f1 + s_best_b.to_double() * s_lt.df
  assert_true(s_peak_f >= 900.0 && s_peak_f <= 1100.0)
  guard s_lt.slope(
      fmin_low=0.0,
      fmax_low=1500.0,
      fmin_high=1500.0,
      fmax_high=4000.0,
    )
    is Some(s_sl) else {
    fail("expected spectrogram LTAS slope")
  }
  assert_true(s_sl < -20.0)
}

///|
test "center_of_gravity and spectrogram spectral features" {
  let fs = 16000.0
  // 16384 = 2^14 aligns 500 Hz (bin 512) and 1500 Hz (bin 1536) cleanly.
  let n = 16384
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double() / fs
    x[i] = 2.0 * @math.sin(2.0 * @math.PI * 500.0 * t) +
      1.0 * @math.sin(2.0 * @math.PI * 1500.0 * t)
  }
  // Power = 2.0: (4*500 + 1*1500)/5 = 700 Hz.
  guard center_of_gravity(x, sample_rate=fs, power=2.0) is Some(cog2) else {
    fail("missing cog2")
  }
  assert_true(approx(cog2, 700.0, 10.0))
  // Power = 1.0: (2*500 + 1*1500)/3 = 833.33 Hz.
  guard center_of_gravity(x, sample_rate=fs, power=1.0) is Some(cog1) else {
    fail("missing cog1")
  }
  assert_true(approx(cog1, 833.3333333333334, 15.0))
  // Silence -> None.
  let silence : FixedArray[Double] = FixedArray::make(1024, 0.0)
  assert_true(center_of_gravity(silence, sample_rate=fs) is None)

  // Spectrogram CoG and spectral slope on 1000 Hz sine.
  let s1000 = sine_fa(16000, fs, 1000.0, 1.0, 0.0)
  let sg = spectrogram(s1000, sample_rate=fs)
  let sg_cog = spectrogram_center_of_gravity(sg)
  guard sg_cog.value_at(0.5) is Some(mid_cog) else {
    fail("missing mid spectrogram CoG")
  }
  assert_true(approx(mid_cog, 1000.0, sg.df))
  let sg_slope = spectrogram_spectral_slope(sg, fmin=800.0, fmax=3000.0)
  guard sg_slope.value_at(0.5) is Some(mid_slope) else {
    fail("missing mid spectrogram slope")
  }
  assert_true(mid_slope < 0.0)
}

///|
test "spectral_tilt measures H1-H2 and formant corrections" {
  let fs = 16000.0
  let n = 16000
  fn two_harm(a1 : Double, a2 : Double) -> FixedArray[Double] {
    let out : FixedArray[Double] = FixedArray::make(n, 0.0)
    for i in 0..<n {
      let t = i.to_double() / fs
      out[i] = a1 * @math.sin(2.0 * @math.PI * 200.0 * t) +
        a2 * @math.sin(2.0 * @math.PI * 400.0 * t)
    }
    out
  }
  let x_pos = two_harm(1.0, 0.5)
  let pt_pos = pitch(x_pos, sample_rate=fs)
  let st_pos = spectral_tilt(x_pos, sample_rate=fs, pitch=pt_pos)
  let mid = st_pos.frames[st_pos.frames.length() / 2]
  guard mid.h1_minus_h2 is Some(d_pos) else { fail("missing +6dB H1-H2") }
  assert_true(approx(d_pos, 6.020599913279624, 0.3))

  let x_neg = two_harm(0.5, 1.0)
  let pt_neg = pitch(x_neg, sample_rate=fs)
  let st_neg = spectral_tilt(x_neg, sample_rate=fs, pitch=pt_neg)
  let mid_neg = st_neg.frames[st_neg.frames.length() / 2]
  guard mid_neg.h1_minus_h2 is Some(d_neg) else { fail("missing -6dB H1-H2") }
  assert_true(approx(d_neg, -6.020599913279624, 0.3))

  // Synthetic vowel-like formant tier triggers H1-A1..A2 and H1*-H2*.
  let vowel = make_vowel(fs, 500.0, 1500.0, 100.0, n, 0.4)
  let ft = formants(vowel, sample_rate=fs)
  let st_corr = spectral_tilt(
    x_pos,
    sample_rate=fs,
    pitch=pt_pos,
    formants=Some(ft),
  )
  let mid_c = st_corr.frames[st_corr.frames.length() / 2]
  guard mid_c.h1_minus_h2 is Some(raw_h12) else {
    fail("missing raw h1_minus_h2")
  }
  guard mid_c.h1_minus_h2_corrected is Some(corr_h12) else {
    fail("missing corrected h1_minus_h2")
  }
  assert_true(mid_c.h1_minus_a1 is Some(_))
  assert_true(mid_c.h1_minus_a2 is Some(_))
  assert_true(mid_c.spectral_slope is Some(_))
  // F1 (~500 Hz) sits closer to H2 (400 Hz) than H1 (200 Hz), so removing
  // the vocal-tract boost raises H1*-H2* relative to raw H1-H2.
  assert_true(corr_h12 > raw_h12)
}
