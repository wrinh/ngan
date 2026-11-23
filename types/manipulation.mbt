// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// TD-PSOLA pitch and duration manipulation data structures (Praat `Manipulation`).

///|
/// Single target pitch control point (`PitchTier` point in Praat).
pub(all) struct PitchPoint {
  time : Double
  frequency : Double
}

///|
/// Single relative duration control point (`DurationTier` point in Praat).
/// `relative_duration = 2.0` doubles local duration (half speed); `0.5`
/// halves local duration (double speed).
pub(all) struct DurationPoint {
  time : Double
  relative_duration : Double
}

///|
/// Praat-style `Manipulation` object pairing extracted glottal pulses with
/// editable pitch and duration control tiers.
pub(all) struct Manipulation {
  sample_rate : Double
  tmin : Double
  tmax : Double
  pulses : PointProcess
  pitch_points : Array[PitchPoint]
  duration_points : Array[DurationPoint]
}
