// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// WebAssembly GC boundary for both the legacy CSV browser demo and the
// TypeScript SDK / AudioWorklet real-time streaming ring buffer.

///|
priv struct WasmState {
  mut samples : FixedArray[Double]
  mut ring : FixedArray[Double]
  mut ring_head : Int32
  mut ring_count : Int32
  mut ring_total : Int32
}

///|
let state : WasmState = {
  samples: FixedArray::make(0, 0.0),
  ring: FixedArray::make(0, 0.0),
  ring_head: 0,
  ring_count: 0,
  ring_total: 0,
}

///|
fn fmt_num(x : Double) -> String {
  if x.is_nan() || x.is_inf() {
    "null"
  } else {
    "\{x}"
  }
}

///|
fn fmt_opt_double(v : Double?) -> String {
  match v {
    Some(x) => fmt_num(x)
    None => "null"
  }
}

///|
fn push_json_string(sb : StringBuilder, s : String) -> Unit {
  sb.write_char('"')
  for c in s {
    match c {
      '"' => sb.write_string("\\\"")
      '\\' => sb.write_string("\\\\")
      '\n' => sb.write_string("\\n")
      '\r' => sb.write_string("\\r")
      '\t' => sb.write_string("\\t")
      _ => {
        let code = c.to_int()
        if code < 0x20 {
          sb.write_string("\\u00")
          let hi = (code >> 4) & 0xF
          let lo = code & 0xF
          let hex = "0123456789abcdef"
          sb.write_char(hex[hi].to_int().unsafe_to_char())
          sb.write_char(hex[lo].to_int().unsafe_to_char())
        } else {
          sb.write_char(c)
        }
      }
    }
  }
  sb.write_char('"')
}

///|
fn write_formant_frames_json(
  sb : StringBuilder,
  frames : Array[@ngan.FormantFrame],
) -> Unit {
  sb <+ "["
  for i, frame in frames {
    if i > 0 {
      sb <+ ", "
    }
    sb <+ "{\"time\": \{fmt_num(frame.time)}, \"formants\": ["
    for j, v in frame.formants {
      if j > 0 {
        sb <+ ", "
      }
      sb <+
        "{\"frequency\": \{fmt_num(v.frequency)}, \"bandwidth\": \{fmt_num(v.bandwidth)}}"
    }
    sb <+ "]}"
  }
  sb <+ "]"
}

///|
/// Allocate the active WASM sample buffer to `len` samples (initialized to
/// 0.0) and return the allocated length.
pub fn alloc_samples(len : Int32) -> Int32 {
  let n = if len > 0 { len } else { 0 }
  state.samples = FixedArray::make(n, 0.0)
  state.samples.length()
}

///|
/// Write a single PCM sample into the active sample buffer at `index`.
pub fn set_sample(index : Int32, value : Double) -> Unit {
  if index >= 0 && index < state.samples.length() {
    state.samples[index] = value
  }
}

///|
/// Read a single PCM sample from the active sample buffer at `index`.
pub fn get_sample(index : Int32) -> Double {
  if index >= 0 && index < state.samples.length() {
    state.samples[index]
  } else {
    0.0
  }
}

///|
/// Return the length of the active sample buffer.
pub fn samples_len() -> Int32 {
  state.samples.length()
}

///|
/// Reset and allocate the streaming ring buffer with `capacity` samples.
pub fn ring_reset(capacity : Int32) -> Int32 {
  let cap = if capacity > 0 { capacity } else { 0 }
  state.ring = FixedArray::make(cap, 0.0)
  state.ring_head = 0
  state.ring_count = 0
  state.ring_total = 0
  state.ring.length()
}

///|
/// Push one sample into the O(1) streaming ring buffer.
pub fn ring_push(sample : Double) -> Unit {
  let cap = state.ring.length()
  if cap <= 0 {
    return
  }
  state.ring[state.ring_head] = sample
  state.ring_head = (state.ring_head + 1) % cap
  if state.ring_count < cap {
    state.ring_count += 1
  }
  state.ring_total += 1
}

///|
/// Current number of valid samples in the streaming ring buffer.
pub fn ring_len() -> Int32 {
  state.ring_count
}

///|
/// Maximum capacity of the streaming ring buffer.
pub fn ring_capacity() -> Int32 {
  state.ring.length()
}

