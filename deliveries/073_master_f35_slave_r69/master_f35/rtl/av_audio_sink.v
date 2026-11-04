`timescale 1ns / 1ps
// av_audio_sink：缓存并输出媒体PCM样本，按与音频桥一致的分数节拍播放。支持启播门控、暂停与会话清尾。
module av_audio_sink #(
    parameter integer AW = 13                 // 8192 样本 ≈ 170ms
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [31:0] in_data,
    input  wire        in_first,             // 本帧音频区首字(样本数)
    output wire        in_ready,

    input  wire        pix_clk,
    input  wire        pix_rst,
    input  wire        play_en,
    input wire flush_async,pause_async,end_of_stream_async,
    output reg         pcm_valid,            // 单拍, 48.077kHz
    output reg  [15:0] pcm,
    output reg  [15:0] underrun_cnt,
    output wire drained,output reg timing_tick,output wire stream_started,
    output wire        room
);
    // ---- ctrl 域: 按样本数截取 ----
    reg  [15:0] left;                        // 本帧剩余样本
    reg  [15:0] hi_s;
    reg         hi_pend;                     // 字的高半字待写

    wire        f_full;
    wire [AW:0] f_level;
    wire        f_wr = (in_valid && in_ready && !in_first && left != 0) || hi_pend;
    wire [15:0] f_wd = hi_pend ? hi_s : in_data[15:0];

    assign in_ready = !hi_pend && (f_level < (1 << AW) - 2);
    // room 只用于调度, 寄存一拍切断 FIFO 水位减法到读卡调度的组合路径
    reg room_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) room_q <= 1'b0; else room_q <= !f_level[AW] && !f_level[AW-1];
    assign room = room_q;

    wire stream_rst_n=rst_n&&!flush_async;
    always @(posedge clk or negedge stream_rst_n) begin
        if (!stream_rst_n) begin left <= 16'd0; hi_s <= 16'd0; hi_pend <= 1'b0; end
        else begin
            if (hi_pend) hi_pend <= 1'b0;
            if (in_valid && in_ready) begin
                if (in_first) left <= in_data[15:0];
                else if (left != 0) begin
                    if (left >= 16'd2) begin hi_s <= in_data[31:16]; hi_pend <= 1'b1; left <= left - 16'd2; end
                    else left <= 16'd0;
                end
            end
        end
    end

    // ---- 跨域 FIFO ----
    wire        f_empty;
    wire [15:0] f_rd;
    reg         f_re;
    async_word_fifo #(.DW(16), .DEPTH(1 << AW), .RAM32(0)) u_fifo (
        .wr_clk(clk), .wr_rst_n(stream_rst_n), .wr_en(f_wr), .wr_data(f_wd),
        .full(f_full), .wr_level(f_level),
        .rd_clk(pix_clk), .rd_rst_n(~pix_rst&&!flush_async), .rd_en(f_re), .rd_data(f_rd), .empty(f_empty));

    // ---- 像素域: 分数分频节拍 ----
    localparam integer TICK_INC = 25, TICK_MOD = 13104;
    reg [13:0] acc;
    reg [1:0]  pe_s;
    reg        re_d, got,started;
    (* async_reg="true" *) reg[1:0] pause_sync;
    (* async_reg="true" *) reg[3:0] end_sync;
    assign stream_started=started;
    assign drained=end_sync[3]&&f_empty&&!got&&!f_re&&!re_d;
    wire       tick = (acc + TICK_INC >= TICK_MOD);
    always @(posedge pix_clk or posedge pix_rst or posedge flush_async) begin
        if (pix_rst||flush_async) begin
            acc <= 14'd0; pe_s <= 2'b00; f_re <= 1'b0; re_d <= 1'b0; got <= 1'b0;
            pcm_valid <= 1'b0; pcm <= 16'd0; underrun_cnt <= 16'd0;
            pause_sync<=0;end_sync<=0;started<=0;timing_tick<=0;
        end else begin
            pe_s <= {pe_s[0], play_en};timing_tick<=tick;
            pause_sync<={pause_sync[0],pause_async};end_sync<={end_sync[2:0],end_of_stream_async};
            acc  <= tick ? acc + TICK_INC - TICK_MOD : acc + TICK_INC;
            f_re <= 1'b0; pcm_valid <= 1'b0;
            re_d <= f_re && !f_empty;
            // 节拍前一拍发读, 节拍拍出样本
            if (tick && pe_s[1]) begin
                pcm_valid <= started||got;
                if(pause_sync[1])pcm<=0;
                else if (got) begin pcm <= f_rd;started<=1;got<=0;end
                else begin
                    pcm <= 16'd0;
                    if(end_sync[3])pcm_valid<=0;
                    else if(started&&underrun_cnt != 16'hFFFF) underrun_cnt <= underrun_cnt + 16'd1;
                end
            end
            if (re_d) got <= 1'b1;
            if (pe_s[1] && !pause_sync[1] && !got && !f_re && !re_d && !f_empty) f_re <= 1'b1;
        end
    end
endmodule
