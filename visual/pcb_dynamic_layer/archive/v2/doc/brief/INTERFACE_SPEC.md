# INTERFACE_SPEC — pcb_dynamic_layer V2

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户本轮批准的“规格变更 V2 + 重构授权”。V1 历史资料见 archive/v1。

## 正式接口

仅删除 W2 P 写口与 W1 P 读口，保留模块名和全部其余正式端口。W2 50MHz，W1 25.2MHz，复位低有效。

```verilog
module pcb_frame_updater (
    input wire clk, rst_n, frame_tick,
    input wire [1023:0] spec_frame,
    input wire cfg_wr_en,
    input wire [5:0] cfg_wr_addr,
    input wire [15:0] cfg_wr_data,
    input wire snapshot_ack_toggle,
    output reg state_wr_en, state_wr_sel,
    output reg [7:0] state_wr_addr,
    output reg [31:0] state_wr_data,
    output reg [1:0] state_wr_lane,
    output reg state_commit_toggle,
    output wire frame_ready,
    output reg frame_accept, frame_done, busy, err_valid,
    output reg [3:0] err_code
);
```

```verilog
module pcb_particle_overlay (
    input wire clk, rst_n, in_valid, in_sof, in_eol,
    input wire [9:0] in_x,
    input wire [8:0] in_y,
    input wire [5:0] in_ridx,
    input wire state_commit_toggle,
    output wire [7:0] st_misc_addr,
    input wire [31:0] st_misc_rdata,
    output reg snapshot_ack_toggle,
    output reg overlay_valid, overlay_hit,
    output reg [15:0] overlay_rgb565,
    output reg [7:0] overlay_alpha,
    output reg bucket_overflow_sticky
);
```

## 帧交握与发布

frame_ready = !busy && ack_sync==state_commit_toggle。ready 时的单拍 tick 锁存 128 路频谱与配置；否则拒绝并置 sticky err_code=1。每帧发布 T1 512 次、T2 140 次，共 652 写；顺序、字段和空槽判据保持冻结。最后一次 T2 写完成后 DRAIN，再翻转一次 commit 并产生单拍 done。ack 返回前不得接受下一帧。两个 toggle 均经接收侧 2FF。W1 预取 T2 64..127 和 137 后返回 ack，预取期间 W2 保持快照。不存在 P 存储、P 写序或最后 P 写提交条件。

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


## W1 动态几何与输出

只保留最多 127 条相邻柱顶连线，首末柱不闭环。h=(barH*34)>>8，r=193+h，x=320+((r*ex)>>8)，y=224+((r*ey)>>8)。仅任一邻柱 h>0 时绘制，亮度 170。整数 Bresenham 包含端点；先裁剪基础像素再做 3×3 最大值膨胀。保留 128 柱 H/Peak 和峰值帽，峰值帽仍由 S2 按 T2 字段绘制；环上彗星仍由 W2 更新 T2/S2，不交 W1 重绘。

行区段池仍为 6144×24bit：[9:0] x0、[15:10] length_minus_one、[23:16] luma；每段 1..64 像素，按 y/x 连续排列。row_base13 / row_count10，无 next 指针。辅助构建区可用有序链表；不作为正式行记录或全屏帧缓存。物理行池目标 ≤6 ERAM32K，辅助 RAM 必须另行计入总占用。桶溢出 sticky 是 FAIL，不静默覆盖。

自然时钟 D=647：overlay_valid[n+647]=in_valid[n]，hit/颜色/alpha/内部 SOF/EOL 同拍。无命中 alpha=0；alpha=(luma*ovK)>>8，ovK 是 T2 137 第二字节。颜色使用 in_ridx 对应的既有调色板及 RGB565 量化。S2 连续帧对齐承诺保留，任意断流的 S6 适配仍不在本轮。几何构建与行记录写入只能在输入无效时进行；本轮实际构建期限单独报告，不从像素等价外推。

## 保留参数与结构常量

配置地址 0..7 的名称、默认值和范围保持 V1：GROW_PX_PER_S=70 [30,200]；GROW_MIN_FR=36 [12,90]；RANK_STAG_FR=9 [0,30]；FLOW_V0=8 [0,32]；FLOW_VG=24 [0,64]；PULSE_V=44 [16,96]；ONSET_FLOOR=160 [64,512]；PULSE_MIN=18 [8,64]。8/9/10 的粒子参数退役、写入忽略，不重编号。11 的 OV_FADE_FR 和 12 的 STROKE_R 的原语义保留；当前正式 W2 无 overlay 开关输入，ovK 从初始 255 保持为 255，故地址 11 不改变可观察结果。W1 固定 3×3，地址 12 不改变基线。配置与 tick 同拍使用写入前值。PULSE_SLOTS=3、RC_N=4、128 音柱、分辨率和其他冻结结构不缩减。

W2 内部集中 RAM 地址为 trace 0..1023、startF 1024..1151、node 1152..1407、bar 1408..1663、prev 1664..1727；其余保留。所有访问按 16bit 同步词口进行，不更改正式 T1/T2 形状。
