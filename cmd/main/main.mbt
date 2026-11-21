// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

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
  // Cross-correlation pitch + psychoacoustic scales.
  let pt_cc = @ngan.pitch_cc(samples, sample_rate=FS)
  let mut cc_voiced = 0
  let mut cc_sum = 0.0
  for f in pt_cc.frames {
    if f.frequency is Some(freq) {
      cc_voiced += 1
      cc_sum += freq
    }
  }
  let mean_f0_cc = if cc_voiced > 0 {
    cc_sum / cc_voiced.to_double()
  } else {
    0.0
  }
  let mean_st = @ngan.hz_to_semitones(mean_f0_cc)
  let mean_erb = @ngan.hz_to_erb(mean_f0_cc)
  let mean_mel = @ngan.hz_to_mel(mean_f0_cc)
  let cc_total = pt_cc.frames.length()
  println(
    "pitch (cc): \{cc_voiced}/\{cc_total} voiced, mean f0 \{mean_f0_cc} Hz (\{mean_st} st, \{mean_erb} ERB, \{mean_mel} Mel)",
  )
  // Harmonicity (HNR) + glottal pulse perturbation (jitter / shimmer).
  let hnr_ac = @ngan.harmonicity_ac(samples, sample_rate=FS)
  let hnr_cc = @ngan.harmonicity_cc(samples, sample_rate=FS)
  let mean_hnr_ac = hnr_ac.mean().unwrap_or(-200.0)
  let mean_hnr_cc = hnr_cc.mean().unwrap_or(-200.0)
  println("harmonicity: HNR(ac) \{mean_hnr_ac} dB, HNR(cc) \{mean_hnr_cc} dB")
  let pp = @ngan.sound_and_pitch_to_point_process_cc(
    samples,
    sample_rate=FS,
    pitch=pt_cc,
  )
  let j = @ngan.jitter(pp)
  let s = @ngan.shimmer(samples, sample_rate=FS, pp~)
  let pp_n = pp.length()
  let j_pct = j.local_rel.unwrap_or(0.0) * 100.0
  let s_pct = s.local_rel.unwrap_or(0.0) * 100.0
  let s_db = s.local_db.unwrap_or(0.0)
  println(
    "voice quality: \{pp_n} pulses, jitter(local) \{j_pct}%, shimmer(local) \{s_pct}% (\{s_db} dB)",
  )
  // Viterbi formant tracking.
  let raw_ft : @ngan.FormantTier = @ngan.formants(samples, sample_rate=FS)
  let tracked_ft = @ngan.track_formants(raw_ft, num_tracks=2)
  let mut tf1 = 0.0
  let mut tf2 = 0.0
  let mut tcnt = 0
  for fr in tracked_ft.frames {
    if fr.formants.length() >= 2 {
      tf1 += fr.formants[0].frequency
      tf2 += fr.formants[1].frequency
      tcnt += 1
    }
  }
  if tcnt > 0 {
    let m1 = tf1 / tcnt.to_double()
    let m2 = tf2 / tcnt.to_double()
    println(
      "tracked formants: \{tcnt} frames, mean F1 \{m1} Hz, mean F2 \{m2} Hz",
    )
  }
  // LTAS, Center of Gravity, and Spectral Tilt (H1-H2).
  let lt = @ngan.ltas(samples, sample_rate=FS)
  let lt_slope = lt.slope().unwrap_or(0.0)
  let cog = @ngan.center_of_gravity(samples, sample_rate=FS).unwrap_or(0.0)
  let tilt = @ngan.spectral_tilt(
    samples,
    sample_rate=FS,
    pitch=pt_cc,
    formants=Some(tracked_ft),
  )
  let mid_tilt = tilt.frames[tilt.frames.length() / 2]
  let h1_h2 = mid_tilt.h1_minus_h2.unwrap_or(0.0)
  let h1_h2_c = mid_tilt.h1_minus_h2_corrected.unwrap_or(0.0)
  println(
    "spectral: CoG \{cog} Hz, LTAS slope \{lt_slope} dB, mid H1-H2 \{h1_h2} dB (H1*-H2* \{h1_h2_c} dB)",
  )
  // TextGrid segment summarization with 20%-50%-80% trajectory points.
  let tg_src =
    #|File type = "ooTextFile"
    #|Object class = "TextGrid"
    #|xmin = 0
    #|xmax = 1.0
    #|tiers? <exists>
    #|size = 1
    #|item []:
    #|    item [1]:
    #|        class = "IntervalTier"
    #|        name = "vowels"
    #|        xmin = 0
    #|        xmax = 1.0
    #|        intervals: size = 1
    #|        intervals [1]:
    #|            xmin = 0.1
    #|            xmax = 0.9
    #|            text = "ə"
  let tg = @ngan.parse_textgrid(tg_src) catch {
    err => abort("TextGrid parse failed: \{Repr(err)}")
  }
  let it_seg = @ngan.intensity(samples, sample_rate=FS)
  let segs = @ngan.summarize_textgrid(
    tg,
    pitch=pt_cc,
    formants=tracked_ft,
    intensity=it_seg,
  )
  if segs.length() > 0 {
    let s0 = segs[0]
    let f0m = s0.f0_mean.unwrap_or(0.0)
    let f1m = s0.f1_mean.unwrap_or(0.0)
    let f2m = s0.f2_mean.unwrap_or(0.0)
    let im = s0.intensity_mean.unwrap_or(0.0)
    let p20 = s0.trajectory[0].f1.unwrap_or(0.0)
    let p50 = s0.trajectory[1].f1.unwrap_or(0.0)
    let p80 = s0.trajectory[2].f1.unwrap_or(0.0)
    println(
      "textgrid[\{s0.label}]: F0 \{f0m} Hz, F1 \{f1m} Hz (20/50/80%: \{p20}/\{p50}/\{p80}), F2 \{f2m} Hz, I \{im} dB",
    )
  }
}
