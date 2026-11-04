// ============================================================================
// interboard_rx.v — 板间链路接收端
//
// 方案: LINK_SPEC.md §四(S2: 异步过采样+边沿重定时) / §六(HUNT/LOCK/安全态)
// 核心防御 (对应变异 m1~m4):
//   - 3FF 同步链 + 三取样X容忍表决        → m1(去同步器) 的防御
//   - 边沿重定时(每边沿相位清零)          → m2(固定采样点) 的防御
//   - CRC-8 校验, 失败丢帧回 HUNT, 并对校验缺失情形做防御
//   - 看门狗(32bit 无边沿判线僵死)+重捕   → m4(去重同步) 的防御
// 跨板信号一律按异步处理: link_clk/link_sync 仅保持端口对称, 功能上禁用
// ============================================================================
`timescale 1ns/1ps

module interboard_rx #(
    parameter OSR = 32              // 与 tx 一致: 位长 = OSR 个 clk
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- 物理接口 (一律按异步处理) ----
    input  wire        link_clk,    // 禁止采样 (规格 §五); 仅端口对称保留
    input  wire        link_sync,   // 仅作观测, 不参与功能
    input  wire        link_data,
    // ---- 下游契约 (clk 域, 与 tx 同构, INTERFACE_SPEC §四) ----
    output reg  [95:0] energy,       // 8x12bit
    output reg         energy_valid, // 每通过一帧脉冲 1 拍 (仅 locked 时)
    output reg  [1:0]  asset_id,
    output reg  [2:0]  effect_mode,
    output reg  [7:0]  param,
    output reg         frame_ref_out,
    output reg  [15:0] frame_id_out,
    // ---- 状态 (供降级/安全态) ----
    output wire        link_locked,
    output reg  [7:0]  link_error,     // CRC 失败事件, 饱和计数
    output reg  [15:0] frame_lost_cnt  // 帧号不连续损失帧数, 饱和计数
);

    // ------------------------------------------------------------------
    // 3FF 同步链 (异步输入唯一入口)
    // ------------------------------------------------------------------
    reg s0, s1, s2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0 <= 1'b1; s1 <= 1'b1; s2 <= 1'b1;
        end else begin
            s0 <= link_data; s1 <= s0; s2 <= s1;
        end
    end

`ifdef MUTANT_M1
    // m1: 去掉同步器 — 直接采样异步原始线 (TB 必须击杀)
    wire dline = link_data;
`else
    wire dline = s2;
`endif

    // ------------------------------------------------------------------
    // 过采样相位: 每边沿清零(重定时) / OSR 自由跑
    // ------------------------------------------------------------------
    localparam [7:0] PH_MAX = OSR - 1;
    reg [7:0] ph;
    reg       s2p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s2p <= 1'b1;
        else        s2p <= s2;
    end
    wire edge_det = (dline !== s2p);          // 含 X 引起的"边沿": 无害, 下个真边沿纠正

`ifdef MUTANT_M2
    // m2: 固定采样点 — 相位自由跑, 不做边沿重定时 (TB 必须击杀)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ph <= 8'd0;
        else if (ph == PH_MAX) ph <= 8'd0;
        else                 ph <= ph + 8'd1;
    end
`else
`ifdef MUTANT_M1
    // m1: 直接跨域采样 — 同步链整体(3FF+重定时+表决)旁路, 相位同样自由跑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ph <= 8'd0;
        else if (ph == PH_MAX) ph <= 8'd0;
        else                 ph <= ph + 8'd1;
    end
`else
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          ph <= 8'd0;
        else if (edge_det)   ph <= 8'd0;              // 边沿 ≈ 位边界
        else if (ph == PH_MAX) ph <= 8'd0;
        else                 ph <= ph + 8'd1;
    end
`endif
`endif

    // ------------------------------------------------------------------
    // 三取样 + X 容忍表决 (中心 ±1 拍)
    // ------------------------------------------------------------------
    localparam [7:0] P1 = OSR/2 - 1;
    localparam [7:0] P2 = OSR/2;
    localparam [7:0] P3 = OSR/2 + 1;

    reg sa, sb;
    reg bit_q;
    reg bit_strobe;

    function bitdec;                 // 2/3 表决; X 只污染一个样本时被丢弃
        input a, b, c, hold;
        begin
            if   (a === b) bitdec = a;
            else if (b === c) bitdec = b;
            else if (a === c) bitdec = a;
            else              bitdec = hold;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sa <= 1'b1; sb <= 1'b1; bit_q <= 1'b1; bit_strobe <= 1'b0;
        end else begin
            bit_strobe <= 1'b0;
