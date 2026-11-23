// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Whitebox tests for `mel_spectrogram`, `bark_spectrogram`, and `mfcc`.

///|
test "mel_spectrogram, bark_spectrogram, and mfcc produce valid shapes and peaks" {
  let fs = 16000.0
  let n = 8000
  let x = sine_fa(n, fs, 1000.0, 1.0, 0.0)
  let mel_sg = mel_spectrogram(x, sample_rate=fs)
  assert_true(mel_sg.number_of_time_frames > 50)
  assert_true(mel_sg.number_of_filters >= 10)
  let mid_t = mel_sg.number_of_time_frames / 2
  // Peak Mel filter should be near hz_to_mel(1000) ~= 569.85 Mel -> filter index ~4 or 5.
  let mut best_m = 0
  let mut best_db = -1000.0
  for m in 0..<mel_sg.number_of_filters {
    guard mel_sg.value_at(m, mid_t) is Some(v) else { fail("missing mel val") }
    if v > best_db {
      best_db = v
      best_m = m
    }
  }
  let peak_mel = mel_sg.f1 + best_m.to_double() * mel_sg.df
  assert_true(@math.abs(peak_mel - @types.hz_to_mel(1000.0)) <= mel_sg.df)
  assert_true(best_db > 75.0)

  let bark_sg = bark_spectrogram(x, sample_rate=fs)
  assert_true(bark_sg.number_of_time_frames > 50)
  assert_true(bark_sg.number_of_filters >= 15)
  let mut best_b = 0
  let mut best_bark_db = -1000.0
  for b in 0..<bark_sg.number_of_filters {
    guard bark_sg.value_at(b, mid_t) is Some(v) else {
      fail("missing bark val")
    }
    if v > best_bark_db {
      best_bark_db = v
      best_b = b
    }
  }
  let peak_bark = bark_sg.f1 + best_b.to_double() * bark_sg.df
  assert_true(
    @math.abs(peak_bark - @types.hz_to_bark(1000.0)) <= 1.5 * bark_sg.df,
  )

  let m_res = mfcc(x, sample_rate=fs, number_of_coefficients=12)
  assert_eq(m_res.frames.length(), mel_sg.number_of_time_frames)
  assert_eq(m_res.frames[mid_t].coeffs.length(), 12)
  assert_true(!m_res.frames[mid_t].c0.is_nan())
  for c in m_res.frames[mid_t].coeffs {
    assert_true(!c.is_nan() && !c.is_inf())
  }
}
