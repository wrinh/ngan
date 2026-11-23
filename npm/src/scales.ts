// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { Spectrogram } from './types.js';

/**
 * Convert frequency in Hz to semitones relative to `referenceHz`
 * (Praat default 100 Hz): `12 * log2(hz / referenceHz)`.
 */
export function hzToSemitones(hz: number, referenceHz = 100): number {
  if (hz > 0 && referenceHz > 0) {
    return 12 * Math.log2(hz / referenceHz);
  }
  return 0;
}

/**
 * Convert semitones relative to `referenceHz` back to Hz.
 */
export function semitonesToHz(semitones: number, referenceHz = 100): number {
  if (referenceHz > 0) {
    return referenceHz * Math.pow(2, semitones / 12);
  }
  return 0;
}

/**
 * Convert frequency in Hz to Praat's ERB-rate scale (`NUMhertzToErb`):
 * `11.17 * ln((hz + 312) / (hz + 14680)) + 43`.
 */
export function hzToErb(hz: number): number {
  if (hz < 0) return 0;
  return 11.17 * Math.log((hz + 312) / (hz + 14680)) + 43;
}

/**
 * Convert Praat's ERB-rate value back to frequency in Hz.
 */
export function erbToHz(erb: number): number {
  const a = Math.exp((erb - 43) / 11.17);
  if (a >= 1) return 0;
  return (14680 * a - 312) / (1 - a);
}

/**
 * Convert frequency in Hz to Praat's Mel scale (`NUMhertzToMel`):
 * `550 * ln(1 + hz / 550)`.
 */
export function hzToMel(hz: number): number {
  if (hz < 0) return 0;
  return 550 * Math.log(1 + hz / 550);
}

/**
 * Convert Praat's Mel scale value back to frequency in Hz.
 */
export function melToHz(mel: number): number {
  return 550 * (Math.exp(mel / 550) - 1);
}

/**
 * Convert frequency in Hz to Praat's Bark scale (`NUMhertzToBark`):
 * `7 * ln(hz / 650 + sqrt(1 + (hz / 650)^2))`.
 */
export function hzToBark(hz: number): number {
  if (hz < 0) return 0;
  const r = hz / 650;
  return 7 * Math.log(r + Math.sqrt(1 + r * r));
}

/**
 * Convert Praat's Bark scale value back to frequency in Hz
 * (`NUMbarkToHertz`): `325 * (exp(bark / 7) - exp(-bark / 7))`.
 */
export function barkToHz(bark: number): number {
  if (bark < 0) return 0;
  const e = Math.exp(bark / 7);
  return 325 * (e - 1 / e);
}

/**
 * Convert linear power spectral density (Pa^2/Hz) or pressure^2 to dB
 * relative to `referencePower` (default `1.0` for relative spectrogram dB,
 * or pass `4e-10` for dB SPL re 2e-5 Pa).
 */
export function powerToDbSpl(
  power: number,
  referencePower = 4e-10,
  floorDb = -300,
): number {
  if (power <= 0 || referencePower <= 0) return floorDb;
  const rel = power / referencePower;
  if (rel <= 1e-30) return floorDb;
  return 10 * Math.log10(rel);
}

/**
 * Convert a band-major `Spectrogram` grid into a relative dB array `[band][frame]`
 * referenced to `spectrogram.maxPower` (clamped at `floorDb`, default `-60`).
 */
export function spectrogramToDbMatrix(
  sg: Spectrogram,
  floorDb = -60,
): Float32Array[] {
  const nt = sg.numberOfTimeFrames;
  const nf = sg.numberOfFrequencyBands;
  const ref = sg.maxPower > 0 ? sg.maxPower : 1;
  const rows: Float32Array[] = new Array(nf);
  for (let b = 0; b < nf; b++) {
    const row = new Float32Array(nt);
    const offset = b * nt;
    for (let t = 0; t < nt; t++) {
      const p = sg.power[offset + t] ?? 0;
      const db = p > 0 ? 10 * Math.log10(p / ref) : floorDb;
      row[t] = db < floorDb ? floorDb : db;
    }
    rows[b] = row;
  }
  return rows;
}
