// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { NganEngine } from './index.js';
import type {
  AcousticAnalysis,
  AnalyzeAllOptions,
  MicrophoneStreamHandle,
  MicrophoneStreamOptions,
  NganWasmExports,
  SampleArray,
  StreamFrameResult,
  StreamSessionOptions,
} from './types.js';
import {
  createWorkletModuleUrl,
  NGAN_WORKLET_PROCESSOR_NAME,
} from './worklet-processor.js';

/**
 * Real-time sliding-window acoustic analysis session backed by the WASM-GC
 * ring buffer (`ring_reset`, `ring_push`, `ring_analyze_frame_json`).
 */
export class NganStreamSession {
  readonly engine: NganEngine;
  readonly exports: NganWasmExports;
  readonly sampleRate: number;
  readonly historyDurationSeconds: number;
  readonly windowDurationSeconds: number;
  readonly hopDurationSeconds: number;
  readonly capacitySamples: number;
  readonly windowSamples: number;
  readonly hopSamples: number;

  private readonly minPitch: number;
  private readonly pitchFloor: number;
  private readonly pitchCeiling: number;
  private readonly maxNumFormants: number;
  private readonly maxFormantFreq: number;
  private readonly onFrame?: (frame: StreamFrameResult) => void;
  private samplesSinceLastHop = 0;

  constructor(engine: NganEngine, options: StreamSessionOptions = {}) {
    this.engine = engine;
    this.exports = engine.exports;
    this.sampleRate = options.sampleRate ?? 16000;
    this.historyDurationSeconds = options.historyDurationSeconds ?? 5.0;
    this.windowDurationSeconds = options.windowDurationSeconds ?? 0.08;
    this.hopDurationSeconds = options.hopDurationSeconds ?? 0.025;
    this.minPitch = options.minPitch ?? 100;
    this.pitchFloor = options.pitchFloor ?? 75;
    this.pitchCeiling = options.pitchCeiling ?? 600;
    this.maxNumFormants = options.maxNumFormants ?? 5;
    this.maxFormantFreq = options.maxFormantFreq ?? 5500;
    this.onFrame = options.onFrame;

    this.windowSamples = Math.max(
      1,
      Math.round(this.sampleRate * this.windowDurationSeconds),
    );
    this.hopSamples = Math.max(
      1,
      Math.round(this.sampleRate * this.hopDurationSeconds),
    );
    this.capacitySamples = Math.max(
      this.windowSamples,
      Math.ceil(this.sampleRate * this.historyDurationSeconds),
    );

    this.exports.ring_reset(this.capacitySamples);
  }

  get bufferedSamples(): number {
    return this.exports.ring_len();
  }

  get totalSamples(): number {
    return this.exports.ring_total_samples();
  }

  /**
   * Push a chunk of mono PCM samples at `this.sampleRate` into the WASM ring
   * buffer and emit sliding-window frame analyses every `hopSamples`.
   */
  pushSamples(chunk: SampleArray): StreamFrameResult[] {
    const emitted: StreamFrameResult[] = [];
    const len = chunk.length;
    for (let i = 0; i < len; i++) {
      this.exports.ring_push(chunk[i] ?? 0);
      this.samplesSinceLastHop += 1;
      if (
        this.samplesSinceLastHop >= this.hopSamples &&
        this.exports.ring_len() >= this.windowSamples
      ) {
        this.samplesSinceLastHop = 0;
        const frame = this.analyzeLatestFrame();
        if (frame) {
          emitted.push(frame);
          this.onFrame?.(frame);
        }
      }
    }
    return emitted;
  }

  /**
   * Immediately analyze the latest `windowSamples` currently held in the WASM
   * ring buffer without waiting for the next hop interval.
   */
  analyzeLatestFrame(): StreamFrameResult | null {
    if (this.exports.ring_len() <= 0) {
      return null;
    }
    const json = this.exports.ring_analyze_frame_json(
      this.sampleRate,
      this.windowSamples,
      this.minPitch,
      this.pitchFloor,
      this.pitchCeiling,
      this.maxNumFormants,
      this.maxFormantFreq,
    );
    return JSON.parse(json) as StreamFrameResult;
  }

  /**
   * Read the most recent `durationSeconds` (defaults to the entire buffered
   * history) from the WASM ring buffer in chronological order.
   */
  getRecentSamples(durationSeconds?: number): Float64Array {
    const requested =
      durationSeconds !== undefined && durationSeconds > 0
        ? Math.round(durationSeconds * this.sampleRate)
        : this.exports.ring_len();
    const n = this.exports.ring_copy_recent(requested);
    const out = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      out[i] = this.exports.get_sample(i);
    }
    return out;
  }

  /**
   * Run a full multi-tier Praat analysis (intensity, pitch, formants, and
   * optional spectrogram) directly on the recent WASM ring buffer history
   * without re-transferring PCM samples from JS.
   */
  analyzeRecentHistory(
    durationSeconds?: number,
    options: AnalyzeAllOptions = {},
  ): AcousticAnalysis {
    const requested =
      durationSeconds !== undefined && durationSeconds > 0
        ? Math.round(durationSeconds * this.sampleRate)
        : this.exports.ring_len();
    const n = this.exports.ring_copy_recent(requested);
    return this.engine.analyzeActiveBufferAll(n, this.sampleRate, options);
  }

  /** Clear the WASM ring buffer and reset hop counters. */
  reset(): void {
    this.samplesSinceLastHop = 0;
    this.exports.ring_reset(this.capacitySamples);
  }
}

