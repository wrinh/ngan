// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import {
  analyzeLongAudio as runLongAudio,
  streamLongAudio as runStreamLongAudio,
} from './chunked.js';
import { loadNganWasm } from './loader.js';
import { NganStreamSession, startMicrophoneStream } from './stream.js';
import type {
  AcousticAnalysis,
  AnalyzeAllOptions,
  AudioChunkAnalysisResult,
  CppsAnalysis,
  CppsOptions,
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
  MfccOptions,
  MfccResult,
  MicrophoneStreamHandle,
  MicrophoneStreamOptions,
  NganInitOptions,
  NganWasmExports,
  PitchOptions,
  PitchTier,
  PsolaOptions,
  SampleArray,
  SegmentSummary,
  SpectralAnalysis,
  SpectralOptions,
  Spectrogram,
  SpectrogramOptions,
  StreamSessionOptions,
  TextGridAnalysisOptions,
  VoiceReport,
  VoiceReportOptions,
} from './types.js';

export * from './types.js';
export * from './scales.js';
export { loadNganWasm } from './loader.js';
export { decodeAudio, extractMonoSamples, resampleSinc } from './audio.js';
export { Float64RingBuffer } from './ring-buffer.js';
export { NganStreamSession, startMicrophoneStream } from './stream.js';
export {
  NGAN_WORKLET_PROCESSOR_NAME,
  getWorkletProcessorSource,
  createWorkletModuleUrl,
} from './worklet-processor.js';
export {
  planAudioChunks,
  analyzeAudioChunk,
  mergeChunkAnalyses,
  streamLongAudio,
  analyzeLongAudio,
} from './chunked.js';
export { NganWorkerClient, createNganWorker } from './worker.js';

/**
 * High-level TypeScript wrapper around the `ngan` WebAssembly GC engine.
 */
export class NganEngine {
  readonly exports: NganWasmExports;

  constructor(exports: NganWasmExports) {
    this.exports = exports;
  }

  /**
   * Copy `samples` into the active WASM sample buffer (`state.samples`)
   * without string/CSV conversion overhead.
   */
  writeSamples(samples: SampleArray): number {
    const len = samples.length;
    const allocated = this.exports.alloc_samples(len);
    for (let i = 0; i < allocated; i++) {
      this.exports.set_sample(i, samples[i] ?? 0);
    }
    return allocated;
  }

  /** Praat `To Intensity...` on the active WASM sample buffer. */
  analyzeActiveIntensity(
    sampleRate: number,
    options: IntensityOptions = {},
  ): IntensityTier {
    const json = this.exports.analyze_intensity_json(
      sampleRate,
      options.minPitch ?? 100.0,
      options.timeStep ?? 0.0,
      options.subtractMean === false ? 0 : 1,
    );
    return JSON.parse(json) as IntensityTier;
  }

  /** Praat `To Intensity...`. */
  analyzeIntensity(
    samples: SampleArray,
    sampleRate: number,
    options: IntensityOptions = {},
  ): IntensityTier {
    this.writeSamples(samples);
    return this.analyzeActiveIntensity(sampleRate, options);
  }

  /** Praat `To Pitch (ac/cc/filtered ac)...` on the active WASM sample buffer. */
  analyzeActivePitch(
    sampleRate: number,
    options: PitchOptions = {},
  ): PitchTier {
    if (options.method === 'filtered_ac') {
      const json = this.exports.analyze_pitch_filtered_ac_json(
        sampleRate,
        options.timeStep ?? 0.0,
        options.pitchFloor ?? 50.0,
        options.pitchCeiling ?? 800.0,
        options.maxCandidates ?? 15,
        options.veryAccurate ? 1 : 0,
        options.attenuationAtTop ?? 0.03,
        options.voicingThreshold ?? 0.5,
        options.silenceThreshold ?? 0.09,
        options.octaveCost ?? 0.055,
        options.octaveJumpCost ?? 0.35,
        options.voicedUnvoicedCost ?? 0.14,
      );
      return JSON.parse(json) as PitchTier;
    }
    const json = this.exports.analyze_pitch_json(
      sampleRate,
      options.timeStep ?? 0.0,
      options.pitchFloor ?? 75.0,
      options.pitchCeiling ?? 600.0,
      options.maxCandidates ?? 15,
      options.voicingThreshold ?? 0.45,
      options.silenceThreshold ?? 0.03,
      options.octaveCost ?? 0.01,
      options.octaveJumpCost ?? 0.35,
      options.voicedUnvoicedCost ?? 0.14,
      options.method === 'cc' ? 1 : 0,
    );
    return JSON.parse(json) as PitchTier;
  }

