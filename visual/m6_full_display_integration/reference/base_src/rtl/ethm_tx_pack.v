`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 051 契约发包机(app_clk 25MHz 域): 以太网二层 + 32B 应用头 + 128 样本(16bit/样本)
// + 4B 应用 CRC32。
// 线上字节流: DA(6) SA(6) ETH_TYPE(2) | HDR(32) PAYLOAD(256) CRC32(4) = 306 字节。
// 前导码/SFD/MAC FCS 由 TEMAC 负责, 本模块只产生应用字节。
// 头内整数一律小端(051 INTERFACE_SPEC "整数小端"); 应用 CRC32 同样按小端 4 字节
// 书写。051 未明文 CRC 字段的字节序, 本包按"整数小端"通则取小端, 已登记为需
// 协调方裁定的开放项(LINK_REPORT §开放项)。
//
// 本模块原来跑在 tx_clk 125MHz, 最差路径就是 byte_idx -> 字节译码(索引算术 +
// 图形混合 + mux) -> CRC 的 8~9 级逻辑, 实测 WNS -1.488ns, 而业务只要 114,750
// 字节/s。现在整台发包机搬到 25MHz(40ns 一拍), 产生的 306 字节不直接喂 MAC,
// 而是写进一个字节 FIFO(ethm_bafifo), 由 tx_clk 域的 ethm_tx_drain 去排空。
// 逐字节序列、字段偏移、CRC 覆盖范围(第 14..301 字节)与本模块原来完全一致。
//
// 节拍: 25MHz 域分数累加器产生样本 tick, 每 128 tick 一包。
//   PACE_FULL=25_000_000 使 pace_step 直接等于样本/s(与原来 125M 口径同形):
//   pace_step=48000 -> 48000 样本/s -> 375 包/s(产品口径)
//   pace_step=60000 -> 60000 样本/s -> 469 包/s(+25% 源余量测量, 置 flags[0])
//   累加器宽度仍然够: pace_acc < PACE_FULL = 2.5e7 < 2^27, 相加后的余数同宽。
//
// 写出口握手(必须让后人看到):
//   * 起帧门: 只有 fifo_wr_space 说"还装得下一整帧"(实例化时 SPACE_MIN=320 >
//     306)才开新帧。开帧之后本模块只管每拍写一个字节、绝不回头查空间, 因为
//     空间是在起帧那拍一次性预留的, 而读侧(tx_clk 125MHz)只会腾出更多空间。
//     => 帧内不可能撞满; 真撞满就是 bug, tx_stall_max 会把它计成等待拍数。
//   * kind=2'b01 只给第 305 个字节(帧内最后一个), 其余给 2'b00。
//   * 节拍到期但上一帧还挂着(pkt_pending 已置) => 沿用原来的 tx_pacer_overrun。
//------------------------------------------------------------------------------
module ethm_tx_pack #(
    parameter integer FRAME_BYTES = 306,
    parameter integer L2_BYTES = 14,
    parameter [26:0] PACE_FULL = 27'd25_000_000
) (
    input  wire        clk,          // app_clk 25MHz
    input  wire        rst,          // app_rst

    input  wire [16:0] pace_step,
    input  wire [7:0]  pkt_type,
    input  wire [15:0] pkt_flags,
    input  wire [31:0] epoch,
    input  wire [47:0] dst_mac,
    input  wire [47:0] src_mac,

    // 字节 FIFO 写侧(交给 tx_clk 域的 ethm_tx_drain 排空)
    output wire        fifo_wr_en,
    output wire [9:0]  fifo_wr_data,
    input  wire        fifo_wr_space,  // 还装得下一整帧(306) 才允许起帧
    input  wire        fifo_wr_full,

    output reg         frame_done,
    output reg  [31:0] tx_frames,
    output reg         tx_pacer_overrun,
    output reg  [15:0] tx_stall_max,
    output reg  [31:0] tx_seq_now
);
    localparam [8:0] HDR_FIRST = L2_BYTES[8:0];
    localparam [8:0] HDR_LAST  = HDR_FIRST + 9'd31;
    localparam [8:0] PAY_FIRST = HDR_FIRST + 9'd32;
    localparam [8:0] PAY_LAST  = HDR_FIRST + 9'd287;
    localparam [8:0] CRC_FIRST = HDR_FIRST + 9'd288;
    localparam [8:0] LAST_BYTE = FRAME_BYTES[8:0] - 9'd1;

    reg  [26:0] pace_acc;
    reg  [7:0]  tick_grp;
    reg         pkt_pending;
    reg  [63:0] samples_next;

    reg  [8:0]  byte_idx;
    reg  [63:0] ctx_first;
    reg  [31:0] ctx_seq;
    reg         busy;
    reg  [15:0] stall_run;
    reg  [7:0]  byte_comb;      // 当前呈现的字节(组合 mux 在下面)
    wire [31:0] crc_stored;

    // ---------------- 节拍产生 ----------------
    wire [27:0] pace_sum  = {1'b0, pace_acc} + {11'd0, pace_step};
    wire        sample_tick = (pace_sum >= {1'b0, PACE_FULL});

    // ---------------- 载荷图形 ----------------
    wire [8:0]   pay_off   = byte_idx - PAY_FIRST;
    wire [31:0]  pat_index = ctx_first[31:0] + {24'd0, pay_off[8:1]};
    wire  [15:0] pat_val;
    ethm_pcm_pattern u_pattern (
        .sample_index (pat_index),
        .salt         (epoch[15:0]),
        .value        (pat_val)
    );

    // ---------------- 写出口(每拍一个字节, kind 只给帧尾打标) ----------------
    assign fifo_wr_en   = busy && (!fifo_wr_full);
    assign fifo_wr_data = { (byte_idx == LAST_BYTE) ? 2'b01 : 2'b00, byte_comb };
    wire       wr_fire  = fifo_wr_en;

    // ---------------- 应用 CRC32 ----------------
    // 覆盖范围与搬域前一致: 帧内第 14..301 字节, 每拍吞掉真正写出口的那个字节。
    wire        crc_en    = busy && wr_fire && (byte_idx >= HDR_FIRST)
                                  && (byte_idx <= PAY_LAST);
    wire [31:0] crc_final = ~crc_stored;
    ethm_crc32_ref u_crc (
        .clk        (clk),
        .rst        (rst),
        .load_init  (!busy),
        .byte_valid (crc_en),
        .byte_in    (byte_comb),
        .crc        (crc_stored)
    );

    // ---------------- 字节组合(byte_idx 即当前呈现的字节序号) ----------------
    wire [8:0] hdr_off = byte_idx - HDR_FIRST;
    always @(*) begin
        byte_comb = 8'h00;
        if ((L2_BYTES != 0) && (byte_idx < 9'd6)) begin
            case (byte_idx)
                9'd0: byte_comb = dst_mac[47:40];
                9'd1: byte_comb = dst_mac[39:32];
                9'd2: byte_comb = dst_mac[31:24];
                9'd3: byte_comb = dst_mac[23:16];
                9'd4: byte_comb = dst_mac[15:8];
                default: byte_comb = dst_mac[7:0];
            endcase
        end
        else if ((L2_BYTES != 0) && (byte_idx < 9'd12)) begin
            case (byte_idx)
                9'd6:  byte_comb = src_mac[47:40];
                9'd7:  byte_comb = src_mac[39:32];
                9'd8:  byte_comb = src_mac[31:24];
                9'd9:  byte_comb = src_mac[23:16];
                9'd10: byte_comb = src_mac[15:8];
                default: byte_comb = src_mac[7:0];
            endcase
        end
        else if ((L2_BYTES != 0) && (byte_idx < HDR_FIRST)) begin
            byte_comb = (byte_idx == 9'd12) ? 8'h88 : 8'hB5;
        end
        else if (byte_idx <= HDR_LAST) begin
            case (hdr_off[4:0])
                5'd0:  byte_comb = 8'h43;   // magic 0x4D365043, 小端
                5'd1:  byte_comb = 8'h50;
                5'd2:  byte_comb = 8'h36;
                5'd3:  byte_comb = 8'h4D;
                5'd4:  byte_comb = 8'h01;   // version
                5'd5:  byte_comb = pkt_type;
                5'd6:  byte_comb = 8'h00;   // payload_bytes = 256, 小端
                5'd7:  byte_comb = 8'h01;
                5'd8:  byte_comb = epoch[7:0];
                5'd9:  byte_comb = epoch[15:8];
                5'd10: byte_comb = epoch[23:16];
                5'd11: byte_comb = epoch[31:24];
                5'd12: byte_comb = ctx_seq[7:0];
                5'd13: byte_comb = ctx_seq[15:8];
                5'd14: byte_comb = ctx_seq[23:16];
                5'd15: byte_comb = ctx_seq[31:24];
                5'd16: byte_comb = ctx_first[7:0];
                5'd17: byte_comb = ctx_first[15:8];
                5'd18: byte_comb = ctx_first[23:16];
                5'd19: byte_comb = ctx_first[31:24];
                5'd20: byte_comb = ctx_first[39:32];
                5'd21: byte_comb = ctx_first[47:40];
                5'd22: byte_comb = ctx_first[55:48];
                5'd23: byte_comb = ctx_first[63:56];
                5'd24: byte_comb = 8'h80;   // count = 128, 小端
                5'd25: byte_comb = 8'h00;
                5'd26: byte_comb = pkt_flags[7:0];
                5'd27: byte_comb = pkt_flags[15:8];
                default: byte_comb = 8'h00; // reserved[0..3]
            endcase
        end
        else if (byte_idx <= PAY_LAST) begin
            if (byte_idx[0])
                byte_comb = pat_val[15:8];
            else
                byte_comb = pat_val[7:0];
        end
        else begin
            case (byte_idx - CRC_FIRST)
                9'd0:  byte_comb = crc_final[7:0];
                9'd1:  byte_comb = crc_final[15:8];
                9'd2:  byte_comb = crc_final[23:16];
                default: byte_comb = crc_final[31:24];
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pace_acc         <= 27'd0;
            tick_grp         <= 8'd0;
            pkt_pending      <= 1'b0;
            samples_next     <= 64'd0;
            byte_idx         <= 9'd0;
            ctx_first        <= 64'd0;
            ctx_seq          <= 32'd0;
            tx_seq_now       <= 32'd0;
            busy             <= 1'b0;
            frame_done       <= 1'b0;
            tx_frames        <= 32'd0;
            tx_pacer_overrun <= 1'b0;
            stall_run        <= 16'd0;
            tx_stall_max     <= 16'd0;
        end
        else begin
            frame_done       <= 1'b0;
            tx_pacer_overrun <= 1'b0;

            if (sample_tick) begin
                pace_acc <= pace_sum[26:0] - PACE_FULL;
                if (tick_grp == 8'd127) begin
                    tick_grp <= 8'd0;
                    if (pkt_pending)
                        tx_pacer_overrun <= 1'b1;
                    pkt_pending <= 1'b1;
                end
                else begin
                    tick_grp <= tick_grp + 8'd1;
                end
            end
            else begin
                pace_acc <= pace_sum[26:0];
            end

            // ---------- 帧主体: 每拍写一个字节进 FIFO ----------
            // stall_run 统计"为了等空间而白烧的拍数"(原来是等 MAC 的 tx_rdy):
            // 起帧前等 fifo_wr_space, 起帧后等 fifo_wr_full 让开, 帧末取最大值。
            if (!busy) begin
                if (pkt_pending && fifo_wr_space) begin
                    pkt_pending  <= 1'b0;
                    ctx_seq      <= tx_seq_now;
                    ctx_first    <= samples_next;
                    samples_next <= samples_next + 64'd128;
                    tx_seq_now   <= tx_seq_now + 32'd1;
                    byte_idx     <= 9'd0;
                    busy         <= 1'b1;
                end
                else if (pkt_pending && (stall_run != 16'hFFFF)) begin
                    stall_run <= stall_run + 16'd1;
                end
            end
            else if (wr_fire) begin
                if (byte_idx == LAST_BYTE) begin
                    busy       <= 1'b0;
                    frame_done <= 1'b1;
                    tx_frames  <= tx_frames + 32'd1;
                    if (stall_run > tx_stall_max)
                        tx_stall_max <= stall_run;
                    stall_run  <= 16'd0;
                end
                else begin
                    byte_idx <= byte_idx + 9'd1;
                end
            end
            else if (stall_run != 16'hFFFF) begin
                stall_run <= stall_run + 16'd1;
            end
        end
    end
endmodule
