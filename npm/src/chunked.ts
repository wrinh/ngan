// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { NganEngine } from './index.js';
import type {
  AudioChunkAnalysisResult,
  AudioChunkDescriptor,
  FilterBankMatrix,
  FilterBankSpectrogramOptions,
  FormantOptions,
  FormantTier,
  HarmonicityOptions,
  HarmonicityTier,
  IntensityOptions,
  IntensityTier,
  LongAudioAnalysisOptions,
  LongAudioAnalysisResult,
  LongAudioProgress,
  MfccOptions,
  MfccResult,
  PitchOptions,
  PitchTier,
  SampleArray,
  Spectrogram,
  SpectrogramOptions,
} from './types.js';

function createAbortError(): Error {
  const err = new Error('Long-audio analysis aborted');
  err.name = 'AbortError';
  return err;
}

function yieldToEventLoop(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function sliceSamples(
  samples: SampleArray,
  start: number,
  end: number,
): SampleArray {
  if (samples instanceof Float32Array || samples instanceof Float64Array) {
    return samples.subarray(start, end);
  }
  return samples.slice(start, end);
}

/**
 * Plan overlap-save sample/time chunks for arbitrarily long audio so
 * frame windows and Viterbi pitch/formant trackers stay accurate across
 * chunk boundaries.
 */
export function planAudioChunks(
  totalSamples: number,
  sampleRate: number,
  options: {
    chunkDurationSeconds?: number;
    overlapDurationSeconds?: number;
  } = {},
): AudioChunkDescriptor[] {
  if (totalSamples <= 0 || sampleRate <= 0) {
    return [];
  }
  const chunkDurationSeconds = Math.max(0.1, options.chunkDurationSeconds ?? 30);
  const overlapDurationSeconds = Math.max(
    0,
    options.overlapDurationSeconds ?? 0.5,
  );
  const chunkSamples = Math.max(1, Math.round(chunkDurationSeconds * sampleRate));
  const overlapSamples = Math.max(
    0,
    Math.round(overlapDurationSeconds * sampleRate),
  );
  const totalChunks = Math.max(1, Math.ceil(totalSamples / chunkSamples));
  const chunks: AudioChunkDescriptor[] = [];

  for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex++) {
    const coreStartSample = chunkIndex * chunkSamples;
    const coreEndSample = Math.min(totalSamples, coreStartSample + chunkSamples);
    const sliceStartSample = Math.max(0, coreStartSample - overlapSamples);
    const sliceEndSample = Math.min(totalSamples, coreEndSample + overlapSamples);
    chunks.push({
      chunkIndex,
      totalChunks,
      coreStartSample,
      coreEndSample,
      sliceStartSample,
      sliceEndSample,
      coreStartTime: coreStartSample / sampleRate,
      coreEndTime: coreEndSample / sampleRate,
      sliceStartTime: sliceStartSample / sampleRate,
      sliceEndTime: sliceEndSample / sampleRate,
    });
  }
  return chunks;
}

function inCoreWindow(
  t: number,
  coreStartTime: number,
  coreEndTime: number,
  isLast: boolean,
): boolean {
  const eps = 1e-9;
  if (t < coreStartTime - eps) return false;
  return isLast ? t <= coreEndTime + eps : t < coreEndTime - eps;
}

function trimIntensity(
  tier: IntensityTier,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): IntensityTier {
  const values: number[] = [];
  let firstTime: number | null = null;
  for (let i = 0; i < tier.values.length; i++) {
    const t = offset + tier.t1 + i * tier.dt;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      if (firstTime === null) firstTime = t;
      values.push(tier.values[i]!);
    }
  }
  return {
    t1: firstTime ?? coreStart,
    dt: tier.dt,
    values,
  };
}

function trimPitch(
  tier: PitchTier,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): PitchTier {
  const frames = [];
  for (const fr of tier.frames) {
    const t = offset + fr.time;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      frames.push({ ...fr, time: t });
    }
  }
  return {
    t1: frames[0]?.time ?? coreStart,
    dt: tier.dt,
    frames,
  };
}

