// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// String-based boundary for the browser demo: PCM samples go in as a
// whitespace-separated CSV, results come back as one JSON object.

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
    let frame = col * stride
    for band in 0..<nf {
      if band > 0 {
        sb <+ ", "
      }
      let p = sg.power[band * nt + frame]
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
