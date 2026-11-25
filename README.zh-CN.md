# ngan

[English](README.md) · [简体中文](README.zh-CN.md)

[![CI](https://github.com/wrinh/ngan/actions/workflows/ci.yml/badge.svg)](https://github.com/wrinh/ngan/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/@wrinh/ngan.svg?logo=npm)](https://www.npmjs.com/package/@wrinh/ngan)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](LICENSE)
[![MoonBit WasmGC](https://img.shields.io/badge/MoonBit-WasmGC-purple.svg)](https://www.moonbitlang.com/)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-0-brightgreen.svg)](npm/package.json)

**ngan [ŋan]**（「[言](https://xtext.kkn.moe/?q=%E8%A8%80&mode=default)」）是一个基于纯 [MoonBit](https://www.moonbitlang.com/) 编写、编译至 **WebAssembly GC** 的 [Praat](https://www.fon.hum.uva.nl/praat/) 兼容声学分析与 TD-PSOLA 语音合成引擎。它从零实现了 Praat 的核心声学分析与语音变换管线，除 `moonbitlang/core` 外无任何第三方依赖，让浏览器、Web Worker 与 Node.js 应用无需引入 20 MB 级的 Emscripten C++ 编译产物即可获得与 Praat 对齐的数值结果。

## 已实现的 Praat 命令对照

| ngan 接口 | 对应 Praat 命令 | 核心算法 |
| --- | --- | --- |
| `@ngan.intensity` | `To Intensity...` | Kaiser-20 加窗平均能量，dB SPL（参考声压 `2e-5 Pa`） |
| `@ngan.pitch_ac` | `To Pitch (ac)...` | Boersma (1993) 归一化自相关 + Viterbi 路径搜索 |
| `@ngan.pitch_cc` | `To Pitch (cc)...` | 前向互相关（`FCC_NORMAL`）+ Viterbi 路径搜索 |
| `@ngan.pitch_filtered_ac` | `To Pitch (filtered ac)...` | Praat 6.4+ 频域高斯低通衰减自相关 + Viterbi 路径搜索 |
| `@ngan.harmonicity_ac` / `harmonicity_cc` | `To Harmonicity (ac/cc)...` | 高斯窗自相关 / 互相关谐噪比 HNR（dB） |
| `@ngan.point_process_cc` | `To PointProcess (periodic, cc)...` | 互相关声门脉冲点序列提取 |
| `@ngan.jitter` / `shimmer` / `voice_breaks` / `voice_report` | `Voice report...` | Local/RAP/PPQ5/DDP 频率微扰、Local/dB/APQ3/5/11/DDA 振幅微扰、清音帧占比与断音次数/程度 |
| `@ngan.formants` | `To Formant (burg)...` | 高斯窗 + Burg LPC + Durand-Kerner 多项式求根 |
| `@ngan.track_formants` | `Formant: Track...` | Viterbi 动态规划共振峰轨迹跟踪 |
| `@ngan.spectrogram` | `To Spectrogram...` | 高斯窗 FFT 功率谱密度语谱图（Pa²/Hz） |
| `@ngan.mel_spectrogram` / `bark_spectrogram` | `To MelSpectrogram...` / `To BarkSpectrogram...` | Mel 三角滤波器组与 Bark（Sekey–Hanson）听觉滤波器组（dB SPL） |
| `@ngan.mfcc` / `mel_spectrogram_to_mfcc` | `To MFCC...` | 基于 Mel 滤波器组的正交 DCT-II 倒谱系数 |
| `@ngan.power_cepstrogram` / `cpps` | `To PowerCepstrogram...` / `Get CPPS...` | 对数功率谱实倒谱平方 + 二维平滑 + 稳健/最小二乘基线回归 CPPS（dB） |
| `@ngan.ltas` / `spectrogram_to_ltas` | `To Ltas...` | 长时平均谱（dB/Hz）、频带均值与斜率 |
| `@ngan.center_of_gravity` / `spectral_tilt` | `Get centre of gravity...` | 谱重心、谱斜率、H1–H2、Iseli et al. 共振峰校正 H1\*–H2\*、H1–A1..A3 |
| `hz_to_semitones` / `erb` / `mel` / `bark` | `hertzToSemitones/Erb/Mel/Bark` | Praat 心理声学频率刻度互转 |
| `@ngan.parse_textgrid` / `analyze_textgrid_segments` | `.TextGrid` 与音段汇总 | Long/Short/Chronological TextGrid 解析 + F0/F1–F3/音强及 20%–50%–80% 动态轨迹点 |
| `@ngan.to_manipulation` / `resynthesize_psola` | `To Manipulation` / OLA 重合成 | TD-PSOLA 基频曲线与时长层级（DurationTier）重合成 |

算法均逐行对照 Praat 源码（`fon/Sound_to_Intensity.cpp`、`fon/Sound_to_Pitch.cpp`、`fon/Pitch.cpp`、`fon/Sound_to_Formant.cpp`、`fon/Sound_and_Spectrogram.cpp`、`dwtools/Cepstrum.cpp`、`dwtools/MFCC.cpp`、`dwsys/NUM2.cpp`）移植：窗函数、归一化方式、帧对齐公式与判决规则保持一致，详见下文 [*Praat 一致性说明*](#praat-一致性说明)。

## 快速开始（MoonBit）

```bash
moon check --target all               # 检查 native 与 wasm-gc 目标类型
moon test                             # 运行全部单元测试、白盒/黑盒测试与 README 文档测试
moon run cmd/main                     # 运行 CLI 示例：合成元音并执行分析
moon build --target wasm-gc --release # 构建 _build/wasm-gc/release/build/web/web.wasm
```

## MoonBit 使用示例

根包提供简洁的位置参数 ABI 与带命名参数的 Praat 对话框级接口：

```moonbit nocheck
// 一键分析音强、基频与共振峰
let result = @ngan.analyze_all(samples, 16000.0, 100.0, 75.0, 600.0, 5, 5500.0)

// Praat 6.4+ Filtered AC 基频提取
let pt = @ngan.pitch_filtered_ac(samples, sample_rate=16000.0)

// PowerCepstrogram 与 CPPS（平滑倒谱峰突出度）
let pc = @ngan.power_cepstrogram(samples, sample_rate=16000.0)
let cpps_db = @ngan.cpps(pc)

// 完整 Voice Report（含清音帧占比、断音次数与程度、Jitter/Shimmer/HNR）
let vr = @ngan.voice_report(samples, sample_rate=16000.0)

// Mel / Bark 语谱图与 MFCC
let mel_sg = @ngan.mel_spectrogram(samples, sample_rate=16000.0)
let bark_sg = @ngan.bark_spectrogram(samples, sample_rate=16000.0)
let mfcc_res = @ngan.mfcc(samples, sample_rate=16000.0, number_of_coefficients=12)

// TD-PSOLA 音高与时长操作
let out = @ngan.resynthesize_psola(
  samples,
  sample_rate=16000.0,
  pitch_shift_semitones=3.0,
  duration_factor=1.25,
)
```

## TypeScript / JavaScript SDK（`@wrinh/ngan`）

[`npm/`](npm/README.md) 目录提供零运行时依赖的 TypeScript SDK（`@wrinh/ngan`），包含完整 `.d.ts` 类型声明、Web Audio API 解码/重采样桥接（`decodeAudio`）、开箱即用的 **Web Worker 后台线程封装**（`createNganWorker`）、**重叠保留（Overlap-Save）长音频流式分块分析**（`analyzeLongAudio` / `streamLongAudio` + `onProgress`），以及基于 `AudioWorklet` + WASM 环形缓冲区的**实时麦克风流式分析**（`startMicrophoneStream` / `createStreamSession`）。

> **运行环境要求**：支持 WebAssembly GC 与 `wasm:js-string` builtins 的运行时（Chrome 130+、Firefox 134+、Safari 18.4+ 或 Node.js 22+）。

### 安装

```bash
npm install @wrinh/ngan
```

### 1. 主线程直接分析与语音变换

```ts
import { createNgan, decodeAudio, spectrogramToDbMatrix } from '@wrinh/ngan';

const ngan = await createNgan();
const { samples, sampleRate } = await decodeAudio(audioFile, { targetSampleRate: 16000 });

// 综合声学分析（支持 Praat 6.4+ filtered_ac）
const result = ngan.analyzeAll(samples, sampleRate, {
  pitch: { method: 'filtered_ac', pitchFloor: 50, pitchCeiling: 800 },
  formants: { maxNumFormants: 5, maxFormantFreq: 5500, track: true },
  spectrogram: true,
});

// CPPS / MFCC / Mel & Bark 语谱图 / 完整 Voice Report
const { cppsDb } = ngan.analyzeCpps(samples, sampleRate);
const mfcc = ngan.analyzeMfcc(samples, sampleRate, { numberOfCoefficients: 12 });
const melSpec = ngan.analyzeMelSpectrogram(samples, sampleRate);
const barkSpec = ngan.analyzeBarkSpectrogram(samples, sampleRate);
const voice = ngan.analyzeVoiceReport(samples, sampleRate);

// TD-PSOLA 拖拽曲线移调与变速
const manipulated = ngan.manipulatePsola(samples, sampleRate, {
  pitchPoints: [
    { time: 0.0, frequency: 180 },
    { time: 0.8, frequency: 250 },
  ],
  durationFactor: 1.2,
});
```

### 2. Web Worker 后台线程与长音频分块流式分析

内置 `createNganWorker()` 同时支持浏览器 `Worker` 与 Node.js `worker_threads`，无需手动配置路径或胶水代码。配合 `analyzeLongAudio` / `streamLongAudio`，可通过 Overlap-Save 重叠分块分析数十分钟以上的超长录音而不阻塞 UI，并提供 `onProgress`、`onChunk` 与 `AbortSignal` 取消控制：

```ts
import { createNganWorker } from '@wrinh/ngan';

const worker = await createNganWorker();
const controller = new AbortController();

// 方式 A：分块分析并自动拼接为完整连续结果（支持进度与 ETA 回调）
const longResult = await worker.analyzeLongAudio(longSamples, sampleRate, {
  chunkDurationSeconds: 20,
  overlapDurationSeconds: 0.5,
  pitch: { method: 'filtered_ac' },
  formants: { track: true },
  melSpectrogram: true,
  mfcc: true,
  signal: controller.signal,
  onProgress(p) {
    console.log(
      `${p.percent.toFixed(1)}% (${p.chunkIndex + 1}/${p.totalChunks}) · 预计剩余 ${(p.estimatedRemainingMs / 1000).toFixed(1)}s`,
    );
  },
  onChunk(chunk) {
    console.log(`已完成分块 [${chunk.startTime}s .. ${chunk.endTime}s]`);
  },
});

// 方式 B：以 AsyncGenerator 流式逐块消费（适合边分析边渲染超长语谱图）
for await (const chunk of worker.streamLongAudio(longSamples, sampleRate, {
  chunkDurationSeconds: 10,
  spectrogram: true,
})) {
  renderChunkToCanvas(chunk);
}

await worker.terminate();
```

### 3. 实时麦克风流式分析（`AudioWorklet` + O(1) WASM 环形缓冲区）

```ts
const mic = await ngan.startMicrophoneStream({
  sampleRate: 16000,
  historyDurationSeconds: 5.0,
  windowDurationSeconds: 0.08,
  hopDurationSeconds: 0.025,
  onFrame(frame) {
    console.log(frame.time, frame.pitch.frequency, frame.formants, frame.intensityDb);
  },
});

// 无需重拷贝即可直接对最近缓冲历史做离线级完整分析
const snapshot = mic.session.analyzeRecentHistory(3.0, { spectrogram: true });
await mic.stop();
```

本地构建与测试 npm SDK（需 Node.js 22+）：

```bash
npm --prefix npm install
npm --prefix npm run build
npm --prefix npm test
```

## 项目结构

```text
ngan
├── moon.mod / moon.pkg   # MoonBit 模块配置与根导出门面
├── lib.mbt               # analyze_intensity / analyze_pitch / analyze_formants / analyze_all 等导出
├── types/                # 公共结果结构体与 Semitone/ERB/Mel/Bark 刻度换算
├── math/                 # 复数、Bessel I0、Durand-Kerner 多项式求根与 libm 封装
├── dsp/                  # 基2 FFT、互相关、Kaiser/Hann/Gaussian 窗、sinc 重采样、Burg LPC
├── analysis/             # 音强、基频(ac/cc/filtered ac)、HNR、声门脉冲、Jitter/Shimmer/断音、共振峰与跟踪、语谱图、倒谱/CPPS、Mel/Bark/MFCC、TD-PSOLA、LTAS、谱倾斜、TextGrid 汇总
├── textgrid/             # Praat .TextGrid 解析器与序列化器（Long / Short / Chronological）
├── web/                  # WASM-GC FFI 边界包（web.mbt），产出 @wrinh/ngan 的 ngan.wasm
├── npm/                  # TypeScript SDK（@wrinh/ngan）、Web Worker 封装、长音频分块与 AudioWorklet 流式捕获
└── cmd/main              # 命令行合成元音演示程序
```

## Praat 一致性说明

当早期的工程需求文档与 Praat 实际源码不一致时，ngan 均以 **Praat 实际行为** 为准：

- **Kaiser-20 音强窗**：使用 Praat 精确形状参数 `beta = 2 pi^2 + 0.5`（约 20.24，旁瓣低于 -100 dB），物理窗长 `6.4 / min_pitch` 秒（`3.2 / min_pitch` 为有效窗长）。
- **能量加权**：减去未加权窗均值后计算 `sum w (x - mean)^2 / sum w`。
- **基频窗与自相关归一化**：周期 Hann 窗 `0.5 - 0.5 cos(2 pi (i + 1) / (N + 1))`；局部均值在 ±1 个最长基音周期内计算；自相关同时除以信号与窗函数的零延迟值 `rx(tau) = (ra(tau)/ra(0)) / (rw(tau)/rw(0))`，并使用 Boersma (1993) 式 (22) 的 Hann 加权 sinc 插值精修峰值。
- **Filtered AC（Praat 6.4+）**：在自相关前执行频域高斯低通衰减滤波（`pitch_ceiling` 处衰减至 `attenuation_at_top`），默认采用 Praat 6.4+ 阈值（`50–800 Hz`、`voicing_threshold = 0.50`、`silence_threshold = 0.09`、`octave_cost = 0.055`），并支持 6 周期高斯窗 `very_accurate` 模式。
- **短时分析帧对齐**：统一遵循 Praat `Sampled_shortTermAnalysis` 对称布局公式：`t1 = mid - 0.5 * n * dt + 0.5 * dt`。
- **倒谱图与 CPPS**：重采样至 `2 * min(maximum_frequency, fs / 2)`、预加重并计算对数功率谱的实倒谱平方，支持平滑前/后去倾斜、直线/指数衰减基线回归（OLS 与 Tukey biweight 稳健回归）与抛物线寻峰。
- **Mel / Bark 与 MFCC**：Mel 采用 `550 * ln(1 + f / 550)` 三角滤波器组；Bark 采用 `7 * ln(f/650 + sqrt(1 + (f/650)^2))` 与 Sekey & Hanson (1984) 听觉滤波器响应；MFCC 采用正交 DCT-II。
- **TD-PSOLA**：基于 `PointProcess` 与分段线性 `DurationTier` 积分进行时间规整，清浊音分段分别采用两周期对称 Hanning 窗基频同步叠加与 5 ms 恒定帧移 COLA 叠加合成。

## 真实浏览器性能与 Praat 对比

以下为在 **Headless Microsoft Edge 158（V8 WasmGC）** 中实测 DSP 优化后的 `@wrinh/ngan`（`ngan.wasm` 体积 `187.55 KiB` / `192,055 B`）并与同机原生 **Praat 7.0**（C++）在完全相同的 16 kHz 单声道 WAV 测试集上的对比结果（`speech_5s.wav` 为 5.0 秒含两段 0.3 秒清音/静音断音的多段元音；`long_30s.wav` 为 30.0 秒音频）：

- **冷启动加载耗时（`ngan.wasm`）**：`createNgan()` 默认加载 `4.90 ms`（仅编译 `2.00 ms`），`fetch` + 初始化总计 `6.00–6.80 ms`；`createNganWorker()` 创建并初始化 Worker `17.80–19.70 ms`。
- **30 秒长音频 Web Worker 分块分析（`analyzeLongAudio`）**：`10 s` 分块、`0.5 s` 重叠（同时计算 Intensity + Pitch AC + Formants + `onProgress` 回调），中位耗时 `194.70 ms`（**RTF 0.00649**，约 **154.08 倍实时速度**）。

### `speech_5s.wav`（5.0 s / 16 kHz / 80,000 采样点）耗时与计算精度对比

| 命令 / 接口 | `ngan` 中位耗时 (ms) | Praat 7.0 平均耗时 (ms) | `ngan` 计算结果 | Praat 7.0 计算结果 | 数值差异 |
| --- | ---: | ---: | --- | --- | --- |
| `To Intensity...` | `1.80` | `1.44` | 618 帧，`77.9963 dB` | 618 帧，`77.9963 dB` | `-0.00003 dB` |
| `To Pitch (ac)...` | `9.95` | `2.25` | 439/497 浊音帧，`196.0066 Hz` | 439/497 浊音帧，`196.0066 Hz` | `-0.000001 Hz` |
| `To Pitch (cc)...` | `28.90` | `9.81` | 1312/1493 浊音帧，`195.9314 Hz` | 1312/1493 浊音帧，`195.9294 Hz` | `+0.0020 Hz` |
| `To Pitch (filtered ac)...` | `15.00` | `7.08` | 291/330 浊音帧，`196.0429 Hz` | 291/330 浊音帧，`196.0429 Hz` | `+0.000001 Hz` |
| `To Formant (burg)...` | `16.85` | `20.25` | 793 帧，F1 `617.75` / F2 `1547.97 Hz` | 793 帧，F1 `628.27` / F2 `1591.01 Hz` | `-10.52` / `-43.04 Hz` |
| `To Spectrogram...` | `6.90` | `1.81` | `2496 × 160`（零 JSON FFI） | — | — |
| `To Harmonicity (ac)...` | `59.85` | `24.06` | 431/489 有效帧，`20.6725 dB` | 431/489 有效帧，`20.6725 dB` | `+0.0000002 dB` |
| `Voice report...` | `73.60` | `18.08` | 2 次断音（`12.168%`），jitter `0.591%`，shimmer `1.326%` | 2 次断音（`12.168%`），jitter `0.589%`，shimmer `1.797%` | 断音完全一致，jitter `+0.001%`，shimmer `-0.47%` |
| `To PowerCepstrogram` + `Get CPPS` | `257.80` | `529.64` | `19.464 dB`（**比 Praat 快 2.05 倍**） | `19.256 dB` | `+0.208 dB` |
| `To MelSpectrogram...` | `3.20` | `9.07` | `994 × 15`（**比 Praat 快 2.84 倍**） | — | — |
| `To BarkSpectrogram...` | `4.15` | `92.54` | `994 × 22`（**比 Praat 快 22.30 倍**） | — | — |
| `To MFCC...` | `6.75` | `9.69` | 994 帧（**比 Praat 快 1.44 倍**） | 994 帧（Praat 非正交缩放） | 帧网格完全一致 |
| `To Manipulation` + OLA（`+4 st`） | `13.50` | `9.52` | `5.000 s`，F0 `246.923 Hz` | `5.000 s`，F0 `246.950 Hz` | `-0.027 Hz`（`0.01%`） |

> 说明：在单线程 Edge WasmGC 下，`ngan` 的 `Formants`、`CPPS`、`MFCC`、`MelSpectrogram` 与 `BarkSpectrogram` 耗时已全面优于原生 C++ 版 `Praat 7.0`；`VoiceReport` 顺序执行 `Pitch` + `PointProcess` + `Harmonicity`；`MFCC` 采用标准正交 `sqrt(1/N)` / `sqrt(2/N)` DCT-II 系数缩放。

### `@wrinh/ngan` 与 `praat-wasm` v6.4.6200 浏览器同条件对比（Edge 158）

在相同 Edge 158 环境下与 Emscripten C++ 编译的 `praat-wasm`（v6.4.6200）进行同条件对比：

- **包体积与冷启动**：
  - **WASM 体积**：`ngan.wasm` `192,055 B`（`187.55 KiB`）vs `praat.wasm` `24,665,614 B`（`23.52 MiB`），体积缩小 **128.4 倍**。
  - **本地冷加载 + 初始化**：`ngan` `6.00 ms` vs `praat-wasm` `211.60 ms`，冷启动快 **35.3 倍**；`createNganWorker()` 初始化 `17.80–19.70 ms`（`praat-wasm` Worker 启动报错 `Error: Worker error`）。

| 操作（`speech_5s.wav`，5.0 s / 16 kHz） | `ngan` 中位耗时 (ms) | `praat-wasm` 中位耗时 (ms) | 速度比（`praat-wasm / ngan`） |
| --- | ---: | ---: | ---: |
| `To Intensity...` | `1.70` | `24.45` | **快 14.38 倍** |
| `To Pitch (ac)...` | `9.70` | `17.55` | **快 1.81 倍** |
| `To Pitch (cc)...` | `28.25` | `993.10` | **快 35.15 倍** |
| `To Pitch (filtered ac)...` | `14.20` | `30.20` | **快 2.13 倍** |
| `To Formant (burg)...` | `15.60` | `224.35` | **快 14.38 倍** |
| `To Spectrogram...` | `7.05` | `38.30` | **快 5.43 倍** |
| `To Harmonicity (ac)...` | `58.50` | `140.00` | **快 2.39 倍** |
| `Voice report...` | `70.50` | `1266.50` | **快 17.96 倍** |
| `To PowerCepstrogram` + `Get CPPS` | `245.40` | `12,222.80` | **快 49.81 倍** |
| `To MelSpectrogram...` | `3.35` | `69.35` | **快 20.70 倍** |
| `To BarkSpectrogram...` | `3.90` | `270.45` | **快 69.35 倍** |
| `To MFCC...` | `7.20` | `95.05` | **快 13.20 倍** |
| `To Manipulation` + OLA（`+4 st`） | `13.80` | `137.25` | **快 9.95 倍** |

## 开源协议

**GPL-3.0-or-later** — 详见 [LICENSE](LICENSE)。

ngan 的分析模块（`analysis/*.mbt` 与 `dsp/window.mbt`）衍生自 Praat 的 GPL 开源 C++ 源码，因此整个仓库遵循 GPL-3.0-or-later 协议发布。ngan 与 Praat 官方项目无隶属关系；Praat 版权归 Paul Boersma 与 David Weenink 所有（<https://www.fon.hum.uva.nl/praat/>）。
