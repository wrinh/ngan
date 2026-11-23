// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';

import {
  createNgan,
  Float64RingBuffer,
  resampleSinc,
  getWorkletProcessorSource,
  NGAN_WORKLET_PROCESSOR_NAME,
  hzToSemitones,
  semitonesToHz,
  hzToErb,
  erbToHz,
  hzToMel,
  melToHz,
  hzToBark,
  barkToHz,
  spectrogramToDbMatrix,
} from '../dist/index.js';

function makeSine(freq, fs, duration) {
  const n = Math.floor(fs * duration);
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    out[i] = Math.sin((2 * Math.PI * freq * i) / fs);
  }
  return out;
}

function makeVowel(f0Start, f0End, fs, duration) {
  const n = Math.floor(fs * duration);
  const section = (freq, bw) => {
    const r = Math.exp((-Math.PI * bw) / fs);
    const theta = (2 * Math.PI * freq) / fs;
    return [-2 * r * Math.cos(theta), r * r];
  };
  const [s1a, s2] = section(500, 120);
  const [s1b] = section(1500, 120);
  const p1 = s1a + s1b;
  const p2 = s1a * s1b + 2 * s2;
  const p3 = (s1a + s1b) * s2;
  const p4 = s2 * s2;
  const x = new Float64Array(n);
  let phase = 0;
  let sincePulse = 0;
  for (let i = 0; i < n; i++) {
    const f0 = f0Start + (f0End - f0Start) * (i / n);
    phase += (2 * Math.PI * f0) / fs;
    if (phase >= 2 * Math.PI) {
      phase -= 2 * Math.PI;
      sincePulse = 0;
    } else {
      sincePulse++;
    }
    const pulse = Math.exp(-sincePulse * 0.15);
    const rnd = Math.sin((i + 1) * 12.9898) * 43758.5453;
    const noise = (rnd - Math.floor(rnd)) * 2 - 1;
    const e = pulse * 0.8 + noise * 0.01;
    x[i] =
      e -
      (i >= 1 ? p1 * x[i - 1] : 0) -
      (i >= 2 ? p2 * x[i - 2] : 0) -
      (i >= 3 ? p3 * x[i - 3] : 0) -
      (i >= 4 ? p4 * x[i - 4] : 0);
  }
  for (let i = n - 1; i >= 1; i--) {
    x[i] -= x[i - 1];
  }
  return x;
}

function makeNoiseVowel(f1, f2, bw, fs, duration) {
  const n = Math.floor(fs * duration);
  const r = Math.exp((-Math.PI * bw) / fs);
  const th1 = (2 * Math.PI * f1) / fs;
  const th2 = (2 * Math.PI * f2) / fs;
  const s1a = -2 * r * Math.cos(th1);
  const s1b = -2 * r * Math.cos(th2);
  const p1 = s1a + s1b;
  const p2 = s1a * s1b + 2 * r * r;
  const p3 = (s1a + s1b) * r * r;
  const p4 = r * r * r * r;
  const x = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const s = Math.sin((i + 1) * 12.9898) * 43758.5453;
    const rnd = (s - Math.floor(s)) * 2 - 1;
    x[i] =
      rnd * 0.4 -
      (i >= 1 ? p1 * x[i - 1] : 0) -
      (i >= 2 ? p2 * x[i - 2] : 0) -
      (i >= 3 ? p3 * x[i - 3] : 0) -
      (i >= 4 ? p4 * x[i - 4] : 0);
  }
  return x;
}

const enginePromise = createNgan();

test('analyzeIntensity matches Praat 220 Hz sine SPL', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const samples = makeSine(220, fs, 1.0);
  const tier = engine.analyzeIntensity(samples, fs, { minPitch: 100 });
  assert.ok(tier.values.length > 50);
  const mid = tier.values[Math.floor(tier.values.length / 2)];
  assert.ok(Math.abs(mid - 90.9691) < 0.05, `expected ~90.9691, got ${mid}`);
});

test('analyzePitch (ac and cc) recovers 220 Hz and rejects silence', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const samples = makeSine(220, fs, 1.0);

  const ac = engine.analyzePitch(samples, fs, { method: 'ac' });
  const midAc = ac.frames[Math.floor(ac.frames.length / 2)];
  assert.ok(midAc.frequency !== null);
  assert.ok(Math.abs(midAc.frequency - 220) < 0.22);

  const cc = engine.analyzePitch(samples, fs, { method: 'cc' });
  const midCc = cc.frames[Math.floor(cc.frames.length / 2)];
  assert.ok(midCc.frequency !== null);
  assert.ok(Math.abs(midCc.frequency - 220) < 0.5);

  const fac = engine.analyzePitch(samples, fs, { method: 'filtered_ac' });
  const midFac = fac.frames[Math.floor(fac.frames.length / 2)];
  assert.ok(midFac.frequency !== null);
  assert.ok(Math.abs(midFac.frequency - 220) < 0.5);

  const silence = new Float32Array(fs * 0.5);
  const silentPitch = engine.analyzePitch(silence, fs);
  assert.ok(silentPitch.frames.every((f) => f.frequency === null));
});

