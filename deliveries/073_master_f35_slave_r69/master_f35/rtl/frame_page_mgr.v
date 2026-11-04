`timescale 1ns / 1ps
// ============================================================================
// frame_page_mgr — 三页帧缓冲所有权与内容节拍(ctrl 域)
//
// 页状态 FREE / FILLING / READY / DISPLAY, 任一时刻最多一个 DISPLAY。
//   * 生产者: fill_req 电平请求, 有 FREE 页时 fill_grant 单拍并给 fill_page;
//     fill_commit 单拍把该页置 READY(帧号递增)。
//   * 显示 DMA: 每次扫描开始 scan_req 单拍, 下一拍 scan_ack 给出本次扫描的
//     页基址。内容节拍按 fps/60 有理数累加: 到期且有 READY 才换页, 旧 DISPLAY
//     立即 FREE —— DMA 在发出 scan_req 时已读完旧页全部字, FIFO 中是副本。
//     到期但无 READY: 保持原页并 repeat 计数, 到期标志保留(不跳帧)。
//   * pause_req 在 scan_req 拍采样: 暂停期间内容节拍冻结、不换页, paused 与
//     页切换同在帧边界生效, 音频据 paused 同步停放, 恢复后音画仍对齐。
//   * clear: 同步清空页状态(重新播放/离开视频时), 期间扫描照常应答但无有效帧。
// ============================================================================
module frame_page_mgr #(
    parameter [20:0] PAGE_WORDS = 21'd153600
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [5:0]  fps,           // 内容帧率 15/24/30 等, <=60
    input  wire        clear,
    input  wire        pause_req,
    output reg         paused,

    input  wire        fill_req,
    output reg         fill_grant,
    output reg  [1:0]  fill_page,
    output wire [20:0] fill_base,
    input  wire        fill_commit,

    input  wire        scan_req,
    output reg         scan_ack,
    output reg  [20:0] scan_base,
    output reg         scan_valid,    // 0: 尚无完整帧, 本次不扫描(输出黑)
    output reg         disp_valid,    // 已有完整帧在显示

    output reg  [15:0] repeat_cnt,
    output reg  [15:0] shown_cnt
);
    localparam [1:0] FREE = 2'd0, FILL = 2'd1, READY = 2'd2, DISP = 2'd3;

    reg [1:0] st [0:2];
    reg [7:0] seq [0:2];              // READY 先后次序
    reg [7:0] seq_ctr;
    reg [6:0] acc;
    reg       due;
    reg [1:0] disp_page;

    function [20:0] base_of(input [1:0] p);
        base_of = (p == 2'd0) ? 21'd0 : (p == 2'd1) ? PAGE_WORDS : (PAGE_WORDS << 1);
    endfunction
    assign fill_base = base_of(fill_page);

    // 组合: 首个 FREE 页 / 最早 READY 页
    reg       has_free, has_ready;
    reg [1:0] free_p, ready_p;
    integer i;
    always @(*) begin
        has_free = 1'b0; free_p = 2'd0;
        has_ready = 1'b0; ready_p = 2'd0;
        for (i = 2; i >= 0; i = i - 1) begin
            if (st[i] == FREE) begin has_free = 1'b1; free_p = i[1:0]; end
        end
        for (i = 0; i < 3; i = i + 1) begin
            if (st[i] == READY && (!has_ready || (seq[i] - seq[ready_p]) >= 8'h80)) begin
                has_ready = 1'b1; ready_p = i[1:0];
            end
        end
    end

    wire [6:0] acc_n   = acc + fps;
    wire       tick    = (acc_n >= 7'd60);
    wire       due_n   = due || tick;
    wire       swap    = scan_req && !pause_req && due_n && has_ready;
    reg        filling;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st[0] <= FREE; st[1] <= FREE; st[2] <= FREE;
            seq[0] <= 8'd0; seq[1] <= 8'd0; seq[2] <= 8'd0;
            seq_ctr    <= 8'd0;
            acc        <= 7'd0;
            due        <= 1'b0;
            disp_page  <= 2'd0;
            disp_valid <= 1'b0;
            fill_grant <= 1'b0;
            fill_page  <= 2'd0;
            filling    <= 1'b0;
            scan_ack   <= 1'b0;
            scan_base  <= 21'd0;
            scan_valid <= 1'b0;
            repeat_cnt <= 16'd0;
            shown_cnt  <= 16'd0;
            paused     <= 1'b0;
        end else if (clear) begin
            st[0] <= FREE; st[1] <= FREE; st[2] <= FREE;
            acc <= 7'd0; due <= 1'b0; disp_valid <= 1'b0; fill_grant <= 1'b0; filling <= 1'b0;
            shown_cnt <= 16'd0; paused <= 1'b0;
            scan_ack <= scan_req; scan_valid <= 1'b0;
        end else begin
            fill_grant <= 1'b0;
            scan_ack   <= 1'b0;

            if (fill_commit && filling) begin
                st[fill_page]  <= READY;
                seq[fill_page] <= seq_ctr;
                seq_ctr        <= seq_ctr + 8'd1;
                filling        <= 1'b0;
            end else if (fill_req && !filling && !fill_grant && has_free) begin
                st[free_p] <= FILL;
                fill_page  <= free_p;
                fill_grant <= 1'b1;
                filling    <= 1'b1;
            end

            if (scan_req) begin
                scan_ack <= 1'b1;
                paused   <= pause_req;
                if (!pause_req) acc <= tick ? acc_n - 7'd60 : acc_n;
                if (pause_req) begin
                    scan_base   <= base_of(disp_page);
                    scan_valid  <= disp_valid;
                end else if (swap) begin
                    if (disp_valid) st[disp_page] <= FREE;
                    st[ready_p] <= DISP;
                    disp_page   <= ready_p;
                    disp_valid  <= 1'b1;
                    scan_base   <= base_of(ready_p);
                    scan_valid  <= 1'b1;
                    due         <= 1'b0;
                    shown_cnt   <= shown_cnt + 16'd1;
                end else begin
                    scan_base   <= base_of(disp_page);
                    scan_valid  <= disp_valid;
                    due         <= due_n;
                    if (due_n && disp_valid && repeat_cnt != 16'hFFFF)
                        repeat_cnt <= repeat_cnt + 16'd1;
                end
            end
        end
    end
endmodule
