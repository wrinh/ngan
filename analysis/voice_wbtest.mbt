// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for Harmonics-to-Noise Ratio (HNR), PointProcess glottal
// pulse extraction, Jitter, and Shimmer.

///|
test "harmonicity_ac and harmonicity_cc on pure sine and silence" {
  let fs = 16000.0
  let x = sine_fa(16000, fs, 200.0, 1.0, 0.0)
  let hac = harmonicity_ac(x, sample_rate=fs)
  let hcc = harmonicity_cc(x, sample_rate=fs)
  guard hac.mean() is Some(mac) else { fail("expected finite AC HNR") }
  guard hcc.mean() is Some(mcc) else { fail("expected finite CC HNR") }
  assert_true(mac > 30.0)
  assert_true(mcc > 25.0)
  // Silence must return None on every frame and None mean.
  let silence : FixedArray[Double] = FixedArray::make(8000, 0.0)
  let hac_sil = harmonicity_ac(silence, sample_rate=fs)
  let hcc_sil = harmonicity_cc(silence, sample_rate=fs)
  assert_true(hac_sil.mean() is None)
  assert_true(hcc_sil.mean() is None)
  for v in hac_sil.values {
    assert_true(v is None)
  }
  for v in hcc_sil.values {
    assert_true(v is None)
  }
}

///|
test "harmonicity tracks calibrated 10 dB and 20 dB SNR signals" {
  let fs = 16000.0
  let n = 16000
  // prand has uniform distribution in [-1, 1) -> variance 1/3 (RMS 1/sqrt(3));
  // unit sine has power 0.5. Remove empirical DC/scaling precisely.
  let noise_raw : FixedArray[Double] = FixedArray::make(n, 0.0)
  let mut n_mean = 0.0
  for i in 0..<n {
    let v = prand(i)
    noise_raw[i] = v
    n_mean += v
  }
  n_mean /= n.to_double()
  let mut n_pow = 0.0
  for i in 0..<n {
    noise_raw[i] -= n_mean
    n_pow += noise_raw[i] * noise_raw[i]
  }
  n_pow /= n.to_double()
  fn make_snr(target_snr_db : Double) -> FixedArray[Double] {
    // Sine power = 0.5 -> target noise power = 0.5 / 10^(snr/10).
    let target_n_pow = 0.5 / @math.pow(10.0, target_snr_db / 10.0)
    let scale = (target_n_pow / n_pow).sqrt()
    let out : FixedArray[Double] = FixedArray::make(n, 0.0)
    for i in 0..<n {
      out[i] = @math.sin(2.0 * @math.PI * 200.0 * i.to_double() / fs) +
        scale * noise_raw[i]
    }
    out
  }
  let x10 = make_snr(10.0)
  let x20 = make_snr(20.0)
  guard harmonicity_ac(x10, sample_rate=fs).mean() is Some(ac10) else {
    fail("ac10 missing")
  }
  guard harmonicity_ac(x20, sample_rate=fs).mean() is Some(ac20) else {
    fail("ac20 missing")
  }
  guard harmonicity_cc(x10, sample_rate=fs).mean() is Some(cc10) else {
    fail("cc10 missing")
  }
  guard harmonicity_cc(x20, sample_rate=fs).mean() is Some(cc20) else {
    fail("cc20 missing")
  }
  assert_true(approx(ac10, 10.0, 2.5))
  assert_true(approx(ac20, 20.0, 3.0))
  assert_true(ac20 > ac10 + 5.0)
  assert_true(approx(cc10, 10.0, 2.5))
  assert_true(approx(cc20, 20.0, 3.0))
  assert_true(cc20 > cc10 + 5.0)
}

///|
test "jitter exact formulas on synthetic PointProcess" {
  // Alternating periods T0 * (1 - 0.02) and T0 * (1 + 0.02), T0 = 0.005 s.
  // Successive differences |T_{i+1} - T_i| = 0.04 * T0, mean = T0
  // -> local_rel = 0.04, local_abs = 0.0002,
  //    rap = (2/3 * 0.04) = 0.08 / 3, ddp = 3 * rap = 0.08.
  let t0 = 0.005
  let pts : Array[Double] = [0.0]
  let mut t = 0.0
  for i in 0..<40 {
    let dt = if i % 2 == 0 { t0 * 0.98 } else { t0 * 1.02 }
    t += dt
    pts.push(t)
  }
  let fa : FixedArray[Double] = FixedArray::make(pts.length(), 0.0)
  for i in 0..<pts.length() {
    fa[i] = pts[i]
  }
  let pp : @types.PointProcess = { tmin: 0.0, tmax: t, points: fa, }
  let j = jitter(pp)
  guard j.local_rel is Some(lr) else { fail("missing local_rel") }
  guard j.local_abs is Some(la) else { fail("missing local_abs") }
  guard j.rap is Some(r) else { fail("missing rap") }
  guard j.ppq5 is Some(p5) else { fail("missing ppq5") }
  guard j.ddp is Some(d) else { fail("missing ddp") }
  assert_true(approx(lr, 0.04, 1.0e-12))
  assert_true(approx(la, 0.04 * t0, 1.0e-12))
  assert_true(approx(r, 0.08 / 3.0, 1.0e-12))
  assert_true(approx(d, 3.0 * r, 1.0e-12))
  assert_true(p5 > 0.0 && p5 < lr)
}

