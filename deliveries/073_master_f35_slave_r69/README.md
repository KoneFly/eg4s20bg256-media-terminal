# 今非昔比 · 多媒体对比终端 — 可复现交付包

2026-11-04。本包含主板与副板的全部 RTL、约束、构建脚本、仿真台、验证证据、位流，以及演示用 TF 卡素材。
按本文步骤可重新生成位流、重跑全部仿真与验证、重新制作卡内素材。

## 1. 版本

| 项 | 主板 F3.5 | 副板 R69 |
|---|---|---|
| 顶层模块 | `t073_master_top` | `slave_demo_physical_wrapper` |
| 器件 | EG4S20BG256（HX4S20C） | EG4S20BG256（HX4S20C） |
| 位流 | `bit/master_f35.bit` | `bit/slave_r69.bit` |
| SHA256 | `250e679b60af0246fe9be7d56c25e96a0bb58fa0d8d3834424a64e9dd2cc4661` | `55d30f56cc77801f5b952b32eb1feb2627fa75600d624fccb572f9f8f9911d4a` |
| PLB | 2390 / 2450 | 2431 / 2450 |
| Setup / Hold WNS | 3.750 / 0.230 ns，零违例 | 0.736 / 0.042 ns，零违例 |
| BRAM9K / 32K / DSP | 59 / 14 / 5 | 25 / 12 / 13 |

## 2. 目录

```
源码/
├─ 主板_F3.5/
│   ├─ rtl/           64 个 .v + 3 个头文件（媒体、显示、音频、板间链路）
│   ├─ vendor/        厂商 HDMI 1.4b 发送器加密 IP
│   ├─ constraints/   引脚 .adc、时钟 .sdc、首级例外 .tcl
│   ├─ td_run/        b1_sources.tcl（文件清单）、b1_gate.tcl、trial_bitgen.tcl、run_b1.sh、td_serial.py
│   ├─ tb/            整板系统台、BMP 加载台、FAT32 台、频谱叠加台、等价性台，以及卡模型与 SDRAM 模型
│   ├─ scripts/       各仿真台的运行脚本、素材转换与镜像生成工具
│   ├─ tools/         独立黄金生成器（C++）与字模表生成（Python）
│   ├─ sim/           sim_files.f（仿真文件清单，由 b1_sources.tcl 去掉替身模块后得到）
│   ├─ doc/           上板操作指南、按键表、门禁报告（area/timing/qor）、发布信息
│   ├─ verification/  引脚、协议身份、文件格式、重载与重启等价性等检查结果
│   └─ bit/           master_f35.bit
├─ 副板_R69/
│   ├─ rtl/           41 个 .v + 7 个头文件（采集、滤波、FFT、自适应、保护、输出、板间、显示）
│   ├─ constraints/   引脚 .adc、时钟 .sdc
│   ├─ td_run/        synth / place / route / complete_bitgen 四个 tcl，门禁报告与各阶段日志
│   ├─ tb/ tests/     副板逻辑测试与用例
│   ├─ validation/    整数控制器 + 保护器的六例验证（源码、输入、证据、脚本）
│   ├─ model/         声路模型结果、工作频段判据、量化系数与中间数据
│   ├─ control/       系数与 ROM 一致性校验脚本
│   ├─ evidence/ host/ models/ frequency_display/   采集与显示相关证据与工具
│   ├─ doc/           副板交付说明、上板指南、B1 与模型验证结果
│   └─ bit/           slave_r69.bit
├─ PC工具/            素材转换：BMP、V29 视频、测试镜像
└─ TF卡素材/          卡根目录应放的 16 个文件
```

## 3. 环境

| 用途 | 要求 |
|---|---|
| 综合/布局/布线/出位 | 安路 TD 6.2（命令行 `D:/AnLu/bin/td_commands_prompt.exe`），器件库 `eagle_s20.db` |
| 仿真 | WSL（Ubuntu）+ Verilator 5.x + g++；建议 `export OBJCACHE=ccache` |
| 素材与脚本 | Python 3.10+，`numpy`、`scipy`；`ffmpeg` 在 PATH 中 |
| 串口 | 副板诊断用 CH340 类 USB-UART，1 Mbps 8N1 |

TD 运行需能访问 `eagle_s20.db`。同一时刻只运行一个 TD 任务，`run_b1.sh` 可传一个锁文件路径实现串行。

## 4. 复现主板位流

