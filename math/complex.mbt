// Complex arithmetic used by the polynomial root finder.

///|
/// Complex number with double-precision components.
pub(all) struct Complex {
  re : Double
  im : Double
}

///|
pub fn Complex::add(self : Complex, other : Complex) -> Complex {
  { re: self.re + other.re, im: self.im + other.im, }
}

///|
pub fn Complex::sub(self : Complex, other : Complex) -> Complex {
  { re: self.re - other.re, im: self.im - other.im, }
}

///|
pub fn Complex::mul(self : Complex, other : Complex) -> Complex {
  {
    re: self.re * other.re - self.im * other.im,
    im: self.re * other.im + self.im * other.re,
  }
}

///|
pub fn Complex::div(self : Complex, other : Complex) -> Complex {
  let d = other.re * other.re + other.im * other.im
  {
    re: (self.re * other.re + self.im * other.im) / d,
    im: (self.im * other.re - self.re * other.im) / d,
  }
}

///|
/// Modulus |z|.
pub fn Complex::abs(self : Complex) -> Double {
  (self.re * self.re + self.im * self.im).sqrt()
}

///|
/// Argument (phase angle) in (-pi, pi].
pub fn Complex::arg(self : Complex) -> Double {
  atan2(self.im, self.re)
}

///|
pub fn Complex::conj(self : Complex) -> Complex {
  { re: self.re, im: -self.im, }
}

///|
/// r * (cos theta + i sin theta).
pub fn Complex::from_polar(r : Double, theta : Double) -> Complex {
  { re: r * cos(theta), im: r * sin(theta), }
}
