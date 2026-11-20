// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Blackbox tests for types scale conversions and container query methods.

///|
fn approx(a : Double, b : Double, tol : Double) -> Bool {
  @math.abs(a - b) <= tol
}

///|
test "psychoacoustic scale conversions and round trips" {
  // Semitones: Praat defaults to 100 Hz reference.
  assert_true(approx(@types.hz_to_semitones(100.0), 0.0, 1.0e-12))
  assert_true(approx(@types.hz_to_semitones(200.0), 12.0, 1.0e-12))
  assert_true(approx(@types.hz_to_semitones(50.0), -12.0, 1.0e-12))
  assert_true(
    approx(@types.hz_to_semitones(440.0, reference_hz=440.0), 0.0, 1.0e-12),
  )
  // Praat ERB: 11.17 * ln((1000 + 312)/(1000 + 14680)) + 43.
  inspect(
    @types.hz_to_erb(1000.0),
    content=(
      #|15.289091766447928
    ),
  )
  // Praat Mel: 550 * ln(1 + 1000 / 550).
  inspect(
    @types.hz_to_mel(1000.0),
    content=(
      #|569.8505624277267
    ),
  )
  // Exact round-trip checks across speech range.
  for f in [75.0, 100.0, 220.0, 440.0, 1000.0, 3500.0] {
    assert_true(
      approx(@types.semitones_to_hz(@types.hz_to_semitones(f)), f, 1.0e-9),
    )
    assert_true(approx(@types.erb_to_hz(@types.hz_to_erb(f)), f, 1.0e-9))
    assert_true(approx(@types.mel_to_hz(@types.hz_to_mel(f)), f, 1.0e-9))
  }
}

///|
test "PitchTier value_at and scale conversions" {
  let pt : @types.PitchTier = {
    t1: 0.01,
    dt: 0.01,
    frames: [
      { time: 0.01, frequency: Some(100.0), strength: 0.9, },
      { time: 0.02, frequency: Some(200.0), strength: 0.95, },
      { time: 0.03, frequency: None, strength: 0.1, },
    ],
  }
  guard pt.value_at(0.015) is Some(mid_f) else {
    fail("expected interpolated f0")
  }
  assert_true(approx(mid_f, 150.0, 1.0e-12))
  assert_true(pt.value_at(0.03) is None)
  assert_true(pt.value_at(-1.0) is None)
  let st = pt.to_semitones()
  assert_eq(st.length(), 3)
  assert_true(st[0] is Some(0.0))
  guard st[1] is Some(st1) else { fail("expected semitone") }
  assert_true(approx(st1, 12.0, 1.0e-12))
  assert_true(st[2] is None)
  let erb = pt.to_erb()
  assert_true(erb[0] is Some(_) && erb[2] is None)
  let mel = pt.to_mel()
  assert_true(mel[0] is Some(_) && mel[2] is None)
}

///|
test "HarmonicityTier PointProcess and Ltas helpers" {
  let ht : @types.HarmonicityTier = {
    t1: 0.01,
    dt: 0.01,
    values: [Some(10.0), None, Some(20.0)],
  }
  assert_true(ht.value_at(0.01) is Some(10.0))
  assert_true(ht.value_at(0.02) is None)
  guard ht.mean() is Some(m) else { fail("expected mean") }
  assert_true(approx(m, 15.0, 1.0e-12))

  let pp : @types.PointProcess = {
    tmin: 0.0,
    tmax: 0.05,
    points: [0.01, 0.015, 0.02, 0.025],
  }
  assert_eq(pp.length(), 4)
  guard pp.mean_period() is Some(mp) else { fail("expected mean period") }
  assert_true(approx(mp, 0.005, 1.0e-12))

  let lt : @types.Ltas = {
    f1: 500.0,
    df: 1000.0,
    values: [60.0, 40.0, 40.0, 40.0],
  }
  assert_true(lt.value_at(500.0) is Some(60.0))
  assert_true(lt.value_at(-10.0) is None)
  guard lt.slope(
      fmin_low=0.0,
      fmax_low=1000.0,
      fmin_high=1000.0,
      fmax_high=4000.0,
    )
    is Some(sl) else {
    fail("expected slope")
  }
  assert_true(approx(sl, -20.0, 1.0e-9))
}
