// ============================================================================
// interboard_tx.v — 板间链路发送端
//
// 方案: LINK_SPEC.md §二(方案A: GPIO串行 1.5625Mbps) / §三(帧格式) / §四(S2同步)
// 帧结构(160bit, LSB first, 逐字节):
//   byte0,1 = SYNC 16'hA55A (明文)
//   byte2..18 = 载荷 B0..B16 (PRBS7 白化)
//   byte19  = CRC-8(0x07) over B0..B16 (白化)
//   帧间填充 = 0101 交替 (永不匹配 SYNC, 保证线上恒有跳变供对端看门狗判活)
// 铁律:
//   - 纯 RTL, 无从板反馈端口 => 主板绝不依赖从板 (构造性成立)
//   - 输入随时锁存, 绝不阻塞上游; frame_ref 只置发送请求
//   - 跨板信号时序假设为零: 对端(rx)负责全部异步处理
// ============================================================================
`timescale 1ns/1ps

module interboard_tx #(
    parameter OSR = 32              // 位长 = OSR 个 clk; 50MHz/32 = 1.5625 Mbps
)(
    input  wire        clk,
    input  wire        rst_n,
    // ---- 上游契约 (clk 域, INTERFACE_SPEC §一) ----
    input  wire [95:0] energy,       // 8x12bit 无符号, energy[i] = energy[i*12 +: 12]
    input  wire        energy_valid, // 脉冲; 024 约束: 周期 >= 35 拍
    input  wire [1:0]  asset_id,
    input  wire [2:0]  effect_mode,
    input  wire [7:0]  param,
    input  wire        cmd_valid,    // 脉冲; 仅变化时发
    input  wire        frame_ref,    // 脉冲; 每基准发一链路帧
    input  wire [15:0] frame_id,
    // ---- 物理接口 (clk 域产生; 跨板后一律按异步处理) ----
    output wire        link_clk,     // 转发位时钟 clk/OSR: 仅供示波器/自环对照, 对端禁用于采样
    output reg         link_sync,    // 帧窗指示: 帧正在线上 = 1
    output reg         link_data     // NRZ 串行; 空闲期 0101 填充
);

    // ------------------------------------------------------------------
    // 输入锁存 (随时锁存, 不等帧)
    // ------------------------------------------------------------------
    reg [95:0] energy_q;
    reg [1:0]  asset_q;
    reg [2:0]  effect_q;
    reg [7:0]  param_q;
    reg        cmd_pend;
    wire        frame_load;             // 高电平一拍: 本拍组帧

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            energy_q  <= 96'd0;
            asset_q   <= 2'd0;
            effect_q  <= 3'd0;
            param_q   <= 8'd0;
            cmd_pend  <= 1'b0;
        end else begin
            if (energy_valid)
                energy_q <= energy;
            if (cmd_valid) begin
                asset_q  <= asset_id;
                effect_q <= effect_mode;
                param_q  <= param;
                cmd_pend <= 1'b1;
            end else if (frame_load) begin
                cmd_pend <= 1'b0;       // 指令已随帧发出, 恢复"仅变化时发"
            end
        end
    end

    // ------------------------------------------------------------------
    // CRC-8 (poly 0x07, 初值 0x00, 无反射) — 与 rx 内实现一致
    // ------------------------------------------------------------------
    function [7:0] crc8_upd;
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

    // ------------------------------------------------------------------
    // 组帧: byte k 存于 frame_bits[8k +: 8], 线上从 frame_bits[0] 起 LSB first
    // 注意: 组帧发生在 load 拍, 必须采样"当拍输入"(frame_id) 与"当拍将更新"的
    //       组合值(hb_next), 不能用同拍才写入的寄存器 (NBA 滞后一拍, 首帧竞态)
    // ------------------------------------------------------------------
    reg [159:0] frame_bits;
    reg         hb;                     // 心跳翻转位
    wire        hb_next = ~hb;

    integer  ci;
    reg [7:0] crc_c;
    always @(posedge clk) begin
        if (frame_load) begin
            // byte0,1: SYNC (明文)
            frame_bits[  7:   0] = 8'hA5;
            frame_bits[ 15:   8] = 8'h5A;
            // B0/B1: 帧号 (当拍输入)
            frame_bits[ 23:  16] = frame_id[7:0];
            frame_bits[ 31:  24] = frame_id[15:8];
            // B2: flags {rsv[7:2], hb[1], frame_ref_strobe[0]}
            frame_bits[ 39:  32] = {6'b000000, hb_next, 1'b1};
            // B3: cmd {valid[7], asset[6:5], effect[4:2], rsv[1:0]}
            frame_bits[ 47:  40] = cmd_pend ? {1'b1, asset_q, effect_q, 2'b00}
                                            : {1'b0, asset_q, effect_q, 2'b00};
            // B4: param
            frame_bits[ 55:  48] = param_q;
            // B5..B12: energy[0..7] 低 8 位
            for (ci = 0; ci < 8; ci = ci + 1)
                frame_bits[8*(7+ci) +: 8] = energy_q[12*ci +: 8];
            // B13..B16: energy 高 4 位两两打包
            frame_bits[127:120] = {energy_q[23:20], energy_q[11: 8]};   // {e1_hi, e0_hi}
            frame_bits[135:128] = {energy_q[47:44], energy_q[35:32]};   // {e3_hi, e2_hi}
            frame_bits[143:136] = {energy_q[71:68], energy_q[59:56]};   // {e5_hi, e4_hi}
            frame_bits[151:144] = {energy_q[95:92], energy_q[83:80]};   // {e7_hi, e6_hi}
            // B17/CRC: 覆盖 B0..B16 (byte2..18)
            crc_c = 8'h00;
            for (ci = 0; ci < 17; ci = ci + 1)
                crc_c = crc8_upd(crc_c, frame_bits[16 + 8*ci +: 8]);
            frame_bits[159:152] = crc_c;
        end
    end

    // ------------------------------------------------------------------
    // 发送状态机: 位节拍 = 每 OSR 个 clk 出 1 bit (clk/32 = 1.5625 MBd)
    // FILL(0101 填充, 每位翻转) <-> FRAME(160bit 移出)
    // ------------------------------------------------------------------
    localparam [7:0] FILL_MIN = 8'd16;   // 帧间最短填充位数
    localparam       S_FILL   = 1'b0;
    localparam       S_FRAME  = 1'b1;
    localparam [7:0] BPH_MAX = OSR - 1;  // 位相位终点

    reg        state;
    reg [7:0]  bit_idx;                  // 0..159
    reg [7:0]  bph;                      // 位相位分频计数
    reg [6:0]  lfsr;                     // PRBS7 x^7+x^6+1, 种子 0x7F
    reg        fill_lvl;
    reg [7:0]  fill_cnt;
    reg        pend;

    wire bit_tick = (bph == BPH_MAX);
    wire do_load  = (state == S_FILL) && pend && (fill_cnt >= FILL_MIN);
    assign frame_load = do_load & bit_tick;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bph <= 8'd0;
        end else if (bit_tick) begin
            bph <= 8'd0;
        end else begin
            bph <= bph + 8'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_FILL;
            bit_idx   <= 8'd0;
            lfsr      <= 7'h7F;
            fill_lvl  <= 1'b1;
            fill_cnt  <= 8'd0;
            pend      <= 1'b0;
            hb        <= 1'b0;
            link_sync <= 1'b0;
            link_data <= 1'b1;
        end else begin
            if (bit_tick) begin
                case (state)
                    S_FILL: begin
                        link_sync <= 1'b0;
                        link_data <= fill_lvl;
                        fill_lvl  <= ~fill_lvl;
                        fill_cnt  <= fill_cnt + 8'd1;
                        if (do_load) begin
                            state     <= S_FRAME;
                            bit_idx   <= 8'd0;
                            lfsr      <= 7'h7F;
                            fill_cnt  <= 8'd0;
                            hb        <= hb_next;
                            pend      <= 1'b0;
                        end
                    end
                    S_FRAME: begin
                        link_sync <= 1'b1;
                        if (bit_idx < 8'd16) begin
                            link_data <= frame_bits[bit_idx];              // SYNC 明文
                        end else begin
                            link_data <= frame_bits[bit_idx] ^ lfsr[6];    // 载荷白化
                            lfsr      <= {lfsr[5:0], lfsr[6] ^ lfsr[5]};
                        end
                        if (bit_idx == 8'd159) begin
                            state    <= S_FILL;
                            fill_cnt <= 8'd0;
                            fill_lvl <= 1'b1;
                        end else begin
                            bit_idx <= bit_idx + 8'd1;
                        end
                    end
                    default: state <= S_FILL;
                endcase
            end
            // frame_ref 处理置于最后: 与 do_load 同拍时置位优先(脉冲不丢)
            if (frame_ref)
                pend <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // 转发位时钟 clk/OSR (占空 50%): 仅观测用, rx 禁止采样
    // ------------------------------------------------------------------
    reg [7:0]  lcdiv;
    reg        lclk;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lcdiv <= 8'd0;
            lclk  <= 1'b0;
        end else if (lcdiv == OSR/2 - 1) begin
            lcdiv <= 8'd0;
            lclk  <= ~lclk;
        end else begin
            lcdiv <= lcdiv + 8'd1;
        end
    end
    assign link_clk = lclk;

endmodule
