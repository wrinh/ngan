// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Iterative radix-2 FFT with precomputed bit-reversal and twiddle tables,
// used for O(N log N) autocorrelation in the pitch tracker.

///|
/// Precomputed plan for in-place radix-2 FFT/IFFT of one power-of-two
/// size.
pub struct FftPlan {
  n : Int32
  rev : FixedArray[Int32]
  cos_t : FixedArray[Double]
  sin_t : FixedArray[Double]
}

///|
/// Smallest power of two >= n.
pub fn next_pow2(n : Int32) -> Int32 {
  let mut m = 1
  while m < n {
    m *= 2
  }
  m
}

///|
fn log2_int(n : Int32) -> Int32 {
  let mut k = 0
  let mut m = n
  while m > 1 {
    m /= 2
    k += 1
  }
  k
}

///|
/// Create a plan for size `n`, which must be a power of two >= 2.
pub fn FftPlan::new(n : Int32) -> FftPlan {
  if n < 2 || (n & (n - 1)) != 0 {
    abort("FftPlan::new: size must be a power of two >= 2, got \{n}")
  }
  let bits = log2_int(n)
  let rev : FixedArray[Int32] = FixedArray::make(n, 0)
  for i in 0..<n {
    let mut r = 0
    let mut x = i
    for _ in 0..<bits {
      r = r * 2 + x % 2
      x /= 2
    }
    rev[i] = r
  }
  let half = n / 2
  let cos_t : FixedArray[Double] = FixedArray::make(half, 0.0)
  let sin_t : FixedArray[Double] = FixedArray::make(half, 0.0)
  for j in 0..<half {
    let a = -2.0 * @math.PI * j.to_double() / n.to_double()
    cos_t[j] = @math.cos(a)
    sin_t[j] = @math.sin(a)
  }
  { n, rev, cos_t, sin_t, }
}

