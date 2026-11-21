// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import type { DecodeAudioOptions, DecodedAudio } from './types.js';

function isAudioBuffer(v: unknown): v is AudioBuffer {
  return (
    typeof v === 'object' &&
    v !== null &&
    typeof (v as AudioBuffer).getChannelData === 'function' &&
    typeof (v as AudioBuffer).sampleRate === 'number' &&
    typeof (v as AudioBuffer).numberOfChannels === 'number'
  );
}

function getAudioContextConstructor(): typeof AudioContext {
  const g = globalThis as unknown as {
    AudioContext?: typeof AudioContext;
    webkitAudioContext?: typeof AudioContext;
  };
  const Ctor = g.AudioContext ?? g.webkitAudioContext;
  if (!Ctor) {
    throw new Error(
      'Web Audio API AudioContext is not available in this environment.',
    );
  }
  return Ctor;
}

function getOfflineAudioContextConstructor():
  | typeof OfflineAudioContext
  | undefined {
  const g = globalThis as unknown as {
    OfflineAudioContext?: typeof OfflineAudioContext;
    webkitOfflineAudioContext?: typeof OfflineAudioContext;
  };
  return g.OfflineAudioContext ?? g.webkitOfflineAudioContext;
}

/**
 * Extract mono PCM samples from an `AudioBuffer`.
 * When `channel` is `'mono'` (default), averages all channels equally.
 * When `channel` is a number, returns that zero-based channel's data.
 */
export function extractMonoSamples(
  buffer: AudioBuffer,
  channel: 'mono' | number = 'mono',
): Float32Array {
  const { length, numberOfChannels } = buffer;
  if (numberOfChannels <= 0 || length <= 0) {
    return new Float32Array(0);
  }

  if (typeof channel === 'number') {
    if (channel < 0 || channel >= numberOfChannels || !Number.isInteger(channel)) {
      throw new RangeError(
        `Channel index ${channel} out of range for ${numberOfChannels}-channel AudioBuffer`,
      );
    }
    return new Float32Array(buffer.getChannelData(channel));
  }

  if (numberOfChannels === 1) {
    return new Float32Array(buffer.getChannelData(0));
  }

  const out = new Float32Array(length);
  const scale = 1 / numberOfChannels;
  for (let ch = 0; ch < numberOfChannels; ch++) {
    const data = buffer.getChannelData(ch);
    for (let i = 0; i < length; i++) {
      out[i] = (out[i] ?? 0) + (data[i] ?? 0) * scale;
    }
  }
  return out;
}

/**
 * Pure-JS windowed-sinc band-limited resampler fallback when Web Audio
 * `OfflineAudioContext` is unavailable.
 */
export function resampleSinc(
  samples: Float32Array | Float64Array,
  sourceRate: number,
  targetRate: number,
): Float32Array {
  if (
    samples.length === 0 ||
    sourceRate <= 0 ||
    targetRate <= 0 ||
    sourceRate === targetRate
  ) {
    return new Float32Array(samples);
  }

  const ratio = sourceRate / targetRate;
  const outLen = Math.max(1, Math.round(samples.length / ratio));
  const out = new Float32Array(outLen);
  const halfTaps = Math.max(12, Math.min(32, Math.ceil(4 * Math.max(1, ratio))));
  const fc = ratio > 1 ? 0.45 / ratio : 0.45;
  const n = samples.length;

  for (let i = 0; i < outLen; i++) {
    const center = i * ratio;
    const base = Math.floor(center);
    let acc = 0;
    let wsum = 0;
    for (let k = -halfTaps; k <= halfTaps; k++) {
      const idx = base + k;
      if (idx < 0 || idx >= n) continue;
      const d = idx - center;
      const x = 2 * fc * d;
      const sinc = x === 0 ? 1 : Math.sin(Math.PI * x) / (Math.PI * x);
      const u = d / (halfTaps + 1);
      const win = Math.abs(u) >= 1 ? 0 : 0.5 * (1 + Math.cos(Math.PI * u));
      const w = sinc * win;
      acc += (samples[idx] ?? 0) * w;
      wsum += w;
    }
    out[i] = wsum > 0 ? acc / wsum : 0;
  }
  return out;
}

