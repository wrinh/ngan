// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Auditory filter-bank spectrogram (Mel / Bark) and MFCC result types.

///|
/// Filter-bank time-frequency representation (Praat `MelSpectrogram` or
/// `BarkSpectrogram`). `values` are band levels in dB, stored filter-major:
/// `index = filter_index * number_of_time_frames + frame_index`.
pub(all) struct FilterBankMatrix {
  t1 : Double
  dt : Double
  number_of_time_frames : Int32
  /// Centre of the first filter in scale units (Mel or Bark).
  f1 : Double
  /// Spacing between adjacent filters in scale units (Mel or Bark).
  df : Double
  number_of_filters : Int32
  values : FixedArray[Double]
}

///|
/// Look up the dB value at `(filter_index, frame_index)`, or `None` if out
/// of bounds.
pub fn FilterBankMatrix::value_at(
  self : FilterBankMatrix,
  filter_index : Int32,
  frame_index : Int32,
) -> Double? {
  if filter_index < 0 ||
    filter_index >= self.number_of_filters ||
    frame_index < 0 ||
    frame_index >= self.number_of_time_frames {
    return None
  }
  Some(self.values[filter_index * self.number_of_time_frames + frame_index])
}

///|
/// Mel-Frequency Cepstral Coefficients for one frame.
pub(all) struct MfccFrame {
  time : Double
  c0 : Double
  coeffs : FixedArray[Double]
}

///|
/// Evenly sampled MFCC sequence matching Praat's `MFCC` object.
pub(all) struct Mfcc {
  t1 : Double
  dt : Double
  fmin_mel : Double
  fmax_mel : Double
  frames : Array[MfccFrame]
}
