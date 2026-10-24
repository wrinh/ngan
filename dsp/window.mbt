// Analysis windows matching Praat's engine exactly.

///|
/// Kaiser window `w[i] = I0(beta * sqrt(1 - x^2)) / I0(beta)` with
/// `x = (i - centre) / half_span`, matching Praat's intensity analysis
/// (Praat uses the raw Bessel values; the constant I0(beta) factor
/// cancels in every ratio ngan computes).
///
/// For intensity analysis Praat passes beta = 2*pi^2 + 0.5 (~= 20.24,
/// sidelobes below -100 dB, the "Kaiser-20" window).
pub fn kaiser_window(n : Int32, beta~ : Double) -> FixedArray[Double] {
  let size = if n < 1 { 1 } else { n }
  let w : FixedArray[Double] = FixedArray::make(size, 1.0)
  if n <= 1 {
    return w
  }
  let denom = @math.bessel_i0(beta)
  let half = (n - 1).to_double() / 2.0
  for i in 0..<n {
    let x = (i.to_double() - half) / half
    let s = 1.0 - x * x
    if s > 0.0 {
      w[i] = @math.bessel_i0(beta * s.sqrt()) / denom
    } else {
      w[i] = 1.0 / denom
    }
  }
  w
}

///|
/// Praat's periodic Hann window
/// `w[i] = 0.5 - 0.5 cos(2 pi (i + 1) / (N + 1))` for i = 0 .. N-1
/// (Sound_to_Pitch.cpp, AC_HANNING). The endpoints are small but nonzero,
/// and the window is symmetric.
pub fn hanning_window(n : Int32) -> FixedArray[Double] {
  let size = if n < 1 { 1 } else { n }
  let w : FixedArray[Double] = FixedArray::make(size, 1.0)
  if n <= 1 {
    return w
  }
  let m = (n + 1).to_double()
  for i in 0..<n {
    w[i] = 0.5 - 0.5 * @math.cos(2.0 * @math.PI * (i + 1).to_double() / m)
  }
  w
}

///|
/// Praat's Gaussian analysis window spanning twice the effective window
/// length: `(exp(-48 (i - imid)^2 / (N + 1)^2) - exp(-12)) / (1 - exp(-12))`
/// with `imid = (N + 1) / 2`, effectively zero at both edges
/// (Sound_to_Formant.cpp).
pub fn gaussian_window(n : Int32) -> FixedArray[Double] {
  let size = if n < 1 { 1 } else { n }
  let w : FixedArray[Double] = FixedArray::make(size, 0.0)
  if n <= 1 {
    w[0] = 1.0
    return w
  }
  let m = (n + 1).to_double()
  let imid = 0.5 * m
  let edge = @math.exp(-12.0)
  let norm = 1.0 - edge
  for i in 0..<n {
    let d = (i + 1).to_double() - imid
    w[i] = (@math.exp(-48.0 * d * d / (m * m)) - edge) / norm
  }
  w
}