///|
/// In-place transform of the complex sequence in `re`/`im` (both of
/// length `plan.n`). With `inverse = false` computes the DFT with
/// exponent -2*pi*i/N; with `inverse = true` the conjugate transform
/// divided by N.
pub fn FftPlan::transform(
  self : FftPlan,
  re : FixedArray[Double],
  im : FixedArray[Double],
  inverse~ : Bool,
) -> Unit {
  let n = self.n
  let rev = self.rev
  // Bit-reversal permutation.
  for i in 0..<n {
    let j = rev[i]
    if j > i {
      let tr = re[i]
      re[i] = re[j]
      re[j] = tr
      let ti = im[i]
      im[i] = im[j]
      im[j] = ti
    }
  }
  // Stage len = 2 (twiddle = 1, pure add/sub).
  let mut i = 0
  while i < n {
    let r0 = re[i]
    let r1 = re[i + 1]
    let i0 = im[i]
    let i1 = im[i + 1]
    re[i] = r0 + r1
    re[i + 1] = r0 - r1
    im[i] = i0 + i1
    im[i + 1] = i0 - i1
    i += 2
  }
  if n >= 4 {
    // Stage len = 4 (twiddles = 1 and -i / +i, no multiplications).
    if inverse {
      let mut base = 0
      while base < n {
        let r0 = re[base]
        let i0 = im[base]
        let r2 = re[base + 2]
        let i2 = im[base + 2]
        re[base] = r0 + r2
        im[base] = i0 + i2
        re[base + 2] = r0 - r2
        im[base + 2] = i0 - i2
        let r1 = re[base + 1]
        let i1 = im[base + 1]
        let r3 = re[base + 3]
        let i3 = im[base + 3]
        // (r3 + i*i3) * (+i) = -i3 + i*r3
        re[base + 1] = r1 - i3
        im[base + 1] = i1 + r3
        re[base + 3] = r1 + i3
        im[base + 3] = i1 - r3
        base += 4
      }
    } else {
      let mut base = 0
      while base < n {
        let r0 = re[base]
        let i0 = im[base]
        let r2 = re[base + 2]
        let i2 = im[base + 2]
        re[base] = r0 + r2
        im[base] = i0 + i2
        re[base + 2] = r0 - r2
        im[base + 2] = i0 - i2
        let r1 = re[base + 1]
        let i1 = im[base + 1]
        let r3 = re[base + 3]
        let i3 = im[base + 3]
        // (r3 + i*i3) * (-i) = i3 - i*r3
        re[base + 1] = r1 + i3
        im[base + 1] = i1 - r3
        re[base + 3] = r1 - i3
        im[base + 3] = i1 + r3
        base += 4
      }
    }
  }
  // Stages len >= 8; branch on `inverse` outside the hot butterfly loop.
  let cos_t = self.cos_t
  let sin_t = self.sin_t
  if inverse {
    let mut len = 8
    while len <= n {
      let half = len / 2
      let step = n / len
      let mut base = 0
      while base < n {
        let mut w = 0
        for k in 0..<half {
          let wr = cos_t[w]
          let wi = -sin_t[w]
          w += step
          let i1 = base + k
          let i2 = i1 + half
          let r2 = re[i2]
          let im2 = im[i2]
          let xr = r2 * wr - im2 * wi
          let xi = r2 * wi + im2 * wr
          let r1 = re[i1]
          let im1 = im[i1]
          re[i2] = r1 - xr
          im[i2] = im1 - xi
          re[i1] = r1 + xr
          im[i1] = im1 + xi
        }
        base += len
      }
      len *= 2
    }
    let inv_n = 1.0 / n.to_double()
    for k in 0..<n {
      re[k] *= inv_n
      im[k] *= inv_n
    }
  } else {
    let mut len = 8
    while len <= n {
      let half = len / 2
      let step = n / len
      let mut base = 0
      while base < n {
        let mut w = 0
        for k in 0..<half {
          let wr = cos_t[w]
          let wi = sin_t[w]
          w += step
          let i1 = base + k
          let i2 = i1 + half
          let r2 = re[i2]
          let im2 = im[i2]
          let xr = r2 * wr - im2 * wi
          let xi = r2 * wi + im2 * wr
          let r1 = re[i1]
          let im1 = im[i1]
          re[i2] = r1 - xr
          im[i2] = im1 - xi
          re[i1] = r1 + xr
          im[i1] = im1 + xi
        }
        base += len
      }
      len *= 2
    }
  }
}

///|
/// Precomputed plan for N-point real-valued FFT / IFFT / autocorrelation
/// via an (N/2)-point complex FFT with reusable scratch buffers.
pub struct RealFftPlan {
  n : Int32
  half : Int32
  half_plan : FftPlan
  cos_u : FixedArray[Double]
  sin_u : FixedArray[Double]
  buf_re : FixedArray[Double]
  buf_im : FixedArray[Double]
}

///|
/// Create a real-FFT plan for size `n`, which must be a power of two >= 4.
pub fn RealFftPlan::new(n : Int32) -> RealFftPlan {
  if n < 4 || (n & (n - 1)) != 0 {
    abort("RealFftPlan::new: size must be a power of two >= 4, got \{n}")
  }
  let half = n / 2
  let quarter = half / 2
  let half_plan = FftPlan::new(half)
  let cos_u : FixedArray[Double] = FixedArray::make(quarter + 1, 0.0)
  let sin_u : FixedArray[Double] = FixedArray::make(quarter + 1, 0.0)
  for k in 0..<=quarter {
    let a = -2.0 * @math.PI * k.to_double() / n.to_double()
    cos_u[k] = @math.cos(a)
    sin_u[k] = @math.sin(a)
  }
  let buf_re : FixedArray[Double] = FixedArray::make(half, 0.0)
  let buf_im : FixedArray[Double] = FixedArray::make(half, 0.0)
  { n, half, half_plan, cos_u, sin_u, buf_re, buf_im, }
}