test('analyzeFormants recovers F1=500 Hz and F2=1500 Hz (raw & tracked)', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const noiseVowel = makeNoiseVowel(500, 1500, 100, fs, 1.0);

  const raw = engine.analyzeFormants(noiseVowel, fs, {
    maxNumFormants: 5,
    maxFormantFreq: 5500,
  });
  assert.ok(raw.frames.length > 100);
  const interior = raw.frames.slice(40, raw.frames.length - 40);
  const f1Vals = interior
    .map((fr) => fr.formants[0]?.frequency)
    .filter((v) => typeof v === 'number');
  const f2Vals = interior
    .map((fr) => fr.formants[1]?.frequency)
    .filter((v) => typeof v === 'number');
  const meanF1 = f1Vals.reduce((a, b) => a + b, 0) / f1Vals.length;
  const meanF2 = f2Vals.reduce((a, b) => a + b, 0) / f2Vals.length;
  assert.ok(Math.abs(meanF1 - 500) < 55, `meanF1=${meanF1}`);
  assert.ok(Math.abs(meanF2 - 1500) < 90, `meanF2=${meanF2}`);

  const tracked = engine.analyzeFormants(noiseVowel, fs, {
    track: true,
    numTracks: 2,
  });
  assert.equal(tracked.frames.length, raw.frames.length);
  const midTracked = tracked.frames[Math.floor(tracked.frames.length / 2)];
  assert.ok(
    Math.abs(midTracked.formants[0].frequency - 500) < 70,
    `trackedF1=${midTracked.formants[0].frequency}`,
  );
  assert.ok(
    Math.abs(midTracked.formants[1].frequency - 1500) < 100,
    `trackedF2=${midTracked.formants[1].frequency}`,
  );
});

test('analyzeHarmonicity, analyzeSpectrogram, analyzeVoiceReport, analyzeSpectral', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const sine1k = makeSine(1000, fs, 0.5);
  const vowel = makeVowel(180, 220, fs, 1.2);

  const hnr = engine.analyzeHarmonicity(makeSine(220, fs, 1.0), fs);
  const voicedHnr = hnr.values.filter((v) => v !== null);
  assert.ok(voicedHnr.length > 10);
  assert.ok(voicedHnr[Math.floor(voicedHnr.length / 2)] > 20);

  const sg = engine.analyzeSpectrogram(sine1k, fs, { maxTimeColumns: 120 });
  assert.ok(sg.numberOfTimeFrames > 0 && sg.numberOfTimeFrames <= 120);
  assert.ok(sg.numberOfFrequencyBands > 0);
  const dbMatrix = spectrogramToDbMatrix(sg);
  assert.equal(dbMatrix.length, sg.numberOfFrequencyBands);

  const spectral = engine.analyzeSpectral(sine1k, fs);
  assert.ok(spectral.centerOfGravityHz !== null);
  assert.ok(
    Math.abs(spectral.centerOfGravityHz - 1000) < 25,
    `CoG=${spectral.centerOfGravityHz}`,
  );
  assert.ok(spectral.ltas.values.length > 10);

  const voice = engine.analyzeVoiceReport(vowel, fs);
  assert.ok(voice.pulses.length > 50);
  assert.ok(voice.meanPitchHz !== null && voice.meanPitchHz > 160);
  assert.ok(voice.meanHnrDb !== null);
  assert.equal(voice.numberOfVoiceBreaks, 0);
  assert.ok(voice.fractionLocallyUnvoiced < 0.1);
  assert.ok(voice.degreeOfVoiceBreaks < 0.1);
  assert.ok(voice.jitter.localRel !== null);
  assert.ok(voice.shimmer.localRel !== null);

  const cppsRes = engine.analyzeCpps(vowel, fs, {
    includeCepstrogram: true,
    maxTimeColumns: 100,
  });
  assert.ok(cppsRes.cppsDb !== null && cppsRes.cppsDb > 5.0);
  assert.ok(cppsRes.cepstrogram !== null);
  assert.ok(cppsRes.cepstrogram.numberOfTimeFrames <= 100);

  const mfccRes = engine.analyzeMfcc(vowel, fs, { numberOfCoefficients: 12 });
  assert.ok(mfccRes.frames.length > 50);
  assert.equal(mfccRes.frames[0].coeffs.length, 12);

  const melSg = engine.analyzeMelSpectrogram(sine1k, fs, { maxTimeColumns: 80 });
  assert.ok(melSg.scale === 'mel' && melSg.numberOfFilters >= 10);
  assert.ok(melSg.numberOfTimeFrames <= 80);

  const barkSg = engine.analyzeBarkSpectrogram(sine1k, fs, { maxTimeColumns: 80 });
  assert.ok(barkSg.scale === 'bark' && barkSg.numberOfFilters >= 15);
  assert.ok(barkSg.numberOfTimeFrames <= 80);

  const stretched = engine.manipulatePsola(vowel, fs, {
    durationFactor: 1.3,
    pitchShiftSemitones: 3.0,
  });
  assert.ok(Math.abs(stretched.length - vowel.length * 1.3) < 128);
  const shiftedPitch = engine.analyzePitch(stretched, fs);
  const voicedShifted = shiftedPitch.frames.filter((f) => f.frequency !== null);
  const meanShifted =
    voicedShifted.reduce((s, f) => s + f.frequency, 0) / voicedShifted.length;
  // Original vowel glides 180->220 (~200 Hz); +3 semitones (~1.189x) -> ~238 Hz.
  assert.ok(meanShifted > 220 && meanShifted < 260, `meanShifted=${meanShifted}`);
});