///|
/// Total number of samples pushed since the last `ring_reset`.
pub fn ring_total_samples() -> Int32 {
  state.ring_total
}

///|
/// Copy the most recent `window_samples` (clamped to `ring_len()`) in
/// chronological order from the ring buffer into the active sample buffer.
pub fn ring_copy_recent(window_samples : Int32) -> Int32 {
  let avail = state.ring_count
  let cap = state.ring.length()
  if avail <= 0 || cap <= 0 || window_samples <= 0 {
    state.samples = FixedArray::make(0, 0.0)
    return 0
  }
  let n = if window_samples < avail { window_samples } else { avail }
  let out = FixedArray::make(n, 0.0)
  let start = (state.ring_head - n + cap) % cap
  for i in 0..<n {
    out[i] = state.ring[(start + i) % cap]
  }
  state.samples = out
  n
}

///|
/// Run Praat `To Intensity...` on the active sample buffer and return JSON.
pub fn analyze_intensity_json(
  fs : Double,
  min_pitch : Double,
  time_step : Double,
  subtract_mean : Int32,
) -> String {
  let it = @ngan.intensity(
    state.samples,
    sample_rate=fs,
    min_pitch~,
    time_step~,
    subtract_mean=subtract_mean != 0,
  )
  let sb = StringBuilder()
  sb <+ "{\"t1\": \{fmt_num(it.t1)}, \"dt\": \{fmt_num(it.dt)}, \"values\": ["
  for i in 0..<it.values.length() {
    if i > 0 {
      sb <+ ", "
    }
    sb.write_string(fmt_num(it.values[i]))
  }
  sb <+ "]}"
  sb.to_string()
}

///|
/// Run Praat `To Pitch (ac/cc)...` on the active sample buffer and return JSON.
pub fn analyze_pitch_json(
  fs : Double,
  time_step : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_candidates : Int32,
  voicing_threshold : Double,
  silence_threshold : Double,
  octave_cost : Double,
  octave_jump_cost : Double,
  voiced_unvoiced_cost : Double,
  use_cc : Int32,
) -> String {
  let pt = if use_cc != 0 {
    @ngan.pitch_cc(
      state.samples,
      sample_rate=fs,
      time_step~,
      pitch_floor~,
      pitch_ceiling~,
      max_candidates~,
      voicing_threshold~,
      silence_threshold~,
      octave_cost~,
      octave_jump_cost~,
      voiced_unvoiced_cost~,
    )
  } else {
    @ngan.pitch(
      state.samples,
      sample_rate=fs,
      time_step~,
      pitch_floor~,
      pitch_ceiling~,
      max_candidates~,
      voicing_threshold~,
      silence_threshold~,
      octave_cost~,
      octave_jump_cost~,
      voiced_unvoiced_cost~,
    )
  }
  let sb = StringBuilder()
  sb <+ "{\"t1\": \{fmt_num(pt.t1)}, \"dt\": \{fmt_num(pt.dt)}, \"frames\": ["
  for i, fr in pt.frames {
    if i > 0 {
      sb <+ ", "
    }
    sb <+
      "{\"time\": \{fmt_num(fr.time)}, \"frequency\": \{fmt_opt_double(fr.frequency)}, \"strength\": \{fmt_num(fr.strength)}}"
  }
  sb <+ "]}"
  sb.to_string()
}

///|
/// Run Praat `To Formant (burg)...` (and optional `Formant: Track...`) on the
/// active sample buffer and return JSON.
pub fn analyze_formants_json(
  fs : Double,
  time_step : Double,
  max_num_formants : Int32,
  max_formant_freq : Double,
  window_length : Double,
  pre_emphasis_from : Double,
  track : Int32,
  num_tracks : Int32,
  ref_f1 : Double,
  ref_f2 : Double,
  ref_f3 : Double,
  ref_f4 : Double,
  ref_f5 : Double,
) -> String {
  let raw = @ngan.formants(
    state.samples,
    sample_rate=fs,
    time_step~,
    max_num_formants~,
    max_formant_freq~,
    window_length~,
    pre_emphasis_from~,
  )
  let ft = if track != 0 {
    @ngan.track_formants(
      raw,
      num_tracks~,
      ref_f1~,
      ref_f2~,
      ref_f3~,
      ref_f4~,
      ref_f5~,
    )
  } else {
    raw
  }
  let sb = StringBuilder()
  sb <+ "{\"t1\": \{fmt_num(ft.t1)}, \"dt\": \{fmt_num(ft.dt)}, \"frames\": "
  write_formant_frames_json(sb, ft.frames)
  sb <+ "}"
  sb.to_string()
}

