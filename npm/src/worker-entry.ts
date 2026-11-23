// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import { mergeChunkAnalyses, streamLongAudio } from './chunked.js';
import { createNgan, type NganEngine } from './index.js';
import type {
  AudioChunkAnalysisResult,
  LongAudioAnalysisOptions,
  LongAudioProgress,
  SampleArray,
  WasmSource,
} from './types.js';

interface WorkerPort {
  postMessage(message: unknown, transfer?: Transferable[]): void;
  onMessage(handler: (data: unknown) => void): void;
}

type RpcRequest =
  | {
      type: 'init';
      id: number;
      wasmSource?: WasmSource;
    }
  | {
      type: 'call';
      id: number;
      method: string;
      args: unknown[];
    }
  | {
      type: 'analyzeLongAudio';
      id: number;
      samples: SampleArray;
      sampleRate: number;
      options: Omit<LongAudioAnalysisOptions, 'onProgress' | 'onChunk' | 'signal'>;
      streamChunks?: boolean;
      emitChunks?: boolean;
    }
  | {
      type: 'cancel';
      id: number;
    };

function serializeError(err: unknown): { name: string; message: string } {
  if (err instanceof Error) {
    return { name: err.name, message: err.message };
  }
  return { name: 'Error', message: String(err) };
}

async function resolvePort(): Promise<WorkerPort> {
  const g = globalThis as unknown as {
    self?: {
      postMessage?: (msg: unknown, transfer?: Transferable[]) => void;
      addEventListener?: (type: string, cb: (ev: { data: unknown }) => void) => void;
    };
    process?: { versions?: { node?: string } };
  };

  if (
    g.self &&
    typeof g.self.postMessage === 'function' &&
    typeof g.self.addEventListener === 'function'
  ) {
    const scope = g.self;
    return {
      postMessage(msg, transfer) {
        if (transfer && transfer.length > 0) {
          scope.postMessage!(msg, transfer);
        } else {
          scope.postMessage!(msg);
        }
      },
      onMessage(handler) {
        scope.addEventListener!('message', (ev) => handler(ev.data));
      },
    };
  }

  if (typeof g.process?.versions?.node === 'string') {
    const spec = 'node:' + 'worker_threads';
    const wt = (await import(/* @vite-ignore */ spec)) as {
      parentPort?: {
        postMessage(msg: unknown, transfer?: readonly unknown[]): void;
        on(ev: 'message', cb: (data: unknown) => void): void;
      } | null;
    };
    if (wt.parentPort) {
      const port = wt.parentPort;
      return {
        postMessage(msg, transfer) {
          if (transfer && transfer.length > 0) {
            port.postMessage(msg, transfer);
          } else {
            port.postMessage(msg);
          }
        },
        onMessage(handler) {
          port.on('message', handler);
        },
      };
    }
  }

  throw new Error('ngan worker-entry must run inside a Web Worker or Node worker_threads');
}

export async function startNganWorkerHost(): Promise<void> {
  const port = await resolvePort();
  let engine: NganEngine | null = null;
  const controllers = new Map<number, AbortController>();

  port.onMessage(async (raw) => {
    const msg = raw as RpcRequest | null;
    if (!msg || typeof msg !== 'object') return;

    if (msg.type === 'cancel') {
      controllers.get(msg.id)?.abort();
      return;
    }

    if (msg.type === 'init') {
      try {
        engine = await createNgan({ wasmSource: msg.wasmSource });
        port.postMessage({ type: 'ready', id: msg.id });
      } catch (err) {
        port.postMessage({
          type: 'error',
          id: msg.id,
          error: serializeError(err),
        });
      }
      return;
    }

    if (!engine) {
      port.postMessage({
        type: 'error',
        id: msg.id,
        error: { name: 'Error', message: 'Ngan worker has not been initialized.' },
      });
      return;
    }

    if (msg.type === 'call') {
      try {
        const fn = (engine as unknown as Record<string, (...a: unknown[]) => unknown>)[
          msg.method
        ];
        if (typeof fn !== 'function') {
          throw new Error(`Unknown NganEngine method: ${msg.method}`);
        }
        const result = fn.apply(engine, msg.args);
        if (result instanceof Float64Array) {
          port.postMessage({ type: 'result', id: msg.id, result }, [
            result.buffer,
          ]);
        } else {
          port.postMessage({ type: 'result', id: msg.id, result });
        }
      } catch (err) {
        port.postMessage({
          type: 'error',
          id: msg.id,
          error: serializeError(err),
        });
      }
      return;
    }

    if (msg.type === 'analyzeLongAudio') {
      const ac = new AbortController();
      controllers.set(msg.id, ac);
      try {
        const chunks: AudioChunkAnalysisResult[] = [];
        const includeChunk = Boolean(msg.streamChunks || msg.emitChunks);
        const totalDuration =
          msg.sampleRate > 0 ? msg.samples.length / msg.sampleRate : 0;

        for await (const chunk of streamLongAudio(
          engine,
          msg.samples,
          msg.sampleRate,
          {
            ...msg.options,
            signal: ac.signal,
            yieldBetweenChunks: true,
            onProgress(progress: LongAudioProgress) {
              if (!includeChunk) {
                port.postMessage({
                  type: 'progress',
                  id: msg.id,
                  progress,
                });
              }
            },
            onChunk(chunkResult: AudioChunkAnalysisResult, progress: LongAudioProgress) {
              if (includeChunk) {
                port.postMessage({
                  type: 'progress',
                  id: msg.id,
                  progress,
                  chunk: chunkResult,
                });
              }
            },
          },
        )) {
          if (!msg.streamChunks) {
            chunks.push(chunk);
          }
        }

        if (msg.streamChunks) {
          port.postMessage({ type: 'done', id: msg.id });
        } else {
          const result =
            msg.options.mergeResults === false
              ? {
                  sampleRate: msg.sampleRate,
                  duration: totalDuration,
                  totalChunks: chunks.length,
                  chunks,
                }
              : mergeChunkAnalyses(chunks, msg.sampleRate, totalDuration);
          port.postMessage({ type: 'result', id: msg.id, result });
        }
      } catch (err) {
        port.postMessage({
          type: 'error',
          id: msg.id,
          error: serializeError(err),
        });
      } finally {
        controllers.delete(msg.id);
      }
    }
  });
}

// Auto-start when loaded directly as a Worker entrypoint.
const gScope = globalThis as unknown as {
  self?: { postMessage?: unknown };
  window?: unknown;
};
const isBrowserWorker =
  typeof gScope.self !== 'undefined' &&
  typeof gScope.self.postMessage === 'function' &&
  typeof gScope.window === 'undefined';

let isNodeWorkerThread = false;
if (
  typeof (globalThis as unknown as { process?: { versions?: { node?: string } } })
    .process?.versions?.node === 'string'
) {
  try {
    const spec = 'node:' + 'worker_threads';
    const wt = (await import(/* @vite-ignore */ spec)) as {
      isMainThread?: boolean;
    };
    isNodeWorkerThread = wt.isMainThread === false;
  } catch {
    isNodeWorkerThread = false;
  }
}

if (isBrowserWorker || isNodeWorkerThread) {
  void startNganWorkerHost();
}