/**
 * Capture live microphone audio via Web Audio `AudioWorkletNode`, anti-alias
 * and downsample to `sampleRate` (default `16000` Hz) on the audio thread,
 * push samples into `NganStreamSession`'s WASM ring buffer, and stream
 * frame-by-frame pitch, formant, intensity, and RMS estimates.
 */
export async function startMicrophoneStream(
  engine: NganEngine,
  options: MicrophoneStreamOptions = {},
): Promise<MicrophoneStreamHandle> {
  const sampleRate = options.sampleRate ?? 16000;
  const hopDurationSeconds = options.hopDurationSeconds ?? 0.025;
  const hopSamples = Math.max(1, Math.round(sampleRate * hopDurationSeconds));
  const session = new NganStreamSession(engine, {
    ...options,
    sampleRate,
    hopDurationSeconds,
  });

  const ownsMediaStream = !options.mediaStream;
  const mediaStream =
    options.mediaStream ??
    (await navigator.mediaDevices.getUserMedia({
      audio: options.audioConstraints ?? {
        echoCancellation: false,
        noiseSuppression: false,
        autoGainControl: false,
        channelCount: 1,
      },
      video: false,
    }));

  const ownsAudioContext = !options.audioContext;
  const AudioCtx =
    globalThis.AudioContext ??
    (globalThis as unknown as { webkitAudioContext: typeof AudioContext })
      .webkitAudioContext;
  const audioContext =
    options.audioContext ?? new AudioCtx({ latencyHint: 'interactive' });

  let blobUrlToRevoke: string | null = null;
  let sourceNode: MediaStreamAudioSourceNode | null = null;
  let workletNode: AudioWorkletNode | null = null;
  let silentGain: GainNode | null = null;

  try {
    if (audioContext.state === 'suspended') {
      await audioContext.resume();
    }

    const workletUrl =
      options.workletUrl !== undefined
        ? options.workletUrl
        : (blobUrlToRevoke = createWorkletModuleUrl());

    await audioContext.audioWorklet.addModule(workletUrl);

    sourceNode = audioContext.createMediaStreamSource(mediaStream);
    workletNode = new AudioWorkletNode(
      audioContext,
      NGAN_WORKLET_PROCESSOR_NAME,
      {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        channelCount: 1,
        processorOptions: {
          targetSampleRate: sampleRate,
          hopSamples,
        },
      },
    );

    // Keep a zero-gain sink connected so browsers continue pulling the worklet
    // without causing microphone speaker feedback.
    silentGain = audioContext.createGain();
    silentGain.gain.value = 0;

    workletNode.port.onmessage = (event: MessageEvent) => {
      try {
        const data = event.data as {
          type?: string;
          samples?: Float32Array;
          sampleRate?: number;
        } | null;
        if (
          data?.type === 'samples' &&
          data.samples instanceof Float32Array
        ) {
          options.onChunk?.(data.samples, data.sampleRate ?? sampleRate);
          session.pushSamples(data.samples);
        }
      } catch (err) {
        options.onError?.(err);
      }
    };

    sourceNode.connect(workletNode);
    workletNode.connect(silentGain);
    silentGain.connect(audioContext.destination);
  } catch (err) {
    sourceNode?.disconnect();
    workletNode?.disconnect();
    silentGain?.disconnect();
    if (blobUrlToRevoke) {
      URL.revokeObjectURL(blobUrlToRevoke);
    }
    if (ownsMediaStream) {
      for (const track of mediaStream.getTracks()) {
        track.stop();
      }
    }
    if (ownsAudioContext) {
      await audioContext.close().catch(() => {});
    }
    throw err;
  }

  let stopped = false;

  return {
    session,
    audioContext,
    mediaStream,
    workletNode,
    sampleRate,
    pause() {
      if (!stopped) {
        workletNode?.port.postMessage({ type: 'pause' });
      }
    },
    resume() {
      if (!stopped) {
        workletNode?.port.postMessage({ type: 'resume' });
      }
    },
    async stop() {
      if (stopped) return;
      stopped = true;
      workletNode.port.onmessage = null;
      sourceNode?.disconnect();
      workletNode.disconnect();
      silentGain?.disconnect();
      if (blobUrlToRevoke) {
        URL.revokeObjectURL(blobUrlToRevoke);
        blobUrlToRevoke = null;
      }
      if (ownsMediaStream) {
        for (const track of mediaStream.getTracks()) {
          track.stop();
        }
      }
      if (ownsAudioContext) {
        await audioContext.close().catch(() => {});
      }
    },
  };
}
