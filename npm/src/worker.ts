// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import { resolveWasmBytes } from './loader.js';
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
  LongAudioProgress,
  MfccOptions,
  MfccResult,
  NganWorkerOptions,
  PitchOptions,
  PitchTier,
  PsolaOptions,
  SampleArray,
  SegmentSummary,
  SpectralAnalysis,
  SpectralOptions,
  Spectrogram,
  SpectrogramOptions,
  TextGridAnalysisOptions,
  VoiceReport,
  VoiceReportOptions,
  WasmSource,
  WorkerLike,
} from './types.js';

interface PendingRpc {
  resolve: (value: any) => void;
  reject: (reason: unknown) => void;
  onProgress?: (progress: LongAudioProgress, chunk?: AudioChunkAnalysisResult) => void;
  onDone?: () => void;
}

type WorkerResponse =
  | { type: 'ready'; id: number }
  | { type: 'result'; id: number; result: unknown }
  | {
      type: 'progress';
      id: number;
      progress: LongAudioProgress;
      chunk?: AudioChunkAnalysisResult;
    }
  | { type: 'done'; id: number }
  | {
      type: 'error';
      id: number;
      error: { name: string; message: string };
    };

function reconstructError(payload: { name: string; message: string }): Error {
  const err = new Error(payload.message);
  err.name = payload.name || 'Error';
  return err;
}

async function spawnDefaultWorker(
  workerUrl?: string | URL,
): Promise<WorkerLike> {
  const url = workerUrl ?? new URL('./worker-entry.js', import.meta.url);
  if (typeof Worker !== 'undefined') {
    return new Worker(url, { type: 'module' }) as unknown as WorkerLike;
  }
  const g = globalThis as unknown as {
    process?: { versions?: { node?: string } };
  };
  if (typeof g.process?.versions?.node === 'string') {
    const spec = 'node:' + 'worker_threads';
    const wt = (await import(/* @vite-ignore */ spec)) as {
      Worker: new (filename: string | URL) => WorkerLike;
    };
    return new wt.Worker(url);
  }
  throw new Error(
    'No Web Worker or Node.js worker_threads implementation available.',
  );
}

async function resolveWorkerWasmPayload(
  source?: WasmSource,
): Promise<{ payload: WasmSource | ArrayBuffer; transfer: Transferable[] }> {
  if (source instanceof WebAssembly.Module) {
    return { payload: source, transfer: [] };
  }
  const bytes = await resolveWasmBytes(source);
  if (bytes instanceof ArrayBuffer) {
    const copy = bytes.slice(0);
    return { payload: copy, transfer: [copy] };
  }
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength));
  return { payload: copy.buffer, transfer: [copy.buffer] };
}

/**
 * Promise-based client communicating with an off-main-thread `NganEngine`
 * running inside a Web Worker (or Node.js `worker_threads`).
 */
export class NganWorkerClient {
  private readonly worker: WorkerLike;
  private readonly pending = new Map<number, PendingRpc>();
  private nextId = 1;
  private terminated = false;
  private readonly detachListener: () => void;

  private constructor(worker: WorkerLike) {
    this.worker = worker;

    const handleRaw = (raw: unknown) => {
      const msg = (
        raw && typeof raw === 'object' && 'data' in raw && !('type' in raw)
          ? (raw as { data: unknown }).data
          : raw
      ) as WorkerResponse | null;
      if (!msg || typeof msg !== 'object' || typeof msg.id !== 'number') {
        return;
      }
      const entry = this.pending.get(msg.id);
      if (!entry) return;

      if (msg.type === 'ready') {
        this.pending.delete(msg.id);
        entry.resolve(undefined);
      } else if (msg.type === 'result') {
        this.pending.delete(msg.id);
        entry.resolve(msg.result);
      } else if (msg.type === 'done') {
        this.pending.delete(msg.id);
        entry.onDone?.();
        entry.resolve(undefined);
      } else if (msg.type === 'progress') {
        entry.onProgress?.(msg.progress, msg.chunk);
      } else if (msg.type === 'error') {
        this.pending.delete(msg.id);
        entry.reject(reconstructError(msg.error));
      }
    };

    const handleErr = (err: unknown) => {
      const error = err instanceof Error ? err : new Error(String(err));
      for (const [id, entry] of this.pending) {
        this.pending.delete(id);
        entry.reject(error);
      }
    };

    if (typeof worker.addEventListener === 'function') {
      const msgListener = (ev: MessageEvent) => handleRaw(ev.data);
      const errListener = (ev: ErrorEvent) => handleErr(ev.error ?? ev.message);
      worker.addEventListener('message', msgListener);
      worker.addEventListener('error', errListener);
      this.detachListener = () => {
        worker.removeEventListener?.('message', msgListener);
        worker.removeEventListener?.('error', errListener);
      };
    } else if (typeof worker.on === 'function') {
      worker.on('message', handleRaw);
      worker.on('error', handleErr);
      this.detachListener = () => {
        worker.off?.('message', handleRaw);
        worker.off?.('error', handleErr);
      };
    } else {
      this.detachListener = () => {};
    }
  }

