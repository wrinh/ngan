// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat TextGrid data structures and query helpers.

///|
/// One labeled time interval `[xmin, xmax]` inside a Praat `IntervalTier`.
#derive(Eq, Debug)
pub(all) struct TextInterval {
  xmin : Double
  xmax : Double
  text : String
}

///|
/// Duration of the interval in seconds (`xmax - xmin`).
pub fn TextInterval::duration(self : TextInterval) -> Double {
  self.xmax - self.xmin
}

///|
/// Midpoint timestamp of the interval in seconds (`0.5 * (xmin + xmax)`).
pub fn TextInterval::midpoint(self : TextInterval) -> Double {
  0.5 * (self.xmin + self.xmax)
}

///|
/// One timestamped label inside a Praat `TextTier` (point tier).
#derive(Eq, Debug)
pub(all) struct TextPoint {
  time : Double
  mark : String
}

///|
/// A Praat `IntervalTier`: contiguous or ordered time intervals with labels.
#derive(Eq, Debug)
pub(all) struct IntervalTier {
  name : String
  xmin : Double
  xmax : Double
  intervals : Array[TextInterval]
}

///|
/// Look up the interval containing timestamp `t` (left-closed `[xmin, xmax)`,
/// and right-closed on the final interval). Returns `None` if no interval
/// covers `t`.
pub fn IntervalTier::interval_at(
  self : IntervalTier,
  t : Double,
) -> TextInterval? {
  let n = self.intervals.length()
  for i in 0..<n {
    let iv = self.intervals[i]
    if t >= iv.xmin && (t < iv.xmax || (i == n - 1 && t <= iv.xmax)) {
      return Some(iv)
    }
  }
  None
}

///|
/// A Praat `TextTier` (point tier) containing timestamped event marks.
#derive(Eq, Debug)
pub(all) struct PointTier {
  name : String
  xmin : Double
  xmax : Double
  points : Array[TextPoint]
}

///|
/// A single tier inside a `TextGrid`: either an `IntervalTier` or a
/// `PointTier`.
#derive(Eq, Debug)
pub(all) enum TextGridTier {
  Intervals(IntervalTier)
  Points(PointTier)
}

///|
/// Tier name.
pub fn TextGridTier::name(self : TextGridTier) -> String {
  match self {
    Intervals(t) => t.name
    Points(t) => t.name
  }
}

///|
/// Start time of the tier domain in seconds.
pub fn TextGridTier::xmin(self : TextGridTier) -> Double {
  match self {
    Intervals(t) => t.xmin
    Points(t) => t.xmin
  }
}

///|
/// End time of the tier domain in seconds.
pub fn TextGridTier::xmax(self : TextGridTier) -> Double {
  match self {
    Intervals(t) => t.xmax
    Points(t) => t.xmax
  }
}

///|
/// Parsed Praat `TextGrid` annotation object covering `[xmin, xmax]`.
#derive(Eq, Debug)
pub(all) struct TextGrid {
  xmin : Double
  xmax : Double
  tiers : Array[TextGridTier]
}

///|
/// Find the first tier whose `name` matches exactly.
pub fn TextGrid::tier_by_name(self : TextGrid, name : String) -> TextGridTier? {
  for tier in self.tiers {
    if tier.name() == name {
      return Some(tier)
    }
  }
  None
}

///|
/// Find the first `IntervalTier` whose `name` matches exactly.
pub fn TextGrid::interval_tier(self : TextGrid, name : String) -> IntervalTier? {
  for tier in self.tiers {
    if tier is Intervals(t) && t.name == name {
      return Some(t)
    }
  }
  None
}

///|
/// Find the first `PointTier` whose `name` matches exactly.
pub fn TextGrid::point_tier(self : TextGrid, name : String) -> PointTier? {
  for tier in self.tiers {
    if tier is Points(t) && t.name == name {
      return Some(t)
    }
  }
  None
}

///|
/// Return all `IntervalTier`s in tier order.
pub fn TextGrid::interval_tiers(self : TextGrid) -> Array[IntervalTier] {
  let out : Array[IntervalTier] = []
  for tier in self.tiers {
    if tier is Intervals(t) {
      out.push(t)
    }
  }
  out
}

///|
/// Error raised when parsing an invalid or unsupported Praat `.TextGrid`.
#derive(Eq, Debug)
pub(all) suberror TextGridError {
  InvalidFormat(line~ : Int32, message~ : String)
}
