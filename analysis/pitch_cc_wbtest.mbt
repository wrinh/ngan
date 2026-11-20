// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for cross-correlation pitch detection (`To Pitch (cc)...`).

///|
test "pitch_cc tracks a 220 hz sine" {
  let fs = 16000.0
  let x = sine_fa(16000, fs, 220.0, 1.0, 0.0)
  let tier = pitch_cc(x, sample_rate=fs)
  let total = tier.frames.length()
  assert_true(total > 100)
  for i in 10..<(total - 10) {
    let fr = tier.frames[i]
    guard fr.frequency is Some(f) else {
      fail("frame \{i} unexpectedly unvoiced")
    }
    assert_true(approx(f, 220.0, 0.25))
    assert_true(fr.strength > 0.99)
  }
}

///|
test "pitch_cc marks silence unvoiced" {
  let fs = 16000.0
  let x : FixedArray[Double] = FixedArray::make(16000, 0.0)
  let tier = pitch_cc(x, sample_rate=fs)
  assert_true(tier.frames.length() > 100)
  for fr in tier.frames {
    assert_true(fr.frequency is None)
    assert_true(fr.strength == 0.0)
  }
}

///|
test "pitch_cc tracks noisy amplitude-modulated periodic voice" {
  // 150 Hz fundamental with breathy noise + cycle amplitude modulation.
  let fs = 16000.0
  let n = 16000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double() / fs
    let env = 1.0 + 0.25 * @math.sin(2.0 * @math.PI * 15.0 * t)
    let voice = env *
      (
        @math.sin(2.0 * @math.PI * 150.0 * t) +
        0.5 * @math.sin(2.0 * @math.PI * 300.0 * t) +
        0.25 * @math.sin(2.0 * @math.PI * 450.0 * t)
      )
    x[i] = voice + 0.2 * prand(i)
  }
  let tier = pitch_cc(x, sample_rate=fs)
  let total = tier.frames.length()
  let mut voiced = 0
  let mut f_sum = 0.0
  for i in 15..<(total - 15) {
    if tier.frames[i].frequency is Some(f) {
      voiced += 1
      f_sum += f
    }
  }
  let interior = total - 30
  assert_true(voiced * 100 >= interior * 95)
  let mean_f0 = f_sum / voiced.to_double()
  assert_true(approx(mean_f0, 150.0, 2.0))
}
