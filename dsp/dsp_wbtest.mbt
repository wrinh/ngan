// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for the dsp package.

///|
fn approx(a : Double, b : Double, tol : Double) -> Bool {
  @math.abs(a - b) <= tol
}

///|
/// Deterministic pseudo-noise in [-1, 1) from the index alone.
fn prand(n : Int32) -> Double {
  let s = @math.sin((n.to_double() + 1.0) * 12.9898) * 43758.5453
  (s - @math.floor(s)) * 2.0 - 1.0
}

///|
test "fft matches direct dft and inverts" {
  let n = 16
  let plan = FftPlan::new(n)
  let src : FixedArray[Double] = FixedArray::make(n, 0.0)
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let t = i.to_double()
    src[i] = @math.sin(0.7 * t) + 0.3 * @math.cos(2.1 * t) + 0.05 * t
    re[i] = src[i]
  }
  plan.transform(re, im, inverse=false)
  for k in 0..<n {
    let mut sr = 0.0
    let mut si = 0.0
    for t in 0..<n {
      let a = -2.0 * @math.PI * (k * t).to_double() / n.to_double()
      sr += src[t] * @math.cos(a)
      si += src[t] * @math.sin(a)
    }
    assert_true(approx(re[k], sr, 1.0e-8))
    assert_true(approx(im[k], si, 1.0e-8))
  }
  plan.transform(re, im, inverse=true)
  for i in 0..<n {
    assert_true(approx(re[i], src[i], 1.0e-9))
    assert_true(approx(im[i], 0.0, 1.0e-9))
  }
}

///|
test "real fft plan matches complex fft power, inverse, and autocorrelation" {
  let n = 128
  let x : FixedArray[Double] = FixedArray::make(64, 0.0)
  for i in 0..<64 {
    x[i] = prand(i)
  }
  let cplan = FftPlan::new(n)
  let rplan = RealFftPlan::new(n)
  // 1. forward_power vs complex FFT
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<64 {
    re[i] = x[i]
  }
  cplan.transform(re, im, inverse=false)
  let rp : FixedArray[Double] = FixedArray::make(n / 2 + 1, 0.0)
  rplan.forward_power(x, 64, rp)
  for k in 0..<=(n / 2) {
    let want = re[k] * re[k] + im[k] * im[k]
    assert_true(approx(rp[k], want, 1.0e-9))
  }
  // 2. autocorrelation vs autocorrelation_fft
  let ac_ref : FixedArray[Double] = FixedArray::make(64, 0.0)
  let ac_fast : FixedArray[Double] = FixedArray::make(64, 0.0)
  autocorrelation_fft(cplan, x, 64, ac_ref, max_lag=63)
  rplan.autocorrelation(x, 64, ac_fast, max_lag=63)
  for tau in 0..<64 {
    assert_true(approx(ac_fast[tau], ac_ref[tau], 1.0e-9))
  }
  // 3. inverse_real_even vs complex IFFT on log-power-like even spectrum
  let spec : FixedArray[Double] = FixedArray::make(n / 2 + 1, 0.0)
  let cre : FixedArray[Double] = FixedArray::make(n, 0.0)
  let cim : FixedArray[Double] = FixedArray::make(n, 0.0)
  for k in 0..<=(n / 2) {
    let v = @math.ln(rp[k] + 1.0)
    spec[k] = v
    cre[k] = v
    if k > 0 && k < n / 2 {
      cre[n - k] = v
    }
  }
  cplan.transform(cre, cim, inverse=true)
  let out : FixedArray[Double] = FixedArray::make(n / 2 + 1, 0.0)
  rplan.inverse_real_even(spec, out, n / 2 + 1)
  for q in 0..<=(n / 2) {
    assert_true(approx(out[q], cre[q], 1.0e-10))
  }
  // 4. filter_real vs complex FFT zero-phase filtering (including odd input length)
  let odd_nx = 63
  let x_odd : FixedArray[Double] = FixedArray::make(odd_nx, 0.0)
  for i in 0..<odd_nx {
    x_odd[i] = prand(i + 17)
  }
  let gains : FixedArray[Double] = FixedArray::make(n / 2 + 1, 0.0)
  for k in 0..<=(n / 2) {
    let r = k.to_double() / 12.0
    gains[k] = @math.exp(-r * r)
  }
  let fre : FixedArray[Double] = FixedArray::make(n, 0.0)
  let fim : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<odd_nx {
    fre[i] = x_odd[i]
  }
  cplan.transform(fre, fim, inverse=false)
  for k in 0..<=(n / 2) {
    let g = gains[k]
    fre[k] *= g
    fim[k] *= g
    if k > 0 && k < n / 2 {
      fre[n - k] *= g
      fim[n - k] *= g
    }
  }
  cplan.transform(fre, fim, inverse=true)
  let filtered : FixedArray[Double] = FixedArray::make(odd_nx, 0.0)
  rplan.filter_real(x_odd, odd_nx, gains, filtered)
  for i in 0..<odd_nx {
    assert_true(approx(filtered[i], fre[i], 1.0e-11))
  }
}

