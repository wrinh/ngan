# Praat 语音分析引擎 (MoonBit / Wasm-GC) 需求与技术规格说明书

## 1. 项目概述与业务背景

### 1.1 项目背景与核心痛点
Praat 是语言学、语音学与声学语音信号处理领域的黄金标杆软件。在现有的 Web 语音分析项目中，通常使用基于 Emscripten 交叉编译原生 Praat C/C++ 源码的方案（即 `praat-wasm`）。该方案在实际生产环境中暴露了诸多严峻问题：
1. **体积臃肿**：原版 Praat 绑定了大量老旧的图形界面库（X11/Motif 遗留层）和复杂基础设施，编译出的 Wasm 产物通常高达 **15MB ~ 30MB+**，首屏加载极慢。
2. **内存泄漏与生命周期风险**：依赖 Emscripten 传统的 Linear Memory（线性内存），在长会话音频流式处理或频繁单句分析时，`malloc/free` 易引发堆内存碎片与泄漏。
3. **不可拆分与黑盒维护**：原生 C 代码历史长达 30 余年，代码拓扑耦合度极高，无法按需裁剪或深度优化现代 Web Audio 管道。

### 1.2 项目定位与目标
本项目基于现代静态强类型编译语言 **MoonBit**，从底层重构 Praat 核心声学分析引擎，并编译为 **WebAssembly GC (Wasm-GC)** 模块。
* **启动与运行时开销**：冷启动实例化 $< 5\text{ ms}$，内存由宿主环境 GC 统一托管，杜绝内存泄漏。
* **算法级完全对齐 (Algorithmic Parity)**：在相同的分析参数下，计算结果与原生 Praat 官方内核相对误差控制在极低公差内（数值相对误差 $\le 0.1\%$）。

---

## 2. 核心需求与验收指标

### 2.1 精度与算法对齐指标
以官方 Praat (C/C++ CLI) 导出的文本矩阵为 Ground Truth：
* **音强 (Intensity)**：每帧能量分贝值（dB）绝对误差 $\le 0.05\text{ dB}$。
* **基频 (Pitch)**：
  * 清/浊音（Voiced/Unvoiced）判定一致率 $\ge 99.5\%$。
  * 浊音基频频率（Hz）相对误差 $\le 0.1\%$。
* **共振峰 (Formant)**：
  * 前 3 个主要共振峰（F1, F2, F3）频率相对误差 $\le 0.5\%$。
  * 共振峰带宽（Bandwidth）相对误差 $\le 1.0\%$。

### 2.2 性能指标
* **分析速度**：在标准移动端/桌面浏览器（Chrome V8 / Safari JavaScriptCore）中，针对 16kHz、5 秒单声道音频，全量分析（音强 + 基频 + 共振峰）耗时 $< 50\text{ ms}$（$\ge 100\times$ 实时处理速度）。
* **内存占用**：分析峰值堆内存增量 $< 10\text{ MB}$，分析完成后随 GC 自动回收。

---

## 3. 功能模块与算法规格

```
[原始音频 PCM] (Float32Array / Float64Array, 采样率 fs)
      │
      ├───────────────────────┬────────────────────────┐
      ▼                       ▼                        ▼
[音强模块 Intensity]    [基频模块 Pitch (AC)]     [共振峰模块 Formant (Burg)]
      │                       │                        │
  Kaiser-20 窗加权         Sinc 插值归一化自相关       带限 Sinc 降采样
  能量积分换算分贝             候选峰提取                预加重 (50 Hz)
      │                   Viterbi 动态规划追踪         高斯窗 + Burg 递推
      ▼                       ▼                   复数多项式求根
[IntensityTier]           [PitchTier]             极点过滤与轨迹跟踪
                                                       ▼
                                                 [FormantTier]
```

### 3.1 基础数学与 DSP 工具库规格（MoonBit 纯原生实现）
由于追求零外部依赖，底层必须自研以下纯函数算法模块：
1. **复数数学库 (`Complex`)**：支持复数基本四则运算、模长、幅角、共轭与极坐标变换。
2. **快速傅里叶变换 (`Radix-2 FFT / IFFT`)**：用于自相关函数（ACF）的高速时频卷积，时间复杂度 $\mathcal{O}(N \log N)$。
3. **带限 Sinc 插值重采样器 (`Sinc Resampler`)**：利用 Kaiser 加权的 Sinc 滤波器核实现任意采样率的无混叠升降采样。
4. **特殊数学函数**：零阶第一类修正贝塞尔函数 $I_0(x)$（用于 Kaiser 窗精确计算）。

