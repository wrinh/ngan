// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for tier query/mean helpers and TextGrid segment
// acoustic summarization.

///|
/// Synthesize a time-varying 2-formant vowel into `out[start..<end]` with
/// F0 gliding from `f0_start` to `f0_end` and formants gliding from
/// `(f1_start, f2_start)` to `(f1_end, f2_end)`.
fn synth_gliding_vowel(
  out : FixedArray[Double],
  start : Int32,
  end : Int32,
  fs : Double,
  f0_start : Double,
  f0_end : Double,
  f1_start : Double,
  f1_end : Double,
  f2_start : Double,
  f2_end : Double,
  gain : Double,
) -> Unit {
  let len = end - start
  if len <= 0 {
    return
  }
  let bw = 110.0
  let r = @math.exp(-@math.PI * bw / fs)
  let r2 = r * r
  let mut phase = 0.0
  let mut samples_since_pulse = 0
  let mut prev = 0.0
  for k in 0..<len {
    let u = k.to_double() / (len - 1).to_double()
    let f0 = f0_start + u * (f0_end - f0_start)
    let f1 = f1_start + u * (f1_end - f1_start)
    let f2 = f2_start + u * (f2_end - f2_start)
    phase += f0 / fs
    if phase >= 1.0 {
      phase -= @math.floor(phase)
      samples_since_pulse = 0
    } else {
      samples_since_pulse += 1
    }
    let pulse = @math.exp(-samples_since_pulse.to_double() * 0.15)
    let e = (pulse * 0.8 + prand(start + k) * 0.01) * gain
    let s1a = -2.0 * r * @math.cos(2.0 * @math.PI * f1 / fs)
    let s1b = -2.0 * r * @math.cos(2.0 * @math.PI * f2 / fs)
    let p1 = s1a + s1b
    let p2 = s1a * s1b + 2.0 * r2
    let p3 = (s1a + s1b) * r2
    let p4 = r2 * r2
    let idx = start + k
    let xm1 = if k >= 1 { out[idx - 1] } else { 0.0 }
    let xm2 = if k >= 2 { out[idx - 2] } else { 0.0 }
    let xm3 = if k >= 3 { out[idx - 3] } else { 0.0 }
    let xm4 = if k >= 4 { out[idx - 4] } else { 0.0 }
    out[idx] = -p1 * xm1 - p2 * xm2 - p3 * xm3 - p4 * xm4 + e
  }
  // Lip radiation (+6 dB/oct) in-place over [start, end)
  for k in 0..<len {
    let idx = start + k
    let cur = out[idx]
    out[idx] = cur - prev
    prev = cur
  }
}

///|
test "tier value_at, value_at_linear, and mean helpers" {
  let it : @types.IntensityTier = {
    t1: 0.01,
    dt: 0.01,
    values: [60.0, 70.0, 80.0],
  }
  guard it.value_at_linear(0.015) is Some(iv_mid) else {
    fail("missing intensity value_at_linear")
  }
  assert_true(approx(iv_mid, 65.0, 1.0e-12))
  assert_true(approx(it.value_at_linear(0.006).unwrap(), 60.0, 1.0e-12))
  assert_true(approx(it.value_at_linear(0.034).unwrap(), 80.0, 1.0e-12))
  assert_true(it.value_at_linear(0.004) is None)
  // Energy mean vs dB mean over the full tier
  let expected_energy_mean = 10.0 *
    @math.log10(
      (@math.pow(10.0, 6.0) + @math.pow(10.0, 7.0) + @math.pow(10.0, 8.0)) / 3.0,
    )
  assert_true(approx(it.mean().unwrap(), expected_energy_mean, 1.0e-9))
  assert_true(approx(it.mean(energy=false).unwrap(), 70.0, 1.0e-12))
  // Narrow window between two frames falls back to linear interpolation
  assert_true(
    approx(it.mean(tmin=0.014, tmax=0.016, energy=false).unwrap(), 65.0, 1.0e-9),
  )

  let pt : @types.PitchTier = {
    t1: 0.01,
    dt: 0.01,
    frames: [
      { time: 0.01, frequency: Some(120.0), strength: 0.9, },
      { time: 0.02, frequency: None, strength: 0.1, },
      { time: 0.03, frequency: Some(180.0), strength: 0.9, },
    ],
  }
  assert_true(approx(pt.mean().unwrap(), 150.0, 1.0e-12))
  assert_true(pt.mean(tmin=0.018, tmax=0.022) is None)

  let ft : @types.FormantTier = {
    t1: 0.01,
    dt: 0.01,
    frames: [
      {
        time: 0.01,
        formants: [
          { frequency: 500.0, bandwidth: 80.0, },
          { frequency: 1500.0, bandwidth: 100.0, },
        ],
      },
      {
        time: 0.02,
        formants: [
          { frequency: 700.0, bandwidth: 100.0, },
          { frequency: 1100.0, bandwidth: 120.0, },
        ],
      },
    ],
  }
  assert_true(approx(ft.value_at(1, 0.015).unwrap(), 600.0, 1.0e-12))
  assert_true(approx(ft.value_at(2, 0.015).unwrap(), 1300.0, 1.0e-12))
  assert_true(ft.value_at(3, 0.015) is None)
  assert_true(ft.value_at(0, 0.015) is None)
  assert_true(approx(ft.bandwidth_at(1, 0.015).unwrap(), 90.0, 1.0e-12))
  assert_true(approx(ft.mean(1).unwrap(), 600.0, 1.0e-12))
  assert_true(approx(ft.mean(2).unwrap(), 1300.0, 1.0e-12))
}

