// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

/** Accepted numeric sample buffer types for acoustic analysis. */
export type SampleArray = Float32Array | Float64Array | readonly number[];

/** Single pitch measurement frame. `frequency` is `null` when unvoiced. */
export interface PitchFrame {
  time: number;
  frequency: number | null;
  strength: number;
}

/** Evenly sampled pitch contour (Praat `Pitch`). */
export interface PitchTier {
  t1: number;
  dt: number;
  frames: PitchFrame[];
}

/** Options mirroring Praat `To Pitch (ac/cc/filtered ac)...`. */
export interface PitchOptions {
  timeStep?: number;
  pitchFloor?: number;
  pitchCeiling?: number;
  maxCandidates?: number;
  veryAccurate?: boolean;
  attenuationAtTop?: number;
  voicingThreshold?: number;
  silenceThreshold?: number;
  octaveCost?: number;
  octaveJumpCost?: number;
  voicedUnvoicedCost?: number;
  method?: 'ac' | 'cc' | 'filtered_ac';
}

/** Single formant resonance peak (Hz) and bandwidth (Hz). */
export interface FormantValue {
  frequency: number;
  bandwidth: number;
}

/** Formant peaks for a single frame, sorted by ascending frequency (F1 < F2 < ...). */
export interface FormantFrame {
  time: number;
  formants: FormantValue[];
}

/** Evenly sampled formant contour (Praat `Formant`). */
export interface FormantTier {
  t1: number;
  dt: number;
  frames: FormantFrame[];
}

/** Options mirroring Praat `To Formant (burg)...` and optional `Formant: Track...`. */
export interface FormantOptions {
  timeStep?: number;
  maxNumFormants?: number;
  maxFormantFreq?: number;
  windowLength?: number;
  preEmphasisFrom?: number;
  track?: boolean;
  numTracks?: number;
  refF1?: number;
  refF2?: number;
  refF3?: number;
  refF4?: number;
  refF5?: number;
}

/** Evenly sampled intensity contour in dB SPL (re 2e-5 Pa). */
export interface IntensityTier {
  t1: number;
  dt: number;
  values: number[];
}

/** Options mirroring Praat `To Intensity...`. */
export interface IntensityOptions {
  minPitch?: number;
  timeStep?: number;
  subtractMean?: boolean;
}

/** Evenly sampled Harmonics-to-Noise Ratio (HNR) contour in dB (`null` = unvoiced). */
export interface HarmonicityTier {
  t1: number;
  dt: number;
  values: (number | null)[];
}

/** Options mirroring Praat `To Harmonicity (ac/cc)...`. */
export interface HarmonicityOptions {
  timeStep?: number;
  minPitch?: number;
  silenceThreshold?: number;
  periodsPerWindow?: number;
  method?: 'ac' | 'cc';
}

/** Band-major power spectral density grid in Pa^2/Hz (Praat `Spectrogram`). */
export interface Spectrogram {
  t1: number;
  dt: number;
  numberOfTimeFrames: number;
  f1: number;
  df: number;
  numberOfFrequencyBands: number;
  maxPower: number;
  /** Band-major linear power values: `index = band * numberOfTimeFrames + frame`. */
  power: number[];
}

/** Options mirroring Praat `To Spectrogram...`. */
export interface SpectrogramOptions {
  windowLength?: number;
  maximumFrequency?: number;
  timeStep?: number;
  frequencyStep?: number;
  /** Optional time-axis cap; averages linear power across stride columns when exceeded. */
  maxTimeColumns?: number;
}

/** Cycle-to-cycle frequency perturbation metrics (Praat `Get jitter (...)`). */
export interface JitterMetrics {
  localRel: number | null;
  localAbs: number | null;
  rap: number | null;
  ppq5: number | null;
  ddp: number | null;
}

/** Cycle-to-cycle amplitude perturbation metrics (Praat `Get shimmer (...)`). */
export interface ShimmerMetrics {
  localRel: number | null;
  localDb: number | null;
  apq3: number | null;
  apq5: number | null;
  apq11: number | null;
  dda: number | null;
}

/** Combined voice quality & perturbation report. */
export interface VoiceReport {
  pulses: number[];
  meanPitchHz: number | null;
  meanHnrDb: number | null;
  fractionLocallyUnvoiced: number;
  numberOfVoiceBreaks: number;
  degreeOfVoiceBreaks: number;
  jitter: JitterMetrics;
  shimmer: ShimmerMetrics;
}

