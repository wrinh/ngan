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
  let tier = pitch(x, sample_rate=fs)
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
  let tier = pitch(x, sample_rate=fs)
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