function trimFormants(
  tier: FormantTier,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): FormantTier {
  const frames = [];
  for (const fr of tier.frames) {
    const t = offset + fr.time;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      frames.push({ ...fr, time: t });
    }
  }
  return {
    t1: frames[0]?.time ?? coreStart,
    dt: tier.dt,
    frames,
  };
}

function trimHarmonicity(
  tier: HarmonicityTier,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): HarmonicityTier {
  const values: (number | null)[] = [];
  let firstTime: number | null = null;
  for (let i = 0; i < tier.values.length; i++) {
    const t = offset + tier.t1 + i * tier.dt;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      if (firstTime === null) firstTime = t;
      values.push(tier.values[i] ?? null);
    }
  }
  return {
    t1: firstTime ?? coreStart,
    dt: tier.dt,
    values,
  };
}

function trimSpectrogram(
  sg: Spectrogram,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): Spectrogram {
  const nt = sg.numberOfTimeFrames;
  const nf = sg.numberOfFrequencyBands;
  const keptCols: number[] = [];
  let firstTime: number | null = null;
  for (let col = 0; col < nt; col++) {
    const t = offset + sg.t1 + col * sg.dt;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      if (firstTime === null) firstTime = t;
      keptCols.push(col);
    }
  }
  const ntOut = keptCols.length;
  const power = new Array<number>(nf * ntOut);
  let maxPower = 0;
  for (let b = 0; b < nf; b++) {
    for (let j = 0; j < ntOut; j++) {
      const p = sg.power[b * nt + keptCols[j]!] ?? 0;
      power[b * ntOut + j] = p;
      if (p > maxPower) maxPower = p;
    }
  }
  return {
    t1: firstTime ?? coreStart,
    dt: sg.dt,
    numberOfTimeFrames: ntOut,
    f1: sg.f1,
    df: sg.df,
    numberOfFrequencyBands: nf,
    maxPower,
    power,
  };
}

function trimFilterBank(
  fb: FilterBankMatrix,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): FilterBankMatrix {
  const nt = fb.numberOfTimeFrames;
  const nf = fb.numberOfFilters;
  const keptCols: number[] = [];
  let firstTime: number | null = null;
  for (let col = 0; col < nt; col++) {
    const t = offset + fb.t1 + col * fb.dt;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      if (firstTime === null) firstTime = t;
      keptCols.push(col);
    }
  }
  const ntOut = keptCols.length;
  const values = new Array<number>(nf * ntOut);
  for (let b = 0; b < nf; b++) {
    for (let j = 0; j < ntOut; j++) {
      values[b * ntOut + j] = fb.values[b * nt + keptCols[j]!] ?? -300;
    }
  }
  return {
    scale: fb.scale,
    t1: firstTime ?? coreStart,
    dt: fb.dt,
    numberOfTimeFrames: ntOut,
    f1: fb.f1,
    df: fb.df,
    numberOfFilters: nf,
    values,
  };
}

function trimMfcc(
  m: MfccResult,
  offset: number,
  coreStart: number,
  coreEnd: number,
  isLast: boolean,
): MfccResult {
  const frames = [];
  for (const fr of m.frames) {
    const t = offset + fr.time;
    if (inCoreWindow(t, coreStart, coreEnd, isLast)) {
      frames.push({ ...fr, time: t });
    }
  }
  return {
    t1: frames[0]?.time ?? coreStart,
    dt: m.dt,
    fminMel: m.fminMel,
    fmaxMel: m.fmaxMel,
    frames,
  };
}

function resolveOpt<T>(
  opt: boolean | T | undefined,
  defaultEnabled: boolean,
): T | null {
  if (opt === undefined) {
    return defaultEnabled ? ({} as T) : null;
  }
  if (opt === false) return null;
  if (opt === true) return {} as T;
  return opt;
}

/**
 * Analyze one overlap-save chunk on `engine`, shifting timestamps to absolute
 * recording time and trimming the overlap margins cleanly.
 */
