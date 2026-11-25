// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Iterative radix-4 / radix-2 FFT with stage-contiguous twiddles, precomputed
// bit-reversal swap pairs, zero-padding pruning, and half-length real FFTs.

///|
/// Precomputed plan for in-place radix-4 / radix-2 FFT and IFFT of one
/// power-of-two size.
pub struct FftPlan {
  n : Int32
  bits : Int32
  swap_a : FixedArray[Int32]
  swap_b : FixedArray[Int32]
  tw_r4 : FixedArray[Double]
  half_plan : FftPlan?
  cos_u : FixedArray[Double]
  sin_u : FixedArray[Double]
}

///|
/// Smallest power of two >= `n` (clamped to >= 1).
/// Aborts if `n > 2^30` (`1073741824`) because the next power of two overflows `Int32`.
pub fn next_pow2(n : Int32) -> Int32 {
  if n > 1073741824 {
    abort("next_pow2: n exceeds max Int32 power of two (2^30), got \{n}")
  }
  if n <= 1 {
    return 1
  }
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
/// Exact twiddle factor `(cos(-2*pi*k/len), sin(-2*pi*k/len))` with exact
/// cardinal axis values to avoid floating-point leakage on real/even signals.
fn exact_twiddle(k : Int32, len : Int32) -> (Double, Double) {
  let mut m = k % len
  if m < 0 {
    m += len
  }
  if m == 0 {
    return (1.0, 0.0)
  }
  if 2 * m == len {
    return (-1.0, 0.0)
  }
  if len % 4 == 0 {
    let q = len / 4
    if m == q {
      return (0.0, -1.0)
    }
    if m == 3 * q {
      return (0.0, 1.0)
    }
  }
  let a = -2.0 * @math.PI * m.to_double() / len.to_double()
  (@math.cos(a), @math.sin(a))
}

///|
fn build_swap_pairs(
  n : Int32,
  bits : Int32,
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let rev : FixedArray[Int32] = FixedArray::make(n, 0)
  let shift = bits - 1
  for i in 1..<n {
    rev[i] = (rev[i >> 1] >> 1) | ((i & 1) << shift)
  }
  let mut count = 0
  for i in 0..<n {
    if rev[i] > i {
      count += 1
    }
  }
  let swap_a : FixedArray[Int32] = FixedArray::make(count, 0)
  let swap_b : FixedArray[Int32] = FixedArray::make(count, 0)
  let mut idx = 0
  for i in 0..<n {
    let j = rev[i]
    if j > i {
      swap_a[idx] = i
      swap_b[idx] = j
      idx += 1
    }
  }
  (swap_a, swap_b)
}

///|
/// Stage-contiguous radix-4 twiddle table `[w1r, w1i, w2r, w2i, w3r, w3i, ...]`
/// covering `k in 1..<q` for each radix-4 stage starting after `len = 4` (even
/// `bits`) or `len = 8` (odd `bits`).
fn build_tw_r4(n : Int32, bits : Int32) -> FixedArray[Double] {
  let quarter_n = n / 4
  let start_q = if (bits & 1) == 1 { 8 } else { 4 }
  let mut total_k = 0
  let mut q = start_q
  while q <= quarter_n {
    total_k += q - 1
    q *= 4
  }
  let tw_r4 : FixedArray[Double] = FixedArray::make(6 * total_k, 0.0)
  let mut off = 0
  q = start_q
  while q <= quarter_n {
    let step4 = 4 * q
    for k in 1..<q {
      let (w1r, w1i) = exact_twiddle(k, step4)
      let (w2r, w2i) = exact_twiddle(2 * k, step4)
      let (w3r, w3i) = exact_twiddle(3 * k, step4)
      tw_r4[off] = w1r
      tw_r4[off + 1] = w1i
      tw_r4[off + 2] = w2r
      tw_r4[off + 3] = w2i
      tw_r4[off + 4] = w3r
      tw_r4[off + 5] = w3i
      off += 6
    }
    q *= 4
  }
  tw_r4
}

///|
fn build_unpack_twiddles(n : Int32) -> (FixedArray[Double], FixedArray[Double]) {
  let quarter = n / 4
  let cos_u : FixedArray[Double] = FixedArray::make(quarter + 1, 0.0)
  let sin_u : FixedArray[Double] = FixedArray::make(quarter + 1, 0.0)
  for k in 0..<=quarter {
    let (c, s) = exact_twiddle(k, n)
    cos_u[k] = c
    sin_u[k] = s
  }
  (cos_u, sin_u)
}

///|
fn FftPlan::new_internal(n : Int32, with_half : Bool) -> FftPlan {
  if n < 2 || n > 1073741824 || (n & (n - 1)) != 0 {
    abort("FftPlan::new: size must be a power of two in [2, 2^30], got \{n}")
  }
  let bits = log2_int(n)
  let (swap_a, swap_b) = build_swap_pairs(n, bits)
  let tw_r4 = build_tw_r4(n, bits)
  let half_plan : FftPlan? = if with_half && n >= 4 {
    Some(FftPlan::new_internal(n / 2, false))
  } else {
    None
  }
  let (cos_u, sin_u) = if with_half && n >= 4 {
    build_unpack_twiddles(n)
  } else {
    ([], [])
  }
  { n, bits, swap_a, swap_b, tw_r4, half_plan, cos_u, sin_u, }
}

///|
/// Create a plan for size `n`, which must be a power of two in `[2, 2^30]`.
pub fn FftPlan::new(n : Int32) -> FftPlan {
  FftPlan::new_internal(n, true)
}

///|
/// In-place forward DFT. When `pruned = true`, skips reads/additions on the
/// second half (`n/2..<n`) zero-padded elements, which occupy odd indices after
/// bit-reversal.
fn FftPlan::transform_forward(
  self : FftPlan,
  re : FixedArray[Double],
  im : FixedArray[Double],
  pruned~ : Bool,
) -> Unit {
  let n = self.n
  let swap_a = self.swap_a
  let swap_b = self.swap_b
  let n_swaps = swap_a.length()
  for s in 0..<n_swaps {
    let a = swap_a[s]
    let b = swap_b[s]
    let tr = re[a]
    re[a] = re[b]
    re[b] = tr
    let ti = im[a]
    im[a] = im[b]
    im[b] = ti
  }
  if n == 2 {
    if pruned {
      let r0 = re[0]
      let i0 = im[0]
      re[1] = r0
      im[1] = i0
    } else {
      let r0 = re[0]
      let r1 = re[1]
      let i0 = im[0]
      let i1 = im[1]
      re[0] = r0 + r1
      re[1] = r0 - r1
      im[0] = i0 + i1
      im[1] = i0 - i1
    }
    return
  }
  // Merged radix-4 first stage combining len = 2 and len = 4 (0 multiplications).
  if pruned {
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
      re[base + 1] = r0 + i2
      im[base + 1] = i0 - r2
      re[base + 3] = r0 - i2
      im[base + 3] = i0 + r2
      base += 4
    }
  } else {
    let mut base = 0
    while base < n {
      let a0r = re[base]
      let a0i = im[base]
      let a1r = re[base + 1]
      let a1i = im[base + 1]
      let a2r = re[base + 2]
      let a2i = im[base + 2]
      let a3r = re[base + 3]
      let a3i = im[base + 3]
      let t0r = a0r + a1r
      let t0i = a0i + a1i
      let t1r = a0r - a1r
      let t1i = a0i - a1i
      let t2r = a2r + a3r
      let t2i = a2i + a3i
      let t3r = a2r - a3r
      let t3i = a2i - a3i
      re[base] = t0r + t2r
      im[base] = t0i + t2i
      re[base + 2] = t0r - t2r
      im[base + 2] = t0i - t2i
      re[base + 1] = t1r + t3i
      im[base + 1] = t1i - t3r
      re[base + 3] = t1r - t3i
      im[base + 3] = t1i + t3r
      base += 4
    }
  }
  // If log2(n) is odd and n >= 8, run one hardcoded len = 8 radix-2 stage.
  if (self.bits & 1) == 1 && n >= 8 {
    let s = 0.7071067811865475244
    let mut base = 0
    while base < n {
      // k = 0: twiddle = (1, 0)
      let r0 = re[base]
      let i0 = im[base]
      let r4 = re[base + 4]
      let i4 = im[base + 4]
      re[base] = r0 + r4
      im[base] = i0 + i4
      re[base + 4] = r0 - r4
      im[base + 4] = i0 - i4
      // k = 1: twiddle = (s, -s)
      let r1 = re[base + 1]
      let i1 = im[base + 1]
      let r5 = re[base + 5]
      let i5 = im[base + 5]
      let x5r = (r5 + i5) * s
      let x5i = (i5 - r5) * s
      re[base + 1] = r1 + x5r
      im[base + 1] = i1 + x5i
      re[base + 5] = r1 - x5r
      im[base + 5] = i1 - x5i
      // k = 2: twiddle = (0, -1)
      let r2 = re[base + 2]
      let i2 = im[base + 2]
      let r6 = re[base + 6]
      let i6 = im[base + 6]
      re[base + 2] = r2 + i6
      im[base + 2] = i2 - r6
      re[base + 6] = r2 - i6
      im[base + 6] = i2 + r6
      // k = 3: twiddle = (-s, -s)
      let r3 = re[base + 3]
      let i3 = im[base + 3]
      let r7 = re[base + 7]
      let i7 = im[base + 7]
      let x7r = (i7 - r7) * s
      let x7i = -(r7 + i7) * s
      re[base + 3] = r3 + x7r
      im[base + 3] = i3 + x7i
      re[base + 7] = r3 - x7r
      im[base + 7] = i3 - x7i
      base += 8
    }
  }
  // Remaining stages are radix-4 with stage-contiguous twiddles.
  let tw_r4 = self.tw_r4
  let quarter_n = n / 4
  let mut q = if (self.bits & 1) == 1 { 8 } else { 4 }
  let mut tw_off = 0
  while q <= quarter_n {
    let step4 = 4 * q
    let q2 = 2 * q
    let q3 = 3 * q
    let mut base = 0
    while base < n {
      // Peeled k = 0 butterfly (W1 = W2 = W3 = 1, 0 multiplications).
      let x0r = re[base]
      let x0i = im[base]
      let x1r = re[base + q]
      let x1i = im[base + q]
      let x2r = re[base + q2]
      let x2i = im[base + q2]
      let x3r = re[base + q3]
      let x3i = im[base + q3]
      let p0r = x0r + x1r
      let p0i = x0i + x1i
      let p1r = x0r - x1r
      let p1i = x0i - x1i
      let q0r = x2r + x3r
      let q0i = x2i + x3i
      let q1r = x2r - x3r
      let q1i = x2i - x3i
      re[base] = p0r + q0r
      im[base] = p0i + q0i
      re[base + q2] = p0r - q0r
      im[base + q2] = p0i - q0i
      re[base + q] = p1r + q1i
      im[base + q] = p1i - q1r
      re[base + q3] = p1r - q1i
      im[base + q3] = p1i + q1r
      let mut tw = tw_off
      for k in 1..<q {
        let i0 = base + k
        let i1 = i0 + q
        let i2 = i0 + q2
        let i3 = i0 + q3
        let w1r = tw_r4[tw]
        let w1i = tw_r4[tw + 1]
        let w2r = tw_r4[tw + 2]
        let w2i = tw_r4[tw + 3]
        let w3r = tw_r4[tw + 4]
        let w3i = tw_r4[tw + 5]
        tw += 6
        let a0r = re[i0]
        let a0i = im[i0]
        let r1 = re[i1]
        let b1 = im[i1]
        let r2 = re[i2]
        let b2 = im[i2]
        let r3 = re[i3]
        let b3 = im[i3]
        // In bit-reversed DIT order, branch +q gets W2 and branch +2q gets W1.
        let t2r = r1 * w2r - b1 * w2i
        let t2i = r1 * w2i + b1 * w2r
        let t1r = r2 * w1r - b2 * w1i
        let t1i = r2 * w1i + b2 * w1r
        let t3r = r3 * w3r - b3 * w3i
        let t3i = r3 * w3i + b3 * w3r
        let e0r = a0r + t2r
        let e0i = a0i + t2i
        let e1r = a0r - t2r
        let e1i = a0i - t2i
        let o0r = t1r + t3r
        let o0i = t1i + t3i
        let o1r = t1r - t3r
        let o1i = t1i - t3i
        re[i0] = e0r + o0r
        im[i0] = e0i + o0i
        re[i2] = e0r - o0r
        im[i2] = e0i - o0i
        re[i1] = e1r + o1i
        im[i1] = e1i - o1r
        re[i3] = e1r - o1i
        im[i3] = e1i + o1r
      }
      base += step4
    }
    tw_off += 6 * (q - 1)
    q *= 4
  }
}

