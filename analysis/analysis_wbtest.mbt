// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for the analysis package: each analyzer is validated on
// synthetic signals with known ground truth (full-scale sine -> exact dB
// SPL, 220 Hz sine -> exact f0, AR(4) resonator -> exact formants).

///|
fn approx(a : Double, b : Double, tol : Double) -> Bool {
  @math.abs(a - b) <= tol
}

///|
fn prand(n : Int32) -> Double {
  let s = @math.sin((n.to_double() + 1.0) * 12.9898) * 43758.5453
  (s - @math.floor(s)) * 2.0 - 1.0
}

///|
fn sine_fa(
  n : Int32,
  fs : Double,
  f : Double,
  amp : Double,
  dc : Double,
) -> FixedArray[Double] {
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = dc + amp * @math.sin(2.0 * @math.PI * f * i.to_double() / fs)
  }
  x
}

///|
/// Noise-driven 4th-order all-pole signal with resonances at
/// (f1, bw) and (f2, bw), sampled at `fs`.
fn make_vowel(
  fs : Double,
  f1 : Double,
  f2 : Double,
  bw : Double,
  n : Int32,
  noise : Double,
) -> FixedArray[Double] {
  let r = @math.exp(-@math.PI * bw / fs)
  let th1 = 2.0 * @math.PI * f1 / fs
  let th2 = 2.0 * @math.PI * f2 / fs
  let s1a = -2.0 * r * @math.cos(th1)
  let s1b = -2.0 * r * @math.cos(th2)
  let p1 = s1a + s1b
  let p2 = s1a * s1b + 2.0 * r * r
  let p3 = (s1a + s1b) * r * r
  let p4 = r * r * r * r
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let mut past_sum = 0.0
    for j in 1..<=4 {
      let pj = if j == 1 {
        p1
      } else if j == 2 {
        p2
      } else if j == 3 {
        p3
      } else {
        p4
      }
      if i - j >= 0 {
        past_sum += pj * x[i - j]
      }
    }
    x[i] = -past_sum + prand(i) * noise
  }
  x
}

///|
test "intensity of a full-scale sine" {
  // Mean square of a unit-amplitude sine is 0.5:
  // 10 log10(0.5 / 4e-10) = 90.9691 dB SPL.
  let fs = 16000.0
  let x = sine_fa(16000, fs, 220.0, 1.0, 0.0)
  let tier = intensity(x, sample_rate=fs, min_pitch=100.0)
  let mid = tier.values[tier.values.length() / 2]
  assert_true(approx(mid, 90.96910013008056, 0.05))
}

///|
test "intensity mean subtraction removes DC" {
  let fs = 16000.0
  // A constant 0.5 signal measures 10 log10(0.25 / 4e-10) = 87.9588 dB
  // without subtraction; with subtraction it vanishes to the floor.
  let x : FixedArray[Double] = FixedArray::make(16000, 0.5)
  let no_sub = intensity(
    x,
    sample_rate=fs,
    min_pitch=100.0,
    subtract_mean=false,
  )
  let mid_raw = no_sub.values[no_sub.values.length() / 2]
  assert_true(approx(mid_raw, 87.95880017345053, 0.01))
  let with_sub = intensity(x, sample_rate=fs, min_pitch=100.0)
  let mid_sub = with_sub.values[with_sub.values.length() / 2]
  assert_true(mid_sub <= -299.9)
  // Sine + DC with subtraction still measures the sine alone.
  let y = sine_fa(16000, fs, 220.0, 1.0, 0.5)
  let sub = intensity(y, sample_rate=fs, min_pitch=100.0)
  let mid = sub.values[sub.values.length() / 2]
  assert_true(approx(mid, 90.96910013008056, 0.06))
}