  /** Praat `To Pitch (ac/cc)...`. */
  analyzePitch(
    samples: SampleArray,
    sampleRate: number,
    options: PitchOptions = {},
  ): PitchTier {
    this.writeSamples(samples);
    return this.analyzeActivePitch(sampleRate, options);
  }

  /** Praat `To Formant (burg)...` (plus optional `Formant: Track...`) on the active WASM sample buffer. */
  analyzeActiveFormants(
    sampleRate: number,
    options: FormantOptions = {},
  ): FormantTier {
    const json = this.exports.analyze_formants_json(
      sampleRate,
      options.timeStep ?? 0.0,
      options.maxNumFormants ?? 5,
      options.maxFormantFreq ?? 5500.0,
      options.windowLength ?? 0.025,
      options.preEmphasisFrom ?? 50.0,
      options.track ? 1 : 0,
      options.numTracks ?? 3,
      options.refF1 ?? 550.0,
      options.refF2 ?? 1650.0,
      options.refF3 ?? 2750.0,
      options.refF4 ?? 3850.0,
      options.refF5 ?? 4950.0,
    );
    return JSON.parse(json) as FormantTier;
  }

  /** Praat `To Formant (burg)...` (and optional `Formant: Track...`). */
  analyzeFormants(
    samples: SampleArray,
    sampleRate: number,
    options: FormantOptions = {},
  ): FormantTier {
    this.writeSamples(samples);
    return this.analyzeActiveFormants(sampleRate, options);
  }

  /** Praat `To Harmonicity (ac/cc)...` on the active WASM sample buffer. */
  analyzeActiveHarmonicity(
    sampleRate: number,
    options: HarmonicityOptions = {},
  ): HarmonicityTier {
    const json = this.exports.analyze_harmonicity_json(
      sampleRate,
      options.timeStep ?? 0.01,
      options.minPitch ?? 75.0,
      options.silenceThreshold ?? 0.1,
      options.periodsPerWindow ?? 4.5,
      options.method === 'cc' ? 1 : 0,
    );
    return JSON.parse(json) as HarmonicityTier;
  }

  /** Praat `To Harmonicity (ac/cc)...` (HNR in dB). */
  analyzeHarmonicity(
    samples: SampleArray,
    sampleRate: number,
    options: HarmonicityOptions = {},
  ): HarmonicityTier {
    this.writeSamples(samples);
    return this.analyzeActiveHarmonicity(sampleRate, options);
  }

  /** Praat `To Spectrogram...` on the active WASM sample buffer. */
  analyzeActiveSpectrogram(
    sampleRate: number,
    options: SpectrogramOptions = {},
  ): Spectrogram {
    const json = this.exports.analyze_spectrogram_json(
      sampleRate,
      options.windowLength ?? 0.005,
      options.maximumFrequency ?? 5000.0,
      options.timeStep ?? 0.002,
      options.frequencyStep ?? 20.0,
      options.maxTimeColumns ?? 0,
    );
    return JSON.parse(json) as Spectrogram;
  }