///|
test "summarize_interval_tier handles narrow and zero-duration intervals locally" {
  let pt : @types.PitchTier = {
    t1: 0.1,
    dt: 0.1,
    frames: [
      { time: 0.1, frequency: Some(100.0), strength: 0.9, },
      { time: 0.2, frequency: Some(200.0), strength: 0.9, },
      { time: 0.3, frequency: Some(300.0), strength: 0.9, },
    ],
  }
  let ft : @types.FormantTier = {
    t1: 0.1,
    dt: 0.1,
    frames: [
      { time: 0.1, formants: [{ frequency: 400.0, bandwidth: 80.0, }], },
      { time: 0.2, formants: [{ frequency: 600.0, bandwidth: 90.0, }], },
      { time: 0.3, formants: [{ frequency: 800.0, bandwidth: 100.0, }], },
    ],
  }
  let it : @types.IntensityTier = {
    t1: 0.1,
    dt: 0.1,
    values: [50.0, 70.0, 90.0],
  }
  // Zero-duration interval at t=0.15 and ultra-narrow interval around t=0.25
  // must interpolate locally rather than collapsing to the whole-tier mean.
  let tier : @types.IntervalTier = {
    name: "probe",
    xmin: 0.0,
    xmax: 0.4,
    intervals: [
      { xmin: 0.15, xmax: 0.15, text: "zero", },
      { xmin: 0.249, xmax: 0.251, text: "narrow", },
    ],
  }
  let segs = summarize_interval_tier(
    tier,
    pitch=pt,
    formants=ft,
    intensity=it,
    trajectory_points=[0.1, 0.5, 0.9],
    energy_intensity=false,
  )
  assert_eq(segs.length(), 2)
  assert_true(approx(segs[0].f0_mean.unwrap(), 150.0, 1.0e-9))
  assert_true(segs[0].f0_sd is None)
  assert_true(approx(segs[0].f1_mean.unwrap(), 500.0, 1.0e-9))
  assert_true(approx(segs[0].intensity_mean.unwrap(), 60.0, 1.0e-9))
  assert_eq(segs[0].trajectory.length(), 3)

  assert_true(approx(segs[1].f0_mean.unwrap(), 250.0, 1.0e-9))
  assert_true(approx(segs[1].f1_mean.unwrap(), 700.0, 1.0e-9))
  assert_true(approx(segs[1].intensity_mean.unwrap(), 80.0, 1.0e-9))

  // Empty trajectory list
  let no_traj = summarize_interval_tier(
    tier,
    pitch=pt,
    formants=ft,
    intensity=it,
    trajectory_points=[],
  )
  assert_eq(no_traj[0].trajectory.length(), 0)
}

