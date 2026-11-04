`timescale 1ns / 1ps
// ============================================================================
// sd_dat_rx — SD 读数据块接收 + 块池(SLOTS×512B, 顺序 FIFO)
//
// 每个 smp 采样一次 DAT: 4 线模式一拍一个 nibble(高 nibble 先), 1 线模式
// 一拍一 bit(MSB 先)。块 = 起始位 + 数据 + 每线 CRC16 + 结束位。
// 块数据按小端打包成 32 位字: word = {b3,b2,b1,b0}(视频 RGB565 LE 直接成字)。
// 只有 CRC 与结束位全部正确的块才进入"已验证"队列; 坏块不占槽, 报 blk_bad。
//
// 停钟流控: 下一块没有空槽时请求停钟(hold_clk)。块内剩余 > HOLD_MARGIN 拍时
//   不停, 留出采样流水内已发出的时钟, 保证下一块起始位不会在无槽时到达;
//   必要时在当前块尾部暂停(SD 卡是静态器件, 主机可在任意时刻停钟)。
// discard=1 或本次已发布 pub_limit 块: 照常接收但不发布、不占槽(CMD12 停止
//   生效前卡多送的块)。限额在块起始时判定, 不依赖上层反应速度。
// 消费端: c_count>0 时队首块可读, c_raddr 选字, c_rdata 下一拍有效; c_release 归还。
// ============================================================================
module sd_dat_rx #(
    parameter integer SLOT_AW     = 3,          // 槽数 = 2^SLOT_AW
    parameter integer HOLD_MARGIN = 8,
    parameter integer TO_W        = 23          // 起始位超时计数宽度(SD 时钟)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        smp,
    input  wire [3:0]  dat_i,

    input  wire        arm,          // 期待数据块
    input  wire        wide,         // 1=4 线
    input  wire [7:0]  blen_words,   // 2 / 16 / 128
    input  wire        discard,
    input  wire        clear,        // 回到等待起始位(停止序列结束后)
    input  wire [15:0] pub_limit,    // 本次(arm 期间)最多发布块数
    input  wire [TO_W-1:0] to_limit,

    output reg         blk_ok,
    output reg         blk_bad,
    output reg         start_to,
    output reg         overflow,
    output wire        in_block,
    output wire        hold_clk,

    output wire [SLOT_AW:0] c_count,
    input  wire [6:0]  c_raddr,
    output reg  [31:0] c_rdata,
    input  wire        c_release
);
    localparam integer SLOTS = 1 << SLOT_AW;
    localparam [1:0] S_WAIT = 2'd0, S_DATA = 2'd1, S_CRC = 2'd2, S_END = 2'd3;

    reg  [1:0]  st;
    reg  [12:0] cnt;               // 块内数据拍计数
    reg  [4:0]  sub;               // 字内 nibble/bit 位置
    reg  [6:0]  widx;
    reg  [31:0] acc;
    reg  [4:0]  ccnt;
    reg         drop;              // 本块不发布(discard 或无槽)
    reg  [TO_W-1:0] tcnt;
    reg  [15:0] pub_cnt;
    wire        at_limit = (pub_cnt == pub_limit);

    reg  [SLOT_AW-1:0] wslot, rslot;
    reg  [SLOT_AW:0]   vcnt;
    assign c_count = vcnt;

    wire [12:0] data_clks = wide ? {2'b00, blen_words, 3'b000} : {blen_words, 5'b00000};
    wire        all_low   = wide ? (dat_i == 4'b0000) : !dat_i[0];
    wire        all_high  = wide ? (dat_i == 4'b1111) : dat_i[0];

    assign in_block = (st != S_WAIT);
    wire [13:0] remain   = (st == S_DATA) ? (data_clks - cnt + 14'd17) :
                           (st == S_CRC)  ? (14'd17 - ccnt) : 14'd1;
    wire [SLOT_AW+1:0] used = vcnt + (in_block && !drop);
    wire        next_ok  = (used < SLOTS);
    assign hold_clk = arm && !discard && !at_limit && !next_ok && !(in_block && remain > HOLD_MARGIN);

    // ---- 每线 CRC16 ----
    reg         crc_clr, crc_en;
    wire [15:0] crc [0:3];
    genvar g;
    generate for (g = 0; g < 4; g = g + 1) begin : L
        sd_crc16 u (.clk(clk), .clr(crc_clr), .en(crc_en), .bit_in(dat_i[g]), .crc(crc[g]));
    end endgenerate
    wire crc_good = wide ? (crc[0] == 16'd0 && crc[1] == 16'd0 && crc[2] == 16'd0 && crc[3] == 16'd0)
                         : (crc[0] == 16'd0);

    always @(*) begin
        crc_clr = (st == S_WAIT);
        crc_en  = smp && (st == S_DATA || st == S_CRC);
    end

    // ---- 打包 ----
    wire [31:0] acc_n = wide ? (acc | ({28'd0, dat_i} << {sub[2:1], ~sub[0], 2'b00}))
                             : (acc | ({31'd0, dat_i[0]} << {sub[4:3], ~sub[2:0]}));
    wire        word_done = wide ? (sub[2:0] == 3'd7) : (sub == 5'd31);

    // 块池落 ERAM9K(32K 池让给缩放行缓冲与像素 FIFO)
    reg  [31:0] mem [0:SLOTS*128-1];
    reg         m_we;
    reg  [SLOT_AW+6:0] m_wa;
    reg  [31:0] m_wd;
    always @(posedge clk) begin
        if (m_we) mem[m_wa] <= m_wd;
        c_rdata <= mem[{rslot, c_raddr}];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_WAIT; cnt <= 13'd0; sub <= 5'd0; widx <= 7'd0; acc <= 32'd0; ccnt <= 5'd0;
            drop <= 1'b0; tcnt <= {TO_W{1'b0}}; pub_cnt <= 16'd0;
            wslot <= {SLOT_AW{1'b0}}; rslot <= {SLOT_AW{1'b0}}; vcnt <= {(SLOT_AW+1){1'b0}};
            blk_ok <= 1'b0; blk_bad <= 1'b0; start_to <= 1'b0; overflow <= 1'b0;
            m_we <= 1'b0; m_wa <= 0; m_wd <= 32'd0;
        end else begin
            blk_ok <= 1'b0; blk_bad <= 1'b0; start_to <= 1'b0; overflow <= 1'b0;
            m_we <= 1'b0;

            if (c_release && vcnt != 0) rslot <= rslot + 1'b1;

            if (clear || !arm) begin
                st <= S_WAIT; tcnt <= {TO_W{1'b0}};
                if (!arm) pub_cnt <= 16'd0;
                if (c_release && vcnt != 0) vcnt <= vcnt - 1'b1;
            end else begin
                if (smp) begin
                    case (st)
                    S_WAIT: begin
                        if (all_low) begin
                            st <= S_DATA; cnt <= 13'd0; sub <= 5'd0; widx <= 7'd0; acc <= 32'd0;
                            tcnt <= {TO_W{1'b0}};
                            drop <= discard || at_limit || (vcnt == SLOTS);
                            if (!discard && !at_limit && vcnt == SLOTS) overflow <= 1'b1;
                        end else if (tcnt == to_limit) begin
                            start_to <= 1'b1; tcnt <= {TO_W{1'b0}};
                        end else tcnt <= tcnt + 1'b1;
                    end
                    S_DATA: begin
                        cnt <= cnt + 13'd1;
                        sub <= word_done ? 5'd0 : sub + 5'd1;
                        if (word_done) begin
                            acc  <= 32'd0;
                            m_we <= !drop; m_wa <= {wslot, widx}; m_wd <= acc_n;
                            widx <= widx + 7'd1;
                        end else acc <= acc_n;
                        if (cnt == data_clks - 1) begin st <= S_CRC; ccnt <= 5'd0; end
                    end
                    S_CRC: begin
                        ccnt <= ccnt + 5'd1;
                        if (ccnt == 5'd15) st <= S_END;
                    end
                    S_END: begin
                        st <= S_WAIT;
                        if (all_high && crc_good) begin
                            if (!drop) begin blk_ok <= 1'b1; wslot <= wslot + 1'b1; pub_cnt <= pub_cnt + 16'd1; end
                        end else blk_bad <= 1'b1;
                    end
                    endcase
                end
                // 已验证计数: 发布 +1, 归还 -1
                case ({(smp && st == S_END && all_high && crc_good && !drop), (c_release && vcnt != 0)})
                2'b10: vcnt <= vcnt + 1'b1;
                2'b01: vcnt <= vcnt - 1'b1;
                default: ;
                endcase
            end
        end
    end
endmodule
