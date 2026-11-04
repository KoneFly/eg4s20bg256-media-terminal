# Interface Spec — pcb_dynamic_layer（W1 + W2）

> 最后核对日期：2026-10-04  
> 维护者：视觉子系统负责人  
> 状态：用户于 2026-10-04 确认 CONTRACT_CHANGE_PROPOSAL；正式端口保持原声明，内部行缓存按本修订冻结。后续变更须登记。  
> 依据：`spec/M6_PCB_SKETCH.md` §3、§6；`task_045_pcb_pixel_renderer/reference/gen_vectors.cjs` 的 `packState()`。

## 1. 端口声明

### 1.1 W2：`pcb_frame_updater`

W2 只在 50MHz 控制域运行。`spec_frame[k] = spec_frame[8*k +: 8]`，k=0 为 40Hz~16kHz 对数通道中的最低通道。

```verilog
module pcb_frame_updater (
    // 控制域
    input  wire         clk,
    input  wire         rst_n,

    // 每帧一次；高电平必须只持续一个 clk 周期
    input  wire         frame_tick,
    input  wire [1023:0] spec_frame,

    // 参数寄存器写口；ctrl 域，同步单拍写入
    input  wire         cfg_wr_en,
    input  wire [5:0]   cfg_wr_addr,
    input  wire [15:0]  cfg_wr_data,

    // W1 完成状态快照预取后的确认 toggle；异步输入，W2 内部 2FF 同步
    input  wire         snapshot_ack_toggle,

    // T1/T2：与 task_045 完全相同的状态表写语义
    output reg          state_wr_en,
    output reg          state_wr_sel,      // 0=T1 st_trace，1=T2 st_misc
    output reg  [7:0]   state_wr_addr,
    output reg  [31:0]  state_wr_data,
    output reg  [1:0]   state_wr_lane,    // T1: 0..3；T2: 忽略

    // P：粒子快照表，2048×16 的独立 ERAM32K bank；有效地址 0..1535
    output reg          part_wr_en,
    output reg  [10:0]  part_wr_addr,
    output reg  [15:0]  part_wr_data,

    // 跨域提交标记；最后一次状态/P 写入完成后翻转一次
    output reg          state_commit_toggle,

    // 调度/诊断状态
    output wire         frame_ready,
    output reg          frame_accept,
    output reg          frame_done,
    output reg          busy,
    output reg          err_valid,
    output reg  [3:0]   err_code
);
endmodule
```

### 1.2 W1：`pcb_particle_overlay`

W1 在 25.2MHz 像素域运行。输入坐标、径向调色板索引和有效信号来自同一条像素流；W1 不产生 HDMI 时序，也不访问 SDRAM。

```verilog
module pcb_particle_overlay (
    input  wire        clk,
    input  wire        rst_n,

    // 与 S2 同一条像素流；in_ridx 为该像素的径向 64 档调色板索引
    input  wire        in_valid,
    input  wire        in_sof,
    input  wire        in_eol,
    input  wire [9:0]  in_x,
    input  wire [8:0]  in_y,
    input  wire [5:0]  in_ridx,

    // W2 的 ctrl 域提交 toggle；本模块内部 2FF 同步
    input  wire        state_commit_toggle,

    // T2 读口：W1 只使用 64..127 音柱字和 137 全局字
    output wire [7:0]  st_misc_addr,
    input  wire [31:0] st_misc_rdata,

    // P 读口：同步读，读回数据在下一拍有效
    output wire [10:0]  part_rd_addr,
    input  wire [15:0]  part_rd_data,

    // 预取完成确认 toggle；回到 W2 后由 W2 内部 2FF 同步
    output reg         snapshot_ack_toggle,

    // 与输入固定延迟 D=647 拍对齐的覆盖层输出
    output reg         overlay_valid,
    output reg         overlay_hit,
    output reg  [15:0] overlay_rgb565,
    output reg  [7:0]  overlay_alpha,

    // sticky 诊断状态（正式端口，可接集成侧状态采集；不替代功能判据）
    output reg         bucket_overflow_sticky
);
endmodule
```

## 2. W2 帧接受与提交时序

