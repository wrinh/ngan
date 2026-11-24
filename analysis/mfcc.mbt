// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `To MelSpectrogram...`, `To BarkSpectrogram...`, and `To MFCC...`,
// ported from dwtools/Sound_and_Spectrogram_extensions.cpp and dwtools/MFCC.cpp.

///|
fn empty_filterbank_matrix() -> @types.FilterBankMatrix {
  {
    t1: 0.0,
    dt: 0.0,
    number_of_time_frames: 0,
    f1: 0.0,
    df: 0.0,
    number_of_filters: 0,
    values: FixedArray::make(0, 0.0),
  }
}

///|
/// Sekey & Hanson (1984) auditory filter power response in Bark space
/// (`dz = bark - fc_bark`), matching Praat's `BarkFilter`.
fn bark_filter_weight(dz : Double) -> Double {
  if @math.abs(dz) > 2.5 {
    return 0.0
  }
  let x = dz + 0.474
  let db = 15.81 + 7.5 * x - 17.5 * (1.0 + x * x).sqrt()
  @math.pow(10.0, db / 10.0)
}

///|
fn filterbank_spectrogram(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  window_length~ : Double,
  time_step~ : Double,
  position_of_first_filter~ : Double,
  distance_between_filters~ : Double,
  maximum_frequency~ : Double,
  use_bark~ : Bool,
) -> @types.FilterBankMatrix {
  let nx = samples.length()
  if nx == 0 ||
    sample_rate <= 0.0 ||
    window_length <= 0.0 ||
    time_step <= 0.0 ||
    distance_between_filters <= 0.0 {
    return empty_filterbank_matrix()
  }
  let dx = 1.0 / sample_rate
  let dur = nx.to_double() * dx
  let physical_width = 2.0 * window_length
  let halfnsamp = @math.floor_int(physical_width * sample_rate) / 2
  let nwin = halfnsamp * 2
  if halfnsamp < 2 || nwin < 4 {
    return empty_filterbank_matrix()
  }
  guard short_term_analysis(dur, nwin.to_double() * dx, time_step) is Some(sa) else {
    return empty_filterbank_matrix()
  }
  let (nframes, t1) = sa
  let nyquist_hz = 0.5 * sample_rate
  let nyquist_scale = if use_bark {
    @types.hz_to_bark(nyquist_hz)
  } else {
    @types.hz_to_mel(nyquist_hz)
  }
  let fmax_scale = if maximum_frequency > 0.0 &&
    maximum_frequency < nyquist_scale {
    maximum_frequency
  } else {
    nyquist_scale
  }
  if fmax_scale <= position_of_first_filter {
    return empty_filterbank_matrix()
  }
  let num_filters = @math.floor_int(
      (fmax_scale - position_of_first_filter) / distance_between_filters,
    ) +
    1
  if num_filters < 1 {
    return empty_filterbank_matrix()
  }
  let win = @dsp.gaussian_window(nwin)
  let mut windowssq = 0.0
  for i in 0..<nwin {
    windowssq += win[i] * win[i]
  }
  if windowssq <= 0.0 {
    return empty_filterbank_matrix()
  }
  let raw_nfft = @dsp.next_pow2(nwin)
  let nfft = if raw_nfft < 256 { 256 } else { raw_nfft }
  let half_nfft = nfft / 2
  let df_fft = sample_rate / nfft.to_double()
  let bin_scales : FixedArray[Double] = FixedArray::make(half_nfft + 1, 0.0)
  for k in 0..<=half_nfft {
    let f = k.to_double() * df_fft
    bin_scales[k] = if use_bark {
      @types.hz_to_bark(f)
    } else {
      @types.hz_to_mel(f)
    }
  }
  // Precompute sparse filterbank weights as (k_start, k_end, weights_array) per filter.
  let filter_k0 : FixedArray[Int32] = FixedArray::make(num_filters, 0)
  let filter_k1 : FixedArray[Int32] = FixedArray::make(num_filters, -1)
  let filter_weights : Array[FixedArray[Double]] = []
  for m in 0..<num_filters {
    let fc = position_of_first_filter + m.to_double() * distance_between_filters
    let mut k_lo = half_nfft + 1
    let mut k_hi = -1
    let temp_w : Array[Double] = []
    for k in 0..<=half_nfft {
      let s = bin_scales[k]
      let w = if use_bark {
        bark_filter_weight(s - fc)
      } else {
        let d = 1.0 - @math.abs(s - fc) / distance_between_filters
        if d > 0.0 {
          d
        } else {
          0.0
        }
      }
      if w > 0.0 {
        if k < k_lo {
          k_lo = k
        }
        if k > k_hi {
          k_hi = k
        }
        temp_w.push(w)
      }
    }
    if k_hi >= k_lo {
      // Rebuild dense slice [k_lo..<=k_hi] to keep evaluation branchless.
      let span = k_hi - k_lo + 1
      let arr : FixedArray[Double] = FixedArray::make(span, 0.0)
      for j in 0..<span {
        let s = bin_scales[k_lo + j]
        arr[j] = if use_bark {
          bark_filter_weight(s - fc)
        } else {
          let d = 1.0 - @math.abs(s - fc) / distance_between_filters
          if d > 0.0 {
            d
          } else {
            0.0
          }
        }
      }
      filter_k0[m] = k_lo
      filter_k1[m] = k_hi
      filter_weights.push(arr)
    } else {
      filter_weights.push(FixedArray::make(0, 0.0))
    }
  }
  let rplan = @dsp.RealFftPlan::new(nfft)
  let frame_buf : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let bin_power : FixedArray[Double] = FixedArray::make(half_nfft + 1, 0.0)
  let values : FixedArray[Double] = FixedArray::make(
    num_filters * nframes,
    -300.0,
  )
  let energy_scale = 1.0 / (windowssq * nfft.to_double())
  let db_scale = 10.0 / @math.LN10
  for iframe in 0..<nframes {
    let t = t1 + iframe.to_double() * time_step
    let lo = low_index(t, sample_rate)
    let start = lo + 1 - halfnsamp
    let mut mean = 0.0
    if start >= 0 && start + nwin <= nx {
      for k in 0..<nwin {
        mean += samples[start + k]
      }
      mean /= nwin.to_double()
      for k in 0..<nwin {
        frame_buf[k] = (samples[start + k] - mean) * win[k]
      }
    } else {
      let mut count = 0
      for k in 0..<nwin {
        let idx = start + k
        if idx >= 0 && idx < nx {
          mean += samples[idx]
          count += 1
        }
      }
      if count > 0 {
        mean /= count.to_double()
      }
      for k in 0..<nwin {
        let idx = start + k
        let v = if idx >= 0 && idx < nx { samples[idx] - mean } else { 0.0 }
        frame_buf[k] = v * win[k]
      }
    }
    rplan.forward_power(frame_buf, nwin, bin_power)
    bin_power[0] *= energy_scale
    bin_power[half_nfft] *= energy_scale
    let two_scale = 2.0 * energy_scale
    for k in 1..<half_nfft {
      bin_power[k] *= two_scale
    }
    for m in 0..<num_filters {
      let k0 = filter_k0[m]
      let k1 = filter_k1[m]
      let mut sum_p = 0.0
      if k1 >= k0 {
        let ws = filter_weights[m]
        for j in 0..<(k1 - k0 + 1) {
          sum_p += ws[j] * bin_power[k0 + j]
        }
      }
      let rel = sum_p / 4.0e-10
      values[m * nframes + iframe] = if rel <= 1.0e-30 {
        -300.0
      } else {
        db_scale * @math.ln(rel)
      }
    }
  }
  {
    t1,
    dt: time_step,
    number_of_time_frames: nframes,
    f1: position_of_first_filter,
    df: distance_between_filters,
    number_of_filters: num_filters,
    values,
  }
}