---

### 3.2 模块一：音强分析 (Intensity Analysis)
对应 Praat 命令：`To Intensity...`

#### 3.2.1 分析参数定义
* `min_pitch`（默认 $100.0\text{ Hz}$）：最低基频，用于自适应决定窗口跨度。
* `time_step`（默认 $0.0\text{ s}$，自适应为 $\frac{0.75}{\text{min\_pitch}}$）。
* `subtract_mean`（默认 `true`）：计算前是否消除帧内均值直流偏置。

#### 3.2.2 算法实现步骤
1. **确定分析窗参数**：
   * 有效窗长：$T_{\text{window}} = \frac{3.2}{\text{min\_pitch}}$。
   * 离散点数：$N = \text{round}(T_{\text{window}} \cdot f_s)$。
2. **生成 Kaiser-20 分析窗**：
   Praat 采用旁瓣抑制超过 $100\text{ dB}$ 的 Kaiser 窗，形状因子 $\beta = 20\pi \approx 62.831853$：
   $$
   w[n] = \frac{I_0\left(\beta \sqrt{1 - \left(\frac{2n}{N-1} - 1\right)^2}\right)}{I_0(\beta)}, \quad 0 \le n < N
   $$
3. **加权能量与有效功率计算**：
   若 `subtract_mean == true`，先计算加权均值 $\bar{x}$ 并扣除，计算加权平均功率：
   $$
   E = \frac{\sum_{n=0}^{N-1} \left( w[n] \cdot (x[n] - \bar{x}) \right)^2}{\sum_{n=0}^{N-1} w[n]^2}
   $$
4. **声压级换算 (dB SPL)**：
   取听阈参考声压 $P_0 = 2 \times 10^{-5}\text{ Pa}$：
   $$
   \text{Intensity (dB)} = 10 \log_{10}\left( \max\left(\frac{E}{P_0^2}, 10^{-30}\right) \right)
   $$

---

### 3.3 模块二：基频分析 (Pitch Analysis - Accurate Autocorrelation)
对应 Praat 命令：`To Pitch (ac)...`（Boersma 1993 自相关算法）。

#### 3.3.1 分析参数定义
* `pitch_floor`（默认 $75.0\text{ Hz}$）：最低基频。
* `pitch_ceiling`（默认 $600.0\text{ Hz}$）：最高基频。
* `time_step`（默认 $0.75 / \text{pitch\_floor}$）。
* `max_candidates`（默认 $15$）：每帧保留的最大候选者数。
* `voicing_threshold`（默认 $0.45$）：清浊音判定阈值。
* `octave_cost`（默认 $0.01$）：偏向高频的八度惩罚系数。
* `octave_jump_cost`（默认 $0.35$）：相邻帧八度跳跃惩罚系数。
* `voiced_unvoiced_cost`（默认 $0.14$）：清浊音切换代价。

#### 3.3.2 算法实现步骤
1. **分帧与加 Hanning 窗**：
   * 窗长取 $T_w = \frac{3.0}{\text{pitch\_floor}}$。
   * 扣除信号局部均值，乘以 Hanning 窗：$w[n] = 0.5 - 0.5 \cos\left(\frac{2\pi n}{N-1}\right)$。
2. **窗函数自相关归一化 (Normalized ACF)**：
   Praat 的核心优势是消除由于窗边缘衰减对长周期滞后的削弱：
   $$
   r_x(\tau) = \sum_{n} x[n] x[n+\tau], \quad r_w(\tau) = \sum_{n} w[n] w[n+\tau]
   $$
   $$
   R(\tau) = \frac{r_x(\tau)}{r_w(\tau)} \quad \left(\text{定义范围: } \frac{f_s}{\text{pitch\_ceiling}} \le \tau \le \frac{f_s}{\text{pitch\_floor}}\right)
   $$
   通过将信号补零至 $2N$ 长度，利用 Radix-2 FFT 与 IFFT 在 $\mathcal{O}(N \log N)$ 复杂度内求解 $r_x(\tau)$。
