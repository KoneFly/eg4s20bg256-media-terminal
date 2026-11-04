`timescale 1ns/1ps
// ============================================================================
// pcb_pixel_renderer —— M6 PCB 线稿频谱 · 像素渲染器（移植计划 S2）
//
// 职责：把「16bit 标签 + 16bit 图像像素」逐拍流按冻结状态表合成为 RGB565。
//   标签解码(8 class) → 逐类着色 (dark/light) → 底部常驻柱形图平面 (strip) →
//   3×3 最大值膨胀（行→列可分离，2 行缓存）→ 径向/通道调色索引（逐行增量）→
//   32 档亮度量化 + 高光混白 → RGB565 →（ov_on 时）与底图亮度自适应叠加。
//
// 状态表 BRAM 在模块体外（冻结契约：st_*_rdata 为输入端口），由 TB/集成方提供；
// T2 音柱字（misc 64..127）在体内有一份写侧镜像缓存 pcb_bar_cache，供底部柱形
// 图按 x/5 通道反查，消除 misc 单读口的逐类变址/柱字争用。
//
// 流水线（固定延迟 D=648 拍，无气泡；断流整链保持、pixel_valid 拉 0）：
//   S0 捕获上下文 + 呈现 misc/trace 读地址（每拍恰一次 misc 读：逐类变址或
//      轮询刷新帧常量字 137/133..136）
//   S1 外部读数据回笼 → en 门控捕获 cap_misc/cap_trace（断流期保持，
//      使断流后重续仍逐位正确——集成时 hblank 逐行断流依赖此）
//   S2 逐类着色（class 计算所需状态数据在本拍全部就位）
//   S3/S4 行窗三级移位（S4 拍 = {x-1,x,x+1} 中心行窗，同时发起行缓存/底图/柱字读）
//   S5 列窗 3 邻域 max（2 行缓存读回 + 错拍写回）、strip 平面、径向增量更新
//   S6 合成第一级（ov_k 增益、墨线底亮、量化、索引选择、调色板乘法）
//   S7 合成第二级（高光混白、叠加混合）→ 输出寄存
//
// 固定延迟 D = 640（列窗因果性固有的 1 行滞后）+ 8 拍流水 = 648 拍
// （in_valid 连续流内逐像素恒定；帧尾最后 1 行输出在帧后 flush 窗口内吐出，
//  集成时落入 VBLANK——见 doc/output/behavior_spec.md §延迟契约）。
//
// 与 INTERFACE_SPEC 字面已登记的实现偏差（9 场景全帧黄金实证，详见
// doc/output/run_report.md §偏差登记）：
//   1) class2/3 生长尖端判据 k==len && len<total，total 为版图常量 ROM
//      （规格"省去 total 比较"的化简与黄金不符：满长走线末端 k==total==len）；
//   2) 脉冲空槽判据 peak==0（JS 权威语义；规格伪码的 pos==0 与其在黄金上输出
//      等价——死槽 amp=0 的 +40 幻影被墨线 154 底亮吞没——但 peak==0 对任意
//      S3 状态严格 JS 等价，故取之）；
//   3) core_q8 字节 0 ≡ 满量 256（mod-256 折叠语义，黄金生成器 core=256 的事实编码）；
//   4) T2 节点/音柱字字节序以 packState() 为准；通道索引用 floor 非 round。
// ============================================================================
module pcb_pixel_renderer (
    // ---- 读侧：像素域 25.2MHz ----
    input  wire        clk,             // 像素时钟 25.2MHz
    input  wire        rst_n,           // 低有效，本域同步释放

    // 来自 async_pixel_fifo 的 {标签, 图像} 同拍像素（valid 与显示 DE 对齐）
    input  wire        in_valid,        // 1 = 本拍 in_label/in_image 有效
    input  wire [15:0] in_label,        // 16bit 标签（编码见 INTERFACE_SPEC §标签编码）
    input  wire [15:0] in_image,        // 16bit 图像像素 RGB565（叠加模式的底图）

    // 叠加开关（像素域电平；由集成方在 VBLANK 同步后给出，本模块视作静态）
    input  wire        ov_on,           // 1 = 叠加模式（可视化层压在图像上）

    // ---- 状态表读口（真双口 BRAM 读侧；存储在模块体外，见 pcb_state_mem） ----
    output wire [7:0]  st_trace_addr,   // 走线号 0..127
    input  wire [127:0] st_trace_rdata, // 走线状态记录（布局见 §状态表内存图 T1）
    output wire [7:0]  st_misc_addr,    // 杂项表地址 0..255
    input  wire [31:0] st_misc_rdata,   // 杂项记录（布局见 §状态表内存图 T2）

    // ---- 状态表写口：ctrl 域 50MHz（集成时由 pcb_frame_updater 驱动；TB 亦由此装载快照） ----
    input  wire        wr_clk,          // ctrl 域时钟 50MHz
    input  wire        wr_en,           // 写使能（单拍）
    input  wire        wr_sel,          // 0 = st_trace，1 = st_misc
    input  wire [7:0]  wr_addr,         // 写地址（st_trace：走线号；st_misc：字地址）
    input  wire [31:0] wr_data,         // 写数据（st_trace 为 128bit 记录的第 {wr_lane} 个 32bit 段）
    input  wire [1:0]  wr_lane,         // st_trace 用：0..3 对应记录 [31:0]/[63:32]/[95:64]/[127:96]

    // ---- 输出（已寄存） ----
    output reg  [15:0] pixel_rgb565,    // RGB565 {R[4:0],G[5:0],B[4:0]}
    output reg         pixel_valid      // 与输入 in_valid 同节拍，固定延迟后有效
);

    // ---------------------------------------------------------------------------
    // 参数与几何常量（版图：圆心 (320,224)，屏 640×480，strip 带 y_out>=451）
    // ---------------------------------------------------------------------------
    localparam [9:0]  SCR_X_LAST = 10'd639;
    localparam [18:0] PIX_LAST   = 19'd307199;
    localparam [9:0]  FLUSH_CYC  = 10'd650;   // 640 拍 y=480 虚行 + 10 拍排空
    localparam [8:0]  FLUSH_Y    = 9'd480;
    localparam [9:0]  DRAIN_HOLD = 10'd10;    // flush 末尾排空相阈值
    localparam [9:0]  CX         = 10'd320;
    localparam [9:0]  CY         = 10'd224;
    localparam [17:0] CXC        = 18'd102400; // 320*320
    localparam [8:0]  STRIP_Y0   = 9'd451;     // strip 带：y_out >= 451

`include "pcb_roms.vh"

    // ---------------------------------------------------------------------------
    // 帧控制：x/y/列计数器、帧像素计数、帧尾 flush（推 1 虚行并排空流水）。
    // 断流（in_valid=0 且非 flush）时 en=0，全链保持，pixel_valid 拉 0。
    // ---------------------------------------------------------------------------
    wire        en = in_valid | flush_active;

    reg         running;
    reg [18:0]  pix_cnt;
    reg [9:0]   flush_cnt;
    reg [9:0]   x_cnt;
    reg [8:0]   y_cnt;
    reg [6:0]   col_r;      // x/5 通道号（strip 通道）
    reg [2:0]   pha_r;      // x%5 相位

    wire        flush_active = (flush_cnt != 10'd0);
    wire        frame_start  = in_valid & (~running | flush_active);
    wire        frame_last   = in_valid & running & ~flush_active & (pix_cnt == PIX_LAST);
    wire        flush_a      = (flush_cnt > DRAIN_HOLD);   // A 相：y=480 虚行

    // 当前捕获像素的坐标与内容（帧首强制 (0,0)；flush 喂哑元）。
    // ★ x_cnt/y_cnt/col_r/pha_r 语义 = "上一个捕获像素"的坐标；本拍捕获像素取
    //   next() —— 直接用 x_cnt 会整体滞后一拍（曾致全流水线 x 左移 1 的实证 bug）。
    wire        x_wrap   = (x_cnt == SCR_X_LAST);       // 上一像素在行尾 ⇒ 本像素开新行
    wire [9:0]  cur_x    = frame_start ? 10'd0 :
                           (x_wrap ? 10'd0 : x_cnt + 10'd1);
    wire [8:0]  cur_y    = frame_start ? 9'd0 :
                           flush_active ? (flush_a ? FLUSH_Y : 9'd0) :
                           (x_wrap ? y_cnt + 9'd1 : y_cnt);
    wire [6:0]  cur_col  = frame_start ? 7'd0 :
                           (x_wrap ? 7'd0 : ((pha_r == 3'd4) ? col_r + 7'd1 : col_r));
    wire [2:0]  cur_pha  = frame_start ? 3'd0 :
                           (x_wrap ? 3'd0 : ((pha_r == 3'd4) ? 3'd0 : pha_r + 3'd1));
    wire        cur_gap  = frame_start ? 1'b0 : (cur_pha == 3'd4);   // x%5==4：通道间隙
    wire [15:0] cur_label = (flush_active & ~frame_start) ? 16'd0 : in_label;
    wire [15:0] cur_image = (flush_active & ~frame_start) ? 16'd0 : in_image;
    wire        cur_emit  = (cur_y != 9'd0);            // 输出行 = cur_y-1 存在

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            pix_cnt   <= 19'd0;
            flush_cnt <= 10'd0;
            x_cnt     <= 10'd0;
            y_cnt     <= 9'd0;
            col_r     <= 7'd0;
            pha_r     <= 3'd0;
        end else if (en) begin
            if (frame_start) begin
                running   <= 1'b1;
                pix_cnt   <= 19'd1;   // 首像素已计入 ⇒ 末拍前值 = PIX_LAST，frame_last 恰好触发
                flush_cnt <= 10'd0;
                x_cnt     <= cur_x;
                y_cnt     <= cur_y;
                col_r     <= cur_col;
                pha_r     <= cur_pha;
            end else if (flush_active) begin
                flush_cnt <= flush_cnt - 10'd1;
                x_cnt <= cur_x;  col_r <= cur_col;  pha_r <= cur_pha;
                // y_cnt 保持：flush 的 y 为强制值，不进计数器
            end else if (in_valid) begin
                pix_cnt <= pix_cnt + 19'd1;
                x_cnt <= cur_x;  y_cnt <= cur_y;
                col_r <= cur_col;  pha_r <= cur_pha;
                if (frame_last) begin
                    flush_cnt <= FLUSH_CYC;
                    running   <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------------------
    // misc 读口调度：en 拍恰一次读 —— 逐类变址读优先，否则轮询刷新帧常量字
    // （137 全局 / 133..136 彗星槽）。刷新仅在真实像素流内进行（flush 与断流期
    // 冻结，保证帧尾输出仍用本帧快照）；帧首指针归 1（先刷全局字）。帧首若干
    // 像素的刷新窗口见 behavior_spec §设计决策（当前版图首行左端为空标签）。
    // ---------------------------------------------------------------------------
    wire [2:0] cls_l  = cur_label[15:13];
    wire [2:0] tick_l = cur_label[6:4];
    wire       vary_cur = en & ~flush_active &
                         ( ((cls_l == 3'd1) & (tick_l != 3'd0))
                         | (cls_l == 3'd5) | (cls_l == 3'd6) | (cls_l == 3'd7) );
    wire [2:0] tick_m1 = tick_l - 3'd1;                    // 0..6
    wire [8:0] vary_addr = (cls_l == 3'd1) ? (tick_m1[2] ? 9'd139 : 9'd138) :
                           (cls_l == 3'd5) ? (9'd64 + {3'b000, cur_label[12:7]}) :
                           (cls_l == 3'd6) ? (9'd0  + {3'b000, cur_label[12:7]}) :
                                             (9'd128 + {6'b000000, cur_label[12:10]});

    reg  [2:0]  rptr;      // 轮询指针：1=137 2=133 3=134 4=135 5=136
    reg  [2:0]  rptr_q;    // 上一 en 拍所呈地址的槽号（对齐读数据）
    reg  [31:0] glob_reg;  // misc[137]: {beat_k, chip_ink, ov_k, core_q8}
    reg  [31:0] rc0, rc1, rc2, rc3; // misc[133..136]: {pos[19:10], dir[9:8], amp[7:0]}

    wire        rf_en    = en & ~flush_active;
    wire [8:0]  refresh_addr = (rptr == 3'd1) ? 9'd137 :
                               (rptr == 3'd2) ? 9'd133 :
                               (rptr == 3'd3) ? 9'd134 :
                               (rptr == 3'd4) ? 9'd135 : 9'd136;
    wire [7:0]  misc_addr_c  = vary_cur ? vary_addr[7:0] : refresh_addr[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rptr     <= 3'd1;
            rptr_q   <= 3'd0;
            glob_reg <= 32'd0;
            rc0      <= 32'd0;
            rc1      <= 32'd0;
            rc2      <= 32'd0;
            rc3      <= 32'd0;
        end else if (en) begin
            if (frame_start)
                rptr <= 3'd1;
            else if (rf_en && !vary_cur)
                rptr <= (rptr == 3'd5) ? 3'd1 : rptr + 3'd1;
            if (rf_en)
                rptr_q <= vary_cur ? 3'd0 : rptr;
            if (rf_en) begin
                case (rptr_q)
                    3'd1: glob_reg <= st_misc_rdata;
                    3'd2: rc0      <= st_misc_rdata;
                    3'd3: rc1      <= st_misc_rdata;
                    3'd4: rc2      <= st_misc_rdata;
                    3'd5: rc3      <= st_misc_rdata;
                    default: ;
                endcase
            end
        end
    end

    assign st_misc_addr = misc_addr_c;

    // 走线读口：cls2/3 才消费；地址恒给出（id = {cls3, label[12:7]}）
    assign st_trace_addr = {1'b0, cls_l[0], cur_label[12:7]};

    // ChipWatcher 可观测：状态表收到过写（sticky，写域，无端口）
    /* verilator lint_off UNUSEDSIGNAL */
    reg st_wr_seen;
    always @(posedge wr_clk) begin
        if (wr_en)
            st_wr_seen <= 1'b1;
    end
    /* verilator lint_on UNUSEDSIGNAL */

    // ---------------------------------------------------------------------------
    // 体内存储：T2 音柱字镜像缓存（写侧译码 64..127）/ 膨胀行缓存 ×2 / 底图行缓存
    // ---------------------------------------------------------------------------
    wire [31:0] bc_rdata;
    wire [15:0] lb0_q, lb1_q, img_q;

    pcb_bar_cache u_barcache (
        .clk      (clk),
        .rd_addr  (s4_col[6:1]),     // 通道 col 的字 = col>>1（S4 拍随行给出）
        .rd_data  (bc_rdata),
        .wr_clk   (wr_clk),
        .we       (wr_en & wr_sel & (wr_addr[7:6] == 2'b01)),
        .wr_addr  (wr_addr[5:0]),
        .wr_data  (wr_data)
    );

    // -----------------------------------------------------------------------
    // S1：外部读数据回笼 → en 门控捕获（断流期保持，重续后仍逐位正确）
    // -----------------------------------------------------------------------
    reg [31:0]  cap_misc;
    reg [127:0] cap_trace;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cap_misc  <= 32'd0;
            cap_trace <= 128'd0;
        end else if (en) begin
            cap_misc  <= st_misc_rdata;
            cap_trace <= st_trace_rdata;
        end
    end

    // -----------------------------------------------------------------------
    // S2 逐类着色（组合；cap_* 与 s2_* 上下文在本拍全部就位）
    // -----------------------------------------------------------------------

    // ---- class 1 静态墨线 ----
    wire [7:0]  c1_lv    = {s2_label[12:8], 3'b000};
    wire [2:0]  c1_tick  = s2_label[6:4];
    wire [2:0]  c1_t1    = c1_tick - 3'd1;
    wire [7:0]  c1_byte  = (c1_t1[1:0] == 2'd0) ? cap_misc[7:0]  :
                           (c1_t1[1:0] == 2'd1) ? cap_misc[15:8] :
                           (c1_t1[1:0] == 2'd2) ? cap_misc[23:16] : cap_misc[31:24];
    wire        c1_core  = s2_label[7];
    wire [15:0] c1_cp    = c1_lv * {1'b0, glob_reg[7:0]};
    // core 位 gate：非核像素不乘 core_q8；字节 0 ≡ 满量 256（mod-256 折叠，偏差登记 3）
    wire [7:0]  c1_lvq   = ~c1_core ? c1_lv :
                           (glob_reg[7:0] == 8'd0) ? c1_lv : c1_cp[15:8];
    wire [15:0] c1_dp    = c1_lvq * {1'b0, glob_reg[23:16]};
    wire [7:0]  c1_dark  = c1_dp[15:8];
    wire [7:0]  c1_light = (c1_tick != 3'd0) ? {1'b0, c1_byte[7:1]} : 8'd0;

    // ---- class 2/3 走线 ----
    wire [6:0]  c23_id   = {(s2_label[15:13] == 3'd3), s2_label[12:7]};
    wire [6:0]  c23_k    = s2_label[6:0];
    wire [15:0] c23_g16  = cap_trace[15:0];
    wire [7:0]  c23_fe   = cap_trace[23:16];
    wire [7:0]  c23_ph   = cap_trace[31:24];
    wire [11:0] c23_len  = c23_g16[15:4];
    wire [3:0]  c23_frac = c23_g16[3:0];
    wire        c23_body = ({5'b00000, c23_k} <= c23_len);          // k <= len

    // 前沿亚像素墨（k == len+1 且 frac!=0）：208*frac = frac<<7+frac<<6+frac<<4
    wire [11:0] c23_fmul   = {1'b0, c23_frac, 7'b0} + {2'b00, c23_frac, 6'b0}
                           + {4'b0000, c23_frac, 4'b0};
    wire [7:0]  c23_dfront = (({5'b00000, c23_k} == (c23_len + 12'd1)) & (c23_frac != 4'd0))
                             ? c23_fmul[11:4] : 8'd0;

    // 生长尖端：k==len 且未满长（total 为版图常量 ROM，偏差登记 1）
    wire [6:0] c23_tot = pcb_total_rom(c23_id);
    wire       c23_tip = ({5'b00000, c23_k} == c23_len) && (c23_len < {5'b00000, c23_tot});

    // 持续电流：fe>20 且 ((k<<4)-ph)&255 < 64（覆盖语义，与 JS 一致）
    wire [7:0] c23_kd    = {c23_k[3:0], 4'b0} - c23_ph;
    wire       c23_fgate = (c23_fe > 8'd20) && (c23_kd < 8'd64);
    wire [14:0] c23_fep  = {1'b0, c23_fe, 6'b0} + {4'b0000, c23_fe, 3'b0}
                         + {6'b000000, c23_fe, 1'b0} + {7'b0000000, c23_fe};
    wire [7:0]  c23_bq2  = glob_reg[31:24] >> 2;
    wire [8:0]  c23_flv  = 9'd180 + {2'b00, c23_fep[14:8]} + {1'b0, c23_bq2};
    wire [7:0]  c23_flow = c23_fgate ? ((c23_flv > 9'd255) ? 8'd255 : c23_flv[7:0]) : 8'd0;

    // 起音脉冲 3 槽（空槽判据 peak==0，偏差登记 2）
    wire [7:0] c23_pv0, c23_pv1, c23_pv2;
    pcb_pulse_slot g_p0 (.w(cap_trace[63:32]),  .k(c23_k), .v(c23_pv0));
    pcb_pulse_slot g_p1 (.w(cap_trace[95:64]),  .k(c23_k), .v(c23_pv1));
    pcb_pulse_slot g_p2 (.w(cap_trace[127:96]), .k(c23_k), .v(c23_pv2));
    wire [7:0] c23_pa = c23_tip ? 8'd200 : 8'd0;
    wire [7:0] c23_pb = c23_fgate ? c23_flow : c23_pa;      // 覆盖（非取大）
    wire [7:0] c23_pc = (c23_pv0 > c23_pb) ? c23_pv0 : c23_pb;
    wire [7:0] c23_pd = (c23_pv1 > c23_pc) ? c23_pv1 : c23_pc;
    wire [7:0] c23_pe = (c23_pv2 > c23_pd) ? c23_pv2 : c23_pd;

    wire [7:0] c23_dark  = c23_body ? 8'd208 : c23_dfront;
    wire [7:0] c23_light = c23_body ? c23_pe : 8'd0;

    // ---- class 4 大圆环彗星 ----
    wire [9:0] c4_a = s2_label[12:3];
    wire [7:0] c4_v0, c4_v1, c4_v2, c4_v3;
    pcb_rc_slot g_r0 (.w(rc0), .a(c4_a), .v(c4_v0));
    pcb_rc_slot g_r1 (.w(rc1), .a(c4_a), .v(c4_v1));
    pcb_rc_slot g_r2 (.w(rc2), .a(c4_a), .v(c4_v2));
    pcb_rc_slot g_r3 (.w(rc3), .a(c4_a), .v(c4_v3));
    wire [7:0] c4_m01   = (c4_v0 > c4_v1) ? c4_v0 : c4_v1;
    wire [7:0] c4_m23   = (c4_v2 > c4_v3) ? c4_v2 : c4_v3;
    wire [7:0] c4_light = (c4_m01 > c4_m23) ? c4_m01 : c4_m23;
    wire [7:0] c4_dark  = 8'd232;

    // ---- class 5 音柱（bar 字经 misc 变址读） ----
    wire [6:0] c5_col = s2_label[12:6];
    wire [5:0] c5_r   = s2_label[5:0];
    wire [7:0] c5_bh  = c5_col[0] ? cap_misc[23:16] : cap_misc[7:0];
    wire [7:0] c5_bp  = c5_col[0] ? cap_misc[31:24] : cap_misc[15:8];
    wire [13:0] c5_hf = {1'b0, c5_bh, 5'b0} + {5'b00000, c5_bh, 1'b0};       // *34
    wire [13:0] c5_pf = {1'b0, c5_bp, 5'b0} + {5'b00000, c5_bp, 1'b0};
    wire [7:0]  c5_h  = {2'b00, c5_hf[13:8]};
    wire [7:0]  c5_pk = {2'b00, c5_pf[13:8]};
    wire [15:0] c5_g150 = {1'b0, c5_bh, 7'b0} + {4'b0000, c5_bh, 4'b0}
                        + {6'b000000, c5_bh, 2'b0} + {7'b0000000, c5_bh, 1'b0};
    wire [7:0]  c5_gv   = c5_g150[15:8];
    wire [7:0]  c5_r8   = {2'b00, c5_r};
    wire [7:0]  c5_lbody= (c5_r8 == c5_h) ? 8'd240 : (8'd90 + c5_gv);
    wire [7:0]  c5_light= (c5_r == 6'd0) ? 8'd0 :
                          ((c5_pk > c5_h + 8'd1) && (c5_r8 == c5_pk)) ? 8'd250 :
                          ((c5_r8 <= c5_h) ? c5_lbody : 8'd0);
    wire [7:0]  c5_dark = (c5_r == 6'd0) ? 8'd150 : 8'd0;

    // ---- class 6 节点/片内 ----
    wire [6:0] c6_id   = s2_label[12:6];
    wire [1:0] c6_part = s2_label[5:4];
    wire [7:0] c6_il   = {s2_label[3:0], 4'b0};
    wire [7:0] c6_vis  = c6_id[0] ? cap_misc[23:16] : cap_misc[7:0];
    wire [7:0] c6_b    = c6_id[0] ? cap_misc[31:24] : cap_misc[15:8];
    wire [15:0] c6_dp  = c6_il * {1'b0, c6_vis};
    wire [8:0]  c6_ls  = {1'b0, 8'd40} + {1'b0, c6_b};
    wire [7:0]  c6_light = (c6_vis == 8'd0) ? 8'd0 :
                           ((c6_part == 2'd1) || (c6_part == 2'd2)) ?
                               ((c6_ls > 9'd255) ? 8'd255 : c6_ls[7:0]) :
                           (c6_part == 2'd3) ? ((c6_b > 8'd120) ? {2'b00, c6_b[7:2]} : 8'd0) :
                                               8'd0;
    wire [7:0]  c6_dark  = ((c6_vis != 8'd0) && ((c6_part == 2'd0) || (c6_part == 2'd2)))
                           ? c6_dp[15:8] : 8'd0;

    // ---- class 7 元件 ----
    wire [4:0] c7_id = s2_label[12:8];
    wire [7:0] c7_f  = (c7_id[1:0] == 2'd0) ? cap_misc[7:0]  :
                       (c7_id[1:0] == 2'd1) ? cap_misc[15:8] :
                       (c7_id[1:0] == 2'd2) ? cap_misc[23:16] : cap_misc[31:24];
    wire [15:0] c7_dp = {1'b0, c7_f} * s2_label[7:0];
    wire [7:0]  c7_dark = (c7_f != 8'd0) ? c7_dp[15:8] : 8'd0;

    // ---- class 汇总 ----
    wire [2:0] s2_cls = s2_label[15:13];
    wire [7:0] dark1_w =
        (s2_cls == 3'd1) ? c1_dark  :
        (s2_cls == 3'd2) ? c23_dark :
        (s2_cls == 3'd3) ? c23_dark :
        (s2_cls == 3'd4) ? c4_dark  :
        (s2_cls == 3'd5) ? c5_dark  :
        (s2_cls == 3'd6) ? c6_dark  :
        (s2_cls == 3'd7) ? c7_dark  : 8'd0;
    wire [7:0] light1_w =
        (s2_cls == 3'd1) ? c1_light  :
        (s2_cls == 3'd2) ? c23_light :
        (s2_cls == 3'd3) ? c23_light :
        (s2_cls == 3'd4) ? c4_light  :
        (s2_cls == 3'd5) ? c5_light  :
        (s2_cls == 3'd6) ? c6_light  : 8'd0;   // cls0/7 无光

    // -----------------------------------------------------------------------
    // 流水线寄存器（S0→S7，统一 en 门控；帧首清 emit 防旧帧残尾混入）
    // -----------------------------------------------------------------------
    reg [15:0] s1_label;
    reg [15:0] s1_image;
    reg [9:0]  s1_x;
    reg [8:0]  s1_y;
    reg [6:0]  s1_col;
    reg        s1_emit;
    reg        s1_gap;

    reg [15:0] s2_label;
    reg [15:0] s2_image;
    reg [9:0]  s2_x;
    reg [8:0]  s2_y;
    reg [6:0]  s2_col;
    reg        s2_emit;
    reg        s2_gap;

    reg [7:0]  s3_dark, s3_light;     // 行窗最新位（x+1）
    reg [15:0] s3_image;
    reg [9:0]  s3_x;
    reg [8:0]  s3_y;
    reg [6:0]  s3_col;
    reg        s3_emit;
    reg        s3_gap;

    reg [7:0]  s4_dark, s4_light;     // 行窗中心（x）
    reg [15:0] s4_image;
    reg [9:0]  s4_x;
    reg [8:0]  s4_y;
    reg [6:0]  s4_col;
    reg        s4_emit;
    reg        s4_gap;

    reg [7:0]  s5_dark, s5_light;     // 行窗最旧位（x-1）；S5 拍即本像素上下文
    reg [15:0] s5_image;
    reg [9:0]  s5_x;
    reg [8:0]  s5_y;
    reg [6:0]  s5_col;
    reg        s5_emit;
    reg        s5_gap;

    reg [7:0]  rm_l_r, rm_d_r;        // S4 拍行 max（行 = s5_y、列 = s5_x）

    reg [7:0]  s6_cl, s6_cd;          // 列 max 后的 light/dark
    reg [7:0]  s6_strip;
    reg [6:0]  s6_col;
    reg        s6_band, s6_emit;
    reg [15:0] s6_bg;

    reg [7:0]  c1_pr, c1_pg, c1_pb, c1_w;
    reg        c1_zero;
    reg [15:0] s7_bg;
    reg        s7_band, s7_emit;

    // ---- 行窗 3 邻域 max（S4 拍：{s5,s4,s3} = {x-1,x,x+1}，中心 = s4） ----
    wire [7:0] max_l01 = (s4_light > s3_light) ? s4_light : s3_light;
    wire [7:0] rm_l_w  = (s4_x == 10'd0)   ? max_l01 :
                         (s4_x == SCR_X_LAST) ? ((s5_light > s4_light) ? s5_light : s4_light) :
                         ((s5_light > max_l01) ? s5_light : max_l01);
    wire [7:0] max_d01 = (s4_dark > s3_dark) ? s4_dark : s3_dark;
    wire [7:0] rm_d_w  = (s4_x == 10'd0)   ? max_d01 :
                         (s4_x == SCR_X_LAST) ? ((s5_dark > s4_dark) ? s5_dark : s4_dark) :
                         ((s5_dark > max_d01) ? s5_dark : max_d01);

    // ---- 列窗 3 邻域 max（S5 拍：行 y-2/y-1 来自行缓存，行 y 为 rm_r） ----
    wire       s5_band = (s5_y >= (STRIP_Y0 + 9'd1));   // y_out>=451 ⟺ y>=452
    wire [7:0] lb1_l = lb1_q[15:8], lb1_d = lb1_q[7:0];
    wire [7:0] lb0_l = lb0_q[15:8], lb0_d = lb0_q[7:0];
    wire [7:0] c_l1 = (s5_y >= 9'd1) ? lb1_l : 8'd0;
    wire [7:0] c_l0 = (s5_y >= 9'd2) ? lb0_l : 8'd0;
    wire [7:0] c_d1 = (s5_y >= 9'd1) ? lb1_d : 8'd0;
    wire [7:0] c_d0 = (s5_y >= 9'd2) ? lb0_d : 8'd0;
    wire [7:0] cmx_l = (c_l1 > c_l0) ? c_l1 : c_l0;
    wire [7:0] cmx_d = (c_d1 > c_d0) ? c_d1 : c_d0;
    wire [7:0] cm_l_w = (rm_l_r > cmx_l) ? rm_l_r : cmx_l;
    wire [7:0] cm_d_w = (rm_d_r > cmx_d) ? rm_d_r : cmx_d;

    // ---- strip 平面（S5 拍；通道色字来自镜像缓存，kk = 480-y，带内 y>=452 ⇒ kk<=28） ----
    wire [7:0] st_bh = s5_col[0] ? bc_rdata[23:16] : bc_rdata[7:0];
    wire [7:0] st_bp = s5_col[0] ? bc_rdata[31:24] : bc_rdata[15:8];
    wire [12:0] st_hf = {st_bh, 5'b0} - {3'b000, st_bh, 2'b0};       // *28 = 32-4
    wire [12:0] st_pf = {st_bp, 5'b0} - {3'b000, st_bp, 2'b0};
    wire [4:0]  st_h  = st_hf[12:8];
    wire [4:0]  st_pk = st_pf[12:8];
    wire [14:0] st_lf = {1'b0, st_bh, 6'b0} + {2'b00, st_bh, 5'b0} + {4'b0000, st_bh, 3'b0}
                      + {5'b00000, st_bh, 2'b0} + {6'b000000, st_bh, 1'b0};
    wire [7:0]  st_lv = 8'd110 + {1'b0, st_lf[14:8]};        // 110 + (barH*110)>>8
    wire [4:0]  st_kk = 5'd0 - s5_y[4:0];                    // (480-y) mod 32，带内即真值
    wire        st_is0   = (st_kk == 5'd0);
    wire        st_ispk  = (st_kk == st_pk) && ({1'b0, st_pk} > ({1'b0, st_h} + 6'd1));
    wire        st_inbar = (st_kk <= st_h) && (st_kk != 5'd0);
    wire [7:0]  strip_w = (s5_band & ~s5_gap) ?      // 间隙像素（x%5==4）恒 0
                          (st_is0   ? 8'd70 :
                           st_ispk  ? 8'd250 :
                           st_inbar ? ((st_kk == st_h) ? 8'd235 : st_lv) : 8'd0) :
                          8'd0;

    // ---- 径向增量索引（S5 拍按输出像素 (x, y-1) 更新；无开方无除法无乘法器） ----
    // r² 增量维护（规格 §算术清单口径）：r 变 ±1 时 r² 变 ±(2r+1)，两次级联单步调整
    //（行首跳变 ≤2 已穷举验证，沿帧内 ≤1）。行首 s 绝对重算；帧首行 r 自举 390。
    wire        rad_en   = en & s5_emit;
    wire [9:0]  rad_x    = s5_x;
    wire [8:0]  rad_yout = s5_y - 9'd1;
    wire        rad_row0 = (rad_x == 10'd0);
    wire [9:0]  rad_dy   = {1'b0, rad_yout} - 10'd224;       // y-224，补码位型
    wire [9:0]  rad_dya  = rad_dy[9] ? (~rad_dy + 10'd1) : rad_dy;
    wire [19:0] rad_dy2  = rad_dya * rad_dya;                // 每行一次（行首），常数级
    wire [11:0] rad_ds   = {1'b0, rad_x, 1'b0} - 12'd641;    // 2x-641 = 2(x-320)-1
    wire [17:0] rad_dse  = {{6{rad_ds[11]}}, rad_ds};        // 符号扩展
    wire [17:0] rad_sn   = rad_row0 ? (CXC + rad_dy2[17:0]) : (s_reg + rad_dse);
    wire        rad_boot = (rad_row0 & (rad_yout == 9'd0));
    wire [9:0]  rad_rc   = rad_boot ? 10'd390 : r_reg;
    wire [19:0] rad_sqc  = rad_boot ? 20'd152100 : sq_reg;   // 390²

    // 单步调整 1：(r,sq) -> (r1,sq1)
    wire [19:0] sq_c_p1  = rad_sqc + {9'b000000000, rad_rc, 1'b0} + 20'd1;          // (r+1)²
    wire        inc1_up  = ({2'b00, rad_sn} >= sq_c_p1);
    wire        inc1_dn  = (rad_rc != 10'd0) && ({2'b00, rad_sn} < rad_sqc);
    wire [9:0]  rad_r1   = rad_rc + {9'd0, inc1_up} - {9'd0, inc1_dn};
    wire [19:0] rad_sq1  = rad_sqc + (inc1_up ? ({9'b000000000, rad_rc, 1'b0} + 20'd1) : 20'd0)
                                  - (inc1_dn ? ({9'b000000000, rad_rc, 1'b0} - 20'd1) : 20'd0);
    // 单步调整 2：(r1,sq1) -> (r2,sq2)
    wire [19:0] sq_1_p1  = rad_sq1 + {9'b000000000, rad_r1, 1'b0} + 20'd1;
    wire        inc2_up  = ({2'b00, rad_sn} >= sq_1_p1);
    wire        inc2_dn  = (rad_r1 != 10'd0) && ({2'b00, rad_sn} < rad_sq1);
    wire [9:0]  rad_r2   = rad_r1 + {9'd0, inc2_up} - {9'd0, inc2_dn};
    wire [19:0] rad_sq2  = rad_sq1 + (inc2_up ? ({9'b000000000, rad_r1, 1'b0} + 20'd1) : 20'd0)
                                  - (inc2_dn ? ({9'b000000000, rad_r1, 1'b0} - 20'd1) : 20'd0);

    reg  [17:0] s_reg;
    reg  [9:0]  r_reg;
    reg  [19:0] sq_reg;

    // ---- 合成第一级（S6）：ov_k 增益 / 墨线底亮 / 量化 / 索引选择 / 调色板 ----
    wire [15:0] lg_p  = s6_cl * glob_reg[15:8];
    wire [7:0]  lg_v  = lg_p[15:8];
    wire [15:0] d190p = {1'b0, s6_cd, 7'b0} + {2'b00, s6_cd, 6'b0} - {7'b0000000, s6_cd, 1'b0};
    wire [7:0]  d190  = d190p[15:8];
    wire [7:0]  a_v   = (s6_cl > d190) ? s6_cl : d190;
    wire [15:0] av_p  = a_v * glob_reg[15:8];
    wire [7:0]  av_v  = av_p[15:8];
    wire [7:0]  v0_w  = (s6_strip > av_v) ? s6_strip : av_v;
    wire        zero_w= (v0_w == 8'd0);
    wire [7:0]  vq_w  = v0_w & 8'hF8;                                    // 32 档量化
    wire [7:0]  ll_w  = (lg_v > s6_strip) ? lg_v : s6_strip;
    wire [7:0]  dif_w = ll_w - 8'd190;
    wire [7:0]  w_w   = (ll_w > 8'd190) ? ((dif_w > 8'd63) ? 8'd255 : {dif_w[5:0], 2'b00}) : 8'd0;
    wire [6:0]  chx_w = pcb_chidx_rom(s6_col);
    wire [7:0]  rsh_w = r_reg[9:2];                                      // r>>2（r<=409 ⇒ <=102）
    wire [6:0]  idxr_w= (rsh_w > 8'd63) ? 7'd63 : {1'b0, rsh_w[5:0]};
    wire [6:0]  idx_w = ((s6_strip != 8'd0) && (s6_strip >= lg_v))
                        ? (s6_band ? chx_w : idxr_w) : idxr_w;
    wire [23:0] pal_w = pcb_pal_rom(idx_w[5:0]);
    wire [15:0] pr_p  = pal_w[23:16] * vq_w;
    wire [15:0] pg_p  = pal_w[15:8]  * vq_w;
    wire [15:0] pb_p  = pal_w[7:0]   * vq_w;

    // ---- 合成第二级（S7）：高光混白 + 叠加混合 ----
    wire [7:0]  inv_r = 8'd255 - c1_pr;
    wire [7:0]  inv_g = 8'd255 - c1_pg;
    wire [7:0]  inv_b = 8'd255 - c1_pb;
    wire [15:0] wm_rp = inv_r * c1_w;
    wire [15:0] wm_gp = inv_g * c1_w;
    wire [15:0] wm_bp = inv_b * c1_w;
    wire [7:0]  r8_w  = (c1_w == 8'd0) ? c1_pr : (c1_pr + wm_rp[15:8]);
    wire [7:0]  g8_w  = (c1_w == 8'd0) ? c1_pg : (c1_pg + wm_gp[15:8]);
    wire [7:0]  b8_w  = (c1_w == 8'd0) ? c1_pb : (c1_pb + wm_bp[15:8]);
    wire [15:0] out_w = {r8_w[7:3], g8_w[7:2], b8_w[7:3]};

    wire [7:0] bg_r0 = s7_band ? {1'b0, s7_bg[15:11], 2'b00} : {s7_bg[15:11], 3'b000};
    wire [7:0] bg_g0 = s7_band ? {1'b0, s7_bg[10:5],  1'b0 } : {s7_bg[10:5],  2'b00};
    wire [7:0] bg_b0 = s7_band ? {1'b0, s7_bg[4:0],   2'b00} : {s7_bg[4:0],   3'b000};
    wire [7:0] fr_r  = {out_w[15:11], 3'b000};
    wire [7:0] fr_g  = {out_w[10:5],  2'b00};
    wire [7:0] fr_b  = {out_w[4:0],   3'b000};
    wire [7:0] v2_w  = (fr_r > fr_g) ? ((fr_r > fr_b) ? fr_r : fr_b)
                                     : ((fr_g > fr_b) ? fr_g : fr_b);
    wire [7:0] m_w   = (v2_w[7:6] == 2'b00) ? 8'd64  :
                       (v2_w[7:6] == 2'b01) ? 8'd128 :
                       (v2_w[7:6] == 2'b10) ? 8'd192 : 8'd224;
    wire [9:0] y_sum = {2'b00, bg_r0} + {1'b0, bg_g0, 1'b0} + {2'b00, bg_b0};
    wire [7:0] y_w   = y_sum[9:2];
    wire [7:0] fr_r2 = (y_w >= 8'd128) ? ((fr_r >> 2) + (fr_r >> 3)) : fr_r;
    wire [7:0] fr_g2 = (y_w >= 8'd128) ? ((fr_g >> 2) + (fr_g >> 3)) : fr_g;
    wire [7:0] fr_b2 = (y_w >= 8'd128) ? ((fr_b >> 2) + (fr_b >> 3)) : fr_b;
    wire signed [8:0]  dr_r = $signed({1'b0, fr_r2}) - $signed({1'b0, bg_r0});
    wire signed [8:0]  dr_g = $signed({1'b0, fr_g2}) - $signed({1'b0, bg_g0});
    wire signed [8:0]  dr_b = $signed({1'b0, fr_b2}) - $signed({1'b0, bg_b0});
    wire signed [16:0] ml_r = dr_r * $signed({1'b0, m_w});
    wire signed [16:0] ml_g = dr_g * $signed({1'b0, m_w});
    wire signed [16:0] ml_b = dr_b * $signed({1'b0, m_w});
    wire [8:0]  bs_r  = {1'b0, bg_r0} + ml_r[16:8];   // (diff*m)>>>8 的补码位型直接相加
    wire [8:0]  bs_g  = {1'b0, bg_g0} + ml_g[16:8];
    wire [8:0]  bs_b  = {1'b0, bg_b0} + ml_b[16:8];
    wire [15:0] ovl_w = c1_zero ? {bg_r0[7:3], bg_g0[7:2], bg_b0[7:3]}
                                : {bs_r[7:3],  bs_g[7:2],  bs_b[7:3]};
    wire [15:0] fin_w = ov_on ? ovl_w : out_w;

    // ---- 行缓存实例（读 S4 拍 / 写 S5 拍末沿，同地址天然错拍） ----
    pcb_linebuf_dp u_lb0 (
        .clk(clk), .rd_addr(s4_x), .rd_data(lb0_q),
        .we(en), .wr_addr(s5_x), .wr_data(lb1_q)              // lb0 ← 旧行 y-1
    );
    pcb_linebuf_dp u_lb1 (
        .clk(clk), .rd_addr(s4_x), .rd_data(lb1_q),
        .we(en), .wr_addr(s5_x), .wr_data({rm_l_r, rm_d_r})   // lb1 ← 当前行 rowmax
    );
    pcb_linebuf_dp u_img (
        .clk(clk), .rd_addr(s4_x), .rd_data(img_q),
        .we(en), .wr_addr(s5_x), .wr_data(s5_image)           // 底图 1 行延迟（写随 S5 错拍）
    );

    // ---- 流水寄存器 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_label <= 16'd0; s1_image <= 16'd0; s1_x <= 10'd0; s1_y <= 9'd0; s1_col <= 7'd0; s1_emit <= 1'b0; s1_gap <= 1'b0;
            s2_label <= 16'd0; s2_image <= 16'd0; s2_x <= 10'd0; s2_y <= 9'd0; s2_col <= 7'd0; s2_emit <= 1'b0; s2_gap <= 1'b0;
            s3_dark <= 8'd0; s3_light <= 8'd0; s3_image <= 16'd0; s3_x <= 10'd0; s3_y <= 9'd0; s3_col <= 7'd0; s3_emit <= 1'b0; s3_gap <= 1'b0;
            s4_dark <= 8'd0; s4_light <= 8'd0; s4_image <= 16'd0; s4_x <= 10'd0; s4_y <= 9'd0; s4_col <= 7'd0; s4_emit <= 1'b0; s4_gap <= 1'b0;
            s5_dark <= 8'd0; s5_light <= 8'd0; s5_image <= 16'd0; s5_x <= 10'd0; s5_y <= 9'd0; s5_col <= 7'd0; s5_emit <= 1'b0; s5_gap <= 1'b0;
            rm_l_r <= 8'd0; rm_d_r <= 8'd0;
            s6_cl <= 8'd0; s6_cd <= 8'd0; s6_strip <= 8'd0; s6_col <= 7'd0;
            s6_band <= 1'b0; s6_emit <= 1'b0; s6_bg <= 16'd0;
            c1_pr <= 8'd0; c1_pg <= 8'd0; c1_pb <= 8'd0; c1_w <= 8'd0; c1_zero <= 1'b0;
            s7_bg <= 16'd0; s7_band <= 1'b0; s7_emit <= 1'b0;
            s_reg <= 18'd0; r_reg <= 10'd0; sq_reg <= 20'd0;
        end else if (en) begin
            // S0→S1
            s1_label <= cur_label;  s1_image <= cur_image;
            s1_x <= cur_x;          s1_y <= cur_y;
            s1_col <= cur_col;      s1_emit <= cur_emit;   s1_gap <= cur_gap;
            // S1→S2
            s2_label <= s1_label;   s2_image <= s1_image;
            s2_x <= s1_x;           s2_y <= s1_y;      s2_col <= s1_col;   s2_gap <= s1_gap;
            s2_emit <= frame_start ? 1'b0 : s1_emit;
            // S2→S3（class 计算结果与上下文同步推进）
            s3_dark <= dark1_w;     s3_light <= light1_w;   s3_image <= s2_image;
            s3_x <= s2_x;           s3_y <= s2_y;      s3_col <= s2_col;   s3_gap <= s2_gap;
            s3_emit <= frame_start ? 1'b0 : s2_emit;
            // S3→S4
            s4_dark <= s3_dark;     s4_light <= s3_light;   s4_image <= s3_image;
            s4_x <= s3_x;           s4_y <= s3_y;      s4_col <= s3_col;   s4_gap <= s3_gap;
            s4_emit <= frame_start ? 1'b0 : s3_emit;
            // S4→S5
            s5_dark <= s4_dark;     s5_light <= s4_light;   s5_image <= s4_image;
            s5_x <= s4_x;           s5_y <= s4_y;      s5_col <= s4_col;   s5_gap <= s4_gap;
            s5_emit <= frame_start ? 1'b0 : s4_emit;
            rm_l_r <= rm_l_w;       rm_d_r <= rm_d_w;
            // S5→S6
            s6_cl <= cm_l_w;        s6_cd <= cm_d_w;
            s6_strip <= strip_w;    s6_col <= s5_col;
            s6_band <= s5_band;     s6_emit <= frame_start ? 1'b0 : s5_emit;
            s6_bg <= img_q;
            // 径向增量（每输出像素一次；r² 同步增量维护）
            if (rad_en) begin
                s_reg  <= rad_sn;
                r_reg  <= rad_r2;
                sq_reg <= rad_sq2;
            end
            // S6→S7
            c1_pr <= pr_p[15:8];    c1_pg <= pg_p[15:8];    c1_pb <= pb_p[15:8];
            c1_w <= w_w;            c1_zero <= zero_w;
            s7_bg <= s6_bg;         s7_band <= s6_band;     s7_emit <= frame_start ? 1'b0 : s6_emit;
        end
    end

    // ---- 输出寄存（仅有效拍更新；断流保持像素值、valid 拉 0） ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_rgb565 <= 16'd0;
            pixel_valid  <= 1'b0;
        end else if (en) begin
            pixel_valid <= s7_emit;
            if (s7_emit)
                pixel_rgb565 <= fin_w;
        end else begin
            pixel_valid <= 1'b0;
        end
    end

endmodule
