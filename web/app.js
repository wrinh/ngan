// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 ngan contributors

// ---- wasm module loading -------------------------------------------------

async function loadNgan() {
  const response = await fetch('./web.wasm');
  const bytes = await response.arrayBuffer();
  // The module imports its string constants as globals from module "_"
  // (the import name is the literal itself) and the "wasm:js-string"
  // builtins, which the engine provides when compiled with
  // { builtins: ['js-string'] } (Chrome 130+, Firefox 134+, Safari 18.4+).
  const mod = await WebAssembly.compile(bytes, { builtins: ['js-string'] });
  const imports = { _: {} };
  for (const im of WebAssembly.Module.imports(mod)) {
    if (im.module === '_' && im.kind === 'global') {
      imports._[im.name] = im.name;
    }
  }
  const instance = new WebAssembly.Instance(mod, imports);
  return instance.exports;
}

// ---- demo signal synthesis (JS twin of cmd/main) --------------------------

function synthesizeVowel() {
  const fs = 16000, n = Math.floor(fs * 1.5);
  const section = (freq, bw) => {
    const r = Math.exp(-Math.PI * bw / fs);
    const theta = 2 * Math.PI * freq / fs;
    return [-2 * r * Math.cos(theta), r * r];
  };
  const [s1a, s2] = section(500, 120);
  const [s1b] = section(1500, 120);
  const p1 = s1a + s1b, p2 = s1a * s1b + 2 * s2, p3 = (s1a + s1b) * s2, p4 = s2 * s2;
  const x = new Float64Array(n);
  let phase = 0;
  let sincePulse = 1000;
  for (let i = 0; i < n; i++) {
    const f0 = 180 + 60 * (i / n); // gentle F0 glide 180 -> 240 Hz
    phase += (2 * Math.PI * f0) / fs;
    if (phase >= 2 * Math.PI) {
      phase -= 2 * Math.PI;
      sincePulse = 0;
    } else {
      sincePulse++;
    }
    // Fixed-shape glottal pulse: amplitude must not depend on the
    // fractional phase, only the time since the last pulse.
    const pulse = Math.exp(-sincePulse * 0.15);
    const rnd = Math.sin((i + 1) * 12.9898) * 43758.5453;
    const noise = rnd - Math.floor(rnd);
    const e = pulse * 0.8 + noise * 0.02;
    x[i] = e - (i >= 1 ? p1 * x[i - 1] : 0) - (i >= 2 ? p2 * x[i - 2] : 0)
             - (i >= 3 ? p3 * x[i - 3] : 0) - (i >= 4 ? p4 * x[i - 4] : 0);
  }
  for (let i = n - 1; i >= 1; i--) x[i] -= x[i - 1]; // lip radiation
  return { samples: x, fs };
}

// ---- audio file loading & playback ---------------------------------------

async function decodeFile(file) {
  const arrayBuffer = await file.arrayBuffer();
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const buffer = await ctx.decodeAudioData(arrayBuffer);
  ctx.close();
  // Resample to 16 kHz mono and cap at 10 s for responsive browser processing.
  const fs = 16000;
  const seconds = Math.min(buffer.duration, 10);
  const length = Math.floor(seconds * fs);
  const offline = new OfflineAudioContext(1, length, fs);
  const src = offline.createBufferSource();
  src.buffer = buffer;
  src.connect(offline.destination);
  src.start();
  const rendered = await offline.startRendering();
  return { samples: rendered.getChannelData(0), fs };
}

let audioCtx = null;
let activeSource = null;

function playAudioBuffer(samples, fs) {
  if (!samples || samples.length === 0) return;
  if (!audioCtx) {
    audioCtx = new (window.AudioContext || window.webkitAudioContext)();
  }
  if (audioCtx.state === 'suspended') {
    audioCtx.resume();
  }
  if (activeSource) {
    try { activeSource.stop(); } catch {}
    activeSource = null;
  }
  const buf = audioCtx.createBuffer(1, samples.length, fs);
  const ch = buf.getChannelData(0);
  let peak = 0;
  for (let i = 0; i < samples.length; i++) {
    const a = Math.abs(samples[i]);
    if (a > peak) peak = a;
  }
  const gain = peak > 0.95 ? 0.9 / peak : 1.0;
  for (let i = 0; i < samples.length; i++) {
    ch[i] = samples[i] * gain;
  }
  const src = audioCtx.createBufferSource();
  src.buffer = buf;
  src.connect(audioCtx.destination);
  src.start();
  activeSource = src;
}