///|
/// Forward real-to-complex power spectrum `|X[k]|^2` for `k = 0..=n/2`
/// of zero-padded real input `x[0..nx)`. Writes `n/2 + 1` values into
/// `power` without heap allocations.
pub fn RealFftPlan::forward_power(
  self : RealFftPlan,
  x : FixedArray[Double],
  nx : Int32,
  power : FixedArray[Double],
) -> Unit {
  let half = self.half
  let re = self.buf_re
  let im = self.buf_im
  let mut lim = if nx < 0 { 0 } else if nx < self.n { nx } else { self.n }
  if lim > x.length() {
    lim = x.length()
  }
  let pairs = lim / 2
  for j in 0..<pairs {
    re[j] = x[2 * j]
    im[j] = x[2 * j + 1]
  }
  let mut next_j = pairs
  if lim % 2 == 1 {
    re[pairs] = x[lim - 1]
    im[pairs] = 0.0
    next_j = pairs + 1
  }
  for j in next_j..<half {
    re[j] = 0.0
    im[j] = 0.0
  }
  self.half_plan.transform(re, im, inverse=false)
  let r0 = re[0]
  let i0 = im[0]
  let x0 = r0 + i0
  let xm = r0 - i0
  power[0] = x0 * x0
  power[half] = xm * xm
  let quarter = half / 2
  let cos_u = self.cos_u
  let sin_u = self.sin_u
  for k in 1..<quarter {
    let m = half - k
    let rk = re[k]
    let ik = im[k]
    let rm = re[m]
    let im_m = im[m]
    let er = 0.5 * (rk + rm)
    let ei = 0.5 * (ik - im_m)
    let or_ = 0.5 * (ik + im_m)
    let oi = -0.5 * (rk - rm)
    let cu = cos_u[k]
    let su = sin_u[k]
    let tr = or_ * cu - oi * su
    let ti = or_ * su + oi * cu
    let xkr = er + tr
    let xki = ei + ti
    let xmr = er - tr
    let xmi = ti - ei
    power[k] = xkr * xkr + xki * xki
    power[m] = xmr * xmr + xmi * xmi
  }
  if quarter > 0 {
    let rq = re[quarter]
    let iq = im[quarter]
    power[quarter] = rq * rq + iq * iq
  }
}

///|
/// Inverse real FFT of a purely real even spectrum `spec[0..=n/2]` (zero
/// imaginary parts), writing the first `out_len` real samples into `out`.
pub fn RealFftPlan::inverse_real_even(
  self : RealFftPlan,
  spec : FixedArray[Double],
  out : FixedArray[Double],
  out_len : Int32,
) -> Unit {
  let half = self.half
  let re = self.buf_re
  let im = self.buf_im
  let s0 = spec[0]
  let sm = spec[half]
  re[0] = 0.5 * (s0 + sm)
  im[0] = 0.5 * (s0 - sm)
  let quarter = half / 2
  let cos_u = self.cos_u
  let sin_u = self.sin_u
  for k in 1..<quarter {
    let m = half - k
    let sk = spec[k]
    let sm_k = spec[m]
    let er = 0.5 * (sk + sm_k)
    let dr = 0.5 * (sk - sm_k)
    let or_ = dr * cos_u[k]
    let oi = -dr * sin_u[k]
    re[k] = er - oi
    im[k] = or_
    re[m] = er + oi
    im[m] = or_
  }
  if quarter > 0 {
    re[quarter] = spec[quarter]
    im[quarter] = 0.0
  }
  self.half_plan.transform(re, im, inverse=true)
  let mut top = if out_len < 0 {
    0
  } else if out_len < self.n {
    out_len
  } else {
    self.n
  }
  if top > out.length() {
    top = out.length()
  }
  let pairs = top / 2
  for j in 0..<pairs {
    out[2 * j] = re[j]
    out[2 * j + 1] = im[j]
  }
  if top % 2 == 1 {
    out[top - 1] = re[pairs]
  }
}