///|
test "fft autocorrelation matches direct computation" {
  let n = 64
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = prand(i)
  }
  let plan = FftPlan::new(next_pow2(2 * n))
  let ac : FixedArray[Double] = FixedArray::make(40, 0.0)
  autocorrelation_fft(plan, x, n, ac, max_lag=39)
  for tau in 0..<40 {
    let mut direct = 0.0
    for i in 0..<(n - tau) {
      direct += x[i] * x[i + tau]
    }
    assert_true(approx(ac[tau], direct, 1.0e-7))
  }
}

///|
test "fft cross_correlation matches direct computation" {
  let nu = 40
  let nv = 100
  let max_lag = 50
  let u : FixedArray[Double] = FixedArray::make(nu, 0.0)
  let v : FixedArray[Double] = FixedArray::make(nv, 0.0)
  for i in 0..<nu {
    u[i] = prand(i)
  }
  for i in 0..<nv {
    v[i] = prand(i + 200)
  }
  let plan = FftPlan::new(next_pow2(nv + max_lag))
  let cc : FixedArray[Double] = FixedArray::make(max_lag + 1, 0.0)
  cross_correlation_fft(plan, u, nu, v, nv, cc, max_lag~)
  for tau in 0..<=max_lag {
    let mut direct = 0.0
    for j in 0..<nu {
      if j + tau < nv {
        direct += u[j] * v[j + tau]
      }
    }
    assert_true(approx(cc[tau], direct, 1.0e-10))
  }
}

///|
test "hanning window shape" {
  // Praat's periodic Hann: 0.5 - 0.5 cos(2 pi (i + 1) / (n + 1)).
  let w = hanning_window(5)
  assert_true(approx(w[0], 0.25, 1.0e-12))
  assert_true(approx(w[1], 0.75, 1.0e-12))
  assert_true(approx(w[2], 1.0, 1.0e-12))
  assert_true(approx(w[3], 0.75, 1.0e-12))
  assert_true(approx(w[4], 0.25, 1.0e-12))
  for i in 0..<5 {
    assert_true(approx(w[i], w[4 - i], 1.0e-12))
  }
}

///|
test "kaiser window shape" {
  let n = 101
  let w = kaiser_window(n, beta=20.0 * @math.PI)
  assert_true(approx(w[50], 1.0, 1.0e-9))
  assert_true(w[0] > 0.0)
  assert_true(w[0] < 1.0e-10)
  for i in 0..<(n / 2) {
    assert_true(approx(w[i], w[n - 1 - i], 1.0e-12))
    // monotonic rise toward the center
    assert_true(w[i] <= w[i + 1])
  }
}

///|
test "gaussian window shape" {
  let n = 101
  let w = gaussian_window(n)
  assert_true(approx(w[50], 1.0, 1.0e-12))
  // Praat's edge correction makes the window effectively zero at the edges.
  assert_true(w[0] >= 0.0 && w[0] < 1.0e-5)
  assert_true(w[n - 1] >= 0.0 && w[n - 1] < 1.0e-5)
  for i in 0..<n {
    assert_true(approx(w[i], w[n - 1 - i], 1.0e-12))
  }
}

