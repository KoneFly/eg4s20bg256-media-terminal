`timescale 1ns / 1ps
// sd_video_stream：解析V29头部并分离像素和交织音频，RGB332展开为RGB565。按目录文件长度读取，完整文件长度与帧数由PC工具交叉校验。
module sd_video_stream #(
    parameter integer EXT_AW = 7,
    parameter [15:0]  RUN    = 16'd256
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input wire cancel,output wire quiescent,

    input  wire [EXT_AW:0]   n_ext,
    output reg  [EXT_AW-1:0] ext_raddr,
    input  wire [31:0] ext_lba,
    input  wire [31:0] ext_blocks,
    input  wire [31:0] file_size,

    output reg         hdr_ok,
    output reg         hdr_err,
    output reg  [1:0]  fmt,              // 1=RGB565 2=RGB332
    output reg  [5:0]  fps,

    input  wire        init_done,
    output reg         st_start,
    output reg  [31:0] st_lba,
    output reg  [15:0] st_count,
    input  wire        st_busy,
    input  wire        st_done,
    input  wire        st_err,
    input  wire [15:0] st_blocks,

    input  wire [3:0]  pool_count,
    output reg  [6:0]  pool_raddr,
    input  wire [31:0] pool_rdata,
    output reg         pool_release,

    output reg         out_valid,
    output reg  [31:0] out_data,
    input  wire        out_ready,

    output reg         aud_valid,
    output reg  [31:0] aud_data,
    output reg         aud_first,
    input  wire        aud_ready,
    output reg         has_audio,
    output wire [31:0] frame_count,      // 文件头帧数(hdr_ok 后有效)

    output reg  [15:0] retry_cnt
);
    // ------------------------------------------------------------------
    // 请求侧: 遍历 extent
    // ------------------------------------------------------------------
    localparam [2:0] Q_IDLE = 3'd0, Q_LD = 3'd1, Q_LD2 = 3'd2, Q_ISSUE = 3'd3, Q_RUN = 3'd4, Q_LD3 = 3'd5;
    reg [2:0]  qs;
    reg [EXT_AW:0] ei;           // 当前 extent 序号
    reg [31:0] e_lba, e_left;    // 当前 extent 剩余
    reg        first_pass;       // 第一遍(含头块)
    reg [31:0] p_left;           // 本遍剩余块
    reg [31:0] x_lba, x_blk;     // extent 读口寄存(切断 RAM 读到比较/选择的长路径)
    wire [31:0] file_blocks = (file_size + 32'd511) >> 9;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            qs <= Q_IDLE; ei <= 0; e_lba <= 0; e_left <= 0; first_pass <= 1'b1; p_left <= 0;
            x_lba <= 0; x_blk <= 0;
            ext_raddr <= 0; st_start <= 1'b0; st_lba <= 0; st_count <= 0; retry_cnt <= 0;
        end else begin
            st_start <= 1'b0;
            case (qs)
            Q_IDLE: if (enable && !cancel && init_done && n_ext != 0) begin
                ei <= 0; ext_raddr <= 0; first_pass <= 1'b1; p_left <= file_blocks; qs <= Q_LD;
            end
            Q_LD:  qs <= Q_LD2;              // extent 读口 1 拍
            Q_LD2: begin
                // 回绕后的第一个 extent 跳过头块
                if (ei == 0 && !first_pass) begin x_lba <= ext_lba + 32'd1; x_blk <= ext_blocks - 32'd1; end
                else begin x_lba <= ext_lba; x_blk <= ext_blocks; end
                qs <= Q_LD3;
            end
            Q_LD3: begin
                // 剩余量不超过本遍剩余
                e_lba  <= x_lba;
                e_left <= (x_blk > p_left) ? p_left : x_blk;
                qs <= Q_ISSUE;
            end
            Q_ISSUE: begin
                if (!enable || cancel || hdr_err) qs <= Q_IDLE;
                else if (e_left == 0) begin
                    if (p_left == 0 || ei + 1'b1 == n_ext) begin
                        ei <= 0; ext_raddr <= 0; first_pass <= 1'b0; p_left <= file_blocks - 32'd1;
                    end
                    else begin ei <= ei + 1'b1; ext_raddr <= ext_raddr + 1'b1; end
                    qs <= Q_LD;
                end else if (!st_busy) begin
                    st_start <= 1'b1;
                    st_lba   <= e_lba;
                    st_count <= (e_left > RUN) ? RUN : e_left[15:0];
                    qs <= Q_RUN;
                end
            end
            Q_RUN: if (st_done) begin
                if (st_err && retry_cnt != 16'hFFFF) retry_cnt <= retry_cnt + 16'd1;
                e_lba  <= e_lba + st_blocks;
                e_left <= e_left - st_blocks;
                p_left <= p_left - st_blocks;
                qs <= Q_ISSUE;
            end
            default: qs <= Q_IDLE;
            endcase
            if(cancel)begin st_start<=0;if(qs!=Q_RUN||st_done)qs<=Q_IDLE;end
        end
    end

    // ------------------------------------------------------------------
    // 数据侧: 头块解析 + 像素字输出
    // ------------------------------------------------------------------
    reg        rd_pend, rd_pend2;
    reg [7:0]  widx;               // 已发出读的字号 0..128
    reg [6:0]  w1, w2;
    reg        hdr_seen;           // 头块已消费
    reg [31:0] h_magic, h_vw, h_dim, h_fmt, h_fb, h_fc;
    reg [5:0]  h_fps;
    reg [7:0]  h_ab;               // 每帧音频块数
    reg [7:0]  a_blocks;
    reg [11:0] pix_blk;            // 帧内像素块序号(到 ppb 后进入音频区)
    reg [7:0]  aud_blk;
    reg        in_aud;
    wire [11:0] ppb = (fmt == 2'd1) ? 12'd1200 : 12'd600;
    // 当前读返回字所属区: 发读时锁存
    reg        a1, a2, af1, af2;
    // 待输出缓冲: RGB332 一个源字产生两个输出字
    reg [31:0] pend_a, pend_b;
    reg [1:0]  pend_n;

    function [15:0] x332(input [7:0] c);
        x332 = {c[7:5], c[7:6], c[4:2], c[4:2], c[1:0], c[1:0], c[1]};   // R5 G6 B5 位复制
    endfunction

    wire in_hdr     = !hdr_seen;
    wire [31:0] h_rec  = h_fb + {15'd0, h_ab, 9'd0};
    // 文件长度不与帧数交叉校验: 播放按目录项文件长度截止(p_left), 截断文件只是提前回绕。
    wire       h_ver1 = (h_vw == 32'h0200_0001) && (h_ab == 8'd0);
    wire       h_ver2 = (h_vw == 32'h0200_0002) && (h_ab != 8'd0);
    wire out_free   = !out_valid || out_ready;
    wire aud_free   = !aud_valid || aud_ready;
    // 归还脉冲在下一拍才更新块池队首/数量；该拍不能据旧count发起下一slot读。
    wire can_issue  = (pool_count != 0) && !pool_release && (widx != 8'd128) && !rd_pend && !rd_pend2 &&
                      (pend_n == 2'd0) && (in_hdr || hdr_ok) && (!in_aud || aud_free);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pool_raddr <= 0; pool_release <= 1'b0; rd_pend <= 1'b0; rd_pend2 <= 1'b0;
            widx <= 0; w1 <= 0; w2 <= 0; hdr_seen <= 1'b0; hdr_ok <= 1'b0; hdr_err <= 1'b0;
            h_magic <= 0; h_vw <= 0; h_dim <= 0; h_fmt <= 0; h_fb <= 0; h_fc <= 0; h_fps <= 0;
            fmt <= 2'd1; fps <= 6'd30;
            pend_a <= 0; pend_b <= 0; pend_n <= 0; out_valid <= 1'b0; out_data <= 0;
            h_ab <= 0; a_blocks <= 0; pix_blk <= 0; aud_blk <= 0; in_aud <= 1'b0;
            a1 <= 0; a2 <= 0; af1 <= 0; af2 <= 0;
            aud_valid <= 1'b0; aud_data <= 0; aud_first <= 1'b0; has_audio <= 1'b0;
        end else begin
            pool_release <= 1'b0;
            if (out_valid && out_ready) out_valid <= 1'b0;
            if (aud_valid && aud_ready) aud_valid <= 1'b0;
            rd_pend2 <= rd_pend; rd_pend <= 1'b0; w2 <= w1; a2 <= a1; af2 <= af1;

            if (!enable) begin
                hdr_seen <= 1'b0; hdr_ok <= 1'b0; hdr_err <= 1'b0;
            end

            // 读返回
            if (rd_pend2) begin
                if (in_hdr) begin
                    case (w2)
                    7'd0: h_magic <= pool_rdata;
                    7'd1: h_vw    <= pool_rdata;      // version | header_bytes<<16
                    7'd2: h_dim   <= pool_rdata;      // width | height<<16
                    7'd3: begin h_fmt <= {24'd0, pool_rdata[7:0]}; h_ab <= pool_rdata[15:8]; end
                    7'd4: h_fps   <= pool_rdata[5:0];
                    7'd6: h_fb    <= pool_rdata;
                    7'd7: h_fc    <= pool_rdata;
                    default: ;
                    endcase
                end else if (a2) begin
                    aud_valid <= 1'b1; aud_data <= pool_rdata; aud_first <= af2;
                end else if (fmt == 2'd2) begin
                    pend_a <= {x332(pool_rdata[15:8]), x332(pool_rdata[7:0])};
                    pend_b <= {x332(pool_rdata[31:24]), x332(pool_rdata[23:16])};
                    pend_n <= 2'd2;
                end else begin
                    pend_a <= pool_rdata; pend_n <= 2'd1;
                end
            end

            // 输出
            if (pend_n != 0 && out_free && !rd_pend2) begin
                out_valid <= 1'b1;
                out_data  <= pend_a;
                pend_a    <= pend_b;
                pend_n    <= pend_n - 2'd1;
            end

            // 发读 / 块结束
            if (can_issue && enable) begin
                pool_raddr <= widx[6:0]; w1 <= widx[6:0]; rd_pend <= 1'b1; widx <= widx + 8'd1;
                a1 <= in_aud && !in_hdr; af1 <= in_aud && !in_hdr && (aud_blk == 0) && (widx == 0);
            end else if (widx == 8'd128 && !rd_pend && !rd_pend2 && pend_n == 0 && !(in_aud && aud_valid)) begin
                pool_release <= 1'b1; widx <= 0;
                // 帧记录内块计数: 像素块 ppb 个, 然后音频块 a_blocks 个
                if (!in_hdr) begin
                    if (!in_aud) begin
                        if (pix_blk + 12'd1 == ppb) begin
                            pix_blk <= 0;
                            if (a_blocks != 0) begin in_aud <= 1'b1; aud_blk <= 0; end
                        end else pix_blk <= pix_blk + 12'd1;
                    end else begin
                        if (aud_blk + 8'd1 == a_blocks) in_aud <= 1'b0;
                        else aud_blk <= aud_blk + 8'd1;
                    end
                end
                if (in_hdr) begin
                    hdr_seen <= 1'b1;
                    pix_blk <= 0; in_aud <= 1'b0; aud_blk <= 0;
                    if (h_magic == 32'h56393254 && (h_ver1 || h_ver2) && h_dim == 32'h01E0_0280 &&
                        (h_fmt == 32'd1 || h_fmt == 32'd2) &&
                        h_fb == ((h_fmt == 32'd1) ? 32'd614400 : 32'd307200) &&
                        (h_fps == 6'd15 || h_fps == 6'd24 || h_fps == 6'd30) && h_fc != 0 &&
                        file_size > 32'd512) begin
                        hdr_ok <= 1'b1; fmt <= h_fmt[1:0]; fps <= h_fps;
                        a_blocks <= h_ab; has_audio <= h_ver2;
                    end else hdr_err <= 1'b1;
                end
            end
            if(cancel)begin
                out_valid<=0;aud_valid<=0;pend_n<=0;rd_pend<=0;rd_pend2<=0;
                hdr_seen<=0;hdr_ok<=0;hdr_err<=0;has_audio<=0;widx<=0;
                pool_release<=pool_count!=0;
            end
        end
    end
    assign frame_count = h_fc;
    assign quiescent=qs==Q_IDLE&&!st_busy&&pool_count==0&&!out_valid&&!aud_valid&&pend_n==0&&!rd_pend&&!rd_pend2;
endmodule
