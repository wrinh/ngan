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
  // Bit-reversal permutation.
  for i in 0..<n {
    let j = self.rev[i]
    if j > i {
      let tr = re[i]
      re[i] = re[j]
      re[j] = tr
      let ti = im[i]
      im[i] = im[j]
      im[j] = ti
    }
  }
  // Butterflies; twiddles for stage length `len` are strided views into
  // the half-size table.
  let mut len = 2
  while len <= n {
    let half = len / 2
    let step = n / len
    let mut base = 0
    while base < n {
      for k in 0..<half {
        let w = k * step
        let wr = self.cos_t[w]
        let wi = if inverse { -self.sin_t[w] } else { self.sin_t[w] }
        let i1 = base + k
        let i2 = i1 + half
        let xr = re[i2] * wr - im[i2] * wi
        let xi = re[i2] * wi + im[i2] * wr
        re[i2] = re[i1] - xr
        im[i2] = im[i1] - xi
        re[i1] += xr
        im[i1] += xi
      }
      base += len
    }
    len *= 2
  }
  if inverse {
    let nf = n.to_double()
    for i in 0..<n {
      re[i] /= nf
      im[i] /= nf
    }
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