1. `frame_tick=1` 且 `frame_ready=1` 时，W2 在该拍锁存完整 `spec_frame`，`frame_accept` 拉高一个周期；
2. `frame_tick=1` 且 `frame_ready=0` 时，不覆盖正在处理的帧，`err_valid` 锁存为 1、`err_code=4'h1`；
3. W2 完成内部动力学更新后，按以下固定顺序输出写口：
   - T1：地址 0..127，每个地址 `wr_lane=0,1,2,3`，共 512 个写拍；
   - T2：地址 0..139，每地址一个写拍，共 140 个写拍；
   - P：全局字地址 0..1535，每地址一个写拍，共 1536 个写拍；地址 `particle*12+word`，每粒子 12 个 16bit 字；
4. 写口有效信号均为单拍脉冲，非写拍 `*_wr_en=0`，其他字段保持上一次值；
5. P 的最后一个写拍结束后，`state_commit_toggle` 翻转一次，`frame_done` 拉高一个周期；
6. 在 `snapshot_ack_toggle == state_commit_toggle` 前，不接受下一次 `frame_tick`。这保证 W1 已经完成当前快照的本地预取后，W2 才能开始下一次状态表写入。

`frame_ready = !busy && (snapshot_ack_toggle_sync == state_commit_toggle)`。

## 3. T1/T2 状态表写入契约

W2 的 T1/T2 写口必须逐字匹配 task_045：

### 3.1 T1：`st_trace[127:0]`，每条记录 128bit

`state_wr_addr=i`，`state_wr_lane` 对应：

| lane | 写入字段 |
|---:|---|
| 0 | `[31:0] = {flow_ph[7:0], flow_e[7:0], grow_q4[15:0]}` |
| 1 | `[63:32] = {slot0.age[7:0], slot0.peak[7:0], slot0.pos_q4[15:0]}` |
| 2 | `[95:64] = {slot1.age[7:0], slot1.peak[7:0], slot1.pos_q4[15:0]}` |
| 3 | `[127:96] = {slot2.age[7:0], slot2.peak[7:0], slot2.pos_q4[15:0]}` |

- `grow_q4`：16bit，无符号，单位为 1/16 像素；
- `flow_ph`：仅低 8bit 写入，按 `flowPh & 8'hFF`；
- `pos_q4`：16bit，无符号 Q4；新发脉冲在写入快照时可为 0；
- `peak=0` 是空槽判据，不能用 `pos_q4=0` 代替；
- 地址 70..127 必须写 0，不能保留上一帧数据。

### 3.2 T2：`st_misc[255:0]`，32bit 字

以下字段以 `packState()` 的低字节优先布局为唯一权威：

| 地址 | `[7:0]` | `[15:8]` | `[23:16]` | `[31:24]` |
|---:|---|---|---|---|
| 0..63 | `nodeVis[2n]` | `nodeB[2n]` | `nodeVis[2n+1]` | `nodeB[2n+1]` |
| 64..127 | `barH[2c]` | `barPeak[2c]` | `barH[2c+1]` | `barPeak[2c+1]` |
| 128..132 | `compFade[4q]` | `compFade[4q+1]` | `compFade[4q+2]` | `compFade[4q+3]` |
| 133..136 | `rcAmp[j]` | `rcDir[j] & 2'b11` | `rcPos[j][9:2]` | `rcPos[j][1:0]` + 保留位 |
| 137 | `core_q8` | `ov_k` | `chip_ink` | `beat_k` |
| 138 | `B[0]` | `B[1]` | `B[2]` | `B[3]` |
| 139 | `B[4]` | `B[5]` | `B[6]` | `B[7]` |

对地址 140..255，若实现方选择写入，必须写 0；默认只写 0..139。

> 注意：地址 133..136 的彗星字应按参考生成器的 `((amp)&255)|((dir&3)<<8)|((pos&0x3ff)<<10)` 打包。上表仅用于说明字段，不允许自行改变位移。

## 4. P 粒子表契约