///|
/// Run Praat `To Harmonicity (ac/cc)...` on the active sample buffer and return JSON.
pub fn analyze_harmonicity_json(
  fs : Double,
  time_step : Double,
  min_pitch : Double,
  silence_threshold : Double,
  periods_per_window : Double,
  use_cc : Int32,
) -> String {
  let ht = if use_cc != 0 {
    @ngan.harmonicity_cc(
      state.samples,
      sample_rate=fs,
      time_step~,
      min_pitch~,
      silence_threshold~,
      periods_per_window~,
    )
  } else {
    @ngan.harmonicity_ac(
      state.samples,
      sample_rate=fs,
      time_step~,
      min_pitch~,
      silence_threshold~,
      periods_per_window~,
    )
  }
  let sb = StringBuilder()
  sb <+ "{\"t1\": \{fmt_num(ht.t1)}, \"dt\": \{fmt_num(ht.dt)}, \"values\": ["
  for i, v in ht.values {
    if i > 0 {
      sb <+ ", "
    }
    match v {
      Some(x) =>
        if x <= -200.0 || x.is_nan() || x.is_inf() {
          sb <+ "null"
        } else {
          sb <+ "\{x}"
        }
      None => sb <+ "null"
    }
  }
  sb <+ "]}"
  sb.to_string()
}

///|
/// Run Praat `To Spectrogram...` on the active sample buffer, optionally
/// stride-averaging linear power along the time axis when `max_time_columns > 0`,
/// and return band-major JSON.
pub fn analyze_spectrogram_json(
  fs : Double,
  window_length : Double,
  maximum_frequency : Double,
  time_step : Double,
  frequency_step : Double,
  max_time_columns : Int32,
) -> String {
  let sg = @ngan.spectrogram(
    state.samples,
    sample_rate=fs,
    window_length~,
    maximum_frequency~,
    time_step~,
    frequency_step~,
  )
  let nt = sg.number_of_time_frames
  let nf = sg.number_of_frequency_bands
  let mut stride = 1
  if max_time_columns > 0 {
    while nt > max_time_columns * stride {
      stride *= 2
    }
  }
  let nt_out = if nt > 0 { (nt - 1) / stride + 1 } else { 0 }
  let total_out = nf * nt_out
  let out_power = FixedArray::make(total_out, 0.0)
  let mut max_p = 0.0
  for band in 0..<nf {
    for col in 0..<nt_out {
      let f_start = col * stride
      let f_end = if f_start + stride < nt { f_start + stride } else { nt }
      let span = (f_end - f_start).to_double()
      let mut sum = 0.0
      for fr in f_start..<f_end {
        sum += sg.power[band * nt + fr]
      }
      let p = if span > 0.0 { sum / span } else { 0.0 }
      out_power[band * nt_out + col] = p
      if p > max_p {
        max_p = p
      }
    }
  }
  let sb = StringBuilder()
  sb <+
    "{\"t1\": \{fmt_num(sg.t1)}, \"dt\": \{fmt_num(sg.dt * stride.to_double())}, \"numberOfTimeFrames\": \{nt_out}"
  sb <+
    ", \"f1\": \{fmt_num(sg.f1)}, \"df\": \{fmt_num(sg.df)}, \"numberOfFrequencyBands\": \{nf}"
  sb <+ ", \"maxPower\": \{fmt_num(max_p)}, \"power\": ["
  for i in 0..<total_out {
    if i > 0 {
      sb <+ ", "
    }
    sb.write_string(fmt_num(out_power[i]))
  }
  sb <+ "]}"
  sb.to_string()
}

