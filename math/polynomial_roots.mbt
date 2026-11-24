// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

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
  // Unpacked real/imag arrays avoid allocating Complex structs per iteration.
  let r_re : FixedArray[Double] = FixedArray::make(deg, 0.0)
  let r_im : FixedArray[Double] = FixedArray::make(deg, 0.0)
  let mut gr = 1.0
  let mut gi = 0.0
  for k in 0..<deg {
    r_re[k] = gr
    r_im[k] = gi
    let ngr = gr * 0.4 - gi * 0.9
    let ngi = gr * 0.9 + gi * 0.4
    gr = ngr
    gi = ngi
  }
  for _ in 0..<200 {
    let mut max_delta_sq = 0.0
    for i in 0..<deg {
      let zr = r_re[i]
      let zi = r_im[i]
      // denominator: product of (z - roots[j]) for j != i
      let mut dr = 1.0
      let mut di = 0.0
      let mut singular = false
      for j in 0..<deg {
        if j != i {
          let xr = zr - r_re[j]
          let xi = zi - r_im[j]
          if xr * xr + xi * xi < 1.0e-300 {
            singular = true
            break
          }
          let ndr = dr * xr - di * xi
          let ndi = dr * xi + di * xr
          dr = ndr
          di = ndi
        }
      }
      if !singular {
        let den_sq = dr * dr + di * di
        if den_sq > 1.0e-300 {
          // Horner evaluation of monic p(z).
          let mut pr = 1.0
          let mut pi = 0.0
          let mut k = deg - 1
          while k >= 0 {
            let npr = pr * zr - pi * zi + c[k]
            let npi = pr * zi + pi * zr
            pr = npr
            pi = npi
            k -= 1
          }
          let inv_den = 1.0 / den_sq
          let dzr = (pr * dr + pi * di) * inv_den
          let dzi = (pi * dr - pr * di) * inv_den
          let dsq = dzr * dzr + dzi * dzi
          if dsq > max_delta_sq {
            max_delta_sq = dsq
          }
          r_re[i] = zr - dzr
          r_im[i] = zi - dzi
        }
      }
    }
    if max_delta_sq < 1.0e-26 {
      break
    }
  }
  for k in 0..<deg {
    roots.push({ re: r_re[k], im: r_im[k], })
  }
  roots
}