///|
/// In-place transform of the complex sequence in `re`/`im` (both of
/// length >= `plan.n`). With `inverse = false` computes the DFT with
/// exponent -2*pi*i/N; with `inverse = true` the conjugate transform
/// divided by N via `IFFT(a + i*b) = (1/N) * swap(FFT(b + i*a))`.
pub fn FftPlan::transform(
  self : FftPlan,
  re : FixedArray[Double],
  im : FixedArray[Double],
  inverse~ : Bool,
) -> Unit {
  let n = self.n
  if re.length() < n || im.length() < n {
    abort(
      "FftPlan::transform: buffer length smaller than plan size \{n} (got re=\{re.length()}, im=\{im.length()})",
    )
  }
  if inverse {
    self.transform_forward(im, re, pruned=false)
    let inv_n = 1.0 / n.to_double()
    for k in 0..<n {
      re[k] *= inv_n
      im[k] *= inv_n
    }
  } else {
    self.transform_forward(re, im, pruned=false)
  }
}

///|
/// Precomputed plan for N-point real-valued FFT / IFFT / autocorrelation
/// via an (N/2)-point complex FFT with reusable scratch buffers.
///
/// NOTE: `RealFftPlan` holds mutable scratch arrays (`buf_re`, `buf_im`),
/// so a single instance is NOT reentrant or thread-safe across concurrent
/// calls. Create separate plans per thread/worker if parallelized.
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
/// Create a real-FFT plan for size `n`, which must be a power of two in `[4, 2^30]`.
pub fn RealFftPlan::new(n : Int32) -> RealFftPlan {
  if n < 4 || n > 1073741824 || (n & (n - 1)) != 0 {
    abort(
      "RealFftPlan::new: size must be a power of two in [4, 2^30], got \{n}",
    )
  }
  let half = n / 2
  let half_plan = FftPlan::new_internal(half, false)
  let (cos_u, sin_u) = build_unpack_twiddles(n)
  let buf_re : FixedArray[Double] = FixedArray::make(half, 0.0)
  let buf_im : FixedArray[Double] = FixedArray::make(half, 0.0)
  { n, half, half_plan, cos_u, sin_u, buf_re, buf_im, }
}