///|
/// Run Praat voice quality perturbation analysis (pulses, HNR, jitter,
/// shimmer) on the active sample buffer and return JSON.
pub fn analyze_voice_report_json(
  fs : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_period_factor : Double,
  max_amplitude_factor : Double,
) -> String {
  let pt = @ngan.pitch(
    state.samples,
    sample_rate=fs,
    pitch_floor~,
    pitch_ceiling~,
  )
  let pp = @ngan.sound_and_pitch_to_point_process_cc(
    state.samples,
    sample_rate=fs,
    pitch=pt,
  )
  let jit = @ngan.jitter(pp, max_period_factor~)
  let shim = @ngan.shimmer(
    state.samples,
    sample_rate=fs,
    pp~,
    max_period_factor~,
    max_amplitude_factor~,
  )
  let hnr = @ngan.harmonicity_ac(
    state.samples,
    sample_rate=fs,
    min_pitch=pitch_floor,
  )
  let sb = StringBuilder()
  sb <+ "{\"pulses\": ["
  for i in 0..<pp.points.length() {
    if i > 0 {
      sb <+ ", "
    }
    sb.write_string(fmt_num(pp.points[i]))
  }
  sb <+ "], \"meanPitchHz\": \{fmt_opt_double(pt.mean())}"
  sb <+ ", \"meanHnrDb\": \{fmt_opt_double(hnr.mean())}"
  sb <+
    ", \"jitter\": {\"localRel\": \{fmt_opt_double(jit.local_rel)}, \"localAbs\": \{fmt_opt_double(jit.local_abs)}, \"rap\": \{fmt_opt_double(jit.rap)}, \"ppq5\": \{fmt_opt_double(jit.ppq5)}, \"ddp\": \{fmt_opt_double(jit.ddp)}}"
  sb <+
    ", \"shimmer\": {\"localRel\": \{fmt_opt_double(shim.local_rel)}, \"localDb\": \{fmt_opt_double(shim.local_db)}, \"apq3\": \{fmt_opt_double(shim.apq3)}, \"apq5\": \{fmt_opt_double(shim.apq5)}, \"apq11\": \{fmt_opt_double(shim.apq11)}, \"dda\": \{fmt_opt_double(shim.dda)}}"
  sb <+ "}"
  sb.to_string()
}

///|
/// Run Praat `To Ltas...` and `Get centre of gravity...` on the active
/// sample buffer and return JSON.
pub fn analyze_spectral_json(
  fs : Double,
  bandwidth : Double,
  power : Double,
  fmin : Double,
  fmax : Double,
) -> String {
  let ltas_res = @ngan.ltas(state.samples, sample_rate=fs, bandwidth~)
  let cog = @ngan.center_of_gravity(
    state.samples,
    sample_rate=fs,
    power~,
    fmin~,
    fmax~,
  )
  let sb = StringBuilder()
  sb <+
    "{\"ltas\": {\"f1\": \{fmt_num(ltas_res.f1)}, \"df\": \{fmt_num(ltas_res.df)}, \"values\": ["
  for i in 0..<ltas_res.values.length() {
    if i > 0 {
      sb <+ ", "
    }
    sb.write_string(fmt_num(ltas_res.values[i]))
  }
  sb <+ "]}, \"centerOfGravityHz\": \{fmt_opt_double(cog)}}"
  sb.to_string()
}

