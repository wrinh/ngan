// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// Praat `Formant: Track...`: Viterbi dynamic-programming formant
// tracker, ported from fon/Formant.cpp (`Formant_tracker`).

///|
/// Generate all strictly increasing `k`-combinations of indices in
/// `0..<m`.
fn formant_combinations(m : Int32, k : Int32) -> Array[FixedArray[Int32]] {
  let out : Array[FixedArray[Int32]] = []
  if k <= 0 || k > m {
    return out
  }
  let cur : FixedArray[Int32] = FixedArray::make(k, 0)
  fn dfs(start : Int32, depth : Int32) -> Unit {
    if depth == k {
      let snap : FixedArray[Int32] = FixedArray::make(k, 0)
      for i in 0..<k {
        snap[i] = cur[i]
      }
      out.push(snap)
      return
    }
    let remaining = k - depth
    let limit = m - remaining
    for i in start..<=limit {
      cur[depth] = i
      dfs(i + 1, depth + 1)
    }
  }
  dfs(0, 0)
  out
}

///|
/// Praat `Formant: Track...`: dynamic-programming (Viterbi) formant
/// trajectory tracker.
///
/// Selects `num_tracks` (1..5, default 3) smooth formant tracks from a
/// raw `FormantTier` by minimizing the sum of:
/// - Reference-frequency deviation cost:
///   `frequency_cost * |F_k - ref_k| / 1000` (skipped when `ref_k <= 0`),
/// - Relative bandwidth cost: `bandwidth_cost * (B_k / F_k)`,
/// - Inter-frame octave transition cost:
///   `transition_cost * |log2(F_k(t) / F_k(t - 1))|`.
///
/// Contiguous runs of frames containing at least `num_tracks` candidates
/// are tracked via exact Viterbi minimization; frames with fewer than
/// `num_tracks` candidates (e.g. silent or unvoiced frames) are passed
/// through unchanged.
pub fn track_formants(
  tier : @types.FormantTier,
  num_tracks~ : Int32 = 3,
  ref_f1~ : Double = 550.0,
  ref_f2~ : Double = 1650.0,
  ref_f3~ : Double = 2750.0,
  ref_f4~ : Double = 3850.0,
  ref_f5~ : Double = 4950.0,
  frequency_cost~ : Double = 1.0,
  bandwidth_cost~ : Double = 1.0,
  transition_cost~ : Double = 1.0,
) -> @types.FormantTier {
  let nframes = tier.frames.length()
  if nframes == 0 || num_tracks < 1 {
    return { t1: tier.t1, dt: tier.dt, frames: [], }
  }
  let k = if num_tracks > 5 { 5 } else { num_tracks }
  let refs : FixedArray[Double] = [ref_f1, ref_f2, ref_f3, ref_f4, ref_f5]
  let out_frames : Array[@types.FormantFrame] = []
  let mut idx = 0
  while idx < nframes {
    if tier.frames[idx].formants.length() < k {
      // Pass through sparse/silent frame unchanged.
      let src = tier.frames[idx]
      let copied : Array[@types.FormantValue] = []
      for fv in src.formants {
        copied.push(fv)
      }
      out_frames.push({ time: src.time, formants: copied, })
      idx += 1
      continue
    }
    let run_start = idx
    while idx + 1 < nframes && tier.frames[idx + 1].formants.length() >= k {
      idx += 1
    }
    let run_end = idx
    idx += 1
    let run_len = run_end - run_start + 1
    let all_states : Array[Array[FixedArray[Int32]]] = []
    let paths : Array[FixedArray[Int32]] = []
    let mut prev_dp : FixedArray[Double] = FixedArray::make(0, 0.0)
    for r in 0..<run_len {
      let fr = tier.frames[run_start + r]
      let m = if fr.formants.length() > 10 { 10 } else { fr.formants.length() }
      let states = formant_combinations(m, k)
      all_states.push(states)
      let ns = states.length()
      let dp : FixedArray[Double] = FixedArray::make(ns, 0.0)
      let back : FixedArray[Int32] = FixedArray::make(ns, 0)
      for s in 0..<ns {
        let combo = states[s]
        let mut lcost = 0.0
        for t in 0..<k {
          let fv = fr.formants[combo[t]]
          if refs[t] > 0.0 {
            lcost += frequency_cost * @math.abs(fv.frequency - refs[t]) / 1000.0
          }
          if fv.frequency > 0.0 {
            lcost += bandwidth_cost * (fv.bandwidth / fv.frequency)
          }
        }
        if r == 0 {
          dp[s] = lcost
        } else {
          let prev_fr = tier.frames[run_start + r - 1]
          let prev_states = all_states[r - 1]
          let mut best_cost = 1.0e300
          let mut best_p = 0
          for p in 0..<prev_states.length() {
            let pcombo = prev_states[p]
            let mut tcost = 0.0
            for t in 0..<k {
              let f_prev = prev_fr.formants[pcombo[t]].frequency
              let f_curr = fr.formants[combo[t]].frequency
              if f_prev > 0.0 && f_curr > 0.0 {
                tcost += transition_cost *
                  @math.abs(@math.log2(f_curr / f_prev))
              }
            }
            let total = prev_dp[p] + tcost
            if total < best_cost {
              best_cost = total
              best_p = p
            }
          }
          dp[s] = best_cost + lcost
          back[s] = best_p
        }
      }
      paths.push(back)
      prev_dp = dp
    }
    // Backtrack minimum-cost path.
    let mut best_s = 0
    for s in 1..<prev_dp.length() {
      if prev_dp[s] < prev_dp[best_s] {
        best_s = s
      }
    }
    let chosen : FixedArray[Int32] = FixedArray::make(run_len, 0)
    chosen[run_len - 1] = best_s
    let mut r = run_len - 1
    while r > 0 {
      chosen[r - 1] = paths[r][chosen[r]]
      r -= 1
    }
    for r in 0..<run_len {
      let fr = tier.frames[run_start + r]
      let combo = all_states[r][chosen[r]]
      let picked : Array[@types.FormantValue] = []
      for t in 0..<k {
        picked.push(fr.formants[combo[t]])
      }
      out_frames.push({ time: fr.time, formants: picked, })
    }
  }
  { t1: tier.t1, dt: tier.dt, frames: out_frames, }
}