/** Options for voice perturbation analysis. */
export interface VoiceReportOptions {
  pitchFloor?: number;
  pitchCeiling?: number;
  maxPeriodFactor?: number;
  maxAmplitudeFactor?: number;
}

/** Quefrency-major power cepstrogram grid (Praat `PowerCepstrogram`). */
export interface PowerCepstrogram {
  t1: number;
  dt: number;
  numberOfTimeFrames: number;
  q1: number;
  dq: number;
  numberOfQuefrencyBins: number;
  maxPower: number;
  /** Quefrency-major linear cepstral power: `index = qBin * numberOfTimeFrames + frame`. */
  power: number[];
}

/** Result of `To PowerCepstrogram...` + `Get CPPS...`. */
export interface CppsAnalysis {
  cppsDb: number | null;
  cepstrogram: PowerCepstrogram | null;
}

/** Options mirroring Praat `To PowerCepstrogram...` + `Get CPPS...`. */
export interface CppsOptions {
  pitchFloor?: number;
  timeStep?: number;
  maximumFrequency?: number;
  preEmphasisFrom?: number;
  subtractTiltBeforeSmoothing?: boolean;
  timeAveragingWindow?: number;
  quefrencyAveragingWindow?: number;
  peakSearchPitchFloor?: number;
  peakSearchPitchCeiling?: number;
  includeCepstrogram?: boolean;
  maxTimeColumns?: number;
}

/** Filter-bank spectrogram grid (Mel or Bark) in dB (`index = filter * numberOfTimeFrames + frame`). */
export interface FilterBankMatrix {
  scale: 'mel' | 'bark';
  t1: number;
  dt: number;
  numberOfTimeFrames: number;
  f1: number;
  df: number;
  numberOfFilters: number;
  values: number[];
}

/** Options mirroring Praat `To MelSpectrogram...` / `To BarkSpectrogram...`. */
export interface FilterBankSpectrogramOptions {
  windowLength?: number;
  timeStep?: number;
  positionOfFirstFilter?: number;
  distanceBetweenFilters?: number;
  maximumFrequency?: number;
  maxTimeColumns?: number;
}

/** Single frame of Mel-Frequency Cepstral Coefficients. */
export interface MfccFrame {
  time: number;
  c0: number;
  coeffs: number[];
}

/** MFCC analysis result matching Praat `MFCC`. */
export interface MfccResult {
  t1: number;
  dt: number;
  fminMel: number;
  fmaxMel: number;
  frames: MfccFrame[];
}

/** Options mirroring Praat `To MFCC...`. */
export interface MfccOptions {
  numberOfCoefficients?: number;
  windowLength?: number;
  timeStep?: number;
  positionOfFirstFilter?: number;
  distanceBetweenFilters?: number;
  maximumFrequency?: number;
}

/** Pitch control point for TD-PSOLA manipulation. */
export interface PitchPoint {
  time: number;
  frequency: number;
}

/** Relative duration control point for TD-PSOLA manipulation. */
export interface DurationPoint {
  time: number;
  relativeDuration: number;
}

/** Options for TD-PSOLA pitch/duration resynthesis (`manipulatePsola`). */
export interface PsolaOptions {
  pitchPoints?: PitchPoint[];
  durationPoints?: DurationPoint[];
  pitchScale?: number;
  pitchShiftSemitones?: number;
  durationFactor?: number;
  pitchFloor?: number;
  pitchCeiling?: number;
}

/** Long-Term Average Spectrum (dB/Hz re 2e-5 Pa). */
export interface Ltas {
  f1: number;
  df: number;
  values: number[];
}

/** Combined LTAS and spectral Center of Gravity result. */
export interface SpectralAnalysis {
  ltas: Ltas;
  centerOfGravityHz: number | null;
}

/** Options for `analyzeSpectral`. */
export interface SpectralOptions {
  bandwidth?: number;
  power?: number;
  fmin?: number;
  fmax?: number;
}

/** Acoustic measurement sampled at a proportional position within a TextGrid interval. */
export interface SegmentTrajectoryPoint {
  proportion: number;
  time: number;
  f0: number | null;
  f1: number | null;
  f2: number | null;
  f3: number | null;
  intensity: number | null;
}

/** Segment-level summary produced from a Praat `.TextGrid` interval tier. */
export interface SegmentSummary {
  tierName: string;
  index: number;
  label: string;
  xmin: number;
  xmax: number;
  duration: number;
  f0Mean: number | null;
  f0Min: number | null;
  f0Max: number | null;
  f0Sd: number | null;
  voicedFraction: number;
  f1Mean: number | null;
  f2Mean: number | null;
  f3Mean: number | null;
  intensityMean: number | null;
  intensityMax: number | null;
  trajectory: SegmentTrajectoryPoint[];
}