///|
/// Parse a Praat `.TextGrid` string and summarize acoustic segments on the
/// active sample buffer, returning JSON (`{"segments": [...]}` or `{"error": "..."}`).
pub fn analyze_textgrid_json(
  fs : Double,
  textgrid_src : String,
  tier_name : String,
  min_pitch : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_num_formants : Int32,
  max_formant_freq : Double,
  use_formant_tracking : Int32,
) -> String {
  let tier_opt : String? = if tier_name.length() > 0 {
    Some(tier_name)
  } else {
    None
  }
  try {
    let segs = @ngan.analyze_textgrid_segments(
      state.samples,
      sample_rate=fs,
      textgrid_src,
      tier_name?=tier_opt,
      min_pitch~,
      pitch_floor~,
      pitch_ceiling~,
      max_num_formants~,
      max_formant_freq~,
      use_formant_tracking=use_formant_tracking != 0,
    )
    let sb = StringBuilder()
    sb <+ "{\"segments\": ["
    for i, seg in segs {
      if i > 0 {
        sb <+ ", "
      }
      sb <+ "{\"tierName\": "
      push_json_string(sb, seg.tier_name)
      sb <+ ", \"index\": \{seg.index}, \"label\": "
      push_json_string(sb, seg.label)
      sb <+
        ", \"xmin\": \{fmt_num(seg.xmin)}, \"xmax\": \{fmt_num(seg.xmax)}, \"duration\": \{fmt_num(seg.duration)}"
      sb <+
        ", \"f0Mean\": \{fmt_opt_double(seg.f0_mean)}, \"f0Min\": \{fmt_opt_double(seg.f0_min)}, \"f0Max\": \{fmt_opt_double(seg.f0_max)}, \"f0Sd\": \{fmt_opt_double(seg.f0_sd)}"
      sb <+ ", \"voicedFraction\": \{fmt_num(seg.voiced_fraction)}"
      sb <+
        ", \"f1Mean\": \{fmt_opt_double(seg.f1_mean)}, \"f2Mean\": \{fmt_opt_double(seg.f2_mean)}, \"f3Mean\": \{fmt_opt_double(seg.f3_mean)}"
      sb <+
        ", \"intensityMean\": \{fmt_opt_double(seg.intensity_mean)}, \"intensityMax\": \{fmt_opt_double(seg.intensity_max)}"
      sb <+ ", \"trajectory\": ["
      for j, pt in seg.trajectory {
        if j > 0 {
          sb <+ ", "
        }
        sb <+
          "{\"proportion\": \{fmt_num(pt.proportion)}, \"time\": \{fmt_num(pt.time)}, \"f0\": \{fmt_opt_double(pt.f0)}, \"f1\": \{fmt_opt_double(pt.f1)}, \"f2\": \{fmt_opt_double(pt.f2)}, \"f3\": \{fmt_opt_double(pt.f3)}, \"intensity\": \{fmt_opt_double(pt.intensity)}}"
      }
      sb <+ "]}"
    }
    sb <+ "]}"
    sb.to_string()
  } catch {
    @ngan.TextGridError::InvalidFormat(line~, message~) => {
      let sb = StringBuilder()
      sb <+ "{\"error\": "
      push_json_string(sb, "TextGrid line \{line}: \{message}")
      sb <+ "}"
      sb.to_string()
    }
  }
}

///|
/// Copy the latest `window_samples` from the ring buffer into the active
/// sample buffer and return a low-latency single-frame acoustic estimate
/// centered on the sliding window.
pub fn ring_analyze_frame_json(
  fs : Double,
  window_samples : Int32,
  min_pitch : Double,
  pitch_floor : Double,
  pitch_ceiling : Double,
  max_num_formants : Int32,
  max_formant_freq : Double,
) -> String {
  let n = ring_copy_recent(window_samples)
  if n <= 0 || fs <= 0.0 {
    return "{\"time\": 0.0, \"totalSamples\": \{state.ring_total}, \"windowSamples\": 0, \"windowDuration\": 0.0, \"rms\": 0.0, \"intensityDb\": null, \"pitch\": {\"frequency\": null, \"strength\": 0.0}, \"formants\": []}"
  }
  let mut sum_sq = 0.0
  for i in 0..<n {
    let x = state.samples[i]
    sum_sq += x * x
  }
  let rms = (sum_sq / n.to_double()).sqrt()
  let it = @ngan.intensity(state.samples, sample_rate=fs, min_pitch~)
  let pt = @ngan.pitch(
    state.samples,
    sample_rate=fs,
    pitch_floor~,
    pitch_ceiling~,
  )
  let ft = @ngan.formants(
    state.samples,
    sample_rate=fs,
    max_num_formants~,
    max_formant_freq~,
  )
  let center_time = ((state.ring_total - n).to_double() + 0.5 * n.to_double()) /
    fs
  let window_duration = n.to_double() / fs
  let sb = StringBuilder()
  sb <+
    "{\"time\": \{fmt_num(center_time)}, \"totalSamples\": \{state.ring_total}, \"windowSamples\": \{n}, \"windowDuration\": \{fmt_num(window_duration)}, \"rms\": \{fmt_num(rms)}, \"intensityDb\": "
  if it.values.length() > 0 {
    sb.write_string(fmt_num(it.values[it.values.length() / 2]))
  } else {
    sb <+ "null"
  }
  sb <+ ", \"pitch\": "
  if pt.frames.length() > 0 {
    let fr = pt.frames[pt.frames.length() / 2]
    sb <+
      "{\"frequency\": \{fmt_opt_double(fr.frequency)}, \"strength\": \{fmt_num(fr.strength)}}"
  } else {
    sb <+ "{\"frequency\": null, \"strength\": 0.0}"
  }
  sb <+ ", \"formants\": ["
  if ft.frames.length() > 0 {
    let frame = ft.frames[ft.frames.length() / 2]
    for j, v in frame.formants {
      if j > 0 {
        sb <+ ", "
      }
      sb <+
        "{\"frequency\": \{fmt_num(v.frequency)}, \"bandwidth\": \{fmt_num(v.bandwidth)}}"
    }
  }
  sb <+ "]}"
  sb.to_string()
}

