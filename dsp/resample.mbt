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
  if ad > l {
    return 0.0
  }
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
fn gcd_int(a : Int32, b : Int32) -> Int32 {
  let mut x = if a < 0 { -a } else { a }
  let mut y = if b < 0 { -b } else { b }
  while y != 0 {
    let r = x % y
    x = y
    y = r
  }
  x
}

///|
fn reflect_index(idx : Int32, n : Int32) -> Int32 {
  if n <= 1 {
    return 0
  }
  let mut i = idx
  while i < 0 || i >= n {
    if i < 0 {
      i = -i
    }
    if i >= n {
      i = 2 * n - 2 - i
    }
  }
  i
}

///|
fn copy_samples(x : FixedArray[Double]) -> FixedArray[Double] {
  let nx = x.length()
  let y = FixedArray::make(nx, 0.0)
  for i in 0..<nx {
    y[i] = x[i]
  }
  y
}

///|
fn resample_core(
  x : FixedArray[Double],
  ratio : Double,
  exact_p : Int32,
  exact_q : Int32,
  beta : Double,
  zero_crossings : Int32,
  rolloff : Double,
  reflect : Bool,
) -> FixedArray[Double] {
  let nx = x.length()
  if nx == 0 || !(ratio > 0.0) {
    return FixedArray::make(0, 0.0)
  }
  if ratio == 1.0 {
    return copy_samples(x)
  }
  let ny_d_raw = nx.to_double() * ratio
  if !(ny_d_raw > 0.0) || !(ny_d_raw < 2147483647.0) {
    return FixedArray::make(0, 0.0)
  }
  let ny_raw = @math.floor(ny_d_raw + 0.5).to_int()
  let ny = if ny_raw < 1 { 1 } else { ny_raw }
  let y : FixedArray[Double] = FixedArray::make(ny, 0.0)
  let r_eff = if !(rolloff > 0.0) {
    0.94
  } else if rolloff > 1.0 {
    1.0
  } else {
    rolloff
  }
  let beta_eff = if beta > 0.0 { beta } else { 0.0 }
  let fc = if ratio < 1.0 { ratio * r_eff } else { 1.0 }
  let inv = if exact_p > 0 && exact_q > 0 {
    exact_q.to_double() / exact_p.to_double()
  } else {
    1.0 / ratio
  }
  let inv_denom = 1.0 / @math.bessel_i0(beta_eff)
  let zc_int = if zero_crossings < 1 { 1 } else { zero_crossings }
  // Scale kernel half-width by 1/fc so it spans `zero_crossings` lobes on each side.
  let l = zc_int.to_double() / fc
  let max_poly_elems = 262144.0
  // Fast path 1: exact rational polyphase filter when inv = q / p with small p.
  let mut period = 0
  let mut step_q = 0
  let max_p = if ny / 2 < 256 { ny / 2 } else { 256 }
  if l <= 1.0e6 && max_p >= 1 {
    if exact_p > 0 && exact_q > 0 {
      if exact_p <= max_p {
        period = exact_p
        step_q = exact_q
      }
    } else {
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
    }
  }
  if period > 0 {
    let stride = @math.ceil(2.0 * l).to_int() + 2
    if period.to_double() * stride.to_double() <= max_poly_elems {
      let weights : FixedArray[Double] = FixedArray::make(period * stride, 0.0)
      let lo_offs : FixedArray[Int32] = FixedArray::make(period, 0)
      let counts : FixedArray[Int32] = FixedArray::make(period, 0)
      let step_q_d = step_q.to_double()
      let period_d = period.to_double()
      for ph in 0..<period {
        let t0 = ph.to_double() * step_q_d / period_d
        let lo0 = @math.ceil(t0 - l).to_int()
        let hi0 = @math.floor(t0 + l).to_int()
        let cnt = hi0 - lo0 + 1
        lo_offs[ph] = lo0
        counts[ph] = cnt
        let row = ph * stride
        let mut w_sum = 0.0
        for k in 0..<cnt {
          let d = t0 - (lo0 + k).to_double()
          let w = kaiser_sinc_tap(d, fc, l, beta_eff, inv_denom)
          weights[row + k] = w
          w_sum += w
        }
        if w_sum > 0.0 {
          let inv_sum = 1.0 / w_sum
          for k in 0..<cnt {
            weights[row + k] = weights[row + k] * inv_sum
          }
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
        } else if reflect {
          for k in 0..<cnt {
            acc += x[reflect_index(base + k, nx)] * weights[row + k]
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
  }
  // Fast path 2: transposed polyphase lookup table with outer-loop interpolation.
  // Scale subdiv proportionally to fc to maintain constant accuracy in u = fc * d
  // while keeping table size nearly independent of the downsampling ratio.
  if l <= 1.0e6 {
    let base_subdiv = 1024.0
    let mut subdiv = @math.ceil(base_subdiv * fc).to_int()
    if subdiv < 32 {
      subdiv = 32
    }
    if subdiv > 1024 {
      subdiv = 1024
    }
    if subdiv % 2 != 0 {
      subdiv += 1
    }
    let half = @math.floor(l).to_int()
    let taps = 2 * half + 2
    let table_elems = (subdiv + 1).to_double() * taps.to_double()
    if ny >= subdiv && table_elems <= 524288.0 {
      let subdiv_d = subdiv.to_double()
      let p_tab : FixedArray[Double] = FixedArray::make(
        (subdiv + 1) * taps,
        0.0,
      )
      let half_subdiv = subdiv / 2
      for ph in 0..<=half_subdiv {
        let f = ph.to_double() / subdiv_d
        let row = ph * taps
        let mut w_sum = 0.0
        for k in 0..<taps {
          let d = f - (k - half).to_double()
          let w = kaiser_sinc_tap(d, fc, l, beta_eff, inv_denom)
          p_tab[row + k] = w
          w_sum += w
        }
        if w_sum > 0.0 {
          let inv_sum = 1.0 / w_sum
          for k in 0..<taps {
            p_tab[row + k] = p_tab[row + k] * inv_sum
          }
        }
        let mirror_ph = subdiv - ph
        if mirror_ph != ph {
          let mrow = mirror_ph * taps
          for k in 0..<taps {
            p_tab[mrow + (taps - 1 - k)] = p_tab[row + k]
          }
        }
      }
      for j in 0..<ny {
        let t = j.to_double() * inv
        let base_i = @math.floor(t).to_int()
        let frac_t = t - base_i.to_double()
        let pos = frac_t * subdiv_d
        let mut ph = pos.to_int()
        if ph < 0 {
          ph = 0
        } else if ph >= subdiv {
          ph = subdiv - 1
        }
        let frac = pos - ph.to_double()
        let base = base_i - half
        let row0 = ph * taps
        let row1 = (ph + 1) * taps
        let mut acc0 = 0.0
        let mut acc1 = 0.0
        if base >= 0 && base + taps <= nx {
          for k in 0..<taps {
            let xv = x[base + k]
            acc0 += xv * p_tab[row0 + k]
            acc1 += xv * p_tab[row1 + k]
          }
        } else if reflect {
          for k in 0..<taps {
            let xv = x[reflect_index(base + k, nx)]
            acc0 += xv * p_tab[row0 + k]
            acc1 += xv * p_tab[row1 + k]
          }
        } else {
          let k_start = if base < 0 { -base } else { 0 }
          let k_end = if base + taps > nx { nx - base } else { taps }
          for k in k_start..<k_end {
            let xv = x[base + k]
            acc0 += xv * p_tab[row0 + k]
            acc1 += xv * p_tab[row1 + k]
          }
        }
        y[j] = acc0 + frac * (acc1 - acc0)
      }
      return y
    }
  }
  // Small-output / extreme-ratio direct fallback.
  for j in 0..<ny {
    let t = j.to_double() * inv
    let lo_full = @math.ceil(t - l).to_int()
    let hi_full = @math.floor(t + l).to_int()
    let mut acc = 0.0
    let mut w_sum = 0.0
    if lo_full >= 0 && hi_full < nx {
      let mut n = lo_full
      while n <= hi_full {
        let w = kaiser_sinc_tap(t - n.to_double(), fc, l, beta_eff, inv_denom)
        acc += x[n] * w
        w_sum += w
        n += 1
      }
    } else if reflect {
      let mut n = lo_full
      while n <= hi_full {
        let w = kaiser_sinc_tap(t - n.to_double(), fc, l, beta_eff, inv_denom)
        acc += x[reflect_index(n, nx)] * w
        w_sum += w
        n += 1
      }
    } else {
      let mut n = lo_full
      while n <= hi_full {
        let w = kaiser_sinc_tap(t - n.to_double(), fc, l, beta_eff, inv_denom)
        w_sum += w
        if n >= 0 && n < nx {
          acc += x[n] * w
        }
        n += 1
      }
    }
    y[j] = if w_sum > 0.0 { acc / w_sum } else { acc }
  }
  y
}

///|
/// Band-limited resampling with a Kaiser-weighted sinc kernel.
///
/// `ratio` is fs_out / fs_in. For downsampling (`ratio < 1.0`), the cutoff is
/// `ratio * rolloff * fs_in / 2` to keep the transition band inside Nyquist;
/// pure upsampling uses cutoff `fs_in / 2`. The kernel spans `zero_crossings`
/// zero crossings on each side (`l = zero_crossings / fc`), and the output
/// length is `round(nx * ratio)`. Linear interpolation must never be used for
/// formant analysis: it distorts the spectrum near Nyquist.
pub fn sinc_resample(
  x : FixedArray[Double],
  ratio~ : Double,
  beta~ : Double = 10.0,
  zero_crossings~ : Int32 = 32,
  rolloff~ : Double = 0.94,
  reflect~ : Bool = false,
) -> FixedArray[Double] {
  resample_core(x, ratio, 0, 0, beta, zero_crossings, rolloff, reflect)
}

///|
/// Band-limited resampling specified by exact integer sample rates (`fs_in` -> `fs_out`).
/// Uses exact rational reduction `gcd(fs_in, fs_out)` to avoid floating-point
/// rational search and long-signal phase drift.
pub fn sinc_resample_rate(
  x : FixedArray[Double],
  fs_in~ : Int32,
  fs_out~ : Int32,
  beta~ : Double = 10.0,
  zero_crossings~ : Int32 = 32,
  rolloff~ : Double = 0.94,
  reflect~ : Bool = false,
) -> FixedArray[Double] {
  let nx = x.length()
  if nx == 0 || fs_in <= 0 || fs_out <= 0 {
    return FixedArray::make(0, 0.0)
  }
  if fs_in == fs_out {
    return copy_samples(x)
  }
  let g = gcd_int(fs_in, fs_out)
  let p = fs_out / g
  let q = fs_in / g
  let ratio = p.to_double() / q.to_double()
  resample_core(x, ratio, p, q, beta, zero_crossings, rolloff, reflect)
}