///|
test "point_process_cc jitter and shimmer on clean and AM sines" {
  let fs = 16000.0
  let n = 16000
  let clean = sine_fa(n, fs, 200.0, 1.0, 0.0)
  let pp = point_process_cc(clean, sample_rate=fs)
  assert_true(pp.length() >= 190 && pp.length() <= 205)
  guard pp.mean_period() is Some(mp) else { fail("missing mean_period") }
  assert_true(approx(mp, 0.005, 5.0e-5))
  let j_clean = jitter(pp)
  let s_clean = shimmer(clean, sample_rate=fs, pp~)
  guard j_clean.local_rel is Some(jc) else { fail("missing clean jitter") }
  guard s_clean.local_rel is Some(sc) else { fail("missing clean shimmer") }
  guard s_clean.local_db is Some(sc_db) else {
    fail("missing clean shimmer db")
  }
  assert_true(jc < 0.002)
  assert_true(sc < 0.005)
  assert_true(sc_db < 0.05)

  // Smooth 25 Hz amplitude modulation on a 200 Hz carrier for end-to-end
  // point_process_cc + shimmer detection.
  let am : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double() / fs
    let env = 1.0 + 0.2 * @math.sin(2.0 * @math.PI * 25.0 * t)
    am[i] = env * @math.sin(2.0 * @math.PI * 200.0 * t)
  }
  let pp_am = point_process_cc(am, sample_rate=fs)
  let s_am = shimmer(am, sample_rate=fs, pp=pp_am)
  guard s_am.local_rel is Some(sa) else { fail("missing AM shimmer") }
  guard s_am.local_db is Some(sa_db) else { fail("missing AM shimmer db") }
  guard s_am.apq3 is Some(apq3) else { fail("missing AM apq3") }
  guard s_am.dda is Some(dda) else { fail("missing AM dda") }
  assert_true(sa > 0.05 && sa < 0.15)
  assert_true(sa_db > 0.4 && sa_db < 1.3)
  assert_true(approx(dda, 3.0 * apq3, 1.0e-12))

  // Exact analytical shimmer check on zero-crossing-aligned PointProcess
  // with alternating cycle amplitudes 1.0 and 1.1.
  let alt : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let cyc = i / 80
    let amp = if cyc % 2 == 0 { 1.0 } else { 1.1 }
    alt[i] = amp * @math.sin(2.0 * @math.PI * 200.0 * i.to_double() / fs)
  }
  let z_pts : Array[Double] = []
  for c in 0..<=199 {
    z_pts.push(c.to_double() * 0.005)
  }
  let z_fa : FixedArray[Double] = FixedArray::make(z_pts.length(), 0.0)
  for i in 0..<z_pts.length() {
    z_fa[i] = z_pts[i]
  }
  let pp_exact : @types.PointProcess = { tmin: 0.0, tmax: 1.0, points: z_fa, }
  let s_exact = shimmer(alt, sample_rate=fs, pp=pp_exact)
  guard s_exact.local_rel is Some(se_rel) else { fail("missing exact shimmer") }
  guard s_exact.local_db is Some(se_db) else {
    fail("missing exact shimmer db")
  }
  assert_true(approx(se_rel, 0.1 / 1.05, 0.002))
  assert_true(approx(se_db, 20.0 * @math.log10(1.1), 0.02))

  // Silence produces empty PointProcess and None perturbation metrics.
  let silence : FixedArray[Double] = FixedArray::make(8000, 0.0)
  let pp_sil = point_process_cc(silence, sample_rate=fs)
  assert_eq(pp_sil.length(), 0)
  let j_sil = jitter(pp_sil)
  let s_sil = shimmer(silence, sample_rate=fs, pp=pp_sil)
  assert_true(j_sil.local_rel is None)
  assert_true(s_sil.local_rel is None)
}
