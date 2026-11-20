// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for Formant trajectory tracking (`Formant: Track...`).

///|
test "track_formants suppresses spurious low-frequency jumps" {
  let frames : Array[@types.FormantFrame] = []
  for i in 0..<20 {
    let t = 0.00625 * i.to_double() + 0.01
    let cands : Array[@types.FormantValue] = []
    // Inject a spurious broadband low pole in frames 5..10 that would
    // otherwise bump F1->200 Hz, F2->500 Hz, F3->1500 Hz in raw Burg order.
    if i >= 5 && i <= 10 {
      cands.push({ frequency: 200.0, bandwidth: 600.0, })
    }
    cands.push({ frequency: 500.0, bandwidth: 80.0, })
    cands.push({ frequency: 1500.0, bandwidth: 100.0, })
    cands.push({ frequency: 2500.0, bandwidth: 120.0, })
    cands.push({ frequency: 3500.0, bandwidth: 150.0, })
    frames.push({ time: t, formants: cands, })
  }
  let raw : @types.FormantTier = { t1: 0.01, dt: 0.00625, frames, }
  let tracked = track_formants(raw, num_tracks=3)
  assert_eq(tracked.frames.length(), 20)
  for i, fr in tracked.frames {
    assert_eq(fr.formants.length(), 3)
    assert_true(approx(fr.formants[0].frequency, 500.0, 1.0e-9))
    assert_true(approx(fr.formants[1].frequency, 1500.0, 1.0e-9))
    assert_true(approx(fr.formants[2].frequency, 2500.0, 1.0e-9))
    ignore(i)
  }
}

///|
test "track_formants handles silent boundary frames and Burg vowel" {
  let fs = 16000.0
  let v = make_vowel(fs, 500.0, 1500.0, 100.0, 8000, 0.4)
  // Pad with leading and trailing silence so empty frames exercise split runs.
  let x : FixedArray[Double] = FixedArray::make(12000, 0.0)
  for i in 0..<8000 {
    x[2000 + i] = v[i]
  }
  let raw = formants(x, sample_rate=fs)
  let tracked = track_formants(raw, num_tracks=2)
  assert_eq(tracked.frames.length(), raw.frames.length())
  let mut empty_kept = 0
  let mut f1_sum = 0.0
  let mut f2_sum = 0.0
  let mut voiced_cnt = 0
  for i in 0..<tracked.frames.length() {
    let t = tracked.frames[i].time
    if t < 0.08 || t > 0.67 {
      if tracked.frames[i].formants.length() == 0 {
        empty_kept += 1
      }
    } else if t >= 0.25 && t <= 0.50 && tracked.frames[i].formants.length() == 2 {
      f1_sum += tracked.frames[i].formants[0].frequency
      f2_sum += tracked.frames[i].formants[1].frequency
      voiced_cnt += 1
    }
  }
  assert_true(empty_kept > 0)
  assert_true(voiced_cnt >= 20)
  assert_true(approx(f1_sum / voiced_cnt.to_double(), 500.0, 60.0))
  assert_true(approx(f2_sum / voiced_cnt.to_double(), 1500.0, 90.0))
}
