// Thin re-exports of the libm surface used across ngan plus small numeric
// helpers, so every other package only needs to import `308K/ngan/math`.

///|
pub const PI : Double = 3.14159265358979323846

///|
pub const LN2 : Double = 0.69314718055994530942

///|
pub const LN10 : Double = 2.30258509299404568402

///|
pub fn sin(x : Double) -> Double {
  @m.sin(x)
}

///|
pub fn cos(x : Double) -> Double {
  @m.cos(x)
}

///|
pub fn exp(x : Double) -> Double {
  @m.exp(x)
}

///|
pub fn ln(x : Double) -> Double {
  @m.ln(x)
}

///|
pub fn log2(x : Double) -> Double {
  @m.log2(x)
}

///|
pub fn log10(x : Double) -> Double {
  @m.log10(x)
}

///|
pub fn atan(x : Double) -> Double {
  @m.atan(x)
}

///|
pub fn atan2(y : Double, x : Double) -> Double {
  @m.atan2(y, x)
}

///|
pub fn floor(x : Double) -> Double {
  @m.floor(x)
}

///|
pub fn ceil(x : Double) -> Double {
  @m.ceil(x)
}

///|
pub fn abs(x : Double) -> Double {
  if x < 0.0 {
    -x
  } else {
    x
  }
}

///|
pub fn dmax(a : Double, b : Double) -> Double {
  if a > b {
    a
  } else {
    b
  }
}

///|
pub fn dmin(a : Double, b : Double) -> Double {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// Round half up to the nearest integer.
pub fn round_int(x : Double) -> Int32 {
  floor(x + 0.5).to_int()
}

///|
pub fn floor_int(x : Double) -> Int32 {
  floor(x).to_int()
}

///|
pub fn ceil_int(x : Double) -> Int32 {
  ceil(x).to_int()
}

///|
/// Clamp to [0, 1].
pub fn clamp01(x : Double) -> Double {
  if x < 0.0 {
    0.0
  } else if x > 1.0 {
    1.0
  } else {
    x
  }
}