///|
test "intensity of silence floors at -300 dB" {
  let fs = 16000.0
  let x : FixedArray[Double] = FixedArray::make(8000, 0.0)
  let tier = intensity(x, sample_rate=fs, min_pitch=100.0)
  for i in 0..<tier.values.length() {
    assert_true(tier.values[i] <= -299.9)
  }
}

///|
test "pitch tracks a 220 hz sine" {
  let fs = 16000.0
  let x = sine_fa(16000, fs, 220.0, 1.0, 0.0)
  let tier = pitch_ac(x, sample_rate=fs)
  let total = tier.frames.length()
  assert_true(total > 50)
  // Interior frames must be voiced at 220 Hz +-0.1% with strength > 0.99.
  for i in 10..<(total - 10) {
    let fr = tier.frames[i]
    guard fr.frequency is Some(f) else {
      fail("frame \{i} unexpectedly unvoiced")
    }
    assert_true(approx(f, 220.0, 0.22))
    assert_true(fr.strength > 0.99)
  }
}

///|
test "pitch marks silence unvoiced" {
  let fs = 16000.0
  let x : FixedArray[Double] = FixedArray::make(16000, 0.0)
  let tier = pitch_ac(x, sample_rate=fs)
  assert_true(tier.frames.length() > 50)
  for fr in tier.frames {
    assert_true(fr.frequency is None)
    assert_true(fr.strength == 0.0)
  }
}

///|
test "formants of a synthetic vowel at native rate" {
  // fs = 2 * 5500 so the analysis runs without internal resampling.
  let fs = 11000.0
  let x = make_vowel(fs, 500.0, 1500.0, 100.0, 11000, 0.4)
  let tier = formants(x, sample_rate=fs)
  assert_true(tier.frames.length() > 100)
  let mut f1_sum = 0.0
  let mut f2_sum = 0.0
  let mut cnt = 0
  for i in 40..<(tier.frames.length() - 40) {
    let fr = tier.frames[i]
    if fr.formants.length() >= 2 {
      f1_sum += fr.formants[0].frequency
      f2_sum += fr.formants[1].frequency
      cnt += 1
    }
  }
  assert_true(cnt >= 70)
  let mean_f1 = f1_sum / cnt.to_double()
  let mean_f2 = f2_sum / cnt.to_double()
  assert_true(@math.abs(mean_f1 - 500.0) < 45.0)
  assert_true(@math.abs(mean_f2 - 1500.0) < 70.0)
}

///|
test "formants after internal band-limited resampling" {
  // fs = 16 kHz forces the 16 kHz -> 11 kHz sinc resample path.
  let fs = 16000.0
  let x = make_vowel(fs, 500.0, 1500.0, 100.0, 16000, 0.4)
  let tier = formants(x, sample_rate=fs)
  let mut f1_sum = 0.0
  let mut f2_sum = 0.0
  let mut cnt = 0
  for i in 40..<(tier.frames.length() - 40) {
    let fr = tier.frames[i]
    if fr.formants.length() >= 2 {
      f1_sum += fr.formants[0].frequency
      f2_sum += fr.formants[1].frequency
      cnt += 1
    }
  }
  assert_true(cnt >= 70)
  let mean_f1 = f1_sum / cnt.to_double()
  let mean_f2 = f2_sum / cnt.to_double()
  assert_true(@math.abs(mean_f1 - 500.0) < 55.0)
  assert_true(@math.abs(mean_f2 - 1500.0) < 90.0)
}

