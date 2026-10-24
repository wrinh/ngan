// Special function needed for exact Kaiser windows.

///|
/// Zeroth-order modified Bessel function of the first kind, I0(x).
///
/// Computed with the ascending power series
/// `I0(x) = sum_k ((x/2)^k / k!)^2`, which stays well conditioned over
/// the whole Kaiser-window range of interest (|x| <= ~64).
pub fn bessel_i0(x_in : Double) -> Double {
  let x = if x_in < 0.0 { -x_in } else { x_in }
  let half_sq = x / 2.0 * (x / 2.0)
  let mut term = 1.0
  let mut sum = 1.0
  for k in 1..<=600 {
    let kf = k.to_double()
    term *= half_sq / (kf * kf)
    sum += term
    if term < sum * 1.0e-18 {
      break
    }
  }
  sum
}
