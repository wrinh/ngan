// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for TD-PSOLA pitch and duration manipulation.

///|
test "resynthesize_psola shifts pitch and stretches duration accurately" {
  let fs = 16000.0
  let n = 16000
  // Synthesize a clean 180 Hz pulse-excited vowel.
  let r = @math.exp(-@math.PI * 100.0 / fs)
  let th = 2.0 * @math.PI * 600.0 / fs
  let a1 = -2.0 * r * @math.cos(th)
  let a2 = r * r
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  let mut phase = 0.0
  let mut since = 100
  for i in 0..<n {
    phase += 2.0 * @math.PI * 180.0 / fs
    if phase >= 2.0 * @math.PI {
      phase -= 2.0 * @math.PI
      since = 0
    } else {
      since += 1
    }
    let exc = @math.exp(-since.to_double() * 0.2)
    let p1 = if i >= 1 { a1 * x[i - 1] } else { 0.0 }
    let p2 = if i >= 2 { a2 * x[i - 2] } else { 0.0 }
    x[i] = exc - p1 - p2
  }
  // 1) Time-stretch by 1.5x without changing pitch.
  let stretched = resynthesize_psola(x, sample_rate=fs, duration_factor=1.5)
  assert_true(@math.abs((stretched.length() - 24000).to_double()) <= 64.0)
  let pt_str = pitch(stretched, sample_rate=fs)
  guard pt_str.mean() is Some(f0_str) else { fail("stretched pitch missing") }
  assert_true(approx(f0_str, 180.0, 4.0))

  // 2) Shift pitch up by 1.3x (~234 Hz) with custom pitch_points.
  let shifted = resynthesize_psola(x, sample_rate=fs, pitch_points=[
    { time: 0.0, frequency: 234.0, },
    { time: 1.0, frequency: 234.0, },
  ])
  assert_true(@math.abs((shifted.length() - n).to_double()) <= 64.0)
  let pt_sh = pitch(shifted, sample_rate=fs)
  guard pt_sh.mean() is Some(f0_sh) else { fail("shifted pitch missing") }
  assert_true(approx(f0_sh, 234.0, 6.0))

  // 3) Manipulation object round-trip with DurationPoint.
  let manip = to_manipulation(x, sample_rate=fs)
  assert_true(manip.pitch_points.length() > 20)
  let manip_edited : @types.Manipulation = {
    ..manip,
    duration_points: [{ time: 0.0, relative_duration: 0.75, }],
  }
  let fast = resynthesize_manipulation(x, manip_edited)
  assert_true(@math.abs((fast.length() - 12000).to_double()) <= 64.0)
}