export function analyzeAudioChunk(
  engine: NganEngine,
  samples: SampleArray,
  sampleRate: number,
  descriptor: AudioChunkDescriptor,
  options: LongAudioAnalysisOptions = {},
): AudioChunkAnalysisResult {
  const slice = sliceSamples(
    samples,
    descriptor.sliceStartSample,
    descriptor.sliceEndSample,
  );
  engine.writeSamples(slice);

  const offset = descriptor.sliceStartTime;
  const isLast = descriptor.chunkIndex === descriptor.totalChunks - 1;
  const out: AudioChunkAnalysisResult = {
    chunkIndex: descriptor.chunkIndex,
    totalChunks: descriptor.totalChunks,
    startTime: descriptor.coreStartTime,
    endTime: descriptor.coreEndTime,
    duration: descriptor.coreEndTime - descriptor.coreStartTime,
  };

  const intOpts = resolveOpt<IntensityOptions>(options.intensity, true);
  if (intOpts) {
    out.intensity = trimIntensity(
      engine.analyzeActiveIntensity(sampleRate, intOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const pitchOpts = resolveOpt<PitchOptions>(options.pitch, true);
  if (pitchOpts) {
    out.pitch = trimPitch(
      engine.analyzeActivePitch(sampleRate, pitchOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const formantOpts = resolveOpt<FormantOptions>(options.formants, true);
  if (formantOpts) {
    out.formants = trimFormants(
      engine.analyzeActiveFormants(sampleRate, formantOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const hnrOpts = resolveOpt<HarmonicityOptions>(options.harmonicity, false);
  if (hnrOpts) {
    out.harmonicity = trimHarmonicity(
      engine.analyzeActiveHarmonicity(sampleRate, hnrOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const sgOpts = resolveOpt<SpectrogramOptions>(options.spectrogram, false);
  if (sgOpts) {
    out.spectrogram = trimSpectrogram(
      engine.analyzeActiveSpectrogram(sampleRate, sgOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const melOpts = resolveOpt<FilterBankSpectrogramOptions>(
    options.melSpectrogram,
    false,
  );
  if (melOpts) {
    out.melSpectrogram = trimFilterBank(
      engine.analyzeActiveMelSpectrogram(sampleRate, melOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const barkOpts = resolveOpt<FilterBankSpectrogramOptions>(
    options.barkSpectrogram,
    false,
  );
  if (barkOpts) {
    out.barkSpectrogram = trimFilterBank(
      engine.analyzeActiveBarkSpectrogram(sampleRate, barkOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  const mfccOpts = resolveOpt<MfccOptions>(options.mfcc, false);
  if (mfccOpts) {
    out.mfcc = trimMfcc(
      engine.analyzeActiveMfcc(sampleRate, mfccOpts),
      offset,
      descriptor.coreStartTime,
      descriptor.coreEndTime,
      isLast,
    );
  }

  return out;
}

/**
 * Merge an ordered array of per-chunk analyses into continuous recording-level
 * tiers.
 */
export function mergeChunkAnalyses(
  chunks: AudioChunkAnalysisResult[],
  sampleRate: number,
  totalDuration: number,
): LongAudioAnalysisResult {
  const result: LongAudioAnalysisResult = {
    sampleRate,
    duration: totalDuration,
    totalChunks: chunks.length,
    chunks,
  };
  if (chunks.length === 0) return result;

  if (chunks.some((c) => c.intensity !== undefined)) {
    const first = chunks.find((c) => c.intensity && c.intensity.values.length > 0)
      ?.intensity;
    const values: number[] = [];
    for (const c of chunks) {
      if (c.intensity) values.push(...c.intensity.values);
    }
    result.intensity = {
      t1: first?.t1 ?? 0,
      dt: first?.dt ?? 0,
      values,
    };
  }

  if (chunks.some((c) => c.pitch !== undefined)) {
    const first = chunks.find((c) => c.pitch && c.pitch.frames.length > 0)?.pitch;
    const frames = [];
    for (const c of chunks) {
      if (c.pitch) frames.push(...c.pitch.frames);
    }
    result.pitch = {
      t1: frames[0]?.time ?? first?.t1 ?? 0,
      dt: first?.dt ?? 0,
      frames,
    };
  }

  if (chunks.some((c) => c.formants !== undefined)) {
    const first = chunks.find((c) => c.formants && c.formants.frames.length > 0)
      ?.formants;
    const frames = [];
    for (const c of chunks) {
      if (c.formants) frames.push(...c.formants.frames);
    }
    result.formants = {
      t1: frames[0]?.time ?? first?.t1 ?? 0,
      dt: first?.dt ?? 0,
      frames,
    };
  }

  if (chunks.some((c) => c.harmonicity !== undefined)) {
    const first = chunks.find(
      (c) => c.harmonicity && c.harmonicity.values.length > 0,
    )?.harmonicity;
    const values: (number | null)[] = [];
    for (const c of chunks) {
      if (c.harmonicity) values.push(...c.harmonicity.values);
    }
    result.harmonicity = {
      t1: first?.t1 ?? 0,
      dt: first?.dt ?? 0,
      values,
    };
  }

  if (chunks.some((c) => c.spectrogram !== undefined)) {
    const valid = chunks
      .map((c) => c.spectrogram)
      .filter((s): s is Spectrogram => Boolean(s && s.numberOfTimeFrames > 0));
    if (valid.length > 0) {
      const ref = valid[0]!;
      const nf = ref.numberOfFrequencyBands;
      const totalCols = valid.reduce((s, sg) => s + sg.numberOfTimeFrames, 0);
      const power = new Array<number>(nf * totalCols);
      let maxPower = 0;
      let colOffset = 0;
      for (const sg of valid) {
        const cols = sg.numberOfTimeFrames;
        const bands = Math.min(nf, sg.numberOfFrequencyBands);
        for (let b = 0; b < bands; b++) {
          for (let col = 0; col < cols; col++) {
            const p = sg.power[b * cols + col] ?? 0;
            power[b * totalCols + colOffset + col] = p;
            if (p > maxPower) maxPower = p;
          }
        }
        colOffset += cols;
      }
      result.spectrogram = {
        t1: ref.t1,
        dt: ref.dt,
        numberOfTimeFrames: totalCols,
        f1: ref.f1,
        df: ref.df,
        numberOfFrequencyBands: nf,
        maxPower,
        power,
      };
    } else {
      result.spectrogram = {
        t1: 0,
        dt: 0,
        numberOfTimeFrames: 0,
        f1: 0,
        df: 0,
        numberOfFrequencyBands: 0,
        maxPower: 0,
        power: [],
      };
    }
  }

  const mergeFb = (pick: (c: AudioChunkAnalysisResult) => FilterBankMatrix | undefined, fallbackScale: 'mel' | 'bark'): FilterBankMatrix | undefined => {
    const all = chunks.map(pick);
    if (!all.some((x) => x !== undefined)) return undefined;
    const valid = all.filter((x): x is FilterBankMatrix =>
      Boolean(x && x.numberOfTimeFrames > 0),
    );
    if (valid.length === 0) {
      return {
        scale: fallbackScale,
        t1: 0,
        dt: 0,
        numberOfTimeFrames: 0,
        f1: 0,
        df: 0,
        numberOfFilters: 0,
        values: [],
      };
    }
    const ref = valid[0]!;
    const nf = ref.numberOfFilters;
    const totalCols = valid.reduce((s, fb) => s + fb.numberOfTimeFrames, 0);
    const values = new Array<number>(nf * totalCols);
    let colOffset = 0;
    for (const fb of valid) {
      const cols = fb.numberOfTimeFrames;
      const bands = Math.min(nf, fb.numberOfFilters);
      for (let b = 0; b < bands; b++) {
        for (let col = 0; col < cols; col++) {
          values[b * totalCols + colOffset + col] = fb.values[b * cols + col] ?? -300;
        }
      }
      colOffset += cols;
    }
    return {
      scale: ref.scale,
      t1: ref.t1,
      dt: ref.dt,
      numberOfTimeFrames: totalCols,
      f1: ref.f1,
      df: ref.df,
      numberOfFilters: nf,
      values,
    };
  };

  const melMerged = mergeFb((c) => c.melSpectrogram, 'mel');
  if (melMerged) result.melSpectrogram = melMerged;

  const barkMerged = mergeFb((c) => c.barkSpectrogram, 'bark');
  if (barkMerged) result.barkSpectrogram = barkMerged;

  if (chunks.some((c) => c.mfcc !== undefined)) {
    const first = chunks.find((c) => c.mfcc && c.mfcc.frames.length > 0)?.mfcc;
    const frames = [];
    for (const c of chunks) {
      if (c.mfcc) frames.push(...c.mfcc.frames);
    }
    result.mfcc = {
      t1: frames[0]?.time ?? first?.t1 ?? 0,
      dt: first?.dt ?? 0,
      fminMel: first?.fminMel ?? 0,
      fmaxMel: first?.fmaxMel ?? 0,
      frames,
    };
  }

  return result;
}

/**
 * Stream overlap-save chunked acoustic analyses as an `AsyncGenerator`,
 * emitting progress metadata via `onProgress` / `onChunk` and yielding
 * to the event loop between chunks unless `yieldBetweenChunks: false`.
 */
export async function* streamLongAudio(
  engine: NganEngine,
  samples: SampleArray,
  sampleRate: number,
  options: LongAudioAnalysisOptions = {},
): AsyncGenerator<AudioChunkAnalysisResult, void, unknown> {
  if (options.signal?.aborted) {
    throw createAbortError();
  }
  const totalSamples = samples.length;
  const descriptors = planAudioChunks(totalSamples, sampleRate, options);
  const totalDurationSeconds = sampleRate > 0 ? totalSamples / sampleRate : 0;
  const tStart = performance.now();

  for (const desc of descriptors) {
    if (options.signal?.aborted) {
      throw createAbortError();
    }
    const chunkResult = analyzeAudioChunk(
      engine,
      samples,
      sampleRate,
      desc,
      options,
    );
    const processedSamples = desc.coreEndSample;
    const processedDurationSeconds =
      sampleRate > 0 ? processedSamples / sampleRate : 0;
    const percent =
      totalSamples > 0 ? (processedSamples / totalSamples) * 100 : 100;
    const elapsedMs = performance.now() - tStart;
    const estimatedRemainingMs =
      processedSamples > 0 && processedSamples < totalSamples
        ? elapsedMs * ((totalSamples - processedSamples) / processedSamples)
        : 0;

    const progress: LongAudioProgress = {
      chunkIndex: desc.chunkIndex,
      totalChunks: desc.totalChunks,
      chunkStartTime: desc.coreStartTime,
      chunkEndTime: desc.coreEndTime,
      processedSamples,
      totalSamples,
      processedDurationSeconds,
      totalDurationSeconds,
      percent,
      elapsedMs,
      estimatedRemainingMs,
    };

    options.onProgress?.(progress);
    options.onChunk?.(chunkResult, progress);
    yield chunkResult;

    if (
      options.yieldBetweenChunks !== false &&
      desc.chunkIndex + 1 < desc.totalChunks
    ) {
      await yieldToEventLoop();
    }
  }
}

/**
 * Analyze long audio recordings using overlap-save chunking with progress
 * reporting (`onProgress`, `onChunk`), optional cancellation (`AbortSignal`),
 * and stitched full-recording tiers.
 */
export async function analyzeLongAudio(
  engine: NganEngine,
  samples: SampleArray,
  sampleRate: number,
  options: LongAudioAnalysisOptions = {},
): Promise<LongAudioAnalysisResult> {
  const chunks: AudioChunkAnalysisResult[] = [];
  for await (const chunk of streamLongAudio(engine, samples, sampleRate, options)) {
    chunks.push(chunk);
  }
  const totalDuration = sampleRate > 0 ? samples.length / sampleRate : 0;
  if (options.mergeResults === false) {
    return {
      sampleRate,
      duration: totalDuration,
      totalChunks: chunks.length,
      chunks,
    };
  }
  return mergeChunkAnalyses(chunks, sampleRate, totalDuration);
}