///|
/// Pack `x[0..lim)` as complex pairs into `re`/`im` (zero-padding up to
/// `half`), returning `lim`.
fn pack_real_pairs(
  x : FixedArray[Double],
  nx : Int32,
  n : Int32,
  half : Int32,
  re : FixedArray[Double],
  im : FixedArray[Double],
) -> Int32 {
  let mut lim = if nx < 0 { 0 } else if nx < n { nx } else { n }
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
  lim
}

///|
/// Unpack interleaved `(re[j], im[j])` pairs into `out[0..count)`.
fn unpack_real_pairs(
  re : FixedArray[Double],
  im : FixedArray[Double],
  count : Int32,
  out : FixedArray[Double],
) -> Unit {
  let lim = if count < out.length() { count } else { out.length() }
  if lim <= 0 {
    return
  }
  let pairs = lim / 2
  for j in 0..<pairs {
    out[2 * j] = re[j]
    out[2 * j + 1] = im[j]
  }
  if lim % 2 == 1 {
    out[lim - 1] = re[pairs]
  }
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
  if power.length() <= half {
    abort(
      "RealFftPlan::forward_power: power length must be >= \{half + 1}, got \{power.length()}",
    )
  }
  let re = self.buf_re
  let im = self.buf_im
  let lim = pack_real_pairs(x, nx, self.n, half, re, im)
  self.half_plan.transform_forward(re, im, pruned=lim <= half)
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
    let pk = rk * rk + ik * ik
    let pm = rm * rm + im_m * im_m
    let er = 0.5 * (pk + pm)
    let dr = (rk * im_m + rm * ik) * cos_u[k] + 0.5 * (pk - pm) * sin_u[k]
    power[k] = er + dr
    power[m] = er - dr
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
  if spec.length() <= half {
    abort(
      "RealFftPlan::inverse_real_even: spec length must be >= \{half + 1}, got \{spec.length()}",
    )
  }
  if out_len <= 0 || out.length() == 0 {
    return
  }
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
  let top = if out_len < self.n { out_len } else { self.n }
  unpack_real_pairs(re, im, top, out)
}