`ifdef MUTANT_M1
            // m1: 直接跨域单点采样 — 无同步链、无表决 (X 注入即位错, TB 击杀)
            if (ph == P2) begin
                bit_q      <= link_data;
                bit_strobe <= 1'b1;
            end
`else
            if (ph == P1) sa <= s2;
            if (ph == P2) sb <= s2;
            if (ph == P3) begin
                bit_q      <= bitdec(sa, sb, s2, bit_q);   // sa,sb = 前两取样, s2 = 本拍
                bit_strobe <= 1'b1;
            end
`endif
        end
    end

    // ------------------------------------------------------------------
    // 位流处理: SYNC 搜索 / 字节积累 / 白化
    // ------------------------------------------------------------------
    localparam [1:0] ST_HUNT = 2'd0;
    localparam [1:0] ST_RECV = 2'd1;

    reg  [1:0]  st;
    reg  [15:0] shreg;
    reg  [4:0]  hunt_bits;              // 当前 HUNT 的有效位数，饱和到 16
    reg  [7:0]  bsh;
    reg  [7:0]  bidx;                   // 0..143 (载荷+CRC 共 144 bit)
    reg  [6:0]  rlfsr;
    reg  [7:0]  bm [0:17];              // B0..B16 + CRC

    wire [15:0] srx  = {shreg[14:0], bit_q};   // 含当前位的滑窗
    wire        whbit = bit_q ^ rlfsr[6];      // 解白化

    function [7:0] crc8_upd;            // 与 tx 一致: poly 0x07, 初值 0x00
        input [7:0] c;
        input [7:0] d;
        reg   [7:0] x;
        integer i;
        begin
            x = c ^ d;
            for (i = 0; i < 8; i = i + 1)
                x = x[7] ? ({x[6:0], 1'b0} ^ 8'h07) : {x[6:0], 1'b0};
            crc8_upd = x;
        end
    endfunction

    // 帧验收组合判定
    // 注意: bidx==143 那拍 CRC 字节正被写入, 须取"新值" {whbit, bsh} 而非旧 bm[17]
    reg  [7:0] cc;
    reg  [7:0] crc_rx_c;
    reg        crc_ok;
    integer    ci;
    always @* begin
        cc = 8'h00;
        for (ci = 0; ci < 17; ci = ci + 1)
            cc = crc8_upd(cc, bm[ci]);
        crc_rx_c = (bidx == 8'd143) ? {whbit, bsh[7:1]} : bm[17];
        crc_ok   = (cc == crc_rx_c);
    end

`ifdef MUTANT_M3
    wire frame_ok = 1'b1;               // m3: 去掉帧校验 (TB 必须击杀)