3. **带限 Sinc 插值峰值微调**：
   对离散峰值点 $\tau_{\text{peak}}$，利用其前后邻域样本点执行 Sinc 插值，计算高精度的亚采样点连续极值偏移量 $\Delta \tau$：
   $$
   \tau_{\text{exact}} = \tau_{\text{peak}} + \Delta \tau, \quad f_0 = \frac{f_s}{\tau_{\text{exact}}}
   $$
4. **生成候选状态集 (Candidate Pool)**：
   * **候选 1（清音/无声假说）**：
     $$
     S_{\text{unvoiced}} = \text{voicing\_threshold} + \text{octave\_cost} \times \log_2\left(\frac{\text{pitch\_ceiling}}{\text{pitch\_floor}}\right)
     $$
   * **候选 $2 \dots M$（周期浊音假说）**：选取局部极大值，强度定义为：
     $$
     S_{\text{voiced}}(f_0) = R(\tau_{\text{exact}}) - \text{octave\_cost} \times \log_2\left(\frac{\text{pitch\_ceiling}}{f_0}\right)
     $$
5. **Viterbi 算法全局动态规划寻优**：
   在帧间构建网格图（Trellis），定义两帧候选间的转移代价：
   $$
   C_{\text{trans}}(c_1, c_2) = \begin{cases}
     0, & c_1, c_2 \text{ 均为清音} \\
     \text{voiced\_unvoiced\_cost}, & \text{一清一浊} \\
     \text{octave\_jump\_cost} \cdot \left| \log_2(f_1 / f_2) \right|, & c_1, c_2 \text{ 均为浊音}
   \end{cases}
   $$
   累计得分 $\max \sum \left( S_{\text{cand}} - C_{\text{trans}} \right)$，回溯得到全局最优基频轨迹。

---

### 3.4 模块三：共振峰分析 (Formant Analysis - Burg Method)
对应 Praat 命令：`To Formant (burg)...`

#### 3.4.1 分析参数定义
* `time_step`（默认 $0.0\text{ s}$，自适应为 $0.25 \times \text{window\_length}$）。
* `max_num_formants`（默认 $5.0$）：提取前 $N$ 个共振峰。
* `max_formant_freq`（默认 $5500.0\text{ Hz}$ 女性/通用，$5000.0\text{ Hz}$ 男性）。
* `window_length`（默认 $0.025\text{ s}$）。
* `pre_emphasis_from`（默认 $50.0\text{ Hz}$）：一阶预加重转折频率。

#### 3.4.2 算法实现步骤
1. **带限 Sinc 滤波重采样 (Resampling)**：
   将音频重采样至奈奎斯特频率覆盖共振峰上限的目标频率：
   $$
   f_{\text{target}} = 2 \times \text{max\_formant\_freq} \quad (\text{例如 } 5500\text{ Hz} \to 11000\text{ Hz})
   $$
   必须采用抗混叠带限 Sinc 插值，严禁使用失真严重的线性插值。
2. **预加重高通滤波 (Pre-emphasis)**：
   $$
   y[n] = x[n] - \alpha \cdot x[n-1], \quad \alpha = \exp\left(-2\pi \cdot \frac{\text{pre\_emphasis\_from}}{f_{\text{target}}}\right)
   $$
3. **高斯窗分帧**：
   Praat 截取长度为 $2 \times \text{window\_length}$ 的分析段，应用高斯窗：
   $$
   w[n] = \exp\left(-48.0 \cdot \left(\frac{n}{N-1} - 0.5\right)^2\right)
   $$
4. **Burg 线性预测系数 (LPC) 计算**：
   * 阶数设定：$P = 2 \times \text{max\_num\_formants}$（如 5 个共振峰设为 10 阶）。
   * 采用 Burg 算法递推反射系数 $k_m$，最小化前向误差 $f_m[n]$ 与后向误差 $b_m[n]$ 平方和：
     $$
     k_m = \frac{2 \sum_{n=m}^{N-1} f_{m-1}[n] b_{m-1}[n-1]}{\sum_{n=m}^{N-1} \left( f_{m-1}[n]^2 + b_{m-1}[n-1]^2 \right)}
     $$
   * 通过 Levinson 递推更新全极点滤波器系数向量 $A = [1, a_1, a_2, \dots, a_P]$。