// ---- drawing --------------------------------------------------------------

const PALETTE = {
  bg: '#0b0e12', fg: '#8a97a6', grid: '#1c232c',
  pitch: '#62d0ff', pitchOrig: 'rgba(98, 208, 255, 0.35)',
  handle: '#ffb454',
  f1: '#ffb454', f2: '#7ee787', f3: '#ff7b72', intensity: '#d2a8ff',
};

function prepCanvas(id) {
  const canvas = document.getElementById(id);
  const dpr = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth || canvas.width;
  const height = parseInt(canvas.getAttribute('height'), 10) || canvas.height;
  canvas.width = cssWidth * dpr;
  canvas.height = height * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  return { canvas, ctx, w: cssWidth, h: height };
}

function frame(ctx, w, h, pad) {
  ctx.fillStyle = PALETTE.bg;
  ctx.fillRect(0, 0, w, h);
  ctx.strokeStyle = PALETTE.grid;
  ctx.lineWidth = 1;
  for (let gy = pad; gy <= h - pad; gy += (h - 2 * pad) / 4) {
    ctx.beginPath(); ctx.moveTo(pad, gy); ctx.lineTo(w - pad, gy); ctx.stroke();
  }
  ctx.strokeStyle = PALETTE.fg;
  ctx.strokeRect(pad, pad, w - 2 * pad, h - 2 * pad);
  return { x0: pad, x1: w - pad, y0: pad, y1: h - pad };
}

// inferno-like colormap for [0, 1]
function heat(t) {
  t = Math.max(0, Math.min(1, t));
  const stops = [
    [0, 0, 4], [22, 11, 57], [66, 10, 104], [106, 0, 131],
    [147, 38, 103], [188, 55, 84], [221, 74, 73], [245, 124, 61],
    [250, 192, 39], [252, 255, 164],
  ];
  const s = t * (stops.length - 1);
  const i = Math.min(stops.length - 2, Math.floor(s));
  const f = s - i;
  return stops[i].map((v, k) => Math.round(v + f * (stops[i + 1][k] - v)));
}

function drawHeatmapGrid(ctx, x0, x1, y0, y1, nt, nRows, getNorm) {
  const plotW = Math.max(1, Math.floor(x1 - x0));
  const plotH = Math.max(1, Math.floor(y1 - y0));
  const off = document.createElement('canvas');
  off.width = plotW;
  off.height = plotH;
  const octx = off.getContext('2d');
  const img = octx.createImageData(plotW, plotH);
  for (let py = 0; py < plotH; py++) {
    const row = Math.min(nRows - 1, Math.max(0, Math.round((1 - py / plotH) * (nRows - 1))));
    for (let px = 0; px < plotW; px++) {
      const col = Math.min(nt - 1, Math.max(0, Math.round((px / plotW) * (nt - 1))));
      const c = heat(getNorm(row, col));
      const o = (py * plotW + px) * 4;
      img.data[o] = c[0]; img.data[o + 1] = c[1]; img.data[o + 2] = c[2]; img.data[o + 3] = 255;
    }
  }
  octx.putImageData(img, 0, 0);
  ctx.drawImage(off, x0, y0, plotW, plotH);
}