```bash
cd 主板_F3.5/td_run
bash run_b1.sh                 # 后台跑完整流程，自动判门禁并在通过后出位
# 或手动：
#   td_commands_prompt.exe b1_gate.tcl
#   td_commands_prompt.exe trial_bitgen.tcl
```

- `b1_gate.tcl`：读入 `b1_sources.tcl` 的 65 个源文件 → 综合 → 门级优化 → 布局 → 布线 → 两轮时序修复 → 输出 `gate_b1.area/.ts/.timing/.qor` 与 `gate_b1.db`。
- `trial_bitgen.tcl`：从 `gate_b1.db` 出位到 `master_f35.bit`，并复核出位前后时序与资源一致。
- 门禁：PLB ≤ 2450、MSlice/LSlice ≤ 4900、零违例、`Setup ≥ 3.690 ns`、`Hold ≥ 0.214 ns`。
- 期望结果：PLB 2390、Setup 3.750 ns、Hold 0.230 ns；`gate_b1.area` 与 `doc/` 归档报告一致。

## 5. 复现主板仿真

全部在 WSL 中运行，脚本自动编译并打印判定行。

| 脚本 | 覆盖内容 | 期望 |
|---|---|---|
| `scripts/run_f3.sh` | 整板系统台：上电启动片→首图、菜单、图片/视频/音乐切换、暂停、图墙、三级采样、重载 | `RESULT PASS`，帧数约 200 |
| `scripts/run_bmp_cases.sh` | BMP 任意尺寸适配（8 种尺寸 × 行序 × 背压） | 8 个用例全部 `RESULT PASS` |
| `scripts/run_fat.sh` | FAT32 挂载、8.3 名查找、多段 extent | `RESULT PASS` |
| `scripts/run_spectrum.sh` | 频谱平滑、横向/纵向渐变、音柱与波形混合，逐像素对模型 | `RESULT PASS`，像素数 > 500 万 |
| `scripts/run_equiv.sh` | 淡入淡出两种实现逐位一致、WAV 解析新旧实现逐样本一致 | 两个台均 `RESULT PASS` |

整板系统台用真实顶层 + SD 卡模型 + 严格 SDRAM 模型，PLL 与 HDMI 发送器用 `tb/sim_stubs.v` 替身；
黄金帧由 `tools/gen_f0.cpp` 独立生成，不复用被测逻辑。

## 6. 复现副板位流

```bash
cd 副板_R69/td_run
td_commands_prompt.exe synth.tcl
td_commands_prompt.exe place.tcl
td_commands_prompt.exe route.tcl
echo ok > release_authorization.permit      # 出位前置检查文件
td_commands_prompt.exe complete_bitgen.tcl
```

- `synth.tcl` 读入 41 个源文件与 7 个头文件，输出 `gate.db`。
- `place.tcl` / `route.tcl` 分别导出 `combined.place.db`、`verified.db`。
- `complete_bitgen.tcl` 需要 `release_authorization.permit` 存在（流程保护），出位到 `slave_r69.bit`。
- 门禁：PLB ≤ 2450、MSlice/LSlice ≤ 4900、`Setup ≥ 0.200 ns`、`Hold ≥ 0.020 ns`、零违例。
- 期望结果：PLB 2431、Setup 0.736 ns、Hold 0.042 ns。

## 7. 复现副板验证

```bash
cd 副板_R69/validation
python -I run_validation.py
```

用包内 `validation/rtl` 编译整数控制器与保护器（Verilator），以 `model/effective/` 的实测声路作为被控对象，
跑 6 个用例（500 Hz、250→500、500→750 × 正常/半幅），结果写入 `evidence/RESULT.json`。
期望：6 例全部进入 RUN，0 饱和、0 削波，最大输出不超过 12288。

`control/verify_sf66.py` 与 `verify_dsp66.py` 用于核对系数函数、ROM 内容与 DSP 映射的一致性。

## 8. TF 卡素材

`TF卡素材/` 内 16 个文件直接复制到卡根目录（FAT32，512 B 扇区，簇 1–128 扇区，8.3 文件名）：

| 文件 | 内容 | 规格 |
|---|---|---|
| `PIC1.BMP` … `PIC8.BMP` | 八张图片（含 1920×1080 与 800×1200 各一张，用于演示任意尺寸适配） | 24 位无压缩 BMP |
| `WAV1.WAV` … `WAV4.WAV` | 音乐与单频验证音 | PCM 16 位、单声道、48 kHz |
| `VID00000.V29` … `VID00002.V29` | 三段短片（包内为 10 秒截取版） | V29 v2、640×480、RGB565、30 fps、带伴音 |
| `BOOT.V29` | 上电启动片（12 秒完整版，末帧与 `PIC1` 同画面） | V29 v2、640×480、RGB565、30 fps |

