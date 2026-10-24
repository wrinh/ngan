// Blackbox tests for the public facade.

///|
fn approx(a : Double, b : Double, tol : Double) -> Bool {
  @math.abs(a - b) <= tol
}

///|
fn sine_fa(n : Int32, fs : Double, f : Double) -> FixedArray[Double] {
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = @math.sin(2.0 * @math.PI * f * i.to_double() / fs)
  }
  x
}

///|
test "facade analyze_pitch" {
  let x = sine_fa(16000, 16000.0, 220.0)
  let tier = @ngan.analyze_pitch(x, 16000.0, 75.0, 600.0)
  let mid = tier.frames[tier.frames.length() / 2]
  guard mid.frequency is Some(f) else { fail("mid frame unvoiced") }
  assert_true(approx(f, 220.0, 0.3))
}

///|
test "facade analyze_intensity" {
  let x = sine_fa(16000, 16000.0, 220.0)
  let tier = @ngan.analyze_intensity(x, 16000.0, 100.0)
  let mid = tier.values[tier.values.length() / 2]
  assert_true(approx(mid, 90.96910013008056, 0.05))
  assert_true(tier.value_at(0.5) is Some(_))
  assert_true(tier.value_at(-1.0) is None)
}

///|
test "facade analyze_all returns consistent sets" {
  let x = sine_fa(16000, 16000.0, 220.0)
  let r = @ngan.analyze_all(x, 16000.0, 100.0, 75.0, 600.0, 5, 5500.0)
  assert_true(r.intensity_times.length() == r.intensity_values.length())
  assert_true(r.intensity_times.length() > 0)
  assert_true(r.pitch_frames.length() > 0)
  assert_true(r.formant_frames.length() > 0)
  assert_true(r.intensity_times[0] > 0.0 && r.intensity_times[0] < 0.04)
  assert_true(
    approx(r.intensity_times[1] - r.intensity_times[0], 0.008, 1.0e-9),
  )
}