test('analyzeTextGridSegments parses TextGrid and handles errors', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const samples = makeSine(220, fs, 1.0);
  const tg = `File type = "ooTextFile"
Object class = "TextGrid"
xmin = 0
xmax = 1.0
tiers? <exists>
size = 1
item []:
    item [1]:
        class = "IntervalTier"
        name = "vowels"
        xmin = 0
        xmax = 1.0
        intervals: size = 1
        intervals [1]:
            xmin = 0.2
            xmax = 0.8
            text = "a"
`;
  const segs = engine.analyzeTextGridSegments(samples, fs, tg, {
    tierName: 'vowels',
  });
  assert.equal(segs.length, 1);
  assert.equal(segs[0].label, 'a');
  assert.equal(segs[0].trajectory.length, 3);
  assert.ok(segs[0].f0Mean !== null && Math.abs(segs[0].f0Mean - 220) < 1);
  assert.ok(segs[0].intensityMean !== null);

  assert.throws(
    () => engine.analyzeTextGridSegments(samples, fs, 'invalid textgrid'),
    /TextGrid line/,
  );
});

test('NganStreamSession handles incremental 128-sample chunks via WASM ring buffer', async () => {
  const engine = await enginePromise;
  const fs = 16000;
  const vowel = makeVowel(180, 240, fs, 1.5);
  const emitted = [];

  const session = engine.createStreamSession({
    sampleRate: fs,
    historyDurationSeconds: 3.0,
    windowDurationSeconds: 0.08,
    hopDurationSeconds: 0.025,
    onFrame: (frame) => emitted.push(frame),
  });

  // Feed in 128-sample AudioWorklet render quanta
  for (let offset = 0; offset < vowel.length; offset += 128) {
    const chunk = new Float32Array(
      vowel.subarray(offset, Math.min(vowel.length, offset + 128)),
    );
    session.pushSamples(chunk);
  }

  assert.equal(session.bufferedSamples, vowel.length);
  assert.equal(session.totalSamples, vowel.length);
  assert.ok(emitted.length >= 45, `expected >= 45 frames, got ${emitted.length}`);

  let prevTime = -1;
  let voicedCount = 0;
  for (const frame of emitted) {
    assert.ok(frame.time > prevTime);
    prevTime = frame.time;
    assert.ok(frame.rms > 0);
    assert.ok(frame.intensityDb !== null && Number.isFinite(frame.intensityDb));
    if (frame.pitch.frequency !== null) {
      voicedCount += 1;
      assert.ok(frame.pitch.frequency > 150 && frame.pitch.frequency < 270);
    }
  }
  assert.ok(voicedCount >= 35, `expected >= 35 voiced frames, got ${voicedCount}`);

  const last = emitted[emitted.length - 1];
  assert.ok(last.formants.length >= 2);
  assert.ok(Math.abs(last.formants[0].frequency - 500) < 120);
  assert.ok(Math.abs(last.formants[1].frequency - 1500) < 160);

  const recent = session.getRecentSamples(0.5);
  assert.equal(recent.length, 8000);
  assert.ok(Math.abs(recent[recent.length - 1] - vowel[vowel.length - 1]) < 1e-6);

  const fullRecent = session.analyzeRecentHistory(1.0, { spectrogram: true });
  assert.equal(fullRecent.sampleRate, fs);
  assert.ok(fullRecent.pitch.frames.length > 50);
  assert.ok(fullRecent.spectrogram && fullRecent.spectrogram.numberOfTimeFrames > 0);

  session.reset();
  assert.equal(session.bufferedSamples, 0);
  assert.equal(session.totalSamples, 0);
});