5. **多项式复数求根与共振峰映射**：
   * 求解复数多项式 $A(z) = 1 + \sum_{k=1}^P a_k z^{-k} = 0$ 的 $P$ 个复根 $z_k$。采用 **Durand-Kerner 算法** 或 **伴随矩阵特征值法（QR 算法）**。
   * 对于上半平面的复数共轭根（虚部 $> 0$），计算其极坐标形式 $z = r e^{j\theta}$：
     $$
     F = \frac{\theta \cdot f_{\text{target}}}{2\pi} \quad (\text{共振峰频率 Hz})
     $$
     $$
     B = -\frac{\ln(r) \cdot f_{\text{target}}}{\pi} \quad (\text{共振峰带宽 Hz})
     $$
6. **极点筛选与物理共振峰排序**：
   * 过滤条件：剔除 $F < 50\text{ Hz}$、超过 $f_{\text{target}}/2 - 50\text{ Hz}$ 或带宽 $B > 700\text{ Hz}$ 的伪极点。
   * 剩余极点按频率 $F$ 升序排列，依次填入 F1, F2, F3... 并保留对应带宽。

---

## 4. 系统架构与 MoonBit 模块设计

### 4.1 项目包结构设计
```
praat_moonbit/
├── moon.mod.json
├── src/
│   ├── math/
│   │   ├── complex.mbt           # 复数基本运算与极坐标
│   │   ├── bessel.mbt            # I0 贝塞尔函数
│   │   └── polynomial_roots.mbt  # Durand-Kerner 复数多项式求根
│   ├── dsp/
│   │   ├── fft.mbt               # Radix-2 快速傅里叶变换
│   │   ├── window.mbt            # Kaiser, Hanning, Gaussian 窗生成
│   │   ├── resample.mbt          # Sinc 带限重采样
│   │   └── burg.mbt              # Burg 递推算法实现
│   ├── analysis/
│   │   ├── intensity.mbt         # 音强计算引擎
│   │   ├── pitch.mbt             # AC 自相关 + Viterbi 基频追踪
│   │   └── formant.mbt           # LPC 极点提取与共振峰跟踪
│   ├── types.mbt                 # 导出数据结构 (Tier / Frame)
│   └── lib.mbt                   # 对外统一公开接口
```

### 4.2 核心数据结构定义

```moonbit
// 单帧基频结果
pub struct PitchFrame {
  time : Double
  frequency : Double? // None 表示清音/静音 (Unvoiced)
  strength : Double   // 周期性强度度量 (0.0 ~ 1.0)
}

// 单个共振峰数据
pub struct FormantValue {
  frequency : Double
  bandwidth : Double
}

// 单帧共振峰结果
pub struct FormantFrame {
  time : Double
  formants : Array[FormantValue] // [F1, F2, F3, ...]
}

// 统一声学分析结果集
pub struct AcousticAnalysisResult {
  intensity_times : FixedArray[Double]
  intensity_values : FixedArray[Double]
  pitch_frames : Array[PitchFrame]
  formant_frames : Array[FormantFrame]
}
```

### 4.3 WebAssembly GC 与 JS 互操作设计 (ABI)

为了保证高效传输而不造成额外内存拷贝：
1. **输入管线**：
   宿主环境（Web Audio API / AudioBuffer）提供 `Float32Array` 音频 PCM 数据。通过 MoonBit 提供的外部适配函数，直接批量复制至 MoonBit 堆上的 `FixedArray[Double]`。
2. **导出接口**：
   暴露细粒度的执行函数与统一分析入口：
   ```moonbit
   pub fn analyze_intensity(
     samples : FixedArray[Double], 
     sample_rate : Double,
     min_pitch : Double
   ) -> IntensityTier
   
   pub fn analyze_pitch(
     samples : FixedArray[Double],
     sample_rate : Double,
     pitch_floor : Double,
     pitch_ceiling : Double
   ) -> PitchTier
   
   pub fn analyze_formants(
     samples : FixedArray[Double],
     sample_rate : Double,
     max_formants : Int,
     max_formant_freq : Double
   ) -> FormantTier
   ```
3. **输出序列化**：
   由于 Wasm-GC 支持高效的复合对象传递，复杂对象可直接由 MoonBit 自动生成的 JS 绑定传递给前端，无需手动解码 JSON 字符串。