///|
test "analyze_segments tracks gliding F0, F1/F2 trajectories, and intensity differences" {
  let fs = 16000.0
  // 1.5 s signal:
  // [0.00, 0.20]: silence
  // [0.20, 0.70]: loud diphthong (F0 140->240 Hz, F1 750->400 Hz, F2 1100->2100 Hz)
  // [0.70, 0.90]: silence
  // [0.90, 1.40]: softer steady vowel (F0 ~180 Hz, F1 ~500 Hz, F2 ~1500 Hz)
  // [1.40, 1.50]: silence
  let n = 24000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  synth_gliding_vowel(
    x, 3200, 11200, fs, 140.0, 240.0, 750.0, 400.0, 1100.0, 2100.0, 1.0,
  )
  synth_gliding_vowel(
    x, 14400, 22400, fs, 180.0, 180.0, 500.0, 500.0, 1500.0, 1500.0, 0.2,
  )

  let tg : @types.TextGrid = {
    xmin: 0.0,
    xmax: 1.5,
    tiers: [
      Intervals({
        name: "phones",
        xmin: 0.0,
        xmax: 1.5,
        intervals: [
          { xmin: 0.0, xmax: 0.2, text: "", },
          { xmin: 0.2, xmax: 0.7, text: "ai", },
          { xmin: 0.7, xmax: 0.9, text: "   ", },
          { xmin: 0.9, xmax: 1.4, text: "ə", },
          { xmin: 1.4, xmax: 1.5, text: "", },
        ],
      }),
    ],
  }

  let segs = analyze_segments(x, sample_rate=fs, tg, tier_name="phones")
  // Skips "", "   ", "" while preserving original interval indices 1 and 3
  assert_eq(segs.length(), 2)
  assert_eq(segs[0].index, 1)
  assert_eq(segs[0].label, "ai")
  assert_eq(segs[1].index, 3)
  assert_eq(segs[1].label, "ə")

  // Loud segment must have strictly higher mean intensity than softer segment
  guard (segs[0].intensity_mean, segs[1].intensity_mean) is (Some(i0), Some(i1)) else {
    fail("missing intensity_mean")
  }
  assert_true(i0 > i1 + 6.0)
  assert_true(segs[0].intensity_max.unwrap() >= i0)

  // Rising F0 glide and opposing F1/F2 trajectories at 20%–50%–80%
  let t = segs[0].trajectory
  assert_eq(t.length(), 3)
  assert_true(approx(t[0].proportion, 0.2, 1.0e-12))
  assert_true(approx(t[1].proportion, 0.5, 1.0e-12))
  assert_true(approx(t[2].proportion, 0.8, 1.0e-12))
  guard (t[0].f0, t[1].f0, t[2].f0) is (Some(f0_20), Some(f0_50), Some(f0_80)) else {
    fail("missing F0 trajectory")
  }
  assert_true(f0_20 < f0_50 && f0_50 < f0_80)
  assert_true(segs[0].f0_sd.unwrap() > 10.0)
  assert_true(segs[0].voiced_fraction > 0.8)

  guard (t[0].f1, t[1].f1, t[2].f1) is (Some(f1_20), Some(f1_50), Some(f1_80)) else {
    fail("missing F1 trajectory")
  }
  assert_true(f1_20 > f1_50 && f1_50 > f1_80)

  guard (t[0].f2, t[1].f2, t[2].f2) is (Some(f2_20), Some(f2_50), Some(f2_80)) else {
    fail("missing F2 trajectory")
  }
  assert_true(f2_20 < f2_50 && f2_50 < f2_80)

  // With skip_empty=false, leading silence has unvoiced interior and low voiced_fraction
  let all_segs = analyze_segments(
    x,
    sample_rate=fs,
    tg,
    tier_name="phones",
    skip_empty=false,
    use_formant_tracking=true,
  )
  assert_eq(all_segs.length(), 5)
  assert_true(all_segs[0].voiced_fraction < 0.25)
  assert_true(all_segs[0].trajectory[1].f0 is None)
  assert_true(all_segs[1].f1_mean is Some(_))
  assert_true(all_segs[1].f2_mean is Some(_))

  // Pure silence yields unvoiced / empty formant summaries, and summarize_textgrid
  // handles multi-tier selection and missing tier names.
  let silent : FixedArray[Double] = FixedArray::make(8000, 0.0)
  let multi_tg : @types.TextGrid = {
    xmin: 0.0,
    xmax: 0.5,
    tiers: [
      Intervals({
        name: "words",
        xmin: 0.0,
        xmax: 0.5,
        intervals: [{ xmin: 0.1, xmax: 0.4, text: "sil", }],
      }),
      Points({
        name: "events",
        xmin: 0.0,
        xmax: 0.5,
        points: [{ time: 0.25, mark: "p", }],
      }),
      Intervals({
        name: "phones",
        xmin: 0.0,
        xmax: 0.5,
        intervals: [
          { xmin: 0.1, xmax: 0.25, text: "s1", },
          { xmin: 0.25, xmax: 0.4, text: "s2", },
        ],
      }),
    ],
  }
  let sil_all = analyze_segments(silent, sample_rate=fs, multi_tg)
  assert_eq(sil_all.length(), 3)
  assert_eq(sil_all[0].tier_name, "words")
  assert_eq(sil_all[1].tier_name, "phones")
  assert_eq(sil_all[2].tier_name, "phones")
  assert_true(sil_all[0].f0_mean is None)
  assert_eq(sil_all[0].voiced_fraction, 0.0)
  assert_true(sil_all[0].f1_mean is None)
  assert_true(sil_all[0].f2_mean is None)
  assert_eq(
    analyze_segments(silent, sample_rate=fs, multi_tg, tier_name="missing").length(),
    0,
  )
}