test('AudioWorklet processor downsamples 48 kHz stereo to 16 kHz mono hops cleanly', async () => {
  const engine = await enginePromise;
  const posted = [];
  let registeredName = null;
  let ProcessorClass = null;

  class MockAudioWorkletProcessor {
    constructor() {
      this.port = {
        onmessage: null,
        postMessage(msg) {
          posted.push(msg);
        },
      };
    }
  }

  const sandbox = {
    AudioWorkletProcessor: MockAudioWorkletProcessor,
    sampleRate: 48000,
    Float32Array,
    Math,
    JSON,
    registerProcessor(name, ctor) {
      registeredName = name;
      ProcessorClass = ctor;
    },
  };

  vm.runInNewContext(getWorkletProcessorSource(), sandbox);
  assert.equal(registeredName, NGAN_WORKLET_PROCESSOR_NAME);
  assert.ok(ProcessorClass !== null);

  const proc = new ProcessorClass({
    processorOptions: { targetSampleRate: 16000, hopSamples: 400 },
  });

  // Feed 0.5 s of 48 kHz stereo 220 Hz sine in 128-sample render quanta
  const inRate = 48000;
  const totalIn = inRate * 0.5;
  for (let off = 0; off < totalIn; off += 128) {
    const len = Math.min(128, totalIn - off);
    const chL = new Float32Array(len);
    const chR = new Float32Array(len);
    for (let i = 0; i < len; i++) {
      const s = Math.sin((2 * Math.PI * 220 * (off + i)) / inRate);
      chL[i] = s;
      chR[i] = s;
    }
    const keepAlive = proc.process([[chL, chR]], [[]], {});
    assert.equal(keepAlive, true);
  }

  assert.ok(posted.length >= 18, `expected >= 18 hops, got ${posted.length}`);
  assert.equal(posted[0].type, 'samples');
  assert.equal(posted[0].sampleRate, 16000);
  assert.equal(posted[0].samples.length, 400);

  const combined = new Float32Array(posted.length * 400);
  for (let i = 0; i < posted.length; i++) {
    combined.set(posted[i].samples, i * 400);
  }

  const pt = engine.analyzePitch(combined, 16000);
  const voiced = pt.frames.filter((f) => f.frequency !== null);
  assert.ok(voiced.length > 10);
  const midF0 = voiced[Math.floor(voiced.length / 2)].frequency;
  assert.ok(Math.abs(midF0 - 220) < 1.0, `expected ~220 Hz, got ${midF0}`);

  // Verify pause / resume control
  const countBeforePause = posted.length;
  proc.port.onmessage({ data: { type: 'pause' } });
  const dummy = new Float32Array(128);
  for (let k = 0; k < 20; k++) proc.process([[dummy]], [[]], {});
  assert.equal(posted.length, countBeforePause);
  proc.port.onmessage({ data: { type: 'resume' } });
  proc.port.onmessage({ data: { type: 'reset' } });
});

test('Float64RingBuffer, resampleSinc, and psychoacoustic scales', () => {
  const rb = new Float64RingBuffer(4);
  rb.pushChunk([1, 2, 3, 4, 5, 6]);
  assert.equal(rb.length, 4);
  assert.equal(rb.totalPushed, 6);
  assert.deepEqual(Array.from(rb.readLatest(4)), [3, 4, 5, 6]);
  assert.deepEqual(Array.from(rb.readLatest(2)), [5, 6]);
  rb.clear();
  assert.equal(rb.length, 0);

  const s48 = makeSine(440, 48000, 0.25);
  const s16 = resampleSinc(s48, 48000, 16000);
  assert.equal(s16.length, 4000);

  assert.ok(Math.abs(semitonesToHz(hzToSemitones(220)) - 220) < 1e-9);
  assert.ok(Math.abs(erbToHz(hzToErb(1000)) - 1000) < 1e-6);
  assert.ok(Math.abs(melToHz(hzToMel(1000)) - 1000) < 1e-6);
  assert.ok(Math.abs(barkToHz(hzToBark(1000)) - 1000) < 1e-6);
});