///|
/// Praat `To MelSpectrogram...`: Gaussian-windowed filterbank spectrogram
/// spaced uniformly on Praat's Mel scale (`550 * ln(1 + f / 550)`).
pub fn mel_spectrogram(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  window_length~ : Double = 0.015,
  time_step~ : Double = 0.005,
  position_of_first_filter~ : Double = 100.0,
  distance_between_filters~ : Double = 100.0,
  maximum_frequency~ : Double = 0.0,
) -> @types.FilterBankMatrix {
  filterbank_spectrogram(
    samples,
    sample_rate~,
    window_length~,
    time_step~,
    position_of_first_filter~,
    distance_between_filters~,
    maximum_frequency~,
    use_bark=false,
  )
}

///|
/// Praat `To BarkSpectrogram...`: Gaussian-windowed auditory filterbank
/// spectrogram spaced uniformly on Praat's Bark scale using Sekey & Hanson
/// (1984) filter shapes.
pub fn bark_spectrogram(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  window_length~ : Double = 0.015,
  time_step~ : Double = 0.005,
  position_of_first_filter~ : Double = 1.0,
  distance_between_filters~ : Double = 1.0,
  maximum_frequency~ : Double = 0.0,
) -> @types.FilterBankMatrix {
  filterbank_spectrogram(
    samples,
    sample_rate~,
    window_length~,
    time_step~,
    position_of_first_filter~,
    distance_between_filters~,
    maximum_frequency~,
    use_bark=true,
  )
}

