// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Segment-level acoustic summary structures for TextGrid intervals.

///|
/// Acoustic measurements sampled at a normalized time `proportion`
/// within a segment (`time = xmin + proportion * duration`, e.g. 0.2,
/// 0.5, 0.8 for 20%–50%–80% dynamic contours).
#derive(Eq, Debug)
pub(all) struct SegmentTrajectoryPoint {
  proportion : Double
  time : Double
  f0 : Double?
  f1 : Double?
  f2 : Double?
  f3 : Double?
  intensity : Double?
}

///|
/// Per-segment summary combining interval metadata with aggregate F0,
/// formant means (F1–F3), intensity statistics, and dynamic trajectory
/// samples.
#derive(Eq, Debug)
pub(all) struct SegmentSummary {
  tier_name : String
  index : Int32
  label : String
  xmin : Double
  xmax : Double
  duration : Double
  f0_mean : Double?
  f0_min : Double?
  f0_max : Double?
  f0_sd : Double?
  voiced_fraction : Double
  f1_mean : Double?
  f2_mean : Double?
  f3_mean : Double?
  intensity_mean : Double?
  intensity_max : Double?
  trajectory : Array[SegmentTrajectoryPoint]
}
