// Root finding for the LPC denominator polynomial.

///|
/// All complex roots of the real-coefficient polynomial
/// `coeffs[0] + coeffs[1] * z + ... + coeffs[deg] * z^deg` (coefficients
/// in ascending powers), found with the Durand-Kerner simultaneous
/// iteration. Leading zero coefficients are trimmed; the result is empty
/// when the polynomial degenerates to a nonzero constant.
///
/// Initial guesses are `(0.4 + 0.9i)^k`; iteration stops when every
/// residual `|p(z_i)|` update is below 1e-13 or after 200 sweeps.
pub fn poly_roots(coeffs : FixedArray[Double]) -> Array[Complex] {
  let roots : Array[Complex] = []
  let mut deg = coeffs.length() - 1
  while deg >= 0 && coeffs[deg] == 0.0 {
    deg -= 1
  }
  if deg < 1 {
    return roots
  }
  // Normalize to monic: p(z) = z^deg + c[deg-1] z^(deg-1) + ... + c[0].
  let c : FixedArray[Double] = FixedArray::make(deg + 1, 0.0)
  let lead = coeffs[deg]
  for i in 0..<=deg {
    c[i] = coeffs[i] / lead
  }
  if deg == 1 {
    roots.push({ re: -c[0], im: 0.0, })
    return roots
  }
  fn eval_at(z : Complex) -> Complex {
    let mut acc : Complex = { re: 1.0, im: 0.0, }
    for k in 0..<deg {
      acc = acc.mul(z).add({ re: c[deg - 1 - k], im: 0.0, })
    }
    acc
  }
  // Initial guesses (0.4 + 0.9i)^k for k = 0 .. deg-1.
  let base : Complex = { re: 0.4, im: 0.9, }
  let mut g : Complex = { re: 1.0, im: 0.0, }
  for _ in 0..<deg {
    roots.push(g)
    g = g.mul(base)
  }
  for _ in 0..<200 {
    let mut max_delta = 0.0
    for i in 0..<deg {
      let z = roots[i]
      // denominator: product of (z - roots[j]) for j != i
      let mut den : Complex = { re: 1.0, im: 0.0, }
      let mut singular = false
      for j in 0..<deg {
        if j != i {
          let diff = z.sub(roots[j])
          if diff.abs() < 1.0e-300 {
            singular = true
            break
          }
          den = den.mul(diff)
        }
      }
      if !singular {
        let dz = eval_at(z).div(den)
        max_delta = dmax(max_delta, dz.abs())
        roots[i] = z.sub(dz)
      }
    }
    if max_delta < 1.0e-13 {
      break
    }
  }
  roots
}