function drawActiveSpectrogramView(mode) {
  if (!currentAnalysis) return;
  const { ctx, w, h } = prepCanvas('spectrogram');
  const pad = 34;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';

  if (mode === 'linear') {
    const sg = currentAnalysis.spectrogram;
    const nt = sg.numberOfTimeFrames, nf = sg.numberOfFrequencyBands;
    if (nt < 1 || nf < 1) return;
    const ref = sg.maxPower > 0 ? sg.maxPower : 1;
    const dbFloor = -60;
    drawHeatmapGrid(ctx, x0, x1, y0, y1, nt, nf, (b, col) => {
      const p = sg.power[b * nt + col];
      const db = p > 0 ? 10 * Math.log10(p / ref) : dbFloor;
      return (db - dbFloor) / -dbFloor;
    });
    const fmax = sg.f1 + (nf - 1) * sg.df;
    for (let k = 0; k <= 4; k++) {
      const f = (fmax * k) / 4;
      const y = y1 - (k / 4) * (y1 - y0);
      ctx.fillText((f / 1000).toFixed(1) + 'k', 2, y + 4);
    }
    const tEnd = sg.t1 + (nt - 1) * sg.dt;
    for (let k = 0; k <= 4; k++) {
      const t = sg.t1 + (k / 4) * (tEnd - sg.t1);
      ctx.fillText(t.toFixed(2) + 's', x0 + (k / 4) * (x1 - x0) - 14, h - 8);
    }
  } else if (mode === 'mel' || mode === 'bark') {
    const fb = mode === 'mel' ? currentAnalysis.melSpec : currentAnalysis.barkSpec;
    const nt = fb.numberOfTimeFrames, nf = fb.numberOfFilters;
    if (nt < 1 || nf < 1) return;
    let hi = -Infinity;
    for (const v of fb.values) if (v > hi) hi = v;
    if (!isFinite(hi)) hi = 90;
    const lo = hi - 60;
    drawHeatmapGrid(ctx, x0, x1, y0, y1, nt, nf, (b, col) => {
      const v = fb.values[b * nt + col];
      return (v - lo) / (hi - lo);
    });
    const fmax = fb.f1 + (nf - 1) * fb.df;
    const unit = mode === 'mel' ? 'mel' : 'Bk';
    for (let k = 0; k <= 4; k++) {
      const val = fb.f1 + (k / 4) * (fmax - fb.f1);
      const y = y1 - (k / 4) * (y1 - y0);
      ctx.fillText(Math.round(val) + (k === 4 ? unit : ''), 2, y + 4);
    }
    const tEnd = fb.t1 + (nt - 1) * fb.dt;
    for (let k = 0; k <= 4; k++) {
      const t = fb.t1 + (k / 4) * (tEnd - fb.t1);
      ctx.fillText(t.toFixed(2) + 's', x0 + (k / 4) * (x1 - x0) - 14, h - 8);
    }
  } else if (mode === 'cepstrogram') {
    const pc = currentAnalysis.cpps.cepstrogram;
    if (!pc || pc.numberOfTimeFrames < 1 || pc.numberOfQuefrencyBins < 1) return;
    const nt = pc.numberOfTimeFrames;
    const qMaxDisplay = 0.020; // display 0..20 ms quefrency (50 Hz..Nyquist)
    const nqShow = Math.min(
      pc.numberOfQuefrencyBins,
      Math.max(4, Math.floor((qMaxDisplay - pc.q1) / pc.dq) + 1),
    );
    let hi = -Infinity;
    for (let q = 2; q < nqShow; q++) {
      for (let t = 0; t < nt; t++) {
        const db = 10 * Math.log10(Math.max(pc.power[q * nt + t], 1e-30));
        if (db > hi) hi = db;
      }
    }
    if (!isFinite(hi)) hi = 0;
    const lo = hi - 35;
    drawHeatmapGrid(ctx, x0, x1, y0, y1, nt, nqShow, (q, col) => {
      const db = 10 * Math.log10(Math.max(pc.power[q * nt + col], 1e-30));
      return (db - lo) / (hi - lo);
    });
    for (let k = 0; k <= 4; k++) {
      const qMs = ((pc.q1 + (k / 4) * (nqShow - 1) * pc.dq) * 1000).toFixed(0);
      const y = y1 - (k / 4) * (y1 - y0);
      ctx.fillText(qMs + 'ms', 2, y + 4);
    }
    const tEnd = pc.t1 + (nt - 1) * pc.dt;
    for (let k = 0; k <= 4; k++) {
      const t = pc.t1 + (k / 4) * (tEnd - pc.t1);
      ctx.fillText(t.toFixed(2) + 's', x0 + (k / 4) * (x1 - x0) - 14, h - 8);
    }
  } else if (mode === 'mfcc') {
    const mf = currentAnalysis.mfcc;
    const nt = mf.frames.length;
    if (nt < 1 || mf.frames[0].coeffs.length < 1) return;
    const nc = mf.frames[0].coeffs.length;
    let maxAbs = 1;
    for (const fr of mf.frames) {
      for (const c of fr.coeffs) {
        if (Math.abs(c) > maxAbs) maxAbs = Math.abs(c);
      }
    }
    drawHeatmapGrid(ctx, x0, x1, y0, y1, nt, nc, (k, col) => {
      const v = mf.frames[col].coeffs[k];
      return (v + maxAbs) / (2 * maxAbs);
    });
    for (let k = 0; k <= 3; k++) {
      const cIdx = Math.round(1 + (k / 3) * (nc - 1));
      const y = y1 - (k / 3) * (y1 - y0);
      ctx.fillText('c' + cIdx, 6, y + 4);
    }
    const tEnd = mf.t1 + (nt - 1) * mf.dt;
    for (let k = 0; k <= 4; k++) {
      const t = mf.t1 + (k / 4) * (tEnd - mf.t1);
      ctx.fillText(t.toFixed(2) + 's', x0 + (k / 4) * (x1 - x0) - 14, h - 8);
    }
  }
}