///|
test "pitch_filtered_ac tracks 220 Hz sine and harmonic complex and rejects silence" {
  let fs = 16000.0
  let n = 16000
  let x = sine_fa(n, fs, 220.0, 1.0, 0.0)
  let pt = pitch_filtered_ac(x, sample_rate=fs)
  guard pt.mean() is Some(m) else { fail("expected voiced filtered_ac pitch") }
  assert_true(approx(m, 220.0, 0.5))

  let pt_acc = pitch_filtered_ac(x, sample_rate=fs, very_accurate=true)
  guard pt_acc.mean() is Some(m_acc) else {
    fail("expected voiced very_accurate filtered_ac pitch")
  }
  assert_true(approx(m_acc, 220.0, 0.5))

  // Rich harmonic complex at 180 Hz with weak fundamental and strong upper harmonics.
  let comp : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double() / fs
    comp[i] = 0.2 * @math.sin(2.0 * @math.PI * 180.0 * t) +
      0.8 * @math.sin(2.0 * @math.PI * 360.0 * t) +
      1.0 * @math.sin(2.0 * @math.PI * 540.0 * t) +
      0.7 * @math.sin(2.0 * @math.PI * 720.0 * t)
  }
  let pt_comp = pitch_filtered_ac(comp, sample_rate=fs)
  guard pt_comp.mean() is Some(m_comp) else {
    fail("expected voiced harmonic complex pitch")
  }
  assert_true(approx(m_comp, 180.0, 2.0))

  let silence : FixedArray[Double] = FixedArray::make(8000, 0.0)
  let pt_sil = pitch_filtered_ac(silence, sample_rate=fs)
  assert_true(pt_sil.mean() is None)
}

///|
test "interp_lag Chebyshev recurrence matches direct Boersma eq 22 formula" {
  let halfwin = 320
  let r : FixedArray[Double] = FixedArray::make(halfwin + 2, 0.0)
  for k in 0..<=(halfwin + 1) {
    r[k] = @math.cos(2.0 * @math.PI * k.to_double() / 72.7272727) *
      @math.exp(-k.to_double() / 500.0)
  }
  fn direct_interp(
    r : FixedArray[Double],
    x : Double,
    halfwin : Int32,
    max_depth : Int32,
  ) -> Double {
    let nl = @math.floor(x).to_int()
    let l = x - nl.to_double()
    let rr = 1.0 - l
    let mut n_max = halfwin - 1 - nl
    if n_max > max_depth {
      n_max = max_depth
    }
    if n_max < 1 {
      n_max = 1
    }
    let n_max_d = n_max.to_double()
    let mut acc = 0.0
    for n in 1..<=n_max {
      let d = l + n.to_double() - 1.0
      let pd = @math.PI * d
      let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
      let taper = 0.5 + 0.5 * @math.cos(@math.PI * d / (l + n_max_d))
      let idx = nl + 1 - n
      let aidx = if idx < 0 { -idx } else { idx }
      if aidx < r.length() {
        acc += r[aidx] * s * taper
      }
    }
    for n in 1..<=n_max {
      let d = rr + n.to_double() - 1.0
      let pd = @math.PI * d
      let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
      let taper = 0.5 + 0.5 * @math.cos(@math.PI * d / (rr + n_max_d))
      let idx = nl + n
      if idx < r.length() {
        acc += r[idx] * s * taper
      }
    }
    acc
  }
  let xs : Array[Double] = [
    2.37, 3.0, 72.0, 72.25, 72.72727, 72.9999999999995, 200.5, 317.4,
  ]
  for x in xs {
    for md in [70, 500] {
      let got = interp_lag(r, x, halfwin~, max_depth=md)
      let want = direct_interp(r, x, halfwin, md)
      assert_true(approx(got, want, 1.0e-10))
    }
  }
  // High-frequency sine near Nyquist (lag ~ 3.2 < 8): harmonicity_ac must still
  // find the true peak (> 20 dB HNR) without pruning short lags.
  let fs = 16000.0
  let hi_sine = sine_fa(16000, fs, 5000.0, 1.0, 0.0)
  let hnr = harmonicity_ac(hi_sine, sample_rate=fs)
  guard hnr.mean() is Some(mean_db) else {
    fail("expected high-frequency sine to have defined HNR")
  }
  assert_true(mean_db > 20.0)
}

