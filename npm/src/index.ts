// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import { loadNganWasm } from './loader.js';
import { NganStreamSession, startMicrophoneStream } from './stream.js';
import type {
  AcousticAnalysis,
  AnalyzeAllOptions,
  FormantOptions,
  FormantTier,
  HarmonicityOptions,
  HarmonicityTier,
  IntensityOptions,
  IntensityTier,
  MicrophoneStreamHandle,
  MicrophoneStreamOptions,
  NganInitOptions,
  NganWasmExports,
  PitchOptions,
  PitchTier,
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

  /** Praat `To Pitch (ac/cc)...` on the active WASM sample buffer. */
  analyzeActivePitch(
    sampleRate: number,
    options: PitchOptions = {},
  ): PitchTier {
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

  /** Praat glottal pulse, jitter, shimmer, and mean HNR voice report. */
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
