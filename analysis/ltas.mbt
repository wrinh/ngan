// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To Ltas...` and `Spectrogram: To Ltas...`: Long-Term Average
// Spectrum in dB/Hz relative to 2e-5 Pa, ported from fon/Ltas.cpp.

///|
fn empty_ltas() -> @types.Ltas {
  { f1: 0.0, df: 0.0, values: FixedArray::make(0, 0.0), }
}

///|
fn psd_to_db(p : Double) -> Double {
  let rel = p / 4.0e-10
  if rel <= 1.0e-30 {
    -300.0
  } else {
    10.0 * @math.log10(rel)
  }
}

///|
/// Praat `Sound: To Ltas...`: Long-Term Average Spectrum with uniform
/// bin width `bandwidth` Hz (default 100 Hz) in dB/Hz relative to
/// `2e-5` Pa.
pub fn ltas(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  bandwidth~ : Double = 100.0,
) -> @types.Ltas {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || bandwidth <= 0.0 {
    return empty_ltas()
  }
  let nyquist = 0.5 * sample_rate
  let nbins = @math.floor_int(nyquist / bandwidth)
  if nbins < 1 {
    return empty_ltas()
  }
  let raw_nfft = @dsp.next_pow2(nx)
  let nfft = if raw_nfft < 2 { 2 } else { raw_nfft }
  let half = nfft / 2
  let re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  for i in 0..<nx {
    re[i] = samples[i]
  }
  let plan = @dsp.FftPlan::new(nfft)
  plan.transform(re, im, inverse=false)
  let denom = nx.to_double() * sample_rate
  let psd : FixedArray[Double] = FixedArray::make(half + 1, 0.0)
  for k in 0..<=half {
    let mag2 = re[k] * re[k] + im[k] * im[k]
    let scale = if k == 0 || k == half { 1.0 } else { 2.0 }
    psd[k] = scale * mag2 / denom
  }
  let df_fft = sample_rate / nfft.to_double()
  let values : FixedArray[Double] = FixedArray::make(nbins, -300.0)
  for b in 0..<nbins {
    let b_lo = b.to_double() * bandwidth
    let b_hi = (b + 1).to_double() * bandwidth
    let mut k_start = @math.floor_int(b_lo / df_fft - 0.5)
    if k_start < 0 {
      k_start = 0
    }
    let mut k_end = @math.ceil_int(b_hi / df_fft + 0.5)
    if k_end > half {
      k_end = half
    }
    let mut sum_p = 0.0
    let mut sum_w = 0.0
    for k in k_start..<=k_end {
      let k_lo = @math.dmax(0.0, (k.to_double() - 0.5) * df_fft)
      let k_hi = @math.dmin(nyquist, (k.to_double() + 0.5) * df_fft)
      let o_lo = @math.dmax(b_lo, k_lo)
      let o_hi = @math.dmin(b_hi, k_hi)
      if o_hi > o_lo {
        let w = o_hi - o_lo
        sum_p += w * psd[k]
        sum_w += w
      }
    }
    if sum_w > 0.0 {
      values[b] = psd_to_db(sum_p / sum_w)
    }
  }
  { f1: 0.5 * bandwidth, df: bandwidth, values, }
}

///|
/// Average a `Spectrogram` linearly across all time frames and re-bin
/// into uniform `bandwidth`-Hz LTAS bins (or keep the spectrogram's own
/// frequency grid when `bandwidth <= 0.0`), returning dB/Hz re `2e-5` Pa.
pub fn spectrogram_to_ltas(
  sg : @types.Spectrogram,
  bandwidth~ : Double = 100.0,
) -> @types.Ltas {
  let nt = sg.number_of_time_frames
  let nb = sg.number_of_frequency_bands
  if nt < 1 || nb < 1 || sg.df <= 0.0 {
    return empty_ltas()
  }
  let mean_band : FixedArray[Double] = FixedArray::make(nb, 0.0)
  let nt_d = nt.to_double()
  for b in 0..<nb {
    let base = b * nt
    let mut s = 0.0
    for fr in 0..<nt {
      s += sg.power[base + fr]
    }
    mean_band[b] = s / nt_d
  }
  if bandwidth <= 0.0 {
    let values : FixedArray[Double] = FixedArray::make(nb, -300.0)
    for b in 0..<nb {
      values[b] = psd_to_db(mean_band[b])
    }
    return { f1: sg.f1, df: sg.df, values, }
  }
  let f_max = sg.f1 + (nb.to_double() - 0.5) * sg.df
  let nbins = @math.floor_int(f_max / bandwidth)
  if nbins < 1 {
    return empty_ltas()
  }
  let values : FixedArray[Double] = FixedArray::make(nbins, -300.0)
  for b in 0..<nbins {
    let b_lo = b.to_double() * bandwidth
    let b_hi = (b + 1).to_double() * bandwidth
    let mut k_start = @math.floor_int((b_lo - sg.f1) / sg.df - 0.5)
    if k_start < 0 {
      k_start = 0
    }
    let mut k_end = @math.ceil_int((b_hi - sg.f1) / sg.df + 0.5)
    if k_end >= nb {
      k_end = nb - 1
    }
    let mut sum_p = 0.0
    let mut sum_w = 0.0
    for k in k_start..<=k_end {
      let k_lo = @math.dmax(0.0, sg.f1 + (k.to_double() - 0.5) * sg.df)
      let k_hi = sg.f1 + (k.to_double() + 0.5) * sg.df
      let o_lo = @math.dmax(b_lo, k_lo)
      let o_hi = @math.dmin(b_hi, k_hi)
      if o_hi > o_lo {
        let w = o_hi - o_lo
        sum_p += w * mean_band[k]
        sum_w += w
      }
    }
    if sum_w > 0.0 {
      values[b] = psd_to_db(sum_p / sum_w)
    }
  }
  { f1: 0.5 * bandwidth, df: bandwidth, values, }
}