///|
/// Parse "v0 v1 v2 ..." into a sample array; unparsable fields read 0.
fn parse_samples(csv : String) -> FixedArray[Double] {
  let parts : Array[Double] = []
  for part in csv.split(" ") {
    if part.length() > 0 {
      parts.push(@string.parse_double(part) catch { _ => 0.0 })
    }
  }
  let out = FixedArray::make(parts.length(), 0.0)
  for i in 0..<parts.length() {
    out[i] = parts[i]
  }
  out
}

///|
/// Analyze a CSV of PCM samples ("v0 v1 v2 ..." recorded at `fs` Hz)
/// with ngan's Praat defaults and return a JSON object with an
/// `intensity` tier, a `pitch` track (`f` is null for unvoiced frames),
/// a `formants` list, and a `spectrogram` in dB relative to the maximum
/// (time axis downsampled to at most 400 columns, values quantized to
/// 0.1 dB).
pub fn analyze_csv(samples_csv : String, fs : Double) -> String {
  let samples = parse_samples(samples_csv)
  let it = @ngan.intensity(samples, sample_rate=fs)
  let pt = @ngan.pitch(samples, sample_rate=fs)
  let ft = @ngan.formants(samples, sample_rate=fs)
  let sg = @ngan.spectrogram(samples, sample_rate=fs)
  let sb = StringBuilder()
  sb <+ "{\n\"intensity\": {\"t1\": \{it.t1}, \"dt\": \{it.dt}, \"values\": ["
  for i in 0..<it.values.length() {
    if i > 0 {
      sb <+ ", "
    }
    sb <+ "\{it.values[i]}"
  }
  sb <+ "]},\n\"pitch\": ["
  for i, fr in pt.frames {
    if i > 0 {
      sb <+ ", "
    }
    if fr.frequency is Some(f) {
      sb <+ "[\{fr.time}, \{f}, \{fr.strength}]"
    } else {
      sb <+ "[\{fr.time}, null, \{fr.strength}]"
    }
  }
  sb <+ "],\n\"formants\": ["
  for i, frame in ft.frames {
    if i > 0 {
      sb <+ ", "
    }
    sb <+ "[\{frame.time}, ["
    for j, v in frame.formants {
      if j > 0 {
        sb <+ ", "
      }
      sb <+ "[\{v.frequency}, \{v.bandwidth}]"
    }
    sb <+ "]]"
  }
  sb <+ "],\n\"spectrogram\": {"
  let nt = sg.number_of_time_frames
  let nf = sg.number_of_frequency_bands
  let mut stride = 1
  while nt > 400 * stride {
    stride *= 2
  }
  let nt_out = if nt > 0 { (nt - 1) / stride + 1 } else { 0 }
  sb <+
    "\"t1\": \{sg.t1}, \"dt\": \{sg.dt * stride.to_double()}, \"nt\": \{nt_out}"
  sb <+ ", \"f1\": \{sg.f1}, \"df\": \{sg.df}, \"nf\": \{nf}"
  let max_p = sg.max_power()
  sb <+ ", \"db\": ["
  for col in 0..<nt_out {
    if col > 0 {
      sb <+ ", "
    }
    sb <+ "["
    // Average the linear power over the stride frames before converting
    // to dB: plain subsampling aliases the glottal-pulse striations.
    let f_start = col * stride
    let f_end = if f_start + stride < nt { f_start + stride } else { nt }
    let span = (f_end - f_start).to_double()
    for band in 0..<nf {
      if band > 0 {
        sb <+ ", "
      }
      let mut sum = 0.0
      for fr in f_start..<f_end {
        sum += sg.power[band * nt + fr]
      }
      let p = sum / span
      let db = if max_p > 0.0 && p > 0.0 {
        10.0 * @math.log10(p / max_p)
      } else {
        -300.0
      }
      sb <+ "\{(db * 10.0).floor() / 10.0}"
    }
    sb <+ "]"
  }
  sb <+ "]}}\n"
  sb.to_string()
}