///|
/// Zero-allocation linear autocorrelation via `RealFftPlan` (two N/2
/// complex FFTs instead of two N-point complex FFTs).
pub fn RealFftPlan::autocorrelation(
  self : RealFftPlan,
  x : FixedArray[Double],
  nx : Int32,
  ac : FixedArray[Double],
  max_lag~ : Int32,
  scratch_power : FixedArray[Double],
) -> Unit {
  self.forward_power(x, nx, scratch_power)
  let mut top = if max_lag < self.n - 1 { max_lag } else { self.n - 1 }
  if top >= ac.length() {
    top = ac.length() - 1
  }
  if top >= 0 {
    self.inverse_real_even(scratch_power, ac, top + 1)
  }
}

///|
/// Apply a real, zero-phase frequency-domain gain `gains[0..=n/2]` to
/// real input `x[0..nx)` via real forward + inverse FFT, writing `nx`
/// filtered samples into `out`.
pub fn RealFftPlan::filter_real(
  self : RealFftPlan,
  x : FixedArray[Double],
  nx : Int32,
  gains : FixedArray[Double],
  out : FixedArray[Double],
) -> Unit {
  let half = self.half
  let re = self.buf_re
  let im = self.buf_im
  let mut lim = if nx < 0 { 0 } else if nx < self.n { nx } else { self.n }
  if lim > x.length() {
    lim = x.length()
  }
  let pairs = lim / 2
  for j in 0..<pairs {
    re[j] = x[2 * j]
    im[j] = x[2 * j + 1]
  }
  let mut next_j = pairs
  if lim % 2 == 1 {
    re[pairs] = x[lim - 1]
    im[pairs] = 0.0
    next_j = pairs + 1
  }
  for j in next_j..<half {
    re[j] = 0.0
    im[j] = 0.0
  }
  self.half_plan.transform(re, im, inverse=false)
  // Unpack, multiply by real gain[k], and repack in-place for inverse half-FFT.
  let r0 = re[0]
  let i0 = im[0]
  let x0 = (r0 + i0) * gains[0]
  let xm = (r0 - i0) * gains[half]
  re[0] = 0.5 * (x0 + xm)
  im[0] = 0.5 * (x0 - xm)
  let quarter = half / 2
  let cos_u = self.cos_u
  let sin_u = self.sin_u
  for k in 1..<quarter {
    let m = half - k
    let rk = re[k]
    let ik = im[k]
    let rm = re[m]
    let im_m = im[m]
    let er = 0.5 * (rk + rm)
    let ei = 0.5 * (ik - im_m)
    let or_ = 0.5 * (ik + im_m)
    let oi = -0.5 * (rk - rm)
    let cu = cos_u[k]
    let su = sin_u[k]
    let tr = or_ * cu - oi * su
    let ti = or_ * su + oi * cu
    let gk = gains[k]
    let gm = gains[m]
    let xkr = (er + tr) * gk
    let xki = (ei + ti) * gk
    let xmr = (er - tr) * gm
    let xmi = (ti - ei) * gm
    // Repack Hermitian (Xk, Xm) into Zk, Zm for inverse half-FFT.
    let e2r = 0.5 * (xkr + xmr)
    let e2i = 0.5 * (xki - xmi)
    let d2r = 0.5 * (xkr - xmr)
    let d2i = 0.5 * (xki + xmi)
    let o2r = d2r * cu + d2i * su
    let o2i = d2i * cu - d2r * su
    re[k] = e2r - o2i
    im[k] = e2i + o2r
    re[m] = e2r + o2i
    im[m] = o2r - e2i
  }
  if quarter > 0 {
    let gq = gains[quarter]
    re[quarter] *= gq
    im[quarter] *= gq
  }
  self.half_plan.transform(re, im, inverse=true)
  let out_lim = if lim < out.length() { lim } else { out.length() }
  let out_pairs = out_lim / 2
  for j in 0..<out_pairs {
    out[2 * j] = re[j]
    out[2 * j + 1] = im[j]
  }
  if out_lim % 2 == 1 {
    out[out_lim - 1] = re[out_pairs]
  }
}