const PITCH_PLOT = { pad: 34, fMin: 60, fMax: 450 };

function pitchToCanvasCoords(t, f, duration, w, h) {
  const { pad, fMin, fMax } = PITCH_PLOT;
  const x0 = pad, x1 = w - pad, y0 = pad, y1 = h - pad;
  return {
    x: x0 + (t / Math.max(1e-6, duration)) * (x1 - x0),
    y: y1 - ((f - fMin) / (fMax - fMin)) * (y1 - y0),
  };
}

function canvasCoordsToPitch(x, y, duration, w, h) {
  const { pad, fMin, fMax } = PITCH_PLOT;
  const x0 = pad, x1 = w - pad, y0 = pad, y1 = h - pad;
  const t = Math.max(0, Math.min(duration, ((x - x0) / (x1 - x0)) * duration));
  const f = Math.max(fMin, Math.min(fMax, fMin + ((y1 - y) / (y1 - y0)) * (fMax - fMin)));
  return { t, f };
}

function drawPitch() {
  if (!currentAnalysis) return;
  const { pitch, duration } = currentAnalysis;
  const { ctx, w, h } = prepCanvas('pitch');
  const { pad, fMin, fMax } = PITCH_PLOT;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const tx = (t) => x0 + (t / Math.max(1e-6, duration)) * (x1 - x0);
  const fy = (f) => y1 - ((f - fMin) / (fMax - fMin)) * (y1 - y0);

  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  for (let f = 100; f <= 400; f += 100) {
    ctx.fillText(f + '', 6, fy(f) + 4);
  }

  // Original analyzed F0 curve (dimmed reference).
  ctx.strokeStyle = PALETTE.pitchOrig;
  ctx.lineWidth = 1.5;
  ctx.setLineDash([4, 4]);
  let prev = null;
  ctx.beginPath();
  for (const fr of pitch.frames) {
    const f = fr.frequency;
    if (f == null || f < fMin || f > fMax) { prev = null; continue; }
    const x = tx(fr.time), y = fy(f);
    if (prev == null) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    prev = { x, y };
  }
  ctx.stroke();
  ctx.setLineDash([]);

  // Editable TD-PSOLA target pitch curve.
  if (editablePitchPoints.length > 0) {
    const shiftSemi = parseFloat(document.getElementById('psola-shift').value) || 0;
    const mult = Math.pow(2, shiftSemi / 12);
    ctx.strokeStyle = PALETTE.pitch;
    ctx.lineWidth = 2.2;
    ctx.beginPath();
    editablePitchPoints.forEach((pt, idx) => {
      const x = tx(pt.time);
      const y = fy(Math.max(fMin, Math.min(fMax, pt.frequency * mult)));
      if (idx === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    });
    ctx.stroke();

    for (let i = 0; i < editablePitchPoints.length; i++) {
      const pt = editablePitchPoints[i];
      const x = tx(pt.time);
      const y = fy(Math.max(fMin, Math.min(fMax, pt.frequency * mult)));
      ctx.fillStyle = i === activeControlIdx ? '#ffffff' : PALETTE.handle;
      ctx.beginPath();
      ctx.arc(x, y, i === activeControlIdx ? 6 : 4.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = '#0b0e12';
      ctx.lineWidth = 1.2;
      ctx.stroke();
    }
  }
}

function drawFormants(tier, duration) {
  const { ctx, w, h } = prepCanvas('formants');
  const pad = 34;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const fMax = 4500;
  const tx = (t) => x0 + (t / Math.max(1e-6, duration)) * (x1 - x0);
  const fy = (f) => y1 - (f / fMax) * (y1 - y0);
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  for (let f = 1000; f < fMax; f += 1000) ctx.fillText((f / 1000) + 'k', 6, fy(f) + 4);
  const colors = [PALETTE.f1, PALETTE.f2, PALETTE.f3];
  for (const fr of tier.frames) {
    for (let k = 0; k < Math.min(3, fr.formants.length); k++) {
      ctx.fillStyle = colors[k];
      ctx.fillRect(tx(fr.time) - 1.5, fy(fr.formants[k].frequency) - 1.5, 3.5, 3.5);
    }
  }
  ctx.font = '12px system-ui';
  ['F1', 'F2', 'F3'].forEach((label, k) => {
    ctx.fillStyle = colors[k];
    ctx.fillText(label, x1 - 70 + k * 24, y0 + 14);
  });
}

function drawIntensity(tier, duration) {
  const { ctx, w, h } = prepCanvas('intensity');
  const pad = 34;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const values = tier.values;
  let lo = Infinity, hi = -Infinity;
  for (const v of values) { if (v < lo) lo = v; if (v > hi) hi = v; }
  if (!isFinite(lo)) { lo = 0; hi = 1; }
  lo = Math.floor(lo - 5); hi = Math.ceil(hi + 3);
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  for (let k = 0; k <= 3; k++) {
    const v = lo + ((hi - lo) * k) / 3;
    const y = y1 - (k / 3) * (y1 - y0);
    ctx.fillText(Math.round(v) + '', 6, y + 4);
  }
  ctx.strokeStyle = PALETTE.intensity;
  ctx.lineWidth = 1.6;
  ctx.beginPath();
  values.forEach((v, i) => {
    const t = tier.t1 + i * tier.dt;
    const x = x0 + (t / Math.max(1e-6, duration)) * (x1 - x0);
    const y = y1 - ((v - lo) / (hi - lo)) * (y1 - y0);
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();
}

function drawWaveform(samples, duration) {
  const { ctx, w, h } = prepCanvas('waveform');
  const pad = 34;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  let peak = 1e-9;
  for (const v of samples) peak = Math.max(peak, Math.abs(v));
  const cols = Math.floor(x1 - x0);
  const midY = (y0 + y1) / 2;
  const scale = (y1 - y0) / 2;
  ctx.strokeStyle = PALETTE.intensity;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let px = 0; px < cols; px++) {
    const a = Math.floor((px / cols) * samples.length);
    const b = Math.max(a + 1, Math.floor(((px + 1) / cols) * samples.length));
    let lo = 1e9, hi = -1e9;
    for (let i = a; i < b && i < samples.length; i++) {
      if (samples[i] < lo) lo = samples[i];
      if (samples[i] > hi) hi = samples[i];
    }
    const x = x0 + px;
    ctx.moveTo(x, midY - (hi / peak) * scale);
    ctx.lineTo(x, midY - (lo / peak) * scale);
  }
  ctx.stroke();
}

// ---- orchestration & interactive TD-PSOLA --------------------------------

const statusEl = document.getElementById('status');
const summaryEl = document.getElementById('summary');
const voiceReportEl = document.getElementById('voice-report');
let wasm = null;
let currentAudio = null; // { samples, fs }
let currentAnalysis = null;
let editablePitchPoints = [];
let activeControlIdx = -1;

function writeSamplesToWasm(samples) {
  const n = wasm.alloc_samples(samples.length);
  for (let i = 0; i < n; i++) {
    wasm.set_sample(i, samples[i] ?? 0);
  }
  return n;
}

function buildEditablePitchControls(pitchTier, duration) {
  const voiced = pitchTier.frames.filter((f) => f.frequency != null);
  if (voiced.length === 0) {
    editablePitchPoints = [
      { time: 0, frequency: 150 },
      { time: duration, frequency: 150 },
    ];
    return;
  }
  const targetCount = Math.min(10, Math.max(3, voiced.length));
  const pts = [];
  for (let k = 0; k < targetCount; k++) {
    const idx = Math.round((k / (targetCount - 1)) * (voiced.length - 1));
    pts.push({ time: voiced[idx].time, frequency: voiced[idx].frequency });
  }
  editablePitchPoints = pts;
}

function run({ samples, fs }) {
  currentAudio = { samples, fs };
  const t0 = performance.now();
  writeSamplesToWasm(samples);

  const method = document.getElementById('pitch-method').value;
  const pitchJson =
    method === 'filtered_ac'
      ? wasm.analyze_pitch_filtered_ac_json(fs, 0.0, 50.0, 800.0, 15, 0, 0.03, 0.5, 0.09, 0.055, 0.35, 0.14)
      : wasm.analyze_pitch_json(fs, 0.0, 75.0, 600.0, 15, 0.45, 0.03, 0.01, 0.35, 0.14, method === 'cc' ? 1 : 0);

  const pitch = JSON.parse(pitchJson);
  const intensity = JSON.parse(wasm.analyze_intensity_json(fs, 100.0, 0.0, 1));
  const formants = JSON.parse(wasm.analyze_formants_json(fs, 0.0, 5, 5500.0, 0.025, 50.0, 0, 3, 550, 1650, 2750, 3850, 4950));
  const spectrogram = JSON.parse(wasm.analyze_spectrogram_json(fs, 0.005, 5000.0, 0.002, 20.0, 400));
  const melSpec = JSON.parse(wasm.analyze_filterbank_spectrogram_json(fs, 0, 0.015, 0.005, 100.0, 100.0, 0.0, 400));
  const barkSpec = JSON.parse(wasm.analyze_filterbank_spectrogram_json(fs, 1, 0.015, 0.005, 1.0, 1.0, 0.0, 400));
  const cpps = JSON.parse(wasm.analyze_cepstrogram_cpps_json(fs, 60.0, 0.002, 5000.0, 50.0, 1, 0.01, 0.001, 60.0, 330.0, 1, 240));
  const mfcc = JSON.parse(wasm.analyze_mfcc_json(fs, 12, 0.015, 0.005, 100.0, 100.0, 0.0));
  const voiceReport = JSON.parse(wasm.analyze_voice_report_json(fs, 75.0, 600.0, 1.3, 1.6));

  const ms = (performance.now() - t0).toFixed(0);
  const duration = samples.length / fs;
  currentAnalysis = { duration, pitch, intensity, formants, spectrogram, melSpec, barkSpec, cpps, mfcc, voiceReport };

  buildEditablePitchControls(pitch, duration);
  drawActiveSpectrogramView(document.getElementById('spec-mode').value);
  drawPitch();
  drawFormants(formants, duration);
  drawIntensity(intensity, duration);
  drawWaveform(samples, duration);

  const voiced = pitch.frames.filter((fr) => fr.frequency != null);
  const meanF0 = voiced.length ? voiced.reduce((s, fr) => s + fr.frequency, 0) / voiced.length : 0;
  let f1s = 0, f2s = 0, f1n = 0;
  for (const fr of formants.frames) {
    if (fr.formants.length >= 2) { f1s += fr.formants[0].frequency; f2s += fr.formants[1].frequency; f1n++; }
  }
  summaryEl.textContent =
    `${duration.toFixed(2)} s @ ${fs / 1000} kHz · analyzed in ${ms} ms · ` +
    `${voiced.length}/${pitch.frames.length} voiced frames` +
    (voiced.length ? ` · mean F0 ${meanF0.toFixed(1)} Hz` : '') +
    (f1n ? ` · mean F1 ${(f1s / f1n).toFixed(0)} Hz, F2 ${(f2s / f1n).toFixed(0)} Hz` : '');

  const vr = voiceReport;
  const cppsStr = cpps.cppsDb != null ? `${cpps.cppsDb.toFixed(2)} dB` : 'n/a';
  const hnrStr = vr.meanHnrDb != null ? `${vr.meanHnrDb.toFixed(1)} dB` : 'n/a';
  const jitStr = vr.jitter.localRel != null ? `${(vr.jitter.localRel * 100).toFixed(2)}%` : 'n/a';
  const shimStr = vr.shimmer.localRel != null ? `${(vr.shimmer.localRel * 100).toFixed(2)}%` : 'n/a';
  voiceReportEl.textContent =
    `Voice Report — CPPS: ${cppsStr} · Unvoiced: ${(vr.fractionLocallyUnvoiced * 100).toFixed(1)}% · ` +
    `Voice breaks: ${vr.numberOfVoiceBreaks} (${(vr.degreeOfVoiceBreaks * 100).toFixed(1)}%) · ` +
    `HNR: ${hnrStr} · Jitter: ${jitStr} · Shimmer: ${shimStr}`;

  statusEl.textContent = 'Done.';
}

function resynthesizeAndPlay() {
  if (!wasm || !currentAudio || !currentAnalysis) return;
  const { samples, fs } = currentAudio;
  writeSamplesToWasm(samples);
  const shiftSemi = parseFloat(document.getElementById('psola-shift').value) || 0;
  const durFactor = parseFloat(document.getElementById('psola-dur').value) || 1;
  const pitchCsv = editablePitchPoints.map((p) => `${p.time.toFixed(4)}:${p.frequency.toFixed(2)}`).join(' ');
  const t0 = performance.now();
  const outLen = wasm.manipulate_psola(fs, pitchCsv, '', 1.0, shiftSemi, durFactor, 75.0, 600.0);
  const out = new Float32Array(outLen);
  for (let i = 0; i < outLen; i++) {
    out[i] = wasm.get_out_sample(i);
  }
  const ms = (performance.now() - t0).toFixed(0);
  drawWaveform(out, outLen / fs);
  playAudioBuffer(out, fs);
  statusEl.textContent = `TD-PSOLA resynthesized ${outLen} samples in ${ms} ms.`;
}

// ---- interactive pitch canvas events -------------------------------------

const pitchCanvas = document.getElementById('pitch');

function getCanvasPointerPos(evt) {
  const rect = pitchCanvas.getBoundingClientRect();
  return { x: evt.clientX - rect.left, y: evt.clientY - rect.top, w: rect.width, h: rect.height };
}

pitchCanvas.addEventListener('pointerdown', (evt) => {
  if (!currentAnalysis || editablePitchPoints.length === 0) return;
  pitchCanvas.setPointerCapture(evt.pointerId);
  const { x, y, w, h } = getCanvasPointerPos(evt);
  const shiftSemi = parseFloat(document.getElementById('psola-shift').value) || 0;
  const mult = Math.pow(2, shiftSemi / 12);
  let bestIdx = 0;
  let bestDist = Infinity;
  editablePitchPoints.forEach((pt, i) => {
    const c = pitchToCanvasCoords(pt.time, pt.frequency * mult, currentAnalysis.duration, w, h);
    const d = Math.hypot(c.x - x, c.y - y);
    if (d < bestDist) { bestDist = d; bestIdx = i; }
  });
  activeControlIdx = bestIdx;
  const { f } = canvasCoordsToPitch(x, y, currentAnalysis.duration, w, h);
  editablePitchPoints[activeControlIdx].frequency = f / mult;
  drawPitch();
});

pitchCanvas.addEventListener('pointermove', (evt) => {
  if (activeControlIdx < 0 || !currentAnalysis) return;
  const { x, y, w, h } = getCanvasPointerPos(evt);
  const shiftSemi = parseFloat(document.getElementById('psola-shift').value) || 0;
  const mult = Math.pow(2, shiftSemi / 12);
  const { t, f } = canvasCoordsToPitch(x, y, currentAnalysis.duration, w, h);
  // Also allow scrubbing smoothly across nearest node if dragging horizontally.
  let idx = activeControlIdx;
  let bestT = Math.abs(editablePitchPoints[idx].time - t);
  editablePitchPoints.forEach((pt, i) => {
    const dt = Math.abs(pt.time - t);
    if (dt < bestT) { bestT = dt; idx = i; }
  });
  activeControlIdx = idx;
  editablePitchPoints[idx].frequency = f / mult;
  drawPitch();
});

function endDrag() {
  if (activeControlIdx >= 0) {
    activeControlIdx = -1;
    drawPitch();
    if (document.getElementById('psola-auto').checked) {
      resynthesizeAndPlay();
    }
  }
}

pitchCanvas.addEventListener('pointerup', endDrag);
pitchCanvas.addEventListener('pointercancel', endDrag);

// ---- UI button & slider listeners ----------------------------------------

document.getElementById('demo').addEventListener('click', () => {
  if (!wasm) return;
  statusEl.textContent = 'Synthesizing demo vowel (gliding 180→240 Hz, resonances 500/1500 Hz)…';
  setTimeout(() => run(synthesizeVowel()), 10);
});

document.getElementById('file').addEventListener('change', async (event) => {
  const file = event.target.files[0];
  if (!file || !wasm) return;
  statusEl.textContent = `Decoding ${file.name}…`;
  try {
    const audio = await decodeFile(file);
    statusEl.textContent = `Analyzing ${audio.samples.length} samples…`;
    setTimeout(() => run(audio), 10);
  } catch (err) {
    statusEl.textContent = `Could not decode audio: ${err}`;
  }
});

document.getElementById('pitch-method').addEventListener('change', () => {
  if (currentAudio && wasm) run(currentAudio);
});

document.getElementById('spec-mode').addEventListener('change', (e) => {
  drawActiveSpectrogramView(e.target.value);
});

document.getElementById('psola-shift').addEventListener('input', (e) => {
  document.getElementById('psola-shift-val').textContent = `${parseFloat(e.target.value).toFixed(1)} st`;
  drawPitch();
});

document.getElementById('psola-dur').addEventListener('input', (e) => {
  document.getElementById('psola-dur-val').textContent = `${parseFloat(e.target.value).toFixed(2)}×`;
});

document.getElementById('play-orig').addEventListener('click', () => {
  if (!currentAudio) return;
  drawWaveform(currentAudio.samples, currentAudio.samples.length / currentAudio.fs);
  playAudioBuffer(currentAudio.samples, currentAudio.fs);
});

document.getElementById('play-psola').addEventListener('click', resynthesizeAndPlay);

document.getElementById('reset-psola').addEventListener('click', () => {
  if (!currentAnalysis || !currentAudio) return;
  document.getElementById('psola-shift').value = '0';
  document.getElementById('psola-shift-val').textContent = '0.0 st';
  document.getElementById('psola-dur').value = '1.0';
  document.getElementById('psola-dur-val').textContent = '1.00×';
  buildEditablePitchControls(currentAnalysis.pitch, currentAnalysis.duration);
  drawPitch();
  drawWaveform(currentAudio.samples, currentAudio.duration);
});

loadNgan().then(
  (exports) => {
    wasm = exports;
    statusEl.textContent = 'Module ready — click "Generate demo vowel" or load an audio file.';
  },
  (err) => {
    statusEl.textContent =
      'This browser cannot run the WebAssembly GC module ' +
      '(needs Chrome 130+, Firefox 134+, or Safari 18.4+): ' + err;
  },
);