  /** Praat `To Spectrogram...`. */
  analyzeSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: SpectrogramOptions = {},
  ): Spectrogram {
    this.writeSamples(samples);
    return this.analyzeActiveSpectrogram(sampleRate, options);
  }

  /** Praat glottal pulse, jitter, shimmer, voice breaks, and mean HNR voice report. */
  analyzeVoiceReport(
    samples: SampleArray,
    sampleRate: number,
    options: VoiceReportOptions = {},
  ): VoiceReport {
    this.writeSamples(samples);
    const json = this.exports.analyze_voice_report_json(
      sampleRate,
      options.pitchFloor ?? 75.0,
      options.pitchCeiling ?? 600.0,
      options.maxPeriodFactor ?? 1.3,
      options.maxAmplitudeFactor ?? 1.6,
    );
    return JSON.parse(json) as VoiceReport;
  }

  /** Praat `To PowerCepstrogram...` + `Get CPPS...`. */
  analyzeCpps(
    samples: SampleArray,
    sampleRate: number,
    options: CppsOptions = {},
  ): CppsAnalysis {
    this.writeSamples(samples);
    const json = this.exports.analyze_cepstrogram_cpps_json(
      sampleRate,
      options.pitchFloor ?? 60.0,
      options.timeStep ?? 0.002,
      options.maximumFrequency ?? 5000.0,
      options.preEmphasisFrom ?? 50.0,
      options.subtractTiltBeforeSmoothing === false ? 0 : 1,
      options.timeAveragingWindow ?? 0.01,
      options.quefrencyAveragingWindow ?? 0.001,
      options.peakSearchPitchFloor ?? 60.0,
      options.peakSearchPitchCeiling ?? 330.0,
      options.includeCepstrogram ? 1 : 0,
      options.maxTimeColumns ?? 0,
    );
    return JSON.parse(json) as CppsAnalysis;
  }

  /** Praat `To MFCC...` on the active WASM sample buffer. */
  analyzeActiveMfcc(
    sampleRate: number,
    options: MfccOptions = {},
  ): MfccResult {
    const json = this.exports.analyze_mfcc_json(
      sampleRate,
      options.numberOfCoefficients ?? 12,
      options.windowLength ?? 0.015,
      options.timeStep ?? 0.005,
      options.positionOfFirstFilter ?? 100.0,
      options.distanceBetweenFilters ?? 100.0,
      options.maximumFrequency ?? 0.0,
    );
    return JSON.parse(json) as MfccResult;
  }

  /** Praat `To MFCC...`. */
  analyzeMfcc(
    samples: SampleArray,
    sampleRate: number,
    options: MfccOptions = {},
  ): MfccResult {
    this.writeSamples(samples);
    return this.analyzeActiveMfcc(sampleRate, options);
  }

  /** Praat `To MelSpectrogram...` on the active WASM sample buffer. */
  analyzeActiveMelSpectrogram(
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): FilterBankMatrix {
    const json = this.exports.analyze_filterbank_spectrogram_json(
      sampleRate,
      0,
      options.windowLength ?? 0.015,
      options.timeStep ?? 0.005,
      options.positionOfFirstFilter ?? 100.0,
      options.distanceBetweenFilters ?? 100.0,
      options.maximumFrequency ?? 0.0,
      options.maxTimeColumns ?? 0,
    );
    return JSON.parse(json) as FilterBankMatrix;
  }

  /** Praat `To MelSpectrogram...`. */
  analyzeMelSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): FilterBankMatrix {
    this.writeSamples(samples);
    return this.analyzeActiveMelSpectrogram(sampleRate, options);
  }

  /** Praat `To BarkSpectrogram...` on the active WASM sample buffer. */
  analyzeActiveBarkSpectrogram(
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): FilterBankMatrix {
    const json = this.exports.analyze_filterbank_spectrogram_json(
      sampleRate,
      1,
      options.windowLength ?? 0.015,
      options.timeStep ?? 0.005,
      options.positionOfFirstFilter ?? 1.0,
      options.distanceBetweenFilters ?? 1.0,
      options.maximumFrequency ?? 0.0,
      options.maxTimeColumns ?? 0,
    );
    return JSON.parse(json) as FilterBankMatrix;
  }

  /** Praat `To BarkSpectrogram...`. */
  analyzeBarkSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): FilterBankMatrix {
    this.writeSamples(samples);
    return this.analyzeActiveBarkSpectrogram(sampleRate, options);
  }

  /** Praat TD-PSOLA pitch & duration manipulation (`To Manipulation` + OLA resynthesis). */
  manipulatePsola(
    samples: SampleArray,
    sampleRate: number,
    options: PsolaOptions = {},
  ): Float64Array {
    this.writeSamples(samples);
    const pitchCsv = (options.pitchPoints ?? [])
      .map((p) => `${p.time}:${p.frequency}`)
      .join(' ');
    const durCsv = (options.durationPoints ?? [])
      .map((d) => `${d.time}:${d.relativeDuration}`)
      .join(' ');
    const outLen = this.exports.manipulate_psola(
      sampleRate,
      pitchCsv,
      durCsv,
      options.pitchScale ?? 1.0,
      options.pitchShiftSemitones ?? 0.0,
      options.durationFactor ?? 1.0,
      options.pitchFloor ?? 75.0,
      options.pitchCeiling ?? 600.0,
    );
    const out = new Float64Array(outLen);
    for (let i = 0; i < outLen; i++) {
      out[i] = this.exports.get_out_sample(i);
    }
    return out;
  }

  /** Praat `To Ltas...` and `Spectrum: Get centre of gravity...`. */
  analyzeSpectral(
    samples: SampleArray,
    sampleRate: number,
    options: SpectralOptions = {},
  ): SpectralAnalysis {
    this.writeSamples(samples);
    const json = this.exports.analyze_spectral_json(
      sampleRate,
      options.bandwidth ?? 100.0,
      options.power ?? 2.0,
      options.fmin ?? 0.0,
      options.fmax ?? 0.0,
    );
    return JSON.parse(json) as SpectralAnalysis;
  }

  /** Parse a Praat `.TextGrid` string and summarize acoustic segments. */
  analyzeTextGridSegments(
    samples: SampleArray,
    sampleRate: number,
    textGridSource: string,
    options: TextGridAnalysisOptions = {},
  ): SegmentSummary[] {
    this.writeSamples(samples);
    const json = this.exports.analyze_textgrid_json(
      sampleRate,
      textGridSource,
      options.tierName ?? '',
      options.minPitch ?? 100.0,
      options.pitchFloor ?? 75.0,
      options.pitchCeiling ?? 600.0,
      options.maxNumFormants ?? 5,
      options.maxFormantFreq ?? 5500.0,
      options.useFormantTracking ? 1 : 0,
    );
    const parsed = JSON.parse(json) as {
      segments?: SegmentSummary[];
      error?: string;
    };
    if (parsed.error) {
      throw new Error(parsed.error);
    }
    return parsed.segments ?? [];
  }

  /** Run intensity, pitch, formants (and optional spectrogram) on the active WASM sample buffer. */
  analyzeActiveBufferAll(
    sampleCount: number,
    sampleRate: number,
    options: AnalyzeAllOptions = {},
  ): AcousticAnalysis {
    const intensity = this.analyzeActiveIntensity(sampleRate, options.intensity);
    const pitch = this.analyzeActivePitch(sampleRate, options.pitch);
    const formants = this.analyzeActiveFormants(sampleRate, options.formants);
    const out: AcousticAnalysis = {
      sampleRate,
      duration: sampleRate > 0 ? sampleCount / sampleRate : 0,
      intensity,
      pitch,
      formants,
    };
    if (options.spectrogram) {
      const sgOpts =
        typeof options.spectrogram === 'object' ? options.spectrogram : {};
      out.spectrogram = this.analyzeActiveSpectrogram(sampleRate, sgOpts);
    }
    return out;
  }

  /** Run intensity, pitch, formants (and optional spectrogram) in one pass. */
  analyzeAll(
    samples: SampleArray,
    sampleRate: number,
    options: AnalyzeAllOptions = {},
  ): AcousticAnalysis {
    const n = this.writeSamples(samples);
    return this.analyzeActiveBufferAll(n, sampleRate, options);
  }

  /** Legacy CSV boundary preserved for compatibility with older callers. */
  analyzeCsv(samplesCsv: string, sampleRate: number): unknown {
    return JSON.parse(this.exports.analyze_csv(samplesCsv, sampleRate));
  }

  /** Create a real-time sliding-window streaming session backed by the WASM ring buffer. */
  createStreamSession(options: StreamSessionOptions = {}): NganStreamSession {
    return new NganStreamSession(this, options);
  }

  /** Start live microphone analysis via `AudioWorklet` + WASM ring buffer. */
  startMicrophoneStream(
    options: MicrophoneStreamOptions = {},
  ): Promise<MicrophoneStreamHandle> {
    return startMicrophoneStream(this, options);
  }

  /** Analyze long audio recordings using overlap-save chunking and progress callbacks. */
  analyzeLongAudio(
    samples: SampleArray,
    sampleRate: number,
    options: LongAudioAnalysisOptions = {},
  ): Promise<LongAudioAnalysisResult> {
    return runLongAudio(this, samples, sampleRate, options);
  }

  /** Stream overlap-save chunked analyses for long audio as an `AsyncGenerator`. */
  streamLongAudio(
    samples: SampleArray,
    sampleRate: number,
    options: LongAudioAnalysisOptions = {},
  ): AsyncGenerator<AudioChunkAnalysisResult, void, unknown> {
    return runStreamLongAudio(this, samples, sampleRate, options);
  }
}

/**
 * Load the `ngan` WebAssembly GC module and return a ready-to-use `NganEngine`.
 */
export async function createNgan(
  options: NganInitOptions = {},
): Promise<NganEngine> {
  const exports = await loadNganWasm(options);
  return new NganEngine(exports);
}