`else
    wire frame_ok = crc_ok;
`endif

    // ------------------------------------------------------------------
    // 看门狗: 32 bit 无边沿 = 线僵死(拔线/对端死机/时钟停) => 回 HUNT + 解锁
    // ------------------------------------------------------------------
    localparam [15:0] WD_LIMIT = 32 * OSR;
    reg [15:0] wdc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     wdc <= 16'd0;
        else if (edge_det)              wdc <= 16'd0;
        else if (wdc < WD_LIMIT)        wdc <= wdc + 16'd1;
    end
    wire wd_fire = (wdc >= WD_LIMIT) && !edge_det;

    // ------------------------------------------------------------------
    // 锁定/账目
    // ------------------------------------------------------------------
    reg  [1:0]  good_cnt;
    reg         locked_r;
    reg  [15:0] last_id;
    reg         have_id;

    wire lock_now = locked_r || (good_cnt >= 2'd1);

    function [7:0] sat_inc8;
        input [7:0] v;
        begin sat_inc8 = (v == 8'hFF) ? 8'hFF : v + 8'd1; end
    endfunction
    function [15:0] sat_add16;
        input [15:0] a, b;
        reg [16:0] s;
        begin
            s = {1'b0, a} + {1'b0, b};
            sat_add16 = s[16] ? 16'hFFFF : s[15:0];
        end
    endfunction

    reg [15:0] delta;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st            <= ST_HUNT;
            shreg         <= 16'h0000;
            hunt_bits     <= 5'd0;
            bsh           <= 8'd0;
            bidx          <= 8'd0;
            rlfsr         <= 7'h7F;
            good_cnt      <= 2'd0;
            locked_r      <= 1'b0;
            last_id       <= 16'd0;
            have_id       <= 1'b0;
            link_error    <= 8'd0;
            frame_lost_cnt<= 16'd0;
            energy        <= 96'd0;
            energy_valid  <= 1'b0;
            asset_id      <= 2'd0;
            effect_mode   <= 3'd0;
            param         <= 8'd0;
            frame_ref_out <= 1'b0;
            frame_id_out  <= 16'd0;
        end else begin
            energy_valid  <= 1'b0;      // 默认无脉冲
            frame_ref_out <= 1'b0;

            // 看门狗: 线僵死 => 安全态 (输出保持确定值, valid=0, locked=0)
            // 优先于位处理: 同拍时位流已不可信
`ifndef MUTANT_M4
            if (wd_fire) begin
                st       <= ST_HUNT;
                shreg    <= 16'h0000;
                hunt_bits<= 5'd0;
                locked_r <= 1'b0;
                good_cnt <= 2'd0;
            end else
`endif
            if (bit_strobe) begin
                case (st)
                    ST_HUNT: begin
                        shreg <= srx;
                        if (hunt_bits < 5'd16)
                            hunt_bits <= hunt_bits + 5'd1;
                        // 含当前位满 16 位才有效，不跨接收帧/失锁/复位边界。
                        if (hunt_bits >= 5'd15 && srx == 16'hA55A) begin
                            st    <= ST_RECV;
                            shreg <= 16'h0000;
                            hunt_bits <= 5'd0;
                            bidx  <= 8'd0;
                            bsh   <= 8'd0;
                            rlfsr <= 7'h7F;          // 白化种子与 tx 对齐
                        end
                    end
                    ST_RECV: begin
                        rlfsr <= {rlfsr[5:0], rlfsr[6] ^ rlfsr[5]};
                        bsh   <= {whbit, bsh[7:1]};
                        if (bidx[2:0] == 3'd7)
                            bm[bidx[7:3]] <= {whbit, bsh[7:1]};   // 整字节完成
                        bidx <= bidx + 8'd1;
                        if (bidx == 8'd143) begin
                            // 候选帧已消费完毕；通过或拒绝都从下一采样位重建窗口。
                            shreg <= 16'h0000;
                            hunt_bits <= 5'd0;
                            // ---- 帧完成: 验收 ----
                            if (frame_ok) begin
                                // 锁定迟滞: 连续 2 帧通过才 locked; 脉冲仅 locked 时发
                                good_cnt <= (good_cnt >= 2'd2) ? 2'd2 : good_cnt + 2'd1;
                                locked_r <= lock_now;
                                if (lock_now) begin
                                    // 数据锁存 + 脉冲 (仅锁定时; 解锁期保持安全态确定值)
                                    frame_id_out <= {bm[1], bm[0]};
                                    energy[ 11:  0] <= {bm[13][3:0], bm[ 5]};
                                    energy[ 23: 12] <= {bm[13][7:4], bm[ 6]};
                                    energy[ 35: 24] <= {bm[14][3:0], bm[ 7]};
                                    energy[ 47: 36] <= {bm[14][7:4], bm[ 8]};
                                    energy[ 59: 48] <= {bm[15][3:0], bm[ 9]};
                                    energy[ 71: 60] <= {bm[15][7:4], bm[10]};
                                    energy[ 83: 72] <= {bm[16][3:0], bm[11]};
                                    energy[ 95: 84] <= {bm[16][7:4], bm[12]};
                                    asset_id      <= bm[3][6:5];
                                    effect_mode   <= bm[3][4:2];
                                    param         <= bm[4];
                                    energy_valid  <= 1'b1;
                                    frame_ref_out <= bm[2][0];
                                end
                                // 帧号账目: 全量记账 (含未脉冲帧), 不连续 => 计损失帧
                                if (have_id) begin
                                    delta = {bm[1], bm[0]} - last_id;
                                    if (delta > 16'd1)
                                        frame_lost_cnt <= sat_add16(frame_lost_cnt, delta - 16'd1);
                                end
                                last_id <= {bm[1], bm[0]};
                                have_id <= 1'b1;
                                st      <= ST_HUNT;      // 回到 SYNC 搜索等下一帧
                            end else begin
                                link_error <= sat_inc8(link_error);
`ifdef MUTANT_M4
                                // m4: 去掉重同步 — 留在 RECV, 按旧位格假设继续 (TB 必须击杀)
`else
                                st       <= ST_HUNT;     // 立即重捕
                                locked_r <= 1'b0;
                                good_cnt <= 2'd0;
`endif
                            end
                        end
                    end
                    default: begin
                        st <= ST_HUNT;
                        shreg <= 16'h0000;
                        hunt_bits <= 5'd0;
                    end
                endcase
            end
        end
    end

    assign link_locked = locked_r;

endmodule