/** Options for segment summarization with a Praat `.TextGrid`. */
export interface TextGridAnalysisOptions {
  tierName?: string;
  minPitch?: number;
  pitchFloor?: number;
  pitchCeiling?: number;
  maxNumFormants?: number;
  maxFormantFreq?: number;
  useFormantTracking?: boolean;
}

/** Combined multi-tier acoustic analysis output. */
export interface AcousticAnalysis {
  sampleRate: number;
  duration: number;
  intensity: IntensityTier;
  pitch: PitchTier;
  formants: FormantTier;
  spectrogram?: Spectrogram;
}

/** Options for `analyzeAll`. */
export interface AnalyzeAllOptions {
  intensity?: IntensityOptions;
  pitch?: PitchOptions;
  formants?: FormantOptions;
  spectrogram?: boolean | SpectrogramOptions;
}

/** Low-latency sliding-window frame emitted during real-time streaming. */
export interface StreamFrameResult {
  time: number;
  totalSamples: number;
  windowSamples: number;
  windowDuration: number;
  rms: number;
  intensityDb: number | null;
  pitch: {
    frequency: number | null;
    strength: number;
  };
  formants: FormantValue[];
}

/** Configuration for `NganStreamSession`. */
export interface StreamSessionOptions {
  sampleRate?: number;
  historyDurationSeconds?: number;
  windowDurationSeconds?: number;
  hopDurationSeconds?: number;
  minPitch?: number;
  pitchFloor?: number;
  pitchCeiling?: number;
  maxNumFormants?: number;
  maxFormantFreq?: number;
  onFrame?: (frame: StreamFrameResult) => void;
}

/** Configuration for `startMicrophoneStream`. */
export interface MicrophoneStreamOptions extends StreamSessionOptions {
  audioContext?: AudioContext;
  mediaStream?: MediaStream;
  audioConstraints?: boolean | MediaTrackConstraints;
  workletUrl?: string | URL;
  onChunk?: (samples: Float32Array, sampleRate: number) => void;
  onError?: (error: unknown) => void;
}

/** Controller returned by `startMicrophoneStream`. */
export interface MicrophoneStreamHandle {
  readonly session: {
    pushSamples(chunk: SampleArray): StreamFrameResult[];
    analyzeLatestFrame(): StreamFrameResult | null;
    getRecentSamples(durationSeconds?: number): Float64Array;
    analyzeRecentHistory(
      durationSeconds?: number,
      options?: AnalyzeAllOptions,
    ): AcousticAnalysis;
    reset(): void;
  };
  readonly audioContext: AudioContext;
  readonly mediaStream: MediaStream;
  readonly workletNode: AudioWorkletNode;
  readonly sampleRate: number;
  pause(): void;
  resume(): void;
  stop(): Promise<void>;
}

/** Options for Web Audio decoding & resampling bridge (`decodeAudio`). */
export interface DecodeAudioOptions {
  /** Target sample rate in Hz (default `16000`). Pass `0` or `null` to keep native rate. */
  targetSampleRate?: number | null;
  /** `'mono'` averages all channels; a numeric index extracts that single channel. */
  channel?: 'mono' | number;
  /** Optional clip ceiling in seconds. */
  maxDurationSeconds?: number;
  /** Subtract DC offset (sample mean) after extraction. */
  removeDc?: boolean;
}

/** Decoded & optionally resampled mono audio payload ready for `ngan`. */
export interface DecodedAudio {
  samples: Float32Array;
  sampleRate: number;
  duration: number;
  sourceSampleRate: number;
  numberOfChannels: number;
}

/** Supported sources for loading the `ngan` WebAssembly GC module. */
export type WasmSource =
  | BufferSource
  | Response
  | URL
  | string
  | WebAssembly.Module;

/** Options for `createNgan` / `loadNganWasm`. */
export interface NganInitOptions {
  wasmSource?: WasmSource;
}

/** Progress payload emitted during chunked/streaming long-audio analysis. */
export interface LongAudioProgress {
  chunkIndex: number;
  totalChunks: number;
  chunkStartTime: number;
  chunkEndTime: number;
  processedSamples: number;
  totalSamples: number;
  processedDurationSeconds: number;
  totalDurationSeconds: number;
  percent: number;
  elapsedMs: number;
  estimatedRemainingMs: number;
}