  /** @internal */
  static async connect(
    options: NganWorkerOptions = {},
  ): Promise<NganWorkerClient> {
    const worker = options.worker ?? (await spawnDefaultWorker(options.workerUrl));
    const client = new NganWorkerClient(worker);
    try {
      const { payload, transfer } = await resolveWorkerWasmPayload(
        options.wasmSource,
      );
      await client.sendInit(payload, transfer);
      return client;
    } catch (err) {
      await client.terminate().catch(() => {});
      throw err;
    }
  }

  private sendInit(
    wasmSource: WasmSource | ArrayBuffer,
    transfer: Transferable[],
  ): Promise<void> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ type: 'init', id, wasmSource }, transfer);
    });
  }

  private call<T>(method: string, args: unknown[]): Promise<T> {
    if (this.terminated) {
      return Promise.reject(new Error('NganWorkerClient has been terminated.'));
    }
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.worker.postMessage({ type: 'call', id, method, args });
    });
  }

  analyzeIntensity(
    samples: SampleArray,
    sampleRate: number,
    options: IntensityOptions = {},
  ): Promise<IntensityTier> {
    return this.call('analyzeIntensity', [samples, sampleRate, options]);
  }

  analyzePitch(
    samples: SampleArray,
    sampleRate: number,
    options: PitchOptions = {},
  ): Promise<PitchTier> {
    return this.call('analyzePitch', [samples, sampleRate, options]);
  }

  analyzeFormants(
    samples: SampleArray,
    sampleRate: number,
    options: FormantOptions = {},
  ): Promise<FormantTier> {
    return this.call('analyzeFormants', [samples, sampleRate, options]);
  }

  analyzeHarmonicity(
    samples: SampleArray,
    sampleRate: number,
    options: HarmonicityOptions = {},
  ): Promise<HarmonicityTier> {
    return this.call('analyzeHarmonicity', [samples, sampleRate, options]);
  }

  analyzeSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: SpectrogramOptions = {},
  ): Promise<Spectrogram> {
    return this.call('analyzeSpectrogram', [samples, sampleRate, options]);
  }

  analyzeVoiceReport(
    samples: SampleArray,
    sampleRate: number,
    options: VoiceReportOptions = {},
  ): Promise<VoiceReport> {
    return this.call('analyzeVoiceReport', [samples, sampleRate, options]);
  }

  analyzeSpectral(
    samples: SampleArray,
    sampleRate: number,
    options: SpectralOptions = {},
  ): Promise<SpectralAnalysis> {
    return this.call('analyzeSpectral', [samples, sampleRate, options]);
  }

  analyzeTextGridSegments(
    samples: SampleArray,
    sampleRate: number,
    textGridSource: string,
    options: TextGridAnalysisOptions = {},
  ): Promise<SegmentSummary[]> {
    return this.call('analyzeTextGridSegments', [
      samples,
      sampleRate,
      textGridSource,
      options,
    ]);
  }

  analyzeCpps(
    samples: SampleArray,
    sampleRate: number,
    options: CppsOptions = {},
  ): Promise<CppsAnalysis> {
    return this.call('analyzeCpps', [samples, sampleRate, options]);
  }

  analyzeMfcc(
    samples: SampleArray,
    sampleRate: number,
    options: MfccOptions = {},
  ): Promise<MfccResult> {
    return this.call('analyzeMfcc', [samples, sampleRate, options]);
  }

  analyzeMelSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): Promise<FilterBankMatrix> {
    return this.call('analyzeMelSpectrogram', [samples, sampleRate, options]);
  }

  analyzeBarkSpectrogram(
    samples: SampleArray,
    sampleRate: number,
    options: FilterBankSpectrogramOptions = {},
  ): Promise<FilterBankMatrix> {
    return this.call('analyzeBarkSpectrogram', [samples, sampleRate, options]);
  }

  manipulatePsola(
    samples: SampleArray,
    sampleRate: number,
    options: PsolaOptions = {},
  ): Promise<Float64Array> {
    return this.call('manipulatePsola', [samples, sampleRate, options]);
  }

  analyzeAll(
    samples: SampleArray,
    sampleRate: number,
    options: AnalyzeAllOptions = {},
  ): Promise<AcousticAnalysis> {
    return this.call('analyzeAll', [samples, sampleRate, options]);
  }

  /**
   * Run overlap-save chunked analysis in the background worker with live
   * `onProgress`, `onChunk`, and `AbortSignal` support.
   */
  analyzeLongAudio(
    samples: SampleArray,
    sampleRate: number,
    options: LongAudioAnalysisOptions = {},
  ): Promise<LongAudioAnalysisResult> {
    if (this.terminated) {
      return Promise.reject(new Error('NganWorkerClient has been terminated.'));
    }
    if (options.signal?.aborted) {
      const err = new Error('Long-audio analysis aborted');
      err.name = 'AbortError';
      return Promise.reject(err);
    }

    const id = this.nextId++;
    const {
      onProgress,
      onChunk,
      signal,
      transfer,
      ...serializableOpts
    } = options;

    return new Promise<LongAudioAnalysisResult>((resolve, reject) => {
      const onAbort = () => {
        this.worker.postMessage({ type: 'cancel', id });
      };
      signal?.addEventListener('abort', onAbort, { once: true });

      this.pending.set(id, {
        resolve: (val) => {
          signal?.removeEventListener('abort', onAbort);
          resolve(val as LongAudioAnalysisResult);
        },
        reject: (err) => {
          signal?.removeEventListener('abort', onAbort);
          reject(err);
        },
        onProgress(progress, chunk) {
          onProgress?.(progress);
          if (chunk && onChunk) {
            onChunk(chunk, progress);
          }
        },
      });

      const transferList: Transferable[] = [];
      if (
        transfer &&
        (samples instanceof Float32Array || samples instanceof Float64Array)
      ) {
        transferList.push(samples.buffer);
      }

      this.worker.postMessage(
        {
          type: 'analyzeLongAudio',
          id,
          samples,
          sampleRate,
          options: serializableOpts,
          streamChunks: false,
          emitChunks: Boolean(onChunk),
        },
        transferList,
      );
    });
  }

  /**
   * Stream overlap-save chunked analyses incrementally from the background
   * worker as an `AsyncGenerator`.
   */
  async *streamLongAudio(
    samples: SampleArray,
    sampleRate: number,
    options: LongAudioAnalysisOptions = {},
  ): AsyncGenerator<AudioChunkAnalysisResult, void, unknown> {
    if (this.terminated) {
      throw new Error('NganWorkerClient has been terminated.');
    }
    if (options.signal?.aborted) {
      const err = new Error('Long-audio analysis aborted');
      err.name = 'AbortError';
      throw err;
    }

    const id = this.nextId++;
    const {
      onProgress,
      onChunk,
      signal,
      transfer,
      ...serializableOpts
    } = options;

    const queue: AudioChunkAnalysisResult[] = [];
    let done = false;
    let failure: unknown = null;
    let notify: (() => void) | null = null;

    const wake = () => {
      const fn = notify;
      notify = null;
      fn?.();
    };

    const onAbort = () => {
      this.worker.postMessage({ type: 'cancel', id });
    };
    signal?.addEventListener('abort', onAbort, { once: true });

    this.pending.set(id, {
      resolve: () => {
        done = true;
        wake();
      },
      reject: (err) => {
        failure = err;
        done = true;
        wake();
      },
      onProgress(progress, chunk) {
        onProgress?.(progress);
        if (chunk) {
          onChunk?.(chunk, progress);
          queue.push(chunk);
          wake();
        }
      },
      onDone: () => {
        done = true;
        wake();
      },
    });

    const transferList: Transferable[] = [];
    if (
      transfer &&
      (samples instanceof Float32Array || samples instanceof Float64Array)
    ) {
      transferList.push(samples.buffer);
    }

    this.worker.postMessage(
      {
        type: 'analyzeLongAudio',
        id,
        samples,
        sampleRate,
        options: serializableOpts,
        streamChunks: true,
        emitChunks: true,
      },
      transferList,
    );

    try {
      while (true) {
        while (queue.length > 0) {
          yield queue.shift()!;
        }
        if (failure !== null) {
          throw failure;
        }
        if (done) {
          break;
        }
        await new Promise<void>((r) => {
          notify = r;
        });
      }
    } finally {
      signal?.removeEventListener('abort', onAbort);
      if (!done) {
        this.worker.postMessage({ type: 'cancel', id });
      }
    }
  }

  /** Terminate the underlying worker and reject any pending calls. */
  async terminate(): Promise<void> {
    if (this.terminated) return;
    this.terminated = true;
    this.detachListener();
    for (const [id, entry] of this.pending) {
      this.pending.delete(id);
      entry.reject(new Error('NganWorkerClient terminated.'));
    }
    await this.worker.terminate?.();
  }
}

/**
 * Spawn an off-main-thread Web Worker (or Node `worker_threads` worker)
 * running `@wrinh/ngan` and resolve a ready-to-use `NganWorkerClient`.
 */
export function createNganWorker(
  options: NganWorkerOptions = {},
): Promise<NganWorkerClient> {
  return NganWorkerClient.connect(options);
}
