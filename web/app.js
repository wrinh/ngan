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
  return instance.exports.analyze_csv;
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

// ---- audio file loading ---------------------------------------------------

async function decodeFile(file) {
  const arrayBuffer = await file.arrayBuffer();
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  const buffer = await ctx.decodeAudioData(arrayBuffer);
  ctx.close();
  // Resample to 16 kHz mono and cap at 10 s to keep the CSV small.
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

// ---- drawing --------------------------------------------------------------

const PALETTE = {
  bg: '#0b0e12', fg: '#8a97a6', grid: '#1c232c',
  pitch: '#62d0ff', f1: '#ffb454', f2: '#7ee787', f3: '#ff7b72', intensity: '#d2a8ff',
};

function prepCanvas(id) {
  const canvas = document.getElementById(id);
  const dpr = window.devicePixelRatio || 1;
  const cssWidth = canvas.clientWidth || canvas.width;
  const height = canvas.height;
  canvas.width = cssWidth * dpr;
  canvas.height = height * dpr;
  const ctx = canvas.getContext('2d');
  ctx.scale(dpr, dpr);
  return { ctx, w: cssWidth, h: height };
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

// inferno-like colormap for dB in [floor, 0]
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
  const c = stops[i].map((v, k) => Math.round(v + f * (stops[i + 1][k] - v)));
  return c;
}

function drawSpectrogram(sg) {
  const { ctx, w, h } = prepCanvas('spectrogram');
  const pad = 30;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const plotW = Math.floor(x1 - x0), plotH = Math.floor(y1 - y0);
  // Render the heatmap into an offscreen canvas at 1:1 pixel scale and
  // stamp it with drawImage, which respects the devicePixelRatio
  // transform (putImageData does not, so the image would come out too
  // small on HiDPI screens).
  const off = document.createElement('canvas');
  off.width = plotW;
  off.height = plotH;
  const octx = off.getContext('2d');
  const img = octx.createImageData(plotW, plotH);
  const t0 = sg.t1, dt = sg.dt, nt = sg.nt;
  const f0 = sg.f1, df = sg.df, nf = sg.nf;
  const cols = img.width, rows = img.height;
  const dbFloor = -60;
  for (let py = 0; py < rows; py++) {
    const band = Math.min(nf - 1, Math.max(0, Math.round((1 - py / rows) * (nf - 1))));
    for (let px = 0; px < cols; px++) {
      const col = Math.min(nt - 1, Math.max(0, Math.round((px / cols) * (nt - 1))));
      const db = sg.db[col][band];
      const c = heat((db - dbFloor) / -dbFloor);
      const o = (py * cols + px) * 4;
      img.data[o] = c[0]; img.data[o + 1] = c[1]; img.data[o + 2] = c[2]; img.data[o + 3] = 255;
    }
  }
  octx.putImageData(img, 0, 0);
  ctx.drawImage(off, x0, y0, plotW, plotH);
  // axes
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  const fmax = f0 + (nf - 1) * df;
  for (let k = 0; k <= 4; k++) {
    const f = fmax * k / 4;
    const y = y1 - (k / 4) * (y1 - y0);
    ctx.fillText(Math.round(f / 1000) + 'k', 4, y + 4);
  }
  const tEnd = t0 + (nt - 1) * dt;
  for (let k = 0; k <= 4; k++) {
    const t = t0 + (k / 4) * (tEnd - t0);
    ctx.fillText(t.toFixed(2) + 's', x0 + (k / 4) * (x1 - x0) - 14, h - 8);
  }
}

function drawPitch(frames, duration) {
  const { ctx, w, h } = prepCanvas('pitch');
  const pad = 30;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const fMax = 350, fMin = 60;
  const tx = (t) => x0 + (t / duration) * (x1 - x0);
  const fy = (f) => y1 - ((f - fMin) / (fMax - fMin)) * (y1 - y0);
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  for (let f = 100; f <= 300; f += 100) {
    ctx.fillText(f + '', 6, fy(f) + 4);
  }
  ctx.strokeStyle = PALETTE.pitch;
  ctx.lineWidth = 1.6;
  let prev = null;
  ctx.beginPath();
  for (const [t, f] of frames) {
    if (f == null || f < fMin || f > fMax) { prev = null; continue; }
    const x = tx(t), y = fy(f);
    if (prev == null) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    prev = { x, y };
  }
  ctx.stroke();
  ctx.fillStyle = PALETTE.pitch;
  for (const [t, f] of frames) {
    if (f == null || f < fMin || f > fMax) continue;
    ctx.fillRect(tx(t) - 1, fy(f) - 1, 2.5, 2.5);
  }
}

function drawFormants(frames, duration) {
  const { ctx, w, h } = prepCanvas('formants');
  const pad = 30;
  const { x0, x1, y0, y1 } = frame(ctx, w, h, pad);
  const fMax = 4500;
  const tx = (t) => x0 + (t / duration) * (x1 - x0);
  const fy = (f) => y1 - (f / fMax) * (y1 - y0);
  ctx.fillStyle = PALETTE.fg;
  ctx.font = '11px system-ui';
  for (let f = 1000; f < fMax; f += 1000) ctx.fillText((f / 1000) + 'k', 6, fy(f) + 4);
  const colors = [PALETTE.f1, PALETTE.f2, PALETTE.f3];
  for (const [t, fs] of frames) {
    for (let k = 0; k < Math.min(3, fs.length); k++) {
      ctx.fillStyle = colors[k];
      ctx.fillRect(tx(t) - 1.5, fy(fs[k][0]) - 1.5, 3.5, 3.5);
    }
  }
  // legend
  ctx.font = '12px system-ui';
  const labels = ['F1', 'F2', 'F3'];
  labels.forEach((label, k) => {
    ctx.fillStyle = colors[k];
    ctx.fillText(label, x1 - 70 + k * 24, y0 + 14);
  });
}

function drawIntensity(tier, duration) {
  const { ctx, w, h } = prepCanvas('intensity');
  const pad = 30;
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
    const x = x0 + (t / duration) * (x1 - x0);
    const y = y1 - ((v - lo) / (hi - lo)) * (y1 - y0);
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();
}

function drawWaveform(samples, duration) {
  const { ctx, w, h } = prepCanvas('waveform');
  const pad = 30;
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

// ---- orchestration ---------------------------------------------------------

const statusEl = document.getElementById('status');
const summaryEl = document.getElementById('summary');
let analyze = null;

function samplesToCsv(samples) {
  const parts = new Array(samples.length);
  for (let i = 0; i < samples.length; i++) parts[i] = samples[i].toFixed(5);
  return parts.join(' ');
}

function run({ samples, fs }) {
  const t0 = performance.now();
  const json = analyze(samplesToCsv(samples), fs);
  const result = JSON.parse(json);
  const ms = (performance.now() - t0).toFixed(0);
  const duration = samples.length / fs;
  drawSpectrogram(result.spectrogram);
  drawPitch(result.pitch, duration);
  drawFormants(result.formants, duration);
  drawIntensity(result.intensity, duration);
  drawWaveform(samples, duration);
  const voiced = result.pitch.filter(([, f]) => f != null);
  const meanF0 = voiced.length ? voiced.reduce((s, [, f]) => s + f, 0) / voiced.length : 0;
  let f1s = 0, f2s = 0, f1n = 0;
  for (const [, fs] of result.formants) {
    if (fs.length >= 2) { f1s += fs[0][0]; f2s += fs[1][0]; f1n++; }
  }
  summaryEl.textContent =
    `${duration.toFixed(2)} s @ ${fs / 1000} kHz · analyzed in ${ms} ms · ` +
    `${voiced.length}/${result.pitch.length} voiced frames` +
    (voiced.length ? ` · mean F0 ${meanF0.toFixed(1)} Hz` : '') +
    (f1n ? ` · mean F1 ${(f1s / f1n).toFixed(0)} Hz, F2 ${(f2s / f1n).toFixed(0)} Hz` : '');
  statusEl.textContent = 'Done.';
}

document.getElementById('demo').addEventListener('click', () => {
  if (!analyze) return;
  statusEl.textContent = 'Synthesizing demo vowel (gliding 180→240 Hz, resonances 500/1500 Hz)…';
  setTimeout(() => run(synthesizeVowel()), 10);
});

document.getElementById('file').addEventListener('change', async (event) => {
  const file = event.target.files[0];
  if (!file || !analyze) return;
  statusEl.textContent = `Decoding ${file.name}…`;
  try {
    const audio = await decodeFile(file);
    statusEl.textContent = `Analyzing ${audio.samples.length} samples…`;
    setTimeout(() => run(audio), 10);
  } catch (err) {
    statusEl.textContent = `Could not decode audio: ${err}`;
  }
});

loadNgan().then(
  (fn) => {
    analyze = fn;
    statusEl.textContent = 'Module ready — click "Generate demo vowel" or load an audio file.';
  },
  (err) => {
    statusEl.textContent =
      'This browser cannot run the WebAssembly GC module ' +
      '(needs Chrome 130+, Firefox 134+, or Safari 18.4+): ' + err;
  },
);
