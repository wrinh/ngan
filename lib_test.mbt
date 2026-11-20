// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

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

///|
test "facade voice quality, formant tracking, ltas and scales" {
  let fs = 16000.0
  let x = sine_fa(16000, fs, 220.0)
  let p_cc = @ngan.analyze_pitch_cc(x, fs, 75.0, 600.0)
  guard p_cc.frames[p_cc.frames.length() / 2].frequency is Some(f0) else {
    fail("pitch_cc mid frame unvoiced")
  }
  assert_true(approx(f0, 220.0, 0.3))
  let st = p_cc.to_semitones()
  let erb = p_cc.to_erb()
  let mel = p_cc.to_mel()
  assert_eq(st.length(), p_cc.frames.length())
  assert_eq(erb.length(), p_cc.frames.length())
  assert_eq(mel.length(), p_cc.frames.length())
  assert_true(
    approx(@ngan.semitones_to_hz(@ngan.hz_to_semitones(220.0)), 220.0, 1.0e-9),
  )
  assert_true(approx(@ngan.erb_to_hz(@ngan.hz_to_erb(220.0)), 220.0, 1.0e-9))
  assert_true(approx(@ngan.mel_to_hz(@ngan.hz_to_mel(220.0)), 220.0, 1.0e-9))

  let hac = @ngan.analyze_harmonicity_ac(x, fs, 75.0)
  let hcc = @ngan.analyze_harmonicity_cc(x, fs, 75.0)
  guard hac.mean() is Some(m_ac) else { fail("missing hac mean") }
  guard hcc.mean() is Some(m_cc) else { fail("missing hcc mean") }
  assert_true(m_ac > 30.0 && m_cc > 25.0)

  let pp = @ngan.point_process_cc(x, sample_rate=fs)
  assert_true(pp.length() > 180)
  let jm = @ngan.jitter(pp)
  let sm = @ngan.shimmer(x, sample_rate=fs, pp~)
  guard jm.local_rel is Some(j_loc) else { fail("missing jitter") }
  guard sm.local_rel is Some(s_loc) else { fail("missing shimmer") }
  assert_true(j_loc < 0.005 && s_loc < 0.01)

  let lt = @ngan.analyze_ltas(x, fs, 100.0)
  assert_true(lt.values.length() == 80)
  guard @ngan.center_of_gravity(x, sample_rate=fs) is Some(cog) else {
    fail("missing center_of_gravity")
  }
  assert_true(approx(cog, 220.0, 10.0))

  let ft = @ngan.analyze_formants(x, fs, 5, 5500.0)
  let tracked = @ngan.track_formants(ft, num_tracks=2)
  assert_eq(tracked.frames.length(), ft.frames.length())

  let tilt = @ngan.spectral_tilt(x, sample_rate=fs, pitch=p_cc)
  assert_eq(tilt.frames.length(), p_cc.frames.length())
}
