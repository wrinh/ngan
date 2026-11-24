// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Anti-aliasing resampler for the formant front end.

///|
fn kaiser_sinc_tap(
  d : Double,
  fc : Double,
  l : Double,
  beta : Double,
  inv_denom : Double,
) -> Double {
  let ad = @math.abs(d)
  let pd = @math.PI * fc * ad
  let s = if pd == 0.0 { 1.0 } else { @math.sin(pd) / pd }
  let arg = ad / l
  let rad = 1.0 - arg * arg
  let wm = if rad > 0.0 {
    @math.bessel_i0(beta * rad.sqrt()) * inv_denom
  } else {
    inv_denom
  }
  fc * s * wm
}

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
  let inv_denom = 1.0 / @math.bessel_i0(beta)
  let l_int = if zero_crossings < 1 { 1 } else { zero_crossings }
  let l = l_int.to_double()
  // Fast path 1: exact rational polyphase filter when inv = q / p with small p.
  let mut period = 0
  let mut step_q = 0
  let max_p = if ny / 2 < 256 { ny / 2 } else { 256 }
  let ny_d = ny.to_double()
  for p in 1..<=max_p {
    let prod = p.to_double() * inv
    let q = @math.floor(prod + 0.5)
    let err = @math.abs(prod - q)
    if q >= 1.0 &&
      q < 1.0e8 &&
      err < 1.0e-11 &&
      err * (ny_d / p.to_double()) < 1.0e-7 {
      period = p
      step_q = q.to_int()
      break
    }
  }
  if period > 0 {
    let stride = 2 * l_int + 1
    let weights : FixedArray[Double] = FixedArray::make(period * stride, 0.0)
    let lo_offs : FixedArray[Int32] = FixedArray::make(period, 0)
    let counts : FixedArray[Int32] = FixedArray::make(period, 0)
    for ph in 0..<period {
      let t0 = ph.to_double() * inv
      let lo0 = @math.ceil(t0 - l).to_int()
      let hi0 = @math.floor(t0 + l).to_int()
      let cnt = hi0 - lo0 + 1
      lo_offs[ph] = lo0
      counts[ph] = cnt
      let row = ph * stride
      for k in 0..<cnt {
        let d = t0 - (lo0 + k).to_double()
        weights[row + k] = kaiser_sinc_tap(d, fc, l, beta, inv_denom)
      }
    }
    let mut ph = 0
    let mut block_base = 0
    for j in 0..<ny {
      let base = block_base + lo_offs[ph]
      let cnt = counts[ph]
      let row = ph * stride
      let mut acc = 0.0
      if base >= 0 && base + cnt <= nx {
        for k in 0..<cnt {
          acc += x[base + k] * weights[row + k]
        }
      } else {
        let k_start = if base < 0 { -base } else { 0 }
        let k_end = if base + cnt > nx { nx - base } else { cnt }
        for k in k_start..<k_end {
          acc += x[base + k] * weights[row + k]
        }
      }
      y[j] = acc
      ph += 1
      if ph == period {
        ph = 0
        block_base += step_q
      }
    }
    return y
  }
  // Fast path 2: general ratio with 1D Kaiser-sinc lookup table (512 steps/unit).
  if ny >= 256 && l_int <= 256 {
    let subdiv = 512
    let subdiv_d = subdiv.to_double()
    let tab_len = l_int * subdiv
    let h_tab : FixedArray[Double] = FixedArray::make(tab_len + 2, 0.0)
    for idx in 0..<=tab_len {
      let u = idx.to_double() / subdiv_d
      h_tab[idx] = kaiser_sinc_tap(u, fc, l, beta, inv_denom)
    }
    h_tab[tab_len + 1] = h_tab[tab_len]
    for j in 0..<ny {
      let t = j.to_double() * inv
      let mut lo = @math.ceil(t - l).to_int()
      let mut hi = @math.floor(t + l).to_int()
      if lo < 0 {
        lo = 0
      }
      if hi >= nx {
        hi = nx - 1
      }
      let mut acc = 0.0
      let mut n = lo
      while n <= hi {
        let ad = @math.abs(t - n.to_double())
        let pos = ad * subdiv_d
        let mut idx = pos.to_int()
        if idx > tab_len {
          idx = tab_len
        }
        let frac = pos - idx.to_double()
        let w = h_tab[idx] + frac * (h_tab[idx + 1] - h_tab[idx])
        acc += x[n] * w
        n += 1
      }
      y[j] = acc
    }
    return y
  }
  // Small-output direct fallback.
  for j in 0..<ny {
    let t = j.to_double() * inv
    let mut lo = @math.ceil(t - l).to_int()
    let mut hi = @math.floor(t + l).to_int()
    if lo < 0 {
      lo = 0
    }
    if hi >= nx {
      hi = nx - 1
    }
    let mut acc = 0.0
    let mut n = lo
    while n <= hi {
      acc += x[n] * kaiser_sinc_tap(t - n.to_double(), fc, l, beta, inv_denom)
      n += 1
    }
    y[j] = acc
  }
  y
}