///|
test "sinc resample preserves passband and rejects alias band" {
  // 500 Hz sine, 16 kHz -> 8 kHz.
  let n = 4000
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    x[i] = @math.sin(2.0 * @math.PI * 500.0 * i.to_double() / 16000.0)
  }
  let y = sinc_resample(x, ratio=0.5)
  assert_eq(y.length(), 2000)
  let mut maxerr = 0.0
  for j in 100..<1900 {
    let want = @math.sin(2.0 * @math.PI * 500.0 * j.to_double() / 8000.0)
    maxerr = @math.dmax(maxerr, @math.abs(y[j] - want))
  }
  assert_true(maxerr < 2.0e-3)
  // A 7 kHz tone lies above the 4 kHz output Nyquist and must vanish.
  let tone : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    tone[i] = @math.sin(2.0 * @math.PI * 7000.0 * i.to_double() / 16000.0)
  }
  let y2 = sinc_resample(tone, ratio=0.5)
  let mut energy = 0.0
  for j in 200..<1800 {
    energy += y2[j] * y2[j]
  }
  assert_true((energy / 1600.0).sqrt() < 1.0e-3)
  // Upsampling 8 kHz -> 16 kHz of the same in-band sine.
  let x3 : FixedArray[Double] = FixedArray::make(2000, 0.0)
  for i in 0..<2000 {
    x3[i] = @math.sin(2.0 * @math.PI * 500.0 * i.to_double() / 8000.0)
  }
  let y3 = sinc_resample(x3, ratio=2.0)
  assert_eq(y3.length(), 4000)
  let mut maxerr3 = 0.0
  for j in 200..<3800 {
    let want = @math.sin(2.0 * @math.PI * 500.0 * j.to_double() / 16000.0)
    maxerr3 = @math.dmax(maxerr3, @math.abs(y3[j] - want))
  }
  assert_true(maxerr3 < 2.0e-3)
  // Rational non-dyadic ratio (16 kHz -> 11 kHz, period 11) and irrational ratio (lookup table path).
  let y_rat = sinc_resample(x, ratio=11000.0 / 16000.0)
  assert_eq(y_rat.length(), 2750)
  let mut maxerr_rat = 0.0
  for j in 150..<2600 {
    let want = @math.sin(2.0 * @math.PI * 500.0 * j.to_double() / 11000.0)
    maxerr_rat = @math.dmax(maxerr_rat, @math.abs(y_rat[j] - want))
  }
  assert_true(maxerr_rat < 2.0e-3)
  let irr = 0.73129137421
  let y_irr = sinc_resample(x, ratio=irr)
  let fs_irr = 16000.0 * irr
  let mut maxerr_irr = 0.0
  for j in 150..<(y_irr.length() - 150) {
    let want = @math.sin(2.0 * @math.PI * 500.0 * j.to_double() / fs_irr)
    maxerr_irr = @math.dmax(maxerr_irr, @math.abs(y_irr[j] - want))
  }
  assert_true(maxerr_irr < 2.0e-3)
  // Edge cases: extreme ratios (0.01, 10.0), tiny inputs (nx = 1..5), zero_crossings = 1.
  for nx in 1..<=5 {
    let tiny : FixedArray[Double] = FixedArray::make(nx, 0.5)
    let y_down = sinc_resample(tiny, ratio=0.01, zero_crossings=1)
    assert_true(y_down.length() >= 1)
    let y_up = sinc_resample(tiny, ratio=10.0, zero_crossings=1)
    assert_eq(y_up.length(), nx * 10)
  }
  let x100 : FixedArray[Double] = FixedArray::make(100, 0.0)
  for i in 0..<100 {
    x100[i] = @math.sin(0.1 * i.to_double())
  }
  let y10x = sinc_resample(x100, ratio=10.0)
  assert_eq(y10x.length(), 1000)
  let y001x = sinc_resample(x, ratio=0.01)
  assert_eq(y001x.length(), 40)
}

///|
test "burg recovers known ar poles" {
  let fs = 11000.0
  let bw = 100.0
  let r = @math.exp(-@math.PI * bw / fs)
  let th1 = 2.0 * @math.PI * 500.0 / fs
  let th2 = 2.0 * @math.PI * 1500.0 / fs
  // Section(z) = 1 + s1 z^-1 + r^2 z^-2, s1 = -2 r cos(theta).
  let s1a = -2.0 * r * @math.cos(th1)
  let s1b = -2.0 * r * @math.cos(th2)
  let p1 = s1a + s1b
  let p2 = s1a * s1b + 2.0 * r * r
  let p3 = (s1a + s1b) * r * r
  let p4 = r * r * r * r
  let n = 8000
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
    x[i] = -past_sum + prand(i) * 0.5
  }
  let a = burg_lpc(x, order=4)
  // A(z) z^4 = z^4 + a[1] z^3 + ... + a[4], ascending powers.
  let coeffs : FixedArray[Double] = [a[4], a[3], a[2], a[1], 1.0]
  let roots = @math.poly_roots(coeffs)
  assert_eq(roots.length(), 4)
  let mut f1 = 0.0
  let mut f2 = 0.0
  let mut upper = 0
  for z in roots {
    if z.im > 0.0 {
      let f = z.arg() * fs / (2.0 * @math.PI)
      if upper == 0 || f < f1 {
        if upper == 1 {
          f2 = f1
        }
        f1 = f
      } else {
        f2 = f
      }
      upper += 1
    }
  }
  assert_eq(upper, 2)
  assert_true(@math.abs(f1 - 500.0) < 30.0)
  assert_true(@math.abs(f2 - 1500.0) < 30.0)
}