///|
/// Zero-allocation in-place linear autocorrelation via `RealFftPlan`.
/// Fuses power-spectrum computation and inverse real-even repacking directly
/// in `buf_re`/`buf_im` using the parallelogram identity (no `scratch_power`).
pub fn RealFftPlan::autocorrelation(
  self : RealFftPlan,
  x : FixedArray[Double],
  nx : Int32,
  ac : FixedArray[Double],
  max_lag~ : Int32,
) -> Unit {
  if max_lag < 0 || ac.length() == 0 {
    return
  }
  let half = self.half
  let re = self.buf_re
  let im = self.buf_im
  let lim = pack_real_pairs(x, nx, self.n, half, re, im)
  self.half_plan.transform_forward(re, im, pruned=lim <= half)
  // Fused power-spectrum + inverse real-even repack in-place.
  let r0 = re[0]
  let i0 = im[0]
  re[0] = r0 * r0 + i0 * i0
  im[0] = 2.0 * r0 * i0
  let quarter = half / 2
  let cos_u = self.cos_u
  let sin_u = self.sin_u
  for k in 1..<quarter {
    let m = half - k
    let rk = re[k]
    let ik = im[k]
    let rm = re[m]
    let im_m = im[m]
    let pk = rk * rk + ik * ik
    let pm = rm * rm + im_m * im_m
    let er = 0.5 * (pk + pm)
    let cu = cos_u[k]
    let su = sin_u[k]
    let dr = (rk * im_m + rm * ik) * cu + 0.5 * (pk - pm) * su
    let or_ = dr * cu
    let oi = -dr * su
    re[k] = er - oi
    im[k] = or_
    re[m] = er + oi
    im[m] = or_
  }
  if quarter > 0 {
    let rq = re[quarter]
    let iq = im[quarter]
    re[quarter] = rq * rq + iq * iq
    im[quarter] = 0.0
  }
  self.half_plan.transform(re, im, inverse=true)
  let top = if max_lag < self.n - 1 { max_lag } else { self.n - 1 }
  unpack_real_pairs(re, im, top + 1, ac)
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
  if gains.length() <= half {
    abort(
      "RealFftPlan::filter_real: gains length must be >= \{half + 1}, got \{gains.length()}",
    )
  }
  let re = self.buf_re
  let im = self.buf_im
  let lim = pack_real_pairs(x, nx, self.n, half, re, im)
  if lim <= 0 || out.length() == 0 {
    return
  }
  self.half_plan.transform_forward(re, im, pruned=lim <= half)
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
    // Merge both 0.5 unpack and 0.5 repack scalings into gk/gm (0.25).
    let er = rk + rm
    let ei = ik - im_m
    let or_ = ik + im_m
    let oi = rm - rk
    let cu = cos_u[k]
    let su = sin_u[k]
    let tr = or_ * cu - oi * su
    let ti = or_ * su + oi * cu
    let gk = 0.25 * gains[k]
    let gm = 0.25 * gains[m]
    let xkr = (er + tr) * gk
    let xki = (ei + ti) * gk
    let xmr = (er - tr) * gm
    let xmi = (ti - ei) * gm
    let e2r = xkr + xmr
    let e2i = xki - xmi
    let d2r = xkr - xmr
    let d2i = xki + xmi
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
  unpack_real_pairs(re, im, lim, out)
}

