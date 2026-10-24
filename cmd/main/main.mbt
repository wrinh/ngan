// Demo: synthesize a one-second two-formant vowel (220 Hz voicing,
// resonances at 500/1500 Hz, 100 Hz bandwidth) at 16 kHz and run the
// full ngan analysis on it.

///|
const FS : Double = 16000.0

///|
const PI2 : Double = 6.283185307179586476925

///|
/// Deterministic pseudo-noise in [-1, 1) from the index alone.
fn prand(n : Int32) -> Double {
  let s = @math.sin((n.to_double() + 1.0) * 12.9898) * 43758.5453
  let f = s - @math.floor(s)
  f * 2.0 - 1.0
}

///|
/// Synthesize `n` samples of an all-pole signal driven by a 220 Hz
/// glottal pulse train plus a little noise, with resonances given by the
/// second-order section coefficients.
fn synth_vowel(
  n : Int32,
  a1 : Double,
  a2 : Double,
  a3 : Double,
  a4 : Double,
) -> FixedArray[Double] {
  let x : FixedArray[Double] = FixedArray::make(n, 0.0)
  // Fixed-interval glottal pulse train (period 73 samples = 219.2 Hz)
  // with an exponentially decaying pulse shape, so voicing is exactly
  // periodic (no amplitude jitter from a fractional period).
  let period = 73
  for i in 0..<n {
    let k = i % period
    let pulse = @math.exp(-k.to_double() * 0.15)
    let e = pulse * 0.8 + prand(i) * 0.01
    let xm1 = if i >= 1 { x[i - 1] } else { 0.0 }
    let xm2 = if i >= 2 { x[i - 2] } else { 0.0 }
    let xm3 = if i >= 3 { x[i - 3] } else { 0.0 }
    let xm4 = if i >= 4 { x[i - 4] } else { 0.0 }
    x[i] = -a1 * xm1 - a2 * xm2 - a3 * xm3 - a4 * xm4 + e
  }
  // Lip radiation: a first-order difference (+6 dB/oct) turns the
  // -6 dB/oct glottal pulse into the flat harmonic envelope of real
  // speech, which is what formant analysis expects.
  let mut k = n - 1
  while k >= 1 {
    x[k] -= x[k - 1]
    k -= 1
  }
  x
}

///|
/// Coefficients (s1, s2) of the second-order resonator section
/// `A(z) = 1 + s1 z^-1 + s2 z^-2` for a pole pair at (freq, bw).
fn section(freq : Double, bw : Double) -> (Double, Double) {
  let r = @math.exp(-@math.PI * bw / FS)
  let theta = PI2 * freq / FS
  (-2.0 * r * @math.cos(theta), r * r)
}

///|
fn main {
  // Cascade two resonators: 500 Hz and 1500 Hz, both 100 Hz bandwidth.
  let (s1a, s2) = section(500.0, 120.0)
  let (s1b, _) = section(1500.0, 120.0)
  // Convolve the two second-order sections into one 4th-order A(z).
  let p1 = s1a + s1b
  let p2 = s1a * s1b + 2.0 * s2
  let p3 = (s1a + s1b) * s2
  let p4 = s2 * s2
  let samples = synth_vowel(16000, p1, p2, p3, p4)
  let result = @ngan.analyze_all(samples, FS, 100.0, 75.0, 600.0, 5, 5500.0)
  // Median-ish summary over the stable middle of the signal.
  let n = result.intensity_values.length()
  let mid_i = result.intensity_values[n / 2]
  println("intensity frames: \{n}, mid-frame \{mid_i} dB SPL")
  let mut voiced = 0
  let mut f_sum = 0.0
  for f in result.pitch_frames {
    if f.frequency is Some(freq) {
      voiced += 1
      f_sum += freq
    }
  }
  let mean_f0 = f_sum / voiced.to_double()
  let total = result.pitch_frames.length()
  println("pitch: \{voiced}/\{total} voiced frames, mean f0 \{mean_f0} Hz")
  let mut f1_sum = 0.0
  let mut f2_sum = 0.0
  let mut cnt = 0
  for fr in result.formant_frames {
    if fr.formants.length() >= 2 {
      f1_sum += fr.formants[0].frequency
      f2_sum += fr.formants[1].frequency
      cnt += 1
    }
  }
  if cnt > 0 {
    let mean_f1 = f1_sum / cnt.to_double()
    let mean_f2 = f2_sum / cnt.to_double()
    println(
      "formants: \{cnt} frames, mean F1 \{mean_f1} Hz, mean F2 \{mean_f2} Hz",
    )
  }
  // Spectrogram: locate the strongest band of the middle frame.
  let sg = @ngan.spectrogram(samples, sample_rate=FS)
  let mid = sg.number_of_time_frames / 2
  let mut best_band = 0
  let mut best_power = -1.0
  for band in 0..<sg.number_of_frequency_bands {
    let p = sg.power[band * sg.number_of_time_frames + mid]
    if p > best_power {
      best_power = p
      best_band = band
    }
  }
  let peak_f = sg.f1 + best_band.to_double() * sg.df
  let total_bands = sg.number_of_frequency_bands
  let total_frames = sg.number_of_time_frames
  println(
    "spectrogram: \{total_frames} frames x \{total_bands} bands, peak band \{peak_f} Hz",
  )
}
