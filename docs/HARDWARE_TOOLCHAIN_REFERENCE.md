# 硬件、官方IP与工具链速查

> 项目：今非昔比·可拼接多媒体对比终端  
> 工作目录：`D:\Download\嵌赛fpga_安路\eg4s20bg256\topic1_media_terminal\`  
> 只记录已核对的硬件事实、已用工具与资料路径；任何新约束以官方手册/原理图/已通过TD工程再次核对。

---

## 1. 硬件平台

| 项 | 值/事实 |
|---|---|
| 板卡 | HX4S20C，共两块，可按赛题允许做多板主从 |
| FPGA | 安路EG4S20BG256 |
| 单板逻辑资源 | 19,600 LUT / 19,600 REG（项目资料口径） |
| 单板DSP | 29个18×18 DSP |
| 单板片上SDRAM | `EG_PHY_SDRAM_2M_32`，2M×32bit=8MB，无外部SDRAM芯片/IO |
| 单板PLL | 4个 |
| 片上RAM | **两类独立 ERAM**：ERAM9K **9216 bit/块 × 64**、ERAM32K **32768 bit/块 × 16**（《内部块RAM用户指南》TN308_1.2 §3.1/§3.2；**9216×4 ≠ 32768 ⇒ 非"拆分/合并"关系，是两个独立物理池**，ERAM32K 配 2K×16 或 4K×8）。⚠️ **09-27 实测占用：9K 池 57/64（余 7 块）、32K 池 0/16（512Kb 全空）** —— **ERAM 已是 M6 第一瓶颈**，见 `iccoder_workspace/BACKLOG.md §F-0.1` |
| 板载参考时钟 | 50MHz，R7 |
| 复位 | KEY1，A2，低有效 |
| LED | 4颗独立LED：A4/A3/C10/B12，对应`led[0]..[3]`，**高电平点亮**（实测） |
| HDMI-B（当前稳定基线） | CLK_P/C3，D0_P/G5，D1_P/F1，D2_P/E1；TD依据LVDS33自动配对N端C2/G6/F2/D1；DDC SCL/P2、SDA/R2 |
| HDMI-A（后续可用） | D2_P/B3、D1_P/E3、D0_P/F5、CLK_P/K1；N端D3/E4/F4/J1；DDC SCL/P1、SDA/R1；**双板 GPIO 链路接线见 §2.5** |
| GPIO | J1/J2各40Pin、各36用户IO，可做OV5640或双板低速控制链路；具体线序必须回查原理图 |

### ERAM 落池规则（task_049 实测，2026-09-28）

**TD 对 EG4S20 的行为级 RAM 推断从不使用 ERAM32K** —— 22 组无引导实验 `bram32k` 恒 0
（含 1024×16 拆 2×9K、FFT 形状 4096×32 → 15×9K）；容量 / 形状 / 端口类型 / 输出寄存均不影响该选择。
**落 32K 池必须显式引导**，两条确定性入口（**均需明文源码**，加密 IP 改不动）：

| 入口 | 写法 | 实测 |
|---|---|---|
| 综合属性 | `(* ram_style = "bram_32k" *) reg [31:0] mem [0:4095];` | 4096×32 → **4 块 32K**（无引导时 15 块 9K） |
| 原语例化 | `EG_PHY_BRAM32K` / `EG_LOGIC_BRAM IMPLEMENT="32K"` / `EG_LOGIC_RAMFIFO IMPLEMENT="32K"`（定义见 `D:/AnLu/arch/eagle_macro.v`） | 各 1 块 32K |

**不存在"全局综合选项"类手段**：`report_param -detail` 对 EG4S20 全枚举 **20 项**（rtl 10 + gate 5 + flow 5）无任何块型开关；
7 组官方策略键逐项/成组实测零效果 ⇒ **加密 IP 内部的 RAM 无法迁入 32K**（厂商 FFT IP 因此不适用于 32K 方案）。

**两个必读陷阱**：
- 真双口写成 `if (rea) dout <= mem[raddr];`（带读使能）会让**推断全灭**（1024×16 → 40,186 LUT，超器件 205%），
  必须用 SWUG106 §5.6.7 的**无条件读**模板；
- **32K 块不支持 READBEFOREWRITE**（同端口先读后写 → `SYN-8418` 报错），须改用 NORMAL / 写穿通模板；9K 块无此限制。

**另**：`set_param` 设**未注册**参数**不报错也不生效** —— 判断参数是否存在必须以 `report_param -detail` 为准。

出处：`iccoder_workspace/tasks/task_049_eram32k_mapping_probe/doc/output/eram32k_probe_report.md`
（另有浮浮酱独立复现 4 组 + 自建 3000×32 交叉验证，见同任务 `acceptance_evidence/`）

### 1.1 片上SDRAM硬性规则

```text
禁止：配置任何外部 sdram_* IO，按外部16bit SDRAM假设设计，单相替换双相时钟。
必须：EG_PHY_SDRAM_2M_32 + 11bit addr + 32bit dq + dm0~dm3；硬核原语内部连线。
```

已验证硬件基线：Task 007。

- ctrl=125MHz 0°、mem=125MHz 180°；
- EM638325真实Die在125MHz下CL=3（CL=2不合法）；
- tRCD/tRP=3、tRFC=8、tREFI=1953拍；
- 上板`0110`判定通过。

Task 010自检专用降频版使用50MHz 0°/180°、刷新781拍，原因是640宽地址乘法锥在125MHz不收敛；它不是替代Task 007通用高带宽架构的默认选择。

---

## 2. 已验证IO/LED解释

| bit | 文件 | 板上成功现象 |
|---|---|---|
| Task 007 SDRAM | `iccoder_workspace\tasks\task_007_sdram_hw_bringup_fix\td_run\sdram_hw_selftest.bit` | 板载LED1闪、LED2常亮、LED3常亮、LED4灭；KEY1按下全灭 |
| Task 011 HDMI视频 | `iccoder_workspace\tasks\task_011_hdmi_video_white_screen_fix\td_run\hdmi_video_fixed.bit` | LED1/2/3常亮、LED4闪；HDMI-B显示8色彩条 |
| Task 010 BMP→SDRAM | `iccoder_workspace\tasks\task_012_bmp_sdram_hw_rework\reference\original_task010\td_run\bmp_sdram_loader.bit` | 历史失败基线，已被 V3 取代**勿再烧录**（原 task_010 目录已并入 Task 012 参考区） |

> 不要把不同任务的LED功能直接混同；先看各自`tb/handoff_packet.md`和顶层RTL注释。

---

## 2.5 双板 GPIO 链路（HDMI-A）接线

**用途**：062 / task_063 双板链路的物理层——主板（043 系）↔ 副板，以 HDMI-A 线缆承载 4 路低速单端信号。

**线缆形态**：一根 **HDMI 公对公线**，两端各接一块板的 **HDMI-A 座**（芯片侧均为 LVCMOS33 直驱，无 AC 耦合）。

| 线对 | 主板侧 | 副板侧（`dual_fft062.adc` 实测） | 用途 |
|---|---|---|---|
| D2（B3 / D3） | B3 输出 | `link_rx_data` = B3 输入；D3 恒低 | PCM 上行 |
| D0（F5 / F4） | F5 输入 | `link_tx_data` = F5 输出；F4 恒低 | 频谱回程 |
| D1（E3 / E4） | E3 输出 | E4 恒低（`return_low[1]`） | 上行 sync 观测 |
| CLK（K1 / J1） | K1 输出 | J1 恒低（`return_low[2]`） | 上行 clock 观测（接收端禁用其采样） |

**电气前置检查（2026-10-09 主人确认）**：+5V（脚 18）、HPD（脚 19）、DDC（SCL/SDA）、CEC（脚 13）**均无冲突** ⇒ **标准 HDMI 线直连即可，无需改造线**；GND 经线缆共地（必需）。

**工程注意**：

- 线长建议 **≤1 m**（1.5625 Mbps 极低速，信号余量巨大）；
- **物理层尚未实测**：P0 阶段为芯片内自环、无线缆（协议原文"P0 没有接线，双向电气与 BER 未验收"）⇒ 线缆电气、BER、拔线恢复属 **④-b 验收项**；
- **接线时机**：主板侧 C1 集成 bit 出位后（task_063 为离线账包、不出 bit）方可接测；
- 双板联调步骤与判据见 `docs/CONSULT_C1_ROADMAP_20261009.md` §5（收口证据清单）。

---

## 2.6 麦克风中继板引脚（**冻结 · 2026-10-14**）

**状态**：四路 I2S 麦克风中继板**已按下表画板** ⇒ **引脚分配冻结**；后续 FPGA 逻辑（采集链）**必须按此实现，不得更改**。
**出处**：`docs/音频采集板要求.md` §12.2（**该文件已分发给硬件队友，线序以此表为准**）。

> **2026-10-27 正式约束核对**：当前副R34B/R37/R40的J1-21/G16已用于 `audio_din` 输出到功放，不能再当预留麦克风输入；MIC1/H13在这些正式ADC中为 `PULLDOWN`。本说明只更正文档，不更改引脚或ADC。

| 信号 | J1 脚位 | **FPGA 球脚** | 方向 | 说明 |
|---|---|---|---|---|
| `mic_bclk` | 1 | **D14** | 输出 | 位时钟（3.07~3.13 MHz，全通道共享） |
| `mic_lrck` | 3 | **G12** | 输出 | 帧时钟（48 kHz 量级，全通道共享） |
| `mic_sd[0]` | 5 | **H13** | 输入 | MIC1 数据 |
| `mic_sd[1]` | 7 | **J14** | 输入 | MIC2 数据 |
| `mic_sd[2]` | 9 | **K12** | 输入 | MIC3 数据 |
| `mic_sd[3]` | 13 | **M14** | 输入 | MIC4 数据 |
| `audio_din` | 21 | **G16** | 输出 | 当前副板I²S数据输出，接功放DIN |
| （历史扩展预留） | 23 / 25 / 27 | **K15 / H15 / K16** | 未分配 | 原8麦规划的其余连接位；当前位未声明对应麦克风端口 |
| — | 29 | — | 电源 | **3.3 V 取电** |
| — | 12、30 | — | 地 | **GND** |

**约束片段（照此写进 `.adc`）**：

```text
set_pin_assignment { mic_bclk  } { LOCATION = D14; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
set_pin_assignment { mic_lrck  } { LOCATION = G12; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
set_pin_assignment { mic_sd[0] } { LOCATION = H13; IOSTANDARD = LVCMOS33; PULLTYPE = PULLDOWN; }
set_pin_assignment { mic_sd[1] } { LOCATION = J14; IOSTANDARD = LVCMOS33; PULLTYPE = NONE; }
set_pin_assignment { mic_sd[2] } { LOCATION = K12; IOSTANDARD = LVCMOS33; PULLTYPE = NONE; }
set_pin_assignment { mic_sd[3] } { LOCATION = M14; IOSTANDARD = LVCMOS33; PULLTYPE = NONE; }
set_pin_assignment { audio_din } { LOCATION = G16; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; }
```

**⚠️ 三条必读**：

1. **连通性核对**（原为"落板前"，现**降级为"上电前必做"，因为板已画、无法再改**）：执行方预核报告指出 **原理图上 FPGA 侧网络名与手册连接器表对不上**（例：球脚 `M10` 手册写 `GPIOA_13`/脚 16，原理图读到的是 `GPIOB30`），且 **GPIOB 网络经 47 Ω 阵列交叉映射**。⇒ **首次上电前**：先只接 3.3 V/GND 量电压；再**单独验证 `mic_bclk`** —— 输出已知时钟，在该球脚与其对应 J1 脚上各量一次波形，**两边都出 3.07~3.13 MHz 才算映射正确**；
2. **当前正式约束的上下拉**：R34B/R37/R40中MIC1/H13为 `PULLDOWN`，MIC2/3/4为 `NONE`；功放G16行未显式指定PULLTYPE。后续硬件/约束调整须单独核对，不能把本表当作改动ADC的指令；
3. **不得随意改动现有分配**；未来若扩展麦克风，J1-21/G16已被功放使用，须另行做引脚和硬件架构评估。

## 2.7 副板 ANC 面板 IO（**规划 · 主人 2026-10-27 授权 · 尚未实现**）

**状态**：目前只存在于任务书 [GPT_ANC_SLAVE_OPT_TASKBOOK_20261026.md](../iccoder_workspace/HANDOFF/GPT_ANC_SLAVE_OPT_TASKBOOK_20261026.md) 的规划中，**R40/R42 及更早的所有副板位都没有这些端口**。只追加端口，不移动 §2.6 和副板现有的 20 个 IO；已与现有球位逐个核对，无冲突。新位出 bit 并上板后，再把本节改为“已验证”。

| 端口 | 球脚 | 电气 | 依据 | 用途（副板本地） |
|---|---|---|---|---|
| `key3` | **B1** | LVCMOS33，PULLUP，按下=0 | 与主板 `m1a_top.adc:28` 相同 | SW3固定频点：ARM态升一档；运行时数码管翻页 |
| `key4` | **C1** | LVCMOS33，PULLUP，按下=0 | 与主板 `m1a_top.adc:27` 相同 | SW3固定频点：ARM态降一档；运行时数码管翻页 |
| `sw[0..3]` = SW1..SW4 | **C8 / C7 / C6 / C5** | LVCMOS33，NONE，拨上=1 | 与主板 `m1a_top.adc:31-39` 相同（主板曾出过位序事故，以此为准） | SW1=AUTO谐波，SW2=AUTO多峰，SW3=固定频点，SW4=保留；只能拨上其中一个，多拨显示 `SW Err` |
| `seg_data[0..7]` | **C15 / C16 / B6 / A5 / B5 / A8 / A7 / A6** | LVCMOS33，驱动8mA，**低有效** | 官方例程 `lab_ex_6_tf_sdram_hdmi/top.adc:12-19` | 段码a..g、dp（例程 `seg_decoder.v` 中为 `{g,f,e,d,c,b,a}`，0=亮） |
| `seg_sel[0..5]` | **E12 / E10 / C13 / F10 / E11 / D11** | LVCMOS33，驱动8mA，**低有效** | 同上 `:20-25`，扫描写法见例程 `seg_scan.v` | 6位位选 |

**⚠️ 必读**：
1. `KEY1`（A2）仍是复位；`KEY2`（B2）的手势保持R40原样，只去掉ARM态“按住时长选频”这一项；
2. 表中的SW是**副板自己的拨码**；目前没有主→副命令协议，主板拨码不能控制副板ANC；
3. 数码管的物理位序（哪一位在最左）须用首颗bit上板确认；如果相反，只在顶层反序。

---

## 3. 时钟域速查

| 域 | 当前已用配置 | 职责 | 规则 |
|---|---|---|---|
| `clk_50m` | 50MHz输入R7 | 板级参考、PLL复位同步 | create_clock 20ns |
| SDRAM ctrl | Task007 125MHz 0°；Task010自检50MHz 0° | 控制器、加载器、帧缓冲状态机 | 目标域同步释放 |
| SDRAM mem | 对应频率180° | `EG_PHY_SDRAM_2M_32`采样 | 原语跨相位路径须有证据后精确约束 |
| HDMI pixel | 25.2MHz | 640×480 AXIS、IP输入、音频采样节拍 | `valid=DE`、VS后SOF、行末EOL |
| HDMI serial | 126MHz（5×pixel，ODDR等效10×） | TMDS串化 | 不盲改PHY/ODDR |
| audio_mclk | 12.3077MHz（预留） | 后续WAV/I2S参考 | 当前48kHz节拍由pixel域525周期精确生成 |
| OV5640 PCLK | 未实施 | 摄像头数据采集 | 后续用异步FIFO入系统域 |
| 双板GPIO | 未实施 | 低速控制/状态协议 | valid/toggle/ack+CRC，V-Blank安全应用 |

---

## 4. 官方资料与参考工程

| 资料/工程 | 路径 | 用途与边界 |
|---|---|---|
| HX4S20C完整例程 | `D:\Download\嵌赛fpga_安路\01_官方资源\例程_HX4S20C\` | 板级引脚、TF/SDRAM/HDMI/OV5640参考 |
| SDRAM/VGA例程 | `...\例程_HX4S20C\lab_ex_3_tf_sdram_vga\` | Task007硬件基线；PLL、片上SDRAM、ADC/SDC权威参考 |
| OV5640例程 | `...\例程_HX4S20C\lab_ex_5_ov5640_sdram_hdmi\` | Board B摄像头架构参考；不可直接搬最终RTL |
| TF/SDRAM/HDMI例程 | `...\例程_HX4S20C\lab_ex_6_tf_sdram_hdmi\` | 低层链路/官方模块行为参考 |
| 官方竞赛例程 | `D:\Download\嵌赛fpga_安路\01_官方资源\例程_lab_ex_2026\` | `lab_ex4_tf`、`lab_ex5_i2s`，HDMI音频官方IP与TF链路参考 |
| HDMI音频IP文档 | `...\lab_ex5_i2s\doc\APUG092_HDMI1.4b_Transmitter_V1.0.docx` | 加密IP公开端口/参数合同 |
| HDMI IP wrapper | `...\lab_ex5_i2s\src\user_source\hdl_source\hdmi1.4b_transmitter_core\hdmi_1_4b_transmitter_core_wrapper.enc.v` | **绝不修改**；只调用 |
| EG4文档 | `D:\Download\嵌赛fpga_安路\01_官方资源\EG4S20数据手册\` | DSP/BRAM/PLL/Library指南 |
| 板卡手册/原理图 | `D:\Download\嵌赛fpga_安路\01_官方资源\赛题文档\HX4S20开发板手册-HDL版2410.pdf`、`原理图\` | 引脚与扩展接口最终权威 |
| 开源参考 | `D:\Download\嵌赛fpga_安路\02_开源资料\开源参考代码\README.md` | OSD、字幕、转场、缩放、双层、频谱；只能借思路/局部算法，遵守原创性规则 |
| 网页Hero参考 | `D:\Download\光电网站\参考资源\图片融合文本.txt` | Hero图片展开/背景退场/标题滑动的视觉语言，见设计文档7.1 |
| 开发指南图片 | `D:\Download\嵌赛fpga_安路\01_官方资源\赛题文档\` | 14张方法论图；项目化规则见`docs\CONTEST_DEVELOPMENT_GUIDE_ADAPTATION.md` |

---

## 4.1 安路 TD IP 库（本地 depot，可合法调用）

> 位置：`D:\AnLu\ip\depot\`（共91个IP目录）。查询入口：TD菜单 `Tools → IP Catalog`。
> **命名说明**：depot目录名带器件编码后缀（如`RAMF9F0D0P0_1.0`），IP Catalog界面显示简名（如`RAM`）。
> **合规性**：调用IP核属于合法依赖，不构成抄袭；但**禁止把明文IP源码复制进本项目`rtl/`**，依据见`docs/CODE_ORIGINALITY_RULES.md`第二节。

### 与本项目直接相关的 IP（逐项清单）

> ⚠️ **2026-09-27 勘误（实测复核，重要）**：本节原表头写作「**明文IP（iverilog可直接仿真，优先选用）**」，
> 经对 depot 逐目录 `grep "pragma protect"` 复核——**该分类严重失真**：
> 表中 **12 项有 10 项实为加密 IP**（含 `Scaler`、`FFT`/`FIR`），
> 只有 `RAM`/`ROM` 与基础逻辑元件是真明文。
> **选型前必须逐项实测加密状态，不得据本节旧分类推断可仿真性。**
> 加密 IP 的仿真路径 = **ModelSim + 公钥解密**（`D:\AnLu\pubkey\`）或**上板**，验证代价须计入任务包。

| IP | depot路径 | 可替代的本项目功能 | 09-27 实测 |
|---|---|---|---|
| `RAM` / `ROM` | `RAMF9F0D0P0_1.0/`、`ROMF9F0D0P0_1.0/` | 字符ROM、字库、行缓存 | ✅ **明文** |
| `Concat`/`Constant`/`Utility Vector Logic`/`Utility Reduced Logic`/`Utility Buffer` | 同名目录 | 基础逻辑元件 | ✅ **明文** |
| `Scaler` 1.0 | `Scaler_1.0/scaler/RTL/scaler.v` | 图片缩放适配（**原计划自研双线性已交付 041，无需求**） | ❌ **加密** |
| `Video_In_to_AXI4_Stream` 1.0 | `Video_In_to_AXI4_Stream_1.0/` | 视频时序→AXIS桥接 | ❌ **加密** |
| `AXI4_Stream_to_Video_Out` 1.0 | `AXI4_Stream_to_Video_Out_1.0/` | AXIS→视频时序 | ❌ **加密** |
| `Soft_FIFO` 3.0 | `Soft_FIFO_3.0/` | 跨时钟域FIFO | ❌ **加密** |
| `AXIS Data FIFO` 1.0 | `AXIS_Data_FIFO_1.0/` | AXIS流缓冲 | ❌ **加密** |
| `AXIS Clock Converter` 1.0 | `AXIS_Clock_Converter_1.0/` | AXIS跨时钟域 | ❌ **加密** |
| `FFT` 1.0 / `FIR` 1.0 | `FFT_1.0/`、`FIR_1.0/` | 音频频谱分析 | ❌ **加密**（`fft_wrapper.v` 明文但 `fft_top.v` 实现段加密；参数化 AXIS 接口，`P_ARCH=2` 突发 / `P_CMPY_TYPE=2` CLB复数乘） |
| `AXI IIC` 1.0 | `AXI_IIC_1.0/` | OV5640的SCCB配置总线 | ❌ **加密** |
| `Divider` 2.0 | （AXIS接口，见IP Catalog） | 数码管/比例运算的除法 | ❌ **加密** |
| `DDR3_4_SDRAM` 1.1 | `DDR3_4_SDRAM_1.1/` | 参考用；本项目用片上`EG_PHY_SDRAM_2M_32` | ❌ **加密** |

### 其余加密IP（同类，未逐项复测）

| IP | 说明 |
|---|---|
| `SPI` 1.0 | SPI主/从控制器（SD卡物理层候选，但仅解决字节收发，协议层仍须自研） |
| `Video NPU` 1.1 | 图像处理加速 |
| `UART` 1.0 | 串口控制器 |
| `FloatingPoint` 2.0 | 浮点运算 |
| `AXI GPIO` / `AXI INTC` / `AXI ERAM Controller` / `apb to apb 16 bridge` | AXI外设类 |

> **经验事实（2026-09-27）**：depot 内**除 `RAM`/`ROM` 与基础逻辑元件外，几乎全部为加密 IP**。
> 凡依赖"明文可仿真"作为选型理由的判断，**一律须先实测**。

### 原语类（Primitive IP，随TD授权，`included`）

`ADC`、`DSP`(18×18乘法器)、`OSC`、`PLL`、`BUFG`、`IDDR`/`IDDRx2`、`ODDR`/`ODDRx2`/`ODDRx2L`、`Utility Buffer`、`DRAM`、`FIFO`、`RAM`、`ROM`、`SDRAM`、`Soft FIFO`。

> 原语与加密IP的公开端口/参数契约以`D:\AnLu\doc\IPUG\`与`D:\AnLu\doc\SWUG\`下对应手册为准。

### 选型决策链（写进每个任务的`## IP复用评估`）

```text
该功能是否已有可用IP?
    ├─ 有明文IP  → 优先选用(可iverilog仿真,验证成本低)
    ├─ 只有加密IP → 权衡:自研可仿真 vs 调IP需ModelSim/上板
    └─ 无匹配IP   → 自研,并写明"已查阅IP库,无匹配项"
```

---

## 5. 开发工具与命令

| 工具 | 路径 | 用途 |
|---|---|---|
| Icarus Verilog 12 | `C:\icarus\bin\iverilog.exe`/`vvp.exe` | 快速行为仿真；指定`export ICCODER_TOOLS_ROOT="C:/icarus/bin"` |
| ModelSim 10.5se | `D:\Modelsim_10.5se\win64\` | 官方加密IP/原语精确仿真；**work库必须在无中文路径** |
| Anlogic TD | `D:\AnLu\bin\td_commands_prompt.exe` | `read_hdl→read_adc→optimize_rtl→read_sdc→optimize_gate→legalize_phy_inst→place→route→bitgen` |
| Anlogic公钥 | `D:\AnLu\pubkey\` | TD/ModelSim解密官方`.enc.v`所需 |
| **ChipWatcher** | TD内置：`Tools → Debug Tools → ChipWatcher` | **片上逻辑分析仪**，无需外部设备，JTAG在线抓内部真实波形；用法见`docs\DEBUG_TOOLS_CHIPWATCHER.md` |
| EK-OmniProbe | `D:\EK-OmniProbe\ek-omniprobe.exe` | JTAG/在线逻辑分析，硬件疑难时使用 |

### 5.1 每个任务的最低验证命令

```bash
# 行为仿真（在任务工作区根目录）
export ICCODER_TOOLS_ROOT="C:/icarus/bin"
bash sim/run.sh

# TD（在任务td_run目录，使用该任务自己的tcl）
D:/AnLu/bin/td_commands_prompt.exe td_full_flow.tcl
```

规则：验收方先删除`sim/compile.log sim/sim.log sim/sim_result.json sim/*.vvp`再重跑；TD独立重跑必须复制源输入到隔离目录，避免覆盖执行方证据。

### 5.2 关键工具事实

- TD无自带功能仿真内核；功能仿真仍由Icarus/ModelSim完成。
- iverilog不支持官方`.enc.v`解密；加密IP任务的行为仿真只能用明确标注的stub做外部接口验证，真实IP行为需ModelSim或上板。
- `.adc`是安路语法，不能把Xilinx XDC属性直接写入。
- 不要把TD的通过当作HDMI画面/音频内容正确；最终看实拍和长稳。

---

## 6. 文件与产物路径原则

- 正式工程根：`topic1_media_terminal\`；隔离任务根：`topic1_media_terminal\iccoder_workspace\tasks\task_XXX_*\`。
- 执行方只在自己的任务目录写入；不得跨任务改已验收依赖或正式工程。
- `reference/`只读；`rtl/tb/sim/constraints/td_run/doc`才是本任务产物。
- 跑完Icarus/ModelSim清理`*.vvp/*.vcd/work/transcript`；保留源码、脚本、最终日志/JSON/报告。
- 最终赛事提交前要做原创性重构：去除官方来源、AI/模型、生成过程等注释；加密官方IP作为合法依赖，不修改其密文。