///|
test "next_pow2 boundaries and overflow panic" {
  assert_eq(next_pow2(-5), 1)
  assert_eq(next_pow2(0), 1)
  assert_eq(next_pow2(1), 1)
  assert_eq(next_pow2(2), 2)
  assert_eq(next_pow2(3), 4)
  assert_eq(next_pow2(1073741824), 1073741824)
}

///|
test "panic next_pow2 overflows beyond 2^30" {
  ignore(next_pow2(1073741825))
}

///|
test "fft radix-4 and odd log2 sizes match direct dft and cardinal axes" {
  let sizes : FixedArray[Int32] = [2, 4, 8, 16, 32, 64]
  for s in sizes {
    let plan = FftPlan::new(s)
    let src_r : FixedArray[Double] = FixedArray::make(s, 0.0)
    let src_i : FixedArray[Double] = FixedArray::make(s, 0.0)
    let re : FixedArray[Double] = FixedArray::make(s, 0.0)
    let im : FixedArray[Double] = FixedArray::make(s, 0.0)
    for j in 0..<s {
      src_r[j] = prand(j + s)
      src_i[j] = prand(j + 100 + s)
      re[j] = src_r[j]
      im[j] = src_i[j]
    }
    plan.transform(re, im, inverse=false)
    for k in 0..<s {
      let mut want_r = 0.0
      let mut want_i = 0.0
      for t in 0..<s {
        let a = -2.0 * @math.PI * (k * t).to_double() / s.to_double()
        let c = @math.cos(a)
        let sn = @math.sin(a)
        want_r += src_r[t] * c - src_i[t] * sn
        want_i += src_r[t] * sn + src_i[t] * c
      }
      assert_true(approx(re[k], want_r, 1.0e-9))
      assert_true(approx(im[k], want_i, 1.0e-9))
    }
    plan.transform(re, im, inverse=true)
    for j in 0..<s {
      assert_true(approx(re[j], src_r[j], 1.0e-10))
      assert_true(approx(im[j], src_i[j], 1.0e-10))
    }
  }
  // Exact cardinal twiddles yield exact zero imaginary bin at Nyquist / Fs/4 for even signal.
  let p8 = FftPlan::new(8)
  let er : FixedArray[Double] = [1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 3.0, 2.0]
  let ei : FixedArray[Double] = FixedArray::make(8, 0.0)
  p8.transform(er, ei, inverse=false)
  assert_true(approx(ei[0], 0.0, 1.0e-15))
  assert_true(approx(ei[2], 0.0, 1.0e-15))
  assert_true(approx(ei[4], 0.0, 1.0e-15))
  assert_true(approx(ei[6], 0.0, 1.0e-15))
}

