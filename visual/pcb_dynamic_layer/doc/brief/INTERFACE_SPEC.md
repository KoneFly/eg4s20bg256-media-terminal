# INTERFACE_SPEC — pcb_dynamic_layer W2 多周期版

> 最后核对日期：2026-10-04  
> 维护者：pcb_dynamic_layer 执行方  
> 授权依据：用户批准“W1 整体出列 + W2 多周期化重构”。V2 原版与证据见 archive/v2。

本包仅保留 pcb_frame_updater；W1 及其正式接口全部出列。以下 W2 端口相对 V2 原样保留，50MHz、低有效复位。snapshot_ack_toggle 仍由外部快照接收方提供，独立 TB 通过正式口模拟接收方；本轮不实现或集成该接收方。

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

## 帧锁存与发布

frame_ready = !busy && ack_sync==state_commit_toggle。ready 时的单拍 tick 锁存 128 路频谱与配置；否则拒绝并置 sticky err_code=1。配置与 tick 同拍仍使用写入前值。

T1 512 写、T2 140 写，共 652 写；最后一次 T2 写排空后，经 DRAIN 再翻转一次 commit，并产生单拍 done。等待接收方 ack 的两拍同步后才允许下一帧。多周期化改变内部计算耗时，不改变发布地址、lane、字段、脉冲或提交边界。不存在 P 存储或 P 写序。

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

## 配置与内部状态

配置地址 0..7 的名称/默认值/范围保持冻结：GROW_PX_PER_S=70 [30,200]；GROW_MIN_FR=36 [12,90]；RANK_STAG_FR=9 [0,30]；FLOW_V0=8 [0,32]；FLOW_VG=24 [0,64]；PULSE_V=44 [16,96]；ONSET_FLOOR=160 [64,512]；PULSE_MIN=18 [8,64]。8/9/10 粒子参数退役，写入忽略，不重编号；11/12 在本包 V2 固定基线下不改变可观察 W2 输出，不新增接口。保留三槽脉冲、四个环上彗星、128 音柱与原 T1/T2 空槽判据。

集中 2048×16bit bank 的地址仍为 trace 0..1023、startF 1024..1151、node 1152..1407、bar 1408..1663、prev 1664..1727。运行时初始化，包括原 startF 初始值。所有访问仍为同步词口；内部寄存器/状态宽度与计算拍数可按等价实现调整，不改变正式口或持久状态语义。

W1 的几何、D=647、行桶与像素黄金契约整体移至 V2 归档，不作为本轮必测或交付接口。既有 S2 峰值帽等显示路径保持只读；本轮只保留其 W2 状态输入。