///|
/// Praat `MelSpectrogram: To MFCC...`: compute orthonormal DCT-II
/// cepstral coefficients `c0` and `c1..c_{number_of_coefficients}` from a
/// `FilterBankMatrix`.
pub fn mel_spectrogram_to_mfcc(
  mel_spec : @types.FilterBankMatrix,
  number_of_coefficients~ : Int32 = 12,
) -> @types.Mfcc {
  let nt = mel_spec.number_of_time_frames
  let nf = mel_spec.number_of_filters
  if nt < 1 || nf < 1 || number_of_coefficients < 1 {
    return { t1: 0.0, dt: 0.0, fmin_mel: 0.0, fmax_mel: 0.0, frames: [], }
  }
  let nc = if number_of_coefficients < nf {
    number_of_coefficients
  } else {
    nf - 1
  }
  let m_d = nf.to_double()
  let s0 = (1.0 / m_d).sqrt()
  let sk = (2.0 / m_d).sqrt()
  // Precompute the (nc x nf) DCT-II basis matrix once instead of calling cos() per frame.
  let dct : FixedArray[Double] = FixedArray::make(nc * nf, 0.0)
  for k in 1..<=nc {
    let kd = k.to_double()
    let row = (k - 1) * nf
    for j in 0..<nf {
      dct[row + j] = sk * @math.cos(@math.PI * kd * (j.to_double() + 0.5) / m_d)
    }
  }
  let col : FixedArray[Double] = FixedArray::make(nf, 0.0)
  let frames : Array[@types.MfccFrame] = []
  for t in 0..<nt {
    let mut sum0 = 0.0
    for j in 0..<nf {
      let v = mel_spec.values[j * nt + t]
      col[j] = v
      sum0 += v
    }
    let c0 = s0 * sum0
    let coeffs : FixedArray[Double] = FixedArray::make(nc, 0.0)
    for k in 0..<nc {
      let row = k * nf
      let mut acc = 0.0
      for j in 0..<nf {
        acc += col[j] * dct[row + j]
      }
      coeffs[k] = acc
    }
    frames.push({ time: mel_spec.t1 + t.to_double() * mel_spec.dt, c0, coeffs, })
  }
  let fmax_mel = mel_spec.f1 + (nf - 1).to_double() * mel_spec.df
  { t1: mel_spec.t1, dt: mel_spec.dt, fmin_mel: mel_spec.f1, fmax_mel, frames, }
}

///|
/// Praat `Sound: To MFCC...`: compute Mel-Frequency Cepstral Coefficients
/// directly from `samples`.
pub fn mfcc(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  number_of_coefficients~ : Int32 = 12,
  window_length~ : Double = 0.015,
  time_step~ : Double = 0.005,
  position_of_first_filter~ : Double = 100.0,
  distance_between_filters~ : Double = 100.0,
  maximum_frequency~ : Double = 0.0,
) -> @types.Mfcc {
  let mel_spec = mel_spectrogram(
    samples,
    sample_rate~,
    window_length~,
    time_step~,
    position_of_first_filter~,
    distance_between_filters~,
    maximum_frequency~,
  )
  mel_spectrogram_to_mfcc(mel_spec, number_of_coefficients~)
}
