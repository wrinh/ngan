// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { SampleArray } from './types.js';

/**
 * Fixed-capacity circular buffer for `Float64` PCM samples.
 * Mirrors the WASM-side ring buffer for JS-side visualization (e.g., rolling
 * waveform rendering) or worker buffering.
 */
export class Float64RingBuffer {
  readonly capacity: number;
  private readonly buf: Float64Array;
  private head = 0;
  private count = 0;
  private total = 0;

  constructor(capacity: number) {
    if (!Number.isInteger(capacity) || capacity <= 0) {
      throw new RangeError(
        `Float64RingBuffer capacity must be a positive integer, got ${capacity}`,
      );
    }
    this.capacity = capacity;
    this.buf = new Float64Array(capacity);
  }

  get length(): number {
    return this.count;
  }

  get totalPushed(): number {
    return this.total;
  }

  push(sample: number): void {
    this.buf[this.head] = sample;
    this.head = (this.head + 1) % this.capacity;
    if (this.count < this.capacity) {
      this.count += 1;
    }
    this.total += 1;
  }

  pushChunk(samples: SampleArray): void {
    const len = samples.length;
    for (let i = 0; i < len; i++) {
      this.push(samples[i] ?? 0);
    }
  }

  /**
   * Copy the most recent `count` samples (clamped to `this.length`) in
   * chronological order into `out` (or a newly allocated `Float64Array`).
   */
  readLatest(count = this.count, out?: Float64Array): Float64Array {
    const n = Math.max(0, Math.min(Math.floor(count), this.count));
    const target = out && out.length >= n ? out : new Float64Array(n);
    if (n === 0) return target.subarray(0, 0);

    const start = (this.head - n + this.capacity) % this.capacity;
    const firstPart = Math.min(n, this.capacity - start);
    target.set(this.buf.subarray(start, start + firstPart), 0);
    if (firstPart < n) {
      target.set(this.buf.subarray(0, n - firstPart), firstPart);
    }
    return target.length === n ? target : target.subarray(0, n);
  }

  clear(): void {
    this.buf.fill(0);
    this.head = 0;
    this.count = 0;
    this.total = 0;
  }
}