///|
test "real fft autocorrelation full length, unpruned vs pruned, and edge inputs" {
  let n = 64
  let rplan = RealFftPlan::new(n)
  let cplan = FftPlan::new(n)
  // Case 1: nx > n/2 (exercises unpruned path) vs direct linear autocorrelation for n=64, nx=37
  // Note: for nx = 37 with n = 64, lags tau <= n - nx = 27 match linear AC without wrap.
  let nx = 37
  let x : FixedArray[Double] = FixedArray::make(nx, 0.0)
  for i in 0..<nx {
    x[i] = prand(i + 50)
  }
  let ac_unpruned : FixedArray[Double] = FixedArray::make(28, 0.0)
  let ac_fft : FixedArray[Double] = FixedArray::make(28, 0.0)
  rplan.autocorrelation(x, nx, ac_unpruned, max_lag=27)
  autocorrelation_fft(cplan, x, nx, ac_fft, max_lag=27)
  for tau in 0..<28 {
    let mut direct = 0.0
    for i in 0..<(nx - tau) {
      direct += x[i] * x[i + tau]
    }
    assert_true(approx(ac_unpruned[tau], direct, 1.0e-9))
    assert_true(approx(ac_fft[tau], direct, 1.0e-9))
  }
  // Case 2: nx <= n/2 (exercises zero-padding pruned path) including odd nx = 31.
  let ac_pruned : FixedArray[Double] = FixedArray::make(31, 0.0)
  rplan.autocorrelation(x, 31, ac_pruned, max_lag=30)
  for tau in 0..<31 {
    let mut direct = 0.0
    for i in 0..<(31 - tau) {
      direct += x[i] * x[i + tau]
    }
    assert_true(approx(ac_pruned[tau], direct, 1.0e-9))
  }
  // Case 3: negative/zero nx and negative max_lag do not panic.
  let ac_edge : FixedArray[Double] = [42.0, 42.0]
  rplan.autocorrelation(x, -3, ac_edge, max_lag=1)
  assert_true(approx(ac_edge[0], 0.0, 1.0e-15))
  assert_true(approx(ac_edge[1], 0.0, 1.0e-15))
  autocorrelation_fft(cplan, x, -1, ac_edge, max_lag=-1)
}

///|
test "cross_correlation_fft_buf handles small sizes and negative/zero lengths" {
  for sz in ([4, 8, 16, 32] : FixedArray[Int32]) {
    let nu = sz / 4 + 1
    let nv = sz / 2 + 2
    let max_lag = sz - nv
    let u : FixedArray[Double] = FixedArray::make(nu, 0.0)
    let v : FixedArray[Double] = FixedArray::make(nv, 0.0)
    for i in 0..<nu {
      u[i] = prand(i + sz)
    }
    for i in 0..<nv {
      v[i] = prand(i + 300 + sz)
    }
    let plan = FftPlan::new(sz)
    let re : FixedArray[Double] = FixedArray::make(sz, 0.0)
    let im : FixedArray[Double] = FixedArray::make(sz, 0.0)
    let cc : FixedArray[Double] = FixedArray::make(max_lag + 1, 0.0)
    cross_correlation_fft_buf(plan, u, nu, v, nv, cc, max_lag~, re, im)
    for tau in 0..<=max_lag {
      let mut direct = 0.0
      for j in 0..<nu {
        if j + tau < nv {
          direct += u[j] * v[j + tau]
        }
      }
      assert_true(approx(cc[tau], direct, 1.0e-10))
    }
    // Negative nu/nv safely zero-fills cc without panicking.
    cross_correlation_fft_buf(plan, u, -5, v, nv, cc, max_lag~, re, im)
    for tau in 0..<=max_lag {
      assert_true(approx(cc[tau], 0.0, 1.0e-15))
    }
    cross_correlation_fft_buf(plan, u, nu, v, -1, cc, max_lag~, re, im)
    for tau in 0..<=max_lag {
      assert_true(approx(cc[tau], 0.0, 1.0e-15))
    }
  }
}

///|
test "sinc_resample_rate and reflect boundary mode preserve DC and frequency" {
  // Constant signal with reflect=true keeps exact 1.0 across boundaries too.
  let ones : FixedArray[Double] = FixedArray::make(200, 1.0)
  let res_ref = sinc_resample_rate(
    ones,
    fs_in=44100,
    fs_out=16000,
    reflect=true,
  )
  assert_eq(res_ref.length(), 73)
  for j in 0..<res_ref.length() {
    assert_true(approx(res_ref[j], 1.0, 1.0e-10))
  }
  // Identity rate returns copy with identical samples.
  let same = sinc_resample_rate(ones, fs_in=16000, fs_out=16000)
  assert_eq(same.length(), 200)
  assert_true(approx(same[0], 1.0, 1.0e-12))
  // Downsampling high-frequency tone above new Nyquist gets attenuated cleanly.
  let fs_in = 48000.0
  let n_in = 1200
  let high : FixedArray[Double] = FixedArray::make(n_in, 0.0)
  for i in 0..<n_in {
    high[i] = @math.sin(2.0 * @math.PI * 10000.0 * i.to_double() / fs_in)
  }
  let down = sinc_resample_rate(high, fs_in=48000, fs_out=16000)
  let mut max_mid = 0.0
  for j in 40..<(down.length() - 40) {
    let a = @math.abs(down[j])
    if a > max_mid {
      max_mid = a
    }
  }
  assert_true(max_mid < 1.0e-4)
}
