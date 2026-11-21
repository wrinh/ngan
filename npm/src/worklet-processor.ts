// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

/** Registered AudioWorkletProcessor name used by `startMicrophoneStream`. */
export const NGAN_WORKLET_PROCESSOR_NAME = 'ngan-capture-processor';

declare class AudioWorkletProcessor {
  readonly port: MessagePort;
  constructor(options?: unknown);
  process(
    inputs: Float32Array[][],
    outputs: Float32Array[][],
    parameters: Record<string, Float32Array>,
  ): boolean;
}

declare function registerProcessor(
  name: string,
  processorCtor: typeof AudioWorkletProcessor,
): void;

declare const sampleRate: number;

export interface WorkletProcessorOptions {
  targetSampleRate?: number;
  hopSamples?: number;
}

/**
 * Self-contained factory that constructs `NganCaptureProcessor` on top of the
 * AudioWorklet global `AudioWorkletProcessor` base class. Kept pure and
 * dependency-free so it can both execute directly in `ngan/worklet` and be
 * serialized into a `Blob` URL by `createWorkletModuleUrl()`.
 */
export function buildCaptureProcessor(
  Base: typeof AudioWorkletProcessor,
  getSampleRate: () => number,
): typeof AudioWorkletProcessor {
  return class NganCaptureProcessor extends Base {
    private targetSampleRate: number;
    private hopSamples: number;
    private paused = false;
    private hopBuf: Float32Array;
    private hopFill = 0;
    private ratio = 1;
    private halfTaps = 12;
    private fc = 0.45;
    private pending: Float32Array;
    private pendingLen = 0;
    private readPos = 0;

    constructor(options?: { processorOptions?: WorkletProcessorOptions }) {
      super(options);
      const opts = options?.processorOptions ?? {};
      this.targetSampleRate =
        typeof opts.targetSampleRate === 'number' && opts.targetSampleRate > 0
          ? opts.targetSampleRate
          : 16000;
      this.hopSamples =
        typeof opts.hopSamples === 'number' && opts.hopSamples > 0
          ? Math.floor(opts.hopSamples)
          : 400;
      this.hopBuf = new Float32Array(this.hopSamples);
      this.pending = new Float32Array(2048);
      this.reconfigureResampler();

      this.port.onmessage = (event: MessageEvent) => {
        const msg = event.data as {
          type?: string;
          targetSampleRate?: number;
          hopSamples?: number;
        } | null;
        if (!msg || typeof msg !== 'object') return;
        if (msg.type === 'pause') {
          this.paused = true;
        } else if (msg.type === 'resume') {
          this.paused = false;
        } else if (msg.type === 'reset') {
          this.resetBuffers();
        } else if (msg.type === 'configure') {
          if (
            typeof msg.targetSampleRate === 'number' &&
            msg.targetSampleRate > 0
          ) {
            this.targetSampleRate = msg.targetSampleRate;
          }
          if (typeof msg.hopSamples === 'number' && msg.hopSamples > 0) {
            this.hopSamples = Math.floor(msg.hopSamples);
            this.hopBuf = new Float32Array(this.hopSamples);
          }
          this.reconfigureResampler();
        }
      };
    }

    private reconfigureResampler(): void {
      const inRate = getSampleRate();
      this.ratio = inRate > 0 ? inRate / this.targetSampleRate : 1;
      this.halfTaps = Math.max(
        7,
        Math.min(31, Math.ceil(4 * Math.max(1, this.ratio))),
      );
      this.fc = this.ratio > 1 ? 0.45 / this.ratio : 0.45;
      this.resetBuffers();
    }

    private resetBuffers(): void {
      this.hopFill = 0;
      this.pending.fill(0, 0, this.halfTaps);
      this.pendingLen = this.halfTaps;
      this.readPos = this.halfTaps;
    }

    private ensurePending(extra: number): void {
      const needed = this.pendingLen + extra;
      if (needed <= this.pending.length) return;
      let nextCap = this.pending.length * 2;
      while (nextCap < needed) nextCap *= 2;
      const next = new Float32Array(nextCap);
      next.set(this.pending.subarray(0, this.pendingLen));
      this.pending = next;
    }

    private emitSample(value: number): void {
      this.hopBuf[this.hopFill] = value;
      this.hopFill += 1;
      if (this.hopFill >= this.hopSamples) {
        const out = new Float32Array(this.hopBuf);
        this.port.postMessage(
          {
            type: 'samples',
            samples: out,
            sampleRate: this.targetSampleRate,
          },
          [out.buffer],
        );
        this.hopFill = 0;
      }
    }

    process(inputs: Float32Array[][]): boolean {
      if (this.paused) return true;
      const inputChannels = inputs[0];
      if (!inputChannels || inputChannels.length === 0) return true;
      const ch0 = inputChannels[0];
      if (!ch0 || ch0.length === 0) return true;

      const frames = ch0.length;
      const numCh = inputChannels.length;
      const inRate = getSampleRate();

      if (inRate === this.targetSampleRate) {
        for (let i = 0; i < frames; i++) {
          let sum = 0;
          for (let c = 0; c < numCh; c++) {
            const chData = inputChannels[c];
            sum += chData ? (chData[i] ?? 0) : 0;
          }
          this.emitSample(sum / numCh);
        }
        return true;
      }

      this.ensurePending(frames);
      for (let i = 0; i < frames; i++) {
        let sum = 0;
        for (let c = 0; c < numCh; c++) {
          const chData = inputChannels[c];
          sum += chData ? (chData[i] ?? 0) : 0;
        }
        this.pending[this.pendingLen + i] = sum / numCh;
      }
      this.pendingLen += frames;

      const half = this.halfTaps;
      const fc = this.fc;
      const ratio = this.ratio;

      while (Math.floor(this.readPos) + half < this.pendingLen) {
        const base = Math.floor(this.readPos);
        let acc = 0;
        let wsum = 0;
        for (let k = -half; k <= half; k++) {
          const idx = base + k;
          const d = idx - this.readPos;
          const x = 2 * fc * d;
          const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
          const u = d / (half + 1);
          const win = Math.abs(u) >= 1 ? 0 : 0.5 * (1 + Math.cos(Math.PI * u));
          const w = sinc * win;
          acc += (this.pending[idx] ?? 0) * w;
          wsum += w;
        }
        this.emitSample(wsum > 0 ? acc / wsum : 0);
        this.readPos += ratio;
      }

      const drop = Math.max(0, Math.floor(this.readPos) - half);
      if (drop > 0) {
        const keep = this.pendingLen - drop;
        this.pending.copyWithin(0, drop, this.pendingLen);
        this.pendingLen = keep;
        this.readPos -= drop;
      }

      return true;
    }
  };
}