///|
/// Linear autocorrelation convenience wrapper around `RealFftPlan`.
/// Allocates `n/2`-length scratch buffers per call; prefer `RealFftPlan::autocorrelation`
/// directly in hot loops to avoid repeated heap allocations.
pub fn autocorrelation_fft(
  plan : FftPlan,
  x : FixedArray[Double],
  nx : Int32,
  ac : FixedArray[Double],
  max_lag~ : Int32,
) -> Unit {
  if max_lag < 0 || ac.length() == 0 {
    return
  }
  let n = plan.n
  if n == 2 {
    let mut lim = if nx < 0 { 0 } else if nx < 2 { nx } else { 2 }
    if lim > x.length() {
      lim = x.length()
    }
    let x0 = if lim > 0 { x[0] } else { 0.0 }
    let x1 = if lim > 1 { x[1] } else { 0.0 }
    ac[0] = x0 * x0 + x1 * x1
    if max_lag >= 1 && ac.length() > 1 {
      ac[1] = 2.0 * x0 * x1
    }
    return
  }
  let half = n / 2
  let rplan : RealFftPlan = {
    n,
    half,
    half_plan: match plan.half_plan {
      Some(hp) => hp
      None => FftPlan::new_internal(half, false)
    },
    cos_u: plan.cos_u,
    sin_u: plan.sin_u,
    buf_re: FixedArray::make(half, 0.0),
    buf_im: FixedArray::make(half, 0.0),
  }
  rplan.autocorrelation(x, nx, ac, max_lag~)
}