P 是独立于 S2 T1/T2 的共享状态 bank：逻辑上 128 条记录、每条 12 个 16bit 字；物理实现固定为 `2048×16` 的单个 ERAM32K（地址 0..1535 有效）。每条记录与 `pcb_model.js` 的一个粒子槽一一对应，`k=0..127`。

```text
logical bits [ 20:  0] = history[0]：低 11bit 为有符号 x[10:0]，高 10bit 为有符号 y[9:0]
logical bits [ 41: 21] = history[1]，布局同上
...
logical bits [167:147] = history[7]，布局同上
logical bits [175:168] = energy[7:0]       // 对应 st.pE[k]
logical bits [183:176] = life[7:0]         // 对应 st.pLife[k]，剩余寿命
logical bit  [184]     = active             // life != 0 时为 1
logical bits [191:185] = 0
```

每条 192bit 逻辑记录拆为 12 个 16bit 小端字：`word_addr=particle_index*12+word_index`，word 0 保存逻辑位[15:0]，word 11 保存逻辑位[191:176]；每个历史点低11bit为有符号 x、高10bit为有符号 y，不重叠。实现方必须以有符号值解释，不得把负坐标当无符号坐标参与比较。

坐标有效范围由黄金模型审计得到：x 像素约为 -8..647，y 像素约为 -55..487；越界值仍写入 P，W1 在光栅化时裁剪到 640×480。

## 5. W1 行分桶与光栅化契约

### 5.1 动态几何

每帧使用最新完整快照生成：

- 柱顶连线：相邻柱顶之间最多 127 条线段；柱顶 `h=(barH[col]*34)>>8`，半径 `r=193+h`，坐标 `x=320+((r*ex)>>8)`、`y=224+((r*ey)>>8)`；仅当当前柱或前一柱高度非零时绘制，亮度 170；
- 粒子轨迹：每个 active 粒子 7 条历史线段（history[7]→history[0]），粒子亮度 `a=(energy*min(255,life*6))>>8`，第 `t` 条（t=7..1）亮度 `(a*(8-t)*28)>>8`；
- 粒子头：history[0] 亮度 a；a>150 时在上下左右邻点追加 a>>1；
- 线段使用标准整数 Bresenham，端点包含；坐标越界点不进入桶。

### 5.2 3px 线宽

W1 对动态层应用与 S2 相同的 3×3 最大值膨胀：每个基础像素向 `x±1,y±1` 贡献，重叠像素保留最大亮度。膨胀应在行分桶构建阶段完成，避免有效像素期访问全屏缓存。

### 5.3 行桶格式与容量

- 使用固定 `SPAN_POOL_DEPTH=6144` 的紧凑行区段池；记录 `[9:0]=x0`、`[15:10]=length_minus_one`、`[23:16]=luma`，共 24bit，长度为 1..64；
- `row_base[0..479]` 为 13bit 起始索引，`row_count[0..479]` 为 10bit 记录数，count=0 表示空行；记录按 y、x 连续保存，无 next 指针；
- 重叠贡献逐像素取 max；只合并亮度相同的相邻像素，超过 64 像素时拆分，不能把不同亮度统一为整段最大值；
- 构建阶段池满时置 `bucket_overflow_sticky=1`，不得覆盖已有区段；该帧仍输出已构建的有效区段，TB 必须将溢出判为 FAIL；
- 独立模型对 180 帧启动、120 帧播放和饱和刺激的最大记录数应小于 6144；黄金脚本必须记录实际存储的 `span_count_max`，并打包/解包还原像素验证。

### 5.4 有效像素期

输入 `in_valid=1` 时，每拍消费一个坐标，查询当前行已准备的数据；输入无效时不推进扫描坐标。输出有效严格按 §6 延迟，帧尾或断流期间可以排空先前真实输入。

W1 不改变像素顺序，不插入额外有效像素，不在行尾或帧尾产生杂散有效输出。

## 6. W1 输出与 S2 对齐

