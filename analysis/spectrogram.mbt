// Praat `To Spectrogram...`: Gaussian-windowed power spectrogram.
// Ported from fon/Sound_and_Spectrogram.cpp (Sound_to_Spectrogram_e with
// the Gaussian window shape and the 8x time/frequency oversampling that
// the `To Spectrogram...` dialog passes).

///|
fn empty_spectrogram() -> @types.Spectrogram {
  {
    t1: 0.0,
    dt: 0.0,
    number_of_time_frames: 0,
    f1: 0.0,
    df: 0.0,
    number_of_frequency_bands: 0,
    power: FixedArray::make(0, 0.0),
  }
}

///|
/// Spectrogram analysis with the parameters of Praat's
/// `To Spectrogram...`.
///
/// The effective analysis window is `window_length` seconds; the actual
/// Gaussian window spans twice that (Praat's formula
/// `(exp(-48 phase^2) - exp(-12)) / (1 - exp(-12))` with the phase in
/// [-0.5, 0.5]). The time and frequency steps are raised to at least
/// `effective_width / 8` (Praat's 8x oversampling limits), and the
/// frequency step is snapped to a whole number of FFT bins: each
/// spectrogram band averages `sum |X_k|^2 / sum w^2 / bin_width` over
/// its bins, giving power spectral density in Pa^2/Hz like Praat.
/// Bands are centred at `f1 + j * df` with
/// `f1 = 0.5 * (df - fft_bin_width)`; `maximum_frequency` is clamped to
/// the Nyquist frequency.
///
/// Frames are fitted symmetrically with fully interior windows; the
/// first frame is at `t1 = 0.5 dx + 0.5 ((nx - 1) dx - (n - 1) dt)`.
pub fn spectrogram(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  window_length~ : Double = 0.005,
  maximum_frequency~ : Double = 5000.0,
  time_step~ : Double = 0.002,
  frequency_step~ : Double = 20.0,
) -> @types.Spectrogram {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || window_length <= 0.0 {
    return empty_spectrogram()
  }
  let dx = 1.0 / sample_rate
  let nyquist = 0.5 / dx
  let dur = nx.to_double() * dx
  // Gaussian window: the physical width is twice the effective width.
  let physical_width = 2.0 * window_length
  if physical_width > dur {
    return empty_spectrogram()
  }
  // Praat's effective widths and 8x oversampling limits.
  let effective_time_width = window_length / @math.PI.sqrt()
  let effective_freq_width = 1.0 / effective_time_width
  let dt = @math.dmax(time_step, effective_time_width / 8.0)
  let mut freq_step = @math.dmax(frequency_step, effective_freq_width / 8.0)
  // Time sampling.
  let approximate_samples_per_window = @math.floor_int(
    physical_width * sample_rate,
  )
  let halfnsamp = approximate_samples_per_window / 2 - 1
  let nwin = halfnsamp * 2
  if nwin < 2 {
    return empty_spectrogram()
  }
  let number_of_times = 1 + @math.floor_int((dur - physical_width) / dt)
  let t1 = 0.5 * dx +
    0.5 * ((nx - 1).to_double() * dx - (number_of_times - 1).to_double() * dt)
  // Frequency sampling of the FFT.
  let mut fmax = maximum_frequency
  if fmax <= 0.0 || fmax > nyquist {
    fmax = nyquist
  }
  let mut number_of_freqs = @math.floor_int(fmax / freq_step)
  if number_of_freqs < 1 {
    return empty_spectrogram()
  }
  let mut nfft = 1
  while nfft < nwin ||
        nfft.to_double() < 2.0 * number_of_freqs.to_double() * (nyquist / fmax) {
    nfft *= 2
  }
  let half_nfft = nfft / 2
  // Spectrogram frequency sampling: snap the step to whole FFT bins.
  let mut bin_width_samples = @math.floor_int(freq_step * dx * nfft.to_double())
  if bin_width_samples < 1 {
    bin_width_samples = 1
  }
  let bin_width_hertz = 1.0 / (dx * nfft.to_double())
  freq_step = bin_width_samples.to_double() * bin_width_hertz
  number_of_freqs = @math.floor_int(fmax / freq_step)
  if number_of_freqs < 1 {
    return empty_spectrogram()
  }
  // Gaussian window (Praat's exact spectrogram formula).
  let window : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let samples_per_window_f = physical_width / dx
  let imid = 0.5 * (nwin + 1).to_double()
  let edge = @math.exp(-12.0)
  let mut windowssq = 0.0
  for i in 0..<nwin {
    let phase = ((i + 1).to_double() - imid) / samples_per_window_f
    let w = (@math.exp(-48.0 * phase * phase) - edge) / (1.0 - edge)
    window[i] = w
    windowssq += w * w
  }
  if windowssq <= 0.0 {
    return empty_spectrogram()
  }
  let one_by_bin_width = 1.0 / windowssq / bin_width_samples.to_double()
  // Per-frame FFT and band averaging.
  let power : FixedArray[Double] = FixedArray::make(
    number_of_times * number_of_freqs,
    0.0,
  )
  let plan = @dsp.FftPlan::new(nfft)
  let data_re : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let data_im : FixedArray[Double] = FixedArray::make(nfft, 0.0)
  let pw : FixedArray[Double] = FixedArray::make(half_nfft + 1, 0.0)
  for iframe in 0..<number_of_times {
    let t = t1 + iframe.to_double() * dt
    let lo = low_index(t, sample_rate)
    let start = lo + 1 - halfnsamp
    for k in 0..<nwin {
      let idx = start + k
      // The frame is guaranteed to fit; clamp defensively anyway.
      let v = if idx >= 0 && idx < nx { samples[idx] } else { 0.0 }
      data_re[k] = v * window[k]
      data_im[k] = 0.0
    }
    for k in nwin..<nfft {
      data_re[k] = 0.0
      data_im[k] = 0.0
    }
    plan.transform(data_re, data_im, inverse=false)
    for k in 0..<=half_nfft {
      pw[k] = data_re[k] * data_re[k] + data_im[k] * data_im[k]
    }
    // Binning: band b averages FFT bins [b * width, (b + 1) * width).
    for band in 0..<number_of_freqs {
      let base = band * bin_width_samples
      let mut sum = 0.0
      for j in 0..<bin_width_samples {
        sum += pw[base + j]
      }
      power[band * number_of_times + iframe] = sum * one_by_bin_width
    }
  }
  {
    t1,
    dt,
    number_of_time_frames: number_of_times,
    f1: 0.5 * (freq_step - bin_width_hertz),
    df: freq_step,
    number_of_frequency_bands: number_of_freqs,
    power,
  }
}
