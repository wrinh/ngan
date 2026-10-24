// Praat `To Intensity...`: frame-wise sound pressure level in dB SPL.
// Ported from fon/Sound_to_Intensity.cpp.

///|
/// Praat's Sampled_shortTermAnalysis: fit as many windows of
/// `window_dur` seconds symmetrically in a sound of `dur` seconds with
/// spacing `dt`, returning (numberOfFrames, timeOfFirstFrame).
fn short_term_analysis(
  dur : Double,
  window_dur : Double,
  dt : Double,
) -> (Int32, Double)? {
  if dt <= 0.0 || window_dur > dur {
    return None
  }
  let nf = @math.floor_int((dur - window_dur) / dt) + 1
  if nf < 1 {
    return None
  }
  let mid = 0.5 * dur
  let t1 = mid - 0.5 * nf.to_double() * dt + 0.5 * dt
  Some((nf, t1))
}

///|
/// Praat's Sampled_xToLowIndex for a sound starting at t = 0.5 / fs
/// (0-based index of the sample just below or at `t`).
fn low_index(t : Double, fs : Double) -> Int32 {
  @math.floor(t * fs - 0.5).to_int()
}

///|
/// Intensity analysis with the parameters of Praat's `To Intensity...`.
///
/// The physical window spans `6.4 / min_pitch` seconds (the effective
/// window length is `3.2 / min_pitch`) and is weighted with Praat's
/// Kaiser-20 window (beta = 2 pi^2 + 0.5). Optionally the unweighted
/// mean of the (clipped) window is subtracted first, and the reported
/// level is `10 log10(sum w (x - mean)^2 / sum w / (2e-5)^2)` dB SPL,
/// floored at -300 dB. The default frame spacing is `0.8 / min_pitch`
/// seconds (Praat's 4x oversampling).
///
/// Frames are fitted symmetrically (Praat's shortTermAnalysis): the
/// first frame is at `t1 = mid - 0.5 * n * dt + 0.5 * dt`; windows at
/// the edges may read fewer samples (clipped to the sound, like Praat).
pub fn intensity(
  samples : FixedArray[Double],
  sample_rate~ : Double,
  min_pitch~ : Double = 100.0,
  time_step~ : Double = 0.0,
  subtract_mean~ : Bool = true,
) -> @types.IntensityTier {
  let nx = samples.length()
  if nx == 0 || sample_rate <= 0.0 || min_pitch <= 0.0 {
    return { t1: 0.0, dt: 0.0, values: FixedArray::make(0, 0.0), }
  }
  let logical_window = 3.2 / min_pitch
  let dt = if time_step > 0.0 { time_step } else { logical_window / 4.0 }
  let physical_window = 2.0 * logical_window
  let half = @math.floor_int(0.5 * physical_window * sample_rate)
  let nwin = 2 * half + 1
  if half < 1 {
    return { t1: 0.0, dt: 0.0, values: FixedArray::make(0, 0.0), }
  }
  let window = @dsp.kaiser_window(nwin, beta=2.0 * @math.PI * @math.PI + 0.5)
  let centre = half // window centre index
  let dur = nx.to_double() / sample_rate
  guard short_term_analysis(dur, physical_window, dt) is Some(sa) else {
    return { t1: 0.0, dt: 0.0, values: FixedArray::make(0, 0.0), }
  }
  let (nframes, t1) = sa
  let values : FixedArray[Double] = FixedArray::make(nframes, 0.0)
  for i in 0..<nframes {
    let t = t1 + i.to_double() * dt
    let sound_centre = @math.round_int(t * sample_rate)
    let mut left = sound_centre - half
    let mut right = sound_centre + half
    if left < 0 {
      left = 0
    }
    if right > nx - 1 {
      right = nx - 1
    }
    if right < left {
      values[i] = -300.0
      continue
    }
    // Window samples aligned to the window centre (Praat keeps the window
    // centred and clips both sound and window to the overlap).
    let w_from = centre - sound_centre + left
    let mut mean = 0.0
    if subtract_mean {
      let span = (right - left + 1).to_double()
      for j in left..<=right {
        mean += samples[j]
      }
      mean /= span
    }
    let mut sumxw = 0.0
    let mut sumw = 0.0
    for j in left..<=right {
      let v = samples[j] - mean
      let w = window[w_from + j - left]
      sumxw += v * v * w
      sumw += w
    }
    let rel = if sumw > 0.0 {
      sumxw / sumw / 4.0e-10 // E / P0^2 with P0 = 2e-5 Pa
    } else {
      0.0
    }
    values[i] = if rel < 1.0e-30 { -300.0 } else { 10.0 * @math.log10(rel) }
  }
  { t1, dt, values, }
}
