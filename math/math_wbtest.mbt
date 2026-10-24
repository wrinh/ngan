// Whitebox tests for the math package (same package scope).

///|
fn approx(a : Double, b : Double, tol : Double) -> Bool {
  abs(a - b) <= tol
}

///|
test "complex arithmetic" {
  let z = { re: 3.0, im: 4.0, }
  assert_true(approx(z.abs(), 5.0, 1.0e-12))
  assert_true(approx(z.arg(), atan2(4.0, 3.0), 1.0e-12))
  // (3 + 4i)(1 + i) = -1 + 7i
  let prod = z.mul({ re: 1.0, im: 1.0, })
  assert_true(approx(prod.re, -1.0, 1.0e-12))
  assert_true(approx(prod.im, 7.0, 1.0e-12))
  // (1 + 2i) / (3 + 4i) = 0.44 + 0.08i
  let q = { re: 1.0, im: 2.0, }.div({ re: 3.0, im: 4.0, })
  assert_true(approx(q.re, 0.44, 1.0e-12))
  assert_true(approx(q.im, 0.08, 1.0e-12))
  // z + conj(z) = 2 Re(z)
  let s = z.add(z.conj())
  assert_true(approx(s.re, 6.0, 1.0e-12))
  assert_true(approx(s.im, 0.0, 1.0e-12))
  // polar round trip
  let p = Complex::from_polar(1.7, -1.2)
  assert_true(approx(p.abs(), 1.7, 1.0e-12))
  assert_true(approx(p.arg(), -1.2, 1.0e-12))
  let up = Complex::from_polar(2.0, PI / 2.0)
  assert_true(approx(up.re, 0.0, 1.0e-12))
  assert_true(approx(up.im, 2.0, 1.0e-12))
}

///|
test "bessel_i0 reference values" {
  assert_true(approx(bessel_i0(0.0), 1.0, 1.0e-12))
  assert_true(approx(bessel_i0(1.0), 1.2660658777520084, 1.0e-12))
  assert_true(approx(bessel_i0(-1.0), bessel_i0(1.0), 0.0))
  assert_true(approx(bessel_i0(10.0), 2815.716628466254, 2.8e-6))
  // Kaiser-20 shape factor 20*pi stays finite and astronomically large.
  let big = bessel_i0(20.0 * PI)
  assert_true(big > 1.0e20)
  assert_true(big < 1.0e30)
}

///|
test "poly_roots of simple polynomials" {
  // z^2 - 1 = 0 -> {1, -1}
  let r1 = poly_roots([-1.0, 0.0, 1.0])
  assert_eq(r1.length(), 2)
  let mut re_sum = 0.0
  for z in r1 {
    assert_true(approx(z.im, 0.0, 1.0e-9))
    assert_true(approx(z.abs(), 1.0, 1.0e-9))
    re_sum += z.re
  }
  assert_true(approx(re_sum, 0.0, 1.0e-9))
  // z^2 + 1 = 0 -> {i, -i}
  let r2 = poly_roots([1.0, 0.0, 1.0])
  assert_eq(r2.length(), 2)
  for z in r2 {
    assert_true(approx(z.re, 0.0, 1.0e-9))
    assert_true(approx(z.abs(), 1.0, 1.0e-9))
  }
  // z^3 - 1 = 0 -> cube roots of unity, p(z) == 1 for every root
  let r3 = poly_roots([-1.0, 0.0, 0.0, 1.0])
  assert_eq(r3.length(), 3)
  for z in r3 {
    let cube = z.mul(z).mul(z)
    assert_true(approx(cube.re, 1.0, 1.0e-9))
    assert_true(approx(cube.im, 0.0, 1.0e-9))
  }
}

///|
test "poly_roots recovers damped complex pair" {
  // (z - r e^{i th})(z - r e^{-i th}) = z^2 - 2 r cos(th) z + r^2
  let r = 0.9718
  let th = 0.2856
  let coeffs : FixedArray[Double] = [r * r, -2.0 * r * cos(th), 1.0]
  let roots = poly_roots(coeffs)
  assert_eq(roots.length(), 2)
  let mut upper : Complex = { re: 0.0, im: 0.0, }
  for z in roots {
    assert_true(approx(z.abs(), r, 1.0e-9))
    if z.im > 0.0 {
      upper = z
    }
  }
  assert_true(approx(upper.arg(), th, 1.0e-9))
}