/** Sample/time bounds for one overlap-save analysis chunk. */
export interface AudioChunkDescriptor {
  chunkIndex: number;
  totalChunks: number;
  coreStartSample: number;
  coreEndSample: number;
  sliceStartSample: number;
  sliceEndSample: number;
  coreStartTime: number;
  coreEndTime: number;
  sliceStartTime: number;
  sliceEndTime: number;
}

/** Acoustic analysis output for one core chunk window (timestamps are absolute). */
export interface AudioChunkAnalysisResult {
  chunkIndex: number;
  totalChunks: number;
  startTime: number;
  endTime: number;
  duration: number;
  intensity?: IntensityTier;
  pitch?: PitchTier;
  formants?: FormantTier;
  harmonicity?: HarmonicityTier;
  spectrogram?: Spectrogram;
  melSpectrogram?: FilterBankMatrix;
  barkSpectrogram?: FilterBankMatrix;
  mfcc?: MfccResult;
}

/** Options for overlap-save chunked / streaming long-audio analysis. */
export interface LongAudioAnalysisOptions {
  /** Core duration per chunk in seconds (default `30.0`). */
  chunkDurationSeconds?: number;
  /** Overlap padding added on each side of a chunk in seconds (default `0.5`). */
  overlapDurationSeconds?: number;
  /** Yield to the event loop between chunks when running on main thread (default `true`). */
  yieldBetweenChunks?: boolean;
  /** Stitch per-chunk results into continuous full-duration tiers (default `true`). */
  mergeResults?: boolean;
  /** Allow transferring typed array buffers to a Web Worker when possible (default `false`). */
  transfer?: boolean;
  /** Optional abort signal to cancel long-audio analysis mid-stream. */
  signal?: AbortSignal;
  intensity?: boolean | IntensityOptions;
  pitch?: boolean | PitchOptions;
  formants?: boolean | FormantOptions;
  harmonicity?: boolean | HarmonicityOptions;
  spectrogram?: boolean | SpectrogramOptions;
  melSpectrogram?: boolean | FilterBankSpectrogramOptions;
  barkSpectrogram?: boolean | FilterBankSpectrogramOptions;
  mfcc?: boolean | MfccOptions;
  onProgress?: (progress: LongAudioProgress) => void;
  onChunk?: (chunk: AudioChunkAnalysisResult, progress: LongAudioProgress) => void;
}

/** Combined result of overlap-save long-audio analysis. */
export interface LongAudioAnalysisResult {
  sampleRate: number;
  duration: number;
  totalChunks: number;
  chunks: AudioChunkAnalysisResult[];
  intensity?: IntensityTier;
  pitch?: PitchTier;
  formants?: FormantTier;
  harmonicity?: HarmonicityTier;
  spectrogram?: Spectrogram;
  melSpectrogram?: FilterBankMatrix;
  barkSpectrogram?: FilterBankMatrix;
  mfcc?: MfccResult;
}

/** Minimal worker-like port interface accepted by `createNganWorker`. */
export interface WorkerLike {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  terminate?: () => void | Promise<unknown>;
  addEventListener?: (type: string, listener: (event: any) => void) => void;
  removeEventListener?: (type: string, listener: (event: any) => void) => void;
  on?: (event: string, listener: (arg: any) => void) => void;
  off?: (event: string, listener: (arg: any) => void) => void;
}

/** Options for `createNganWorker`. */
export interface NganWorkerOptions extends NganInitOptions {
  /** Custom module worker script URL (defaults to bundled `./worker-entry.js`). */
  workerUrl?: string | URL;
  /** Pre-created browser `Worker` or Node `worker_threads.Worker` instance. */
  worker?: WorkerLike;
}