/**
 * Return standalone ES module JavaScript source that registers
 * `'ngan-capture-processor'` inside an `AudioWorkletGlobalScope`.
 */
export function getWorkletProcessorSource(): string {
  return (
    `const buildCaptureProcessor = ${buildCaptureProcessor.toString()};\n` +
    `registerProcessor(${JSON.stringify(NGAN_WORKLET_PROCESSOR_NAME)}, ` +
    `buildCaptureProcessor(AudioWorkletProcessor, () => sampleRate));\n`
  );
}

/**
 * Create a `blob:` URL containing the `AudioWorkletProcessor` script so
 * callers do not need to configure bundler asset paths or server MIME headers.
 */
export function createWorkletModuleUrl(): string {
  if (typeof Blob === 'undefined' || typeof URL === 'undefined') {
    throw new Error(
      'createWorkletModuleUrl requires browser Blob and URL APIs.',
    );
  }
  const blob = new Blob([getWorkletProcessorSource()], {
    type: 'application/javascript',
  });
  return URL.createObjectURL(blob);
}

// Auto-register when loaded directly inside an AudioWorkletGlobalScope via
// `audioContext.audioWorklet.addModule(new URL('@wrinh/ngan/worklet', import.meta.url))`.
if (
  typeof AudioWorkletProcessor !== 'undefined' &&
  typeof registerProcessor === 'function'
) {
  registerProcessor(
    NGAN_WORKLET_PROCESSOR_NAME,
    buildCaptureProcessor(AudioWorkletProcessor, () => sampleRate),
  );
}