///|
/// Zero-allocation linear cross-correlation `cc[tau] = sum u[j] * v[j + tau]`
/// using caller-provided `re`/`im` scratch arrays of length >= `plan.n`:
/// real-pair forward packing (`N`-point complex FFT) plus a half-length
/// (`N/2`-point) real inverse FFT (3 half-length FFT equivalents total).
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
  if re.length() < n || im.length() < n {
    abort(
      "cross_correlation_fft_buf: scratch buffer length smaller than plan size \{n}",
    )
  }
  let u_pos = if nu < 0 { 0 } else { nu }
  let v_pos = if nv < 0 { 0 } else { nv }
  let u_len = if u_pos < u.length() { u_pos } else { u.length() }
  let v_len = if v_pos < v.length() { v_pos } else { v.length() }
  let nu_clamped = if u_len < n { u_len } else { n }
  let nv_clamped = if v_len < n { v_len } else { n }
  let mut top = if max_lag < n - 1 { max_lag } else { n - 1 }
  if top > cc.length() - 1 {
    top = cc.length() - 1
  }
  if nu_clamped == 0 || nv_clamped == 0 {
    for tau in 0..<=top {
      cc[tau] = 0.0
    }
    return
  }
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
  plan.transform_forward(re, im, pruned=false)
  if n == 2 {
    let x0 = re[0] * im[0]
    let x1 = re[1] * im[1]
    cc[0] = 0.5 * (x0 + x1)
    if top >= 1 {
      cc[1] = 0.5 * (x0 - x1)
    }
    return
  }
  let half = n / 2
  let quarter = half / 2
  let cos_u = plan.cos_u
  let sin_u = plan.sin_u
  // k = 0 and k = N/2: purely real product packed into Z_half[0].
  let x0 = re[0] * im[0]
  let xh = re[half] * im[half]
  re[0] = 0.5 * (x0 + xh)
  im[0] = 0.5 * (x0 - xh)
  // 1 <= k < N/4: unpack X[k] and X[half - k] from Z_full, then repack into
  // Z_half[0..<half] for a half-length real inverse FFT.
  for k in 1..<quarter {
    let m = half - k
    let nk = n - k
    let nm = n - m
    let ak = re[k]
    let bk = im[k]
    let ck = re[nk]
    let dk = im[nk]
    let am = re[m]
    let bm = im[m]
    let cm = re[nm]
    let dm = im[nm]
    let xkr = 0.5 * (ak * dk + bk * ck)
    let xki = 0.25 * (ck * ck + dk * dk - ak * ak - bk * bk)
    let xmr = 0.5 * (am * dm + bm * cm)
    let xmi = 0.25 * (cm * cm + dm * dm - am * am - bm * bm)
    let cu = cos_u[k]
    let su = sin_u[k]
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
    let q3 = n - quarter
    let aq = re[quarter]
    let bq = im[quarter]
    let cq = re[q3]
    let dq = im[q3]
    let pr = 0.5 * (aq * dq + bq * cq)
    let pi = 0.25 * (cq * cq + dq * dq - aq * aq - bq * bq)
    // Z_half[quarter] = conj(X[quarter])
    re[quarter] = pr
    im[quarter] = -pi
  }
  match plan.half_plan {
    Some(hp) => hp.transform(re, im, inverse=true)
    None => ()
  }
  unpack_real_pairs(re, im, top + 1, cc)
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