- **播放时长不受板载限制**：V29 是逐帧原始像素，板端按文件长度循环播放，没有帧数或时长上限；
  受约束的只有单个文件不超过 4 GB（FAT32）、卡容量与读卡带宽（RGB565@30 约 18.5 MB/s，实测上限 24.3 MB/s）。
  因此卡上实际使用的是每段 30 秒的完整版，包内 10 秒截取版只是为了把交付包控制在 200 MB 以内。
- 生成方式：图片用 `PC工具/make_bmp.py`；视频用 `主板_F3.5/scripts/make_v29.py --fmt 565 --fps 30`（可加 `--max-sec` 控制时长）；
  音频需 PCM16/48 kHz/单声道。`PC工具/trim_v29.py` 可对已有 V29 截取帧区间（`--head` 取片头、`--tail` 取片尾）。
- 视频码率需求 18.5 MB/s，SD 主机四线高速模式实测上限 24.3 MB/s，余量约 24%。若出现画面重复帧，可用 `--fmt 332` 重新生成（6.8 MB/s，画质有色带）。
- 包内音频为素材源版本；实际演示卡上如另有一版音频（时长不同），以卡上文件为准，替换 `WAV*.WAV` 即可。
- 启动片末帧必须与 `PIC1.BMP` 在 RGB565 域逐像素一致才能做到交接无黑帧；换图时需同步重新生成启动片。

## 9. 关键实现要点

| 环节 | 做法 |
|---|---|
| 读卡 | 原生四线 SD，开放式多块读，块池 8 槽，停钟流控；高速模式 50 MHz |
| 文件系统 | FAT32 只读，8.3 名，extent 索引；图片与音乐两个上下文分时共用读卡 |
| 帧存储 | 器件内 SDRAM 七页：视频三页、图片两页、图墙两页；四 bank 开页流水，写/读经仲裁 |
| 显示 | 每帧描述字驱动两层 DMA，帧边界原子切换；转场引擎逐像素一拍 |
| 图片 | 任意尺寸等比最近邻适配；÷1/÷2/÷4 三级采样由行地址与水平保持实现 |
| 图墙 | 读图时顺带写 ÷2 缩略图，显示时线性读，不额外占用片上 RAM |
| 音频 | 视频伴音、WAV、测试音共用一个音频桥；桥后 PCM 同时供板间链路 |
| 板间 | 自有串行协议，一根线缆承载主→副 PCM 与副→主两路频谱 |
| 副板采集 | 四路 I2S 数字麦克风：一路误差、一路参考、其余参与均值 |
| 副板处理 | 4 节二阶节滤波 → 4096 点 FFT（仅观测）→ 128 tap 声路模型 → 自适应系数更新 → I2S 反相输出 |
| 副板保护 | 增声检测、静音核查、等待源与首错快照；不因听感绕过保护 |

## 10. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 主板 PLB 超出 2450 | 确认使用包内 `rtl/` 与 `b1_sources.tcl`，不要混入其它版本文件 |
| 出位后时序与 §1 不同 | TD 版本或 seed 不同；以本次 `gate_b1.ts` 为准，门禁值不变 |
| 副板 `complete_bitgen.tcl` 报缺少许可文件 | 按 §6 创建 `release_authorization.permit` 空文件 |
| 仿真脚本报找不到 `sim/sim_files.f` | 该文件已提供；若被删除，可从 `b1_sources.tcl` 去掉 vendor 与替身模块后重新生成 |
| 启动片交接出现黑帧 | 启动片末帧与 `PIC1.BMP` 不一致，按 §8 重新生成 |
| 副板验证用例不进 RUN | 检查 `model/effective/` 四个声路文件是否完整，以及 `inputs/` 是否与之一致 |

## 11. 说明

- 注释按“只写电路行为与设计原因”整理过，个别文件 SHA 与位流封存记录不同，差异仅为注释；位流由整理前的源码生成，逻辑一致。
- `vendor/` 内为厂商加密 IP，不可读、不可改，仅随工程编译。
- 保留的 `FIXME` 表示已知限制（SD 采样点、D0/D1 半周期映射、SDRAM 突发模式、诊断计数未引出），不是未完成功能。