async function toArrayBuffer(
  input: Blob | ArrayBuffer | Uint8Array,
): Promise<ArrayBuffer> {
  if (input instanceof ArrayBuffer) {
    return input;
  }
  if (ArrayBuffer.isView(input)) {
    const copy = new Uint8Array(input.byteLength);
    copy.set(new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
    return copy.buffer;
  }
  if (typeof Blob !== 'undefined' && input instanceof Blob) {
    return input.arrayBuffer();
  }
  throw new TypeError('Unsupported audio input passed to decodeAudio');
}

/**
 * Web Audio API decoding and resampling bridge.
 *
 * Accepts a `File`, `Blob`, `ArrayBuffer`, `Uint8Array`, or already-decoded
 * `AudioBuffer`, extracts mono (or a specified channel), optionally truncates
 * to `maxDurationSeconds`, and resamples via `OfflineAudioContext` (defaulting
 * to `16000` Hz for speech analysis).
 */
export async function decodeAudio(
  input: Blob | File | ArrayBuffer | Uint8Array | AudioBuffer,
  options: DecodeAudioOptions = {},
): Promise<DecodedAudio> {
  const {
    targetSampleRate = 16000,
    channel = 'mono',
    maxDurationSeconds,
    removeDc = false,
  } = options;

  let audioBuffer: AudioBuffer;
  if (isAudioBuffer(input)) {
    audioBuffer = input;
  } else {
    const AudioCtx = getAudioContextConstructor();
    const arrayBuffer = await toArrayBuffer(input);
    const ctx = new AudioCtx();
    try {
      audioBuffer = await ctx.decodeAudioData(arrayBuffer.slice(0));
    } finally {
      await ctx.close().catch(() => {});
    }
  }

  const sourceSampleRate = audioBuffer.sampleRate;
  const numberOfChannels = audioBuffer.numberOfChannels;
  let mono = extractMonoSamples(audioBuffer, channel);

  if (
    maxDurationSeconds !== undefined &&
    maxDurationSeconds > 0 &&
    mono.length > Math.floor(maxDurationSeconds * sourceSampleRate)
  ) {
    mono = mono.subarray(0, Math.floor(maxDurationSeconds * sourceSampleRate));
  }

  let outputSamples: Float32Array;
  let outputSampleRate = sourceSampleRate;

  const shouldResample =
    targetSampleRate !== null &&
    targetSampleRate > 0 &&
    targetSampleRate !== sourceSampleRate &&
    mono.length > 0;

  if (shouldResample) {
    outputSampleRate = targetSampleRate;
    const OfflineCtx = getOfflineAudioContextConstructor();
    if (OfflineCtx) {
      const targetLength = Math.max(
        1,
        Math.round((mono.length / sourceSampleRate) * targetSampleRate),
      );
      const offline = new OfflineCtx(1, targetLength, targetSampleRate);
      const monoBuffer = offline.createBuffer(1, mono.length, sourceSampleRate);
      monoBuffer.getChannelData(0).set(mono);
      const src = offline.createBufferSource();
      src.buffer = monoBuffer;
      src.connect(offline.destination);
      src.start(0);
      const rendered = await offline.startRendering();
      outputSamples = new Float32Array(rendered.getChannelData(0));
    } else {
      outputSamples = resampleSinc(mono, sourceSampleRate, targetSampleRate);
    }
  } else {
    outputSamples = new Float32Array(mono);
  }

  if (removeDc && outputSamples.length > 0) {
    let sum = 0;
    for (let i = 0; i < outputSamples.length; i++) {
      sum += outputSamples[i] ?? 0;
    }
    const mean = sum / outputSamples.length;
    for (let i = 0; i < outputSamples.length; i++) {
      outputSamples[i] = (outputSamples[i] ?? 0) - mean;
    }
  }

  return {
    samples: outputSamples,
    sampleRate: outputSampleRate,
    duration: outputSampleRate > 0 ? outputSamples.length / outputSampleRate : 0,
    sourceSampleRate,
    numberOfChannels,
  };
}
