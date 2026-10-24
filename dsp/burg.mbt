// Burg linear-prediction front end for formant analysis.

///|
/// Burg linear-prediction coefficients of `x`, minimizing the summed
/// forward and backward squared prediction error.
///
/// Returns `a[0..=order]` with `a[0] = 1` for the error filter
/// `A(z) = 1 + a[1] z^-1 + ... + a[order] z^-order` whose poles are the
/// vocal-tract resonances. The reflection coefficient of stage m is
/// `k_m = 2 * sum f[n] b[n-1] / sum (f[n]^2 + b[n-1]^2)`; the
/// Levinson-style update keeps all poles inside the unit circle
/// (|k_m| <= 1).
pub fn burg_lpc(x : FixedArray[Double], order~ : Int32) -> FixedArray[Double] {
  let n = x.length()
  let a : FixedArray[Double] = FixedArray::make(order + 1, 0.0)
  a[0] = 1.0
  if order < 1 || n < order + 1 {
    return a
  }
  // f/b are the forward/backward prediction errors of the previous stage.
  let f : FixedArray[Double] = FixedArray::make(n, 0.0)
  let b : FixedArray[Double] = FixedArray::make(n, 0.0)
  for i in 0..<n {
    f[i] = x[i]
    b[i] = x[i]
  }
  let prev : FixedArray[Double] = FixedArray::make(order + 1, 0.0)
  for m in 1..<=order {
    let mut num = 0.0
    let mut den = 0.0
    for i in m..<n {
      num += f[i] * b[i - 1]
      den += f[i] * f[i] + b[i - 1] * b[i - 1]
    }
    let mut k = 0.0
    if den > 1.0e-300 {
      k = 2.0 * num / den
    }
    if k > 1.0 {
      k = 1.0
    }
    if k < -1.0 {
      k = -1.0
    }
    for i in 0..<=order {
      prev[i] = a[i]
    }
    // a_m[i] = a_{m-1}[i] - k * a_{m-1}[m-i] for i = 1..m-1; a_m[m] = -k.
    for i in 1..<m {
      a[i] = prev[i] - k * prev[m - i]
    }
    a[m] = -k
    // f_m[i] = f[i] - k b[i-1]; b_m[i] = b[i-1] - k f[i]. The old b[i-1]
    // must be carried across iterations because b is updated in place.
    let mut bi_prev = b[m - 1]
    for i in m..<n {
      let fi = f[i]
      let b_old_i = b[i]
      f[i] = fi - k * bi_prev
      b[i] = bi_prev - k * fi
      bi_prev = b_old_i
    }
  }
  a
}
