// Anti-aliasing resampler for the formant front end.

///|
/// Band-limited resampling with a Kaiser-weighted sinc kernel.
///
/// `ratio` is fs_out / fs_in. The cutoff is min(fs_in, fs_out) / 2 (no
/// filtering for pure upsampling), the kernel spans `zero_crossings`
/// zero crossings on each side, and the output length is
/// `round(nx * ratio)`. Linear interpolation must never be used for
/// formant analysis: it distorts the spectrum near Nyquist.
pub fn sinc_resample(
  x : FixedArray[Double],
  ratio~ : Double,
  beta~ : Double = 12.0,
  zero_crossings~ : Int32 = 32,
) -> FixedArray[Double] {
  let nx = x.length()
  if nx == 0 || ratio <= 0.0 {
    return FixedArray::make(0, 0.0)
  }
  let ny_raw = @math.floor(nx.to_double() * ratio + 0.5).to_int()
  let ny = if ny_raw < 1 { 1 } else { ny_raw }
  let y : FixedArray[Double] = FixedArray::make(ny, 0.0)
  let fc = if ratio < 1.0 { ratio } else { 1.0 }
  let inv = 1.0 / ratio
  let denom = @math.bessel_i0(beta)
  let l = if zero_crossings < 1 { 1.0 } else { zero_crossings.to_double() }
  for j in 0..<ny {
    let t = j.to_double() * inv // output position in input samples
    let lo = @math.ceil(t - l).to_int()
    let hi = @math.floor(t + l).to_int()
    let mut acc = 0.0
    let mut n = lo
    while n <= hi {
      if n >= 0 && n < nx {
        let d = t - n.to_double()
        let pd = @math.PI * fc * d
        let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
        let arg = d / l
        let wm = @math.bessel_i0(beta * (1.0 - arg * arg).sqrt()) / denom
        acc += x[n] * (fc * s) * wm
      }
      n += 1
    }
    y[j] = acc
  }
  y
}