- 输出固定自然时钟延迟 **D=647 拍**，`overlay_valid[n+647]=in_valid[n]`；与 task_045 的对齐承诺限于完整连续输入帧，S2 任意断流下的重对齐由 S6 适配；
- `overlay_valid` 是延迟后的输入有效，且与对应坐标、`overlay_hit`、`overlay_rgb565`、`overlay_alpha` 同拍；
- `overlay_hit=0` 时 `overlay_alpha=0`，`overlay_rgb565` 保持或输出 0 均可，但 TB 只采信 `overlay_hit=1` 的颜色；
- `overlay_alpha = min(255, (overlay_luma * ov_k) >> 8)`；`ov_k` 来自 T2 地址 137 的第二字节；
- `overlay_rgb565` 使用 `in_ridx` 对应的 64 档调色板和 `overlay_luma` 的 8bit 亮度，必须与 S2 调色板的 RGB565 量化一致；
- `in_sof/in_eol` 在模块内部同延迟保存供 TB 检查；正式端口不增加，S6 从原输入流独立延迟标记；
- 每个有效输出必须对应 647 拍前的真实输入有效，不允许插入虚构像素；合体覆盖条件为 `overlay_valid && overlay_hit`。

## 7. W2 动力学语义

W2 必须逐项实现 `M6_PCB_SKETCH.md §3.2~§3.8`，包括：

- 8 段聚合 `B[g]`、谱通量 `flux[g]`、自适应门限、cooldown、onset；
- `beatK` 与 `loOn`；
- 70 条走线 `grow_q4` 的启动错峰和 smoothstep；
- `flowE/flowPh`、3 槽脉冲和节点命中；
- 节点可见度、节点/片内低频表；
- 128 路音柱快攻慢释、峰值帽和冷却；
- 128 粒子槽的发射、Q4 速度/重力、历史点、回收；
- 4 槽环上彗星；
- 所有计算每帧最多更新一次，禁止在 `frame_tick` 之间偷偷推进状态。

内部所有中间量必须有明确位宽、符号属性、饱和/截断规则；除固定查表外不得使用浮点和任意除法。

## 8. 参数寄存器写口

`cfg_wr_addr` 映射如下，写入后从下一次 `frame_tick` 起生效；未写过时使用默认值。

| 地址 | 参数 | 位宽 | 默认值 |
|---:|---|---:|---:|
| 0 | `GROW_PX_PER_S` | 8 | 70 |
| 1 | `GROW_MIN_FR` | 8 | 36 |
| 2 | `RANK_STAG_FR` | 8 | 9 |
| 3 | `FLOW_V0` | 8 | 8 |
| 4 | `FLOW_VG` | 8 | 24 |
| 5 | `PULSE_V` | 8 | 44 |
| 6 | `ONSET_FLOOR` | 10 | 160 |
| 7 | `PULSE_MIN` | 8 | 18 |
| 8 | `PART_LIFE` | 8 | 110 |
| 9 | `PART_RISE` | 8 | 26 |
| 10 | `PART_HOT` | 8 | 175 |
| 11 | `OV_FADE_FR` | 8 | 18 |
| 12 | `STROKE_R` | 1 | 1（W1 固定 3×3；写入 0 时仍不得改变本任务的 3px 验收基线） |

参数写入越界地址忽略；数值超范围时按规格范围饱和后使用。`PART_N=128`、`PART_TRAIL=8`、`PULSE_SLOTS=3`、`RC_N=4` 是结构常量，不可运行时缩减。

## 9. 已知的接口限制

1. W1 的 `in_ridx` 必须由集成侧与 S2 使用同一坐标语义生成；本模块不从 RGB565 底图反推半径。
2. T1/T2/P 的状态写入与 W1 预取使用外部状态 RAM；本任务不提供状态 RAM 实例，不允许实现方把状态数组后门写入 TB。
3. `state_commit_toggle` 与 `snapshot_ack_toggle` 是跨域 toggle，不是脉冲；两侧必须 2FF 同步，不能直接组合使用。
4. W1 只保证在 `span_count_max < 6144` 的规格场景下无溢出；溢出是可观察的 FAIL，不得静默截断后声称 PASS。
5. W1 输出 `overlay_rgb565` 是覆盖层颜色，不是 S2 最终合成像素；S6 合成级不在本任务范围内。
6. 本模块不声明任何引脚和 PLL 资源；像素/控制时钟由集成任务提供。