///|
test "half-integer period broadband pulse train is not pruned in pitch or harmonicity" {
  // Regression test: a bright pulse train at period T = 80.5 samples (198.76 Hz)
  // has sinc(0.5) = 0.637 at integer lags 80 and 81 (parabolic estimate ~0.74),
  // whereas lag 161.0 (2*T) lands on an exact integer. Curvature-aware pruning
  // must still refine lag 80.5 and recover ~198.76 Hz and ~19 dB HNR.
  let fs = 16000.0
  let n = 16000
  let f0 = fs / 80.5
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double() / fs
    let mut s = 0.0
    for h in 1..<=38 {
      s += @math.cos(2.0 * @math.PI * h.to_double() * f0 * t)
    }
    x[i] = s / 38.0 * (1.0 + 0.35 * @math.cos(2.0 * @math.PI * 15.0 * t))
  }
  let pt_k1 = pitch_ac(
    x,
    sample_rate=fs,
    pitch_floor=75.0,
    pitch_ceiling=600.0,
    max_candidates=15,
    octave_cost=0.0,
    octave_jump_cost=0.0,
    voiced_unvoiced_cost=0.0,
  )
  let mid_fr = pt_k1.frames[pt_k1.frames.length() / 2]
  guard mid_fr.frequency is Some(f_k1) else {
    fail("expected voiced frame on half-integer pulse train")
  }
  assert_true(approx(f_k1, f0, 0.1))
  assert_true(mid_fr.strength > 0.98)

  let hnr = harmonicity_ac(x, sample_rate=fs, min_pitch=75.0)
  guard hnr.values[hnr.values.length() / 2] is Some(hnr_mid) else {
    fail("expected defined HNR on half-integer pulse train")
  }
  assert_true(hnr_mid > 18.0)

  // High octave_cost where upper_score > 1.5 must still keep short-lag and
  // long-lag ordering sound without mis-pruning.
  let s_hi : FixedArray[Double] = FixedArray::make(8000, 0.0)
  for i in 0..<8000 {
    let t = i.to_double() / fs
    s_hi[i] = @math.sin(2.0 * @math.PI * 2500.0 * t) +
      0.3 * @math.sin(2.0 * @math.PI * 150.0 * t)
  }
  let pt_hi = pitch_ac(
    s_hi,
    sample_rate=fs,
    pitch_floor=50.0,
    pitch_ceiling=4000.0,
    octave_cost=0.35,
  )
  guard pt_hi.mean() is Some(m_hi) else {
    fail("expected voiced frame with high octave_cost")
  }
  assert_true(approx(m_hi, 2500.0, 20.0))
}

///|
test "refine_peak converges accurately on asymmetric autocorrelation peaks" {
  // Asymmetric curve: sum of two shifted damped cosines peaking off-integer.
  let halfwin = 200
  let r : FixedArray[Double] = FixedArray::make(halfwin + 2, 0.0)
  for k in 0..<=(halfwin + 1) {
    let kd = k.to_double()
    let d1 = (kd - 40.31) / 3.5
    let d2 = (kd - 41.8) / 2.2
    r[k] = 0.85 * @math.exp(-d1 * d1) + 0.35 * @math.exp(-d2 * d2)
  }
  let dr = 0.5 * (r[41] - r[39])
  let d2r = r[40] - r[39] + (r[40] - r[41])
  let delta = dr / d2r
  let (val_brent, lag_brent) = refine_peak(r, 40, delta, halfwin~, max_depth=70)
  // Dense grid reference over [39.0, 41.0] at step 1e-4.
  let mut best_v = -1.0e9
  let mut best_x = 40.0
  for step in 0..<=20000 {
    let x = 39.0 + step.to_double() * 1.0e-4
    let v = interp_lag(r, x, halfwin~, max_depth=70)
    if v > best_v {
      best_v = v
      best_x = x
    }
  }
  assert_true(approx(lag_brent, best_x, 2.0e-4))
  assert_true(approx(val_brent, best_v, 1.0e-8))
}
