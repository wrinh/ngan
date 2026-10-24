// Praat `To Formant (burg)...`: Gaussian-windowed Burg LPC analysis.
// Ported from fon/Sound_to_Formant.cpp.

///|
/// Formant analysis with the parameters of Praat's
/// `To Formant (burg)...`.
///
/// 1. The sound is resampled to `2 * max_formant_freq` Hz with a
///    Kaiser-weighted band-limited sinc kernel (Praat zeroes the spectrum
///    above the target Nyquist and interpolates with a 50-term sinc;
///    ngan's Kaiser-12/32-crossing kernel reaches the same effect).
/// 2. A first-order pre-emphasis with turnover `pre_emphasis_from` Hz is
///    applied over the whole signal: `y[n] = x[n] - alpha x[n-1]` with
///    `alpha = exp(-2 pi f / fs)` (Praat's Sound_preEmphasize).
/// 3. Frames spanning `2 * window_length` seconds (Gaussian window,
///    effective length `window_length`) are analysed with Burg LPC of
///    order `2 * max_num_formants`.
/// 4. The roots of `A(z)` (Durand-Kerner) are reflected into the unit
///    circle like Praat's Roots_fixIntoUnitCircle; every upper-half-plane
///    pole at least 50 Hz from DC and Nyquist becomes a formant with
///    `F = theta * fs / 2 pi` and `B = -ln(r) * fs / pi`, sorted by
///    ascending frequency (F1, F2, ...).
///
/// The default frame spacing is `0.25 * window_length` seconds. Frames
/// are fitted symmetrically (Praat's shortTermAnalysis); windows at the
/// edges are clipped to the sound like Praat.
pub fn formants(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  time_step~ : Double = 0.0,
  max_num_formants~ : Int32 = 5,
  max_formant_freq~ : Double = 5500.0,
  window_length~ : Double = 0.025,
  pre_emphasis_from~ : Double = 50.0,
) -> @types.FormantTier {
  let empty : Array[@types.FormantFrame] = []
  let nx = samples.length()
  if nx == 0 ||
    sample_rate <= 0.0 ||
    max_num_formants < 1 ||
    max_formant_freq <= 0.0 ||
    window_length <= 0.0 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  // 1) Band-limited resampling to 2 * max_formant_freq.
  let target_fs = 2.0 * max_formant_freq
  let same_rate = @math.abs(sample_rate - target_fs) < 1.0e-12 * sample_rate
  let data : FixedArray[Double] = if same_rate {
    let d = FixedArray::make(nx, 0.0)
    for i in 0..<nx {
      d[i] = samples[i]
    }
    d
  } else {
    @dsp.sinc_resample(samples, ratio=target_fs / sample_rate)
  }
  let fs = if same_rate { sample_rate } else { target_fs }
  let n = data.length()
  // 2) First-order pre-emphasis over the whole signal.
  let alpha = @math.exp(-2.0 * @math.PI * pre_emphasis_from / fs)
  let mut i = n - 1
  while i >= 1 {
    data[i] -= alpha * data[i - 1]
    i -= 1
  }
  // 3) Framing.
  let dt = if time_step > 0.0 { time_step } else { 0.25 * window_length }
  let dt_window = 2.0 * window_length
  let halfnsamp = @math.floor_int(dt_window * fs) / 2
  let nwin = halfnsamp * 2
  let order = 2 * max_num_formants
  if halfnsamp < 2 || nwin < order + 1 {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let win = @dsp.gaussian_window(nwin)
  let dur = n.to_double() / fs
  guard short_term_analysis(dur, nwin.to_double() / fs, dt) is Some(sa) else {
    return { t1: 0.0, dt: 0.0, frames: empty, }
  }
  let (nframes, t1) = sa
  let nyquist = 0.5 * fs
  let wframe : FixedArray[Double] = FixedArray::make(nwin, 0.0)
  let frames : Array[@types.FormantFrame] = []
  for fi in 0..<nframes {
    let t = t1 + fi.to_double() * dt
    let lo = low_index(t, fs)
    let mut left = lo + 1 - halfnsamp
    let mut right = lo + halfnsamp
    if left < 0 {
      left = 0
    }
    if right > n - 1 {
      right = n - 1
    }
    let actual = right - left + 1
    let formants : Array[@types.FormantValue] = []
    if actual > order {
      // Praat aligns the window to the start of the (possibly clipped)
      // segment and skips all-zero frames ("Burg cannot stand zeroes").
      let mut max_abs = 0.0
      for j in 0..<actual {
        let v = @math.abs(data[left + j])
        if v > max_abs {
          max_abs = v
        }
      }
      if max_abs > 0.0 {
        let mut energy = 0.0
        for j in 0..<actual {
          wframe[j] = data[left + j] * win[j]
          energy += wframe[j] * wframe[j]
        }
        if energy > 1.0e-300 {
          let a = @dsp.burg_lpc(wframe, order~)
          // A(z) z^P = z^P + a[1] z^(P-1) + ... + a[P], ascending powers.
          let coeffs : FixedArray[Double] = FixedArray::make(order + 1, 0.0)
          for k in 0..<=order {
            coeffs[k] = a[order - k]
          }
          let roots = @math.poly_roots(coeffs)
          for z in roots {
            if z.im > 0.0 {
              let mut r = z.abs()
              if r > 0.0 && r < 1.0e-12 {
                continue // pole at the origin carries no formant
              }
              // Reflect poles outside the unit circle back inside
              // (Praat's Roots_fixIntoUnitCircle keeps the angle).
              if r > 1.0 {
                r = 1.0 / r
              }
              let f = @math.abs(z.arg()) * nyquist / @math.PI
              if f >= 50.0 && f <= nyquist - 50.0 {
                formants.push({
                  frequency: f,
                  bandwidth: -@math.ln(r) * nyquist / @math.PI,
                })
              }
            }
          }
          formants.sort_by(fn(p, q) {
            if p.frequency < q.frequency {
              -1
            } else if p.frequency > q.frequency {
              1
            } else {
              0
            }
          })
        }
      }
    }
    frames.push({ time: t, formants, })
  }
  { t1, dt, frames, }
}