///|
/// Linear autocorrelation of `x[0..nx)` computed as the inverse FFT of
/// the power spectrum (Wiener-Khinchin). `plan.n` must be at least
/// `next_pow2(2 * nx)`; lags `0..=max_lag` are written into `ac`.
pub fn autocorrelation_fft(
  plan : FftPlan,
  x : FixedArray[Double],
  nx : Int32,
  ac : FixedArray[Double],
  max_lag~ : Int32,
) -> Unit {
  let n = plan.n
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<nx {
    re[i] = x[i]
  }
  plan.transform(re, im, inverse=false)
  for i in 0..<n {
    re[i] = re[i] * re[i] + im[i] * im[i]
    im[i] = 0.0
  }
  plan.transform(re, im, inverse=true)
  let top = if max_lag < n - 1 { max_lag } else { n - 1 }
  for tau in 0..<=top {
    if tau < ac.length() {
      ac[tau] = re[tau]
    }
  }
}

///|
/// Zero-allocation linear cross-correlation `cc[tau] = sum u[j] * v[j + tau]`
/// using caller-provided `re`/`im` scratch arrays of length `plan.n` and
/// real-pair packing (2 complex FFTs instead of 3).
pub fn cross_correlation_fft_buf(
  plan : FftPlan,
  u : FixedArray[Double],
  nu : Int32,
  v : FixedArray[Double],
  nv : Int32,
  cc : FixedArray[Double],
  max_lag~ : Int32,
  re : FixedArray[Double],
  im : FixedArray[Double],
) -> Unit {
  if max_lag < 0 || cc.length() == 0 {
    return
  }
  let n = plan.n
  let u_len = if nu < u.length() { nu } else { u.length() }
  let v_len = if nv < v.length() { nv } else { v.length() }
  let nu_clamped = if u_len < n { u_len } else { n }
  let nv_clamped = if v_len < n { v_len } else { n }
  for i in 0..<nu_clamped {
    re[i] = u[i]
  }
  for i in nu_clamped..<n {
    re[i] = 0.0
  }
  for i in 0..<nv_clamped {
    im[i] = v[i]
  }
  for i in nv_clamped..<n {
    im[i] = 0.0
  }
  // Single forward FFT of z = u + i*v.
  plan.transform(re, im, inverse=false)
  let half = n / 2
  // k = 0 and k = N/2: purely real product.
  re[0] = re[0] * im[0]
  im[0] = 0.0
  if half > 0 {
    re[half] = re[half] * im[half]
    im[half] = 0.0
  }
  // 1 <= k < N/2: conj(U[k]) * V[k] unpacked from Z[k] and Z[N - k].
  for k in 1..<half {
    let m = n - k
    let a = re[k]
    let b = im[k]
    let c = re[m]
    let d = im[m]
    let pr = 0.5 * (a * d + b * c)
    let pi = 0.25 * (c * c + d * d - a * a - b * b)
    re[k] = pr
    im[k] = pi
    re[m] = pr
    im[m] = -pi
  }
  plan.transform(re, im, inverse=true)
  let mut top = if max_lag < n - 1 { max_lag } else { n - 1 }
  if top > cc.length() - 1 {
    top = cc.length() - 1
  }
  for tau in 0..<=top {
    cc[tau] = re[tau]
  }
}

///|
/// Linear cross-correlation `cc[tau] = sum_{j=0}^{nu-1} u[j] * v[j + tau]`
/// for `0 <= tau <= max_lag`, computed via `IFFT(conj(FFT(u)) * FFT(v))`.
/// `plan.n` must be at least `next_pow2(max(nv, nu + max_lag))` to avoid
/// circular wrap-around.
pub fn cross_correlation_fft(
  plan : FftPlan,
  u : FixedArray[Double],
  nu : Int32,
  v : FixedArray[Double],
  nv : Int32,
  cc : FixedArray[Double],
  max_lag~ : Int32,
) -> Unit {
  if max_lag < 0 || cc.length() == 0 {
    return
  }
  let n = plan.n
  let re : FixedArray[Double] = FixedArray::make(n, 0.0)
  let im : FixedArray[Double] = FixedArray::make(n, 0.0)
  cross_correlation_fft_buf(plan, u, nu, v, nv, cc, max_lag~, re, im)
}