/** Raw exported functions from `web/web.mbt` compiled to wasm-gc. */
export interface NganWasmExports extends WebAssembly.Exports {
  analyze_csv(samplesCsv: string, fs: number): string;
  alloc_samples(len: number): number;
  set_sample(index: number, value: number): void;
  get_sample(index: number): number;
  samples_len(): number;
  out_samples_len(): number;
  get_out_sample(index: number): number;
  out_matrix_len(): number;
  get_out_matrix(index: number): number;
  ring_reset(capacity: number): number;
  ring_push(sample: number): void;
  ring_len(): number;
  ring_capacity(): number;
  ring_total_samples(): number;
  ring_copy_recent(windowSamples: number): number;
  analyze_intensity_json(
    fs: number,
    minPitch: number,
    timeStep: number,
    subtractMean: number,
  ): string;
  analyze_pitch_json(
    fs: number,
    timeStep: number,
    pitchFloor: number,
    pitchCeiling: number,
    maxCandidates: number,
    voicingThreshold: number,
    silenceThreshold: number,
    octaveCost: number,
    octaveJumpCost: number,
    voicedUnvoicedCost: number,
    useCc: number,
  ): string;
  analyze_pitch_filtered_ac_json(
    fs: number,
    timeStep: number,
    pitchFloor: number,
    pitchCeiling: number,
    maxCandidates: number,
    veryAccurate: number,
    attenuationAtTop: number,
    voicingThreshold: number,
    silenceThreshold: number,
    octaveCost: number,
    octaveJumpCost: number,
    voicedUnvoicedCost: number,
  ): string;
  analyze_formants_json(
    fs: number,
    timeStep: number,
    maxNumFormants: number,
    maxFormantFreq: number,
    windowLength: number,
    preEmphasisFrom: number,
    track: number,
    numTracks: number,
    refF1: number,
    refF2: number,
    refF3: number,
    refF4: number,
    refF5: number,
  ): string;
  analyze_harmonicity_json(
    fs: number,
    timeStep: number,
    minPitch: number,
    silenceThreshold: number,
    periodsPerWindow: number,
    useCc: number,
  ): string;
  analyze_spectrogram_meta_json(
    fs: number,
    windowLength: number,
    maximumFrequency: number,
    timeStep: number,
    frequencyStep: number,
    maxTimeColumns: number,
  ): string;
  analyze_spectrogram_json(
    fs: number,
    windowLength: number,
    maximumFrequency: number,
    timeStep: number,
    frequencyStep: number,
    maxTimeColumns: number,
  ): string;
  analyze_voice_report_json(
    fs: number,
    pitchFloor: number,
    pitchCeiling: number,
    maxPeriodFactor: number,
    maxAmplitudeFactor: number,
  ): string;
  analyze_cepstrogram_cpps_meta_json(
    fs: number,
    pitchFloor: number,
    timeStep: number,
    maximumFrequency: number,
    preEmphasisFrom: number,
    subtractTiltBeforeSmoothing: number,
    timeAveragingWindow: number,
    quefrencyAveragingWindow: number,
    peakSearchPitchFloor: number,
    peakSearchPitchCeiling: number,
    includeCepstrogram: number,
    maxTimeColumns: number,
  ): string;
  analyze_cepstrogram_cpps_json(
    fs: number,
    pitchFloor: number,
    timeStep: number,
    maximumFrequency: number,
    preEmphasisFrom: number,
    subtractTiltBeforeSmoothing: number,
    timeAveragingWindow: number,
    quefrencyAveragingWindow: number,
    peakSearchPitchFloor: number,
    peakSearchPitchCeiling: number,
    includeCepstrogram: number,
    maxTimeColumns: number,
  ): string;
  analyze_mfcc_json(
    fs: number,
    numberOfCoefficients: number,
    windowLength: number,
    timeStep: number,
    positionOfFirstFilter: number,
    distanceBetweenFilters: number,
    maximumFrequency: number,
  ): string;
  analyze_filterbank_spectrogram_meta_json(
    fs: number,
    useBark: number,
    windowLength: number,
    timeStep: number,
    positionOfFirstFilter: number,
    distanceBetweenFilters: number,
    maximumFrequency: number,
    maxTimeColumns: number,
  ): string;
  analyze_filterbank_spectrogram_json(
    fs: number,
    useBark: number,
    windowLength: number,
    timeStep: number,
    positionOfFirstFilter: number,
    distanceBetweenFilters: number,
    maximumFrequency: number,
    maxTimeColumns: number,
  ): string;
  manipulate_psola(
    fs: number,
    pitchPointsCsv: string,
    durationPointsCsv: string,
    pitchScale: number,
    pitchShiftSemitones: number,
    durationFactor: number,
    pitchFloor: number,
    pitchCeiling: number,
  ): number;
  analyze_spectral_json(
    fs: number,
    bandwidth: number,
    power: number,
    fmin: number,
    fmax: number,
  ): string;
  analyze_textgrid_json(
    fs: number,
    textgridSrc: string,
    tierName: string,
    minPitch: number,
    pitchFloor: number,
    pitchCeiling: number,
    maxNumFormants: number,
    maxFormantFreq: number,
    useFormantTracking: number,
  ): string;
  ring_analyze_frame_json(
    fs: number,
    windowSamples: number,
    minPitch: number,
    pitchFloor: number,
    pitchCeiling: number,
    maxNumFormants: number,
    maxFormantFreq: number,
  ): string;
}
