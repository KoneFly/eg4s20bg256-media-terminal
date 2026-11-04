`timescale 1ns / 1ps
// layer_ctrl：帧边界提交显示层描述。视频使用三页页管理器的扫描页，图片双页在转场期间分别作为前后两层。
module layer_ctrl #(
    parameter [20:0] PAGE_WORDS   = 21'd153600,
    parameter integer TRANS_FRAMES = 30
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        mode_video,

    // 视频页(来自 frame_page_mgr)
    output wire        v_scan_req,
    input  wire        v_scan_ack,
    input  wire [20:0] v_scan_base,
    input  wire        v_scan_valid,

    // 图片页控制
    input  wire        show_req,
    input  wire [1:0]  show_page,
    input  wire [2:0]  show_mode,
    input  wire [1:0]  zoom,
    input  wire [1:0]  wall_cell,
    output wire        trans_busy,
    output reg         shown,         // 当前显示页已有内容(首张图片显示后置位)
    output reg  [1:0]  cur_page,

    // 两路 DMA
    input  wire        a_scan_req,
    output reg         a_scan_ack,
    output reg  [20:0] a_scan_base,
    output reg         a_scan_valid,
    output reg  [31:0] a_scan_desc,
    input  wire        b_scan_req,
    output reg         b_scan_ack,
    output reg  [20:0] b_scan_base,
    output reg         b_scan_valid,
    output reg  [31:0] b_scan_desc
);
    function [20:0] img_base(input [1:0] p);
        img_base = PAGE_WORDS * (21'd3 + {19'd0, p});
    endfunction

    assign v_scan_req = mode_video && a_scan_req;

    // ---- 请求锁存: 下一帧边界生效 ----
    reg        pend;
    reg [1:0]  pend_page;
    reg [2:0]  pend_mode;
    reg [1:0]  nxt_page;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin pend <= 1'b0; pend_page <= 2'd0; pend_mode <= 3'd0; end
        else if (show_req) begin pend <= 1'b1; pend_page <= show_page; pend_mode <= show_mode; end
        else if (a_scan_req && !mode_video) pend <= 1'b0;

    // ---- 进度机 ----
    wire        tp_active, tp_done, tp_direct;
    wire [2:0]  tp_mode;
    wire [7:0]  tp_t;
    wire        frame_pulse = a_scan_req && !mode_video;
    trans_progress #(.TRANS_FRAMES(TRANS_FRAMES)) u_tp (
        .clk(clk), .rst_n(rst_n), .vsync_pulse(frame_pulse),
        .req_start(pend && shown), .req_mode(pend_mode), .dst_ready(1'b1),
        .trans_active(tp_active), .trans_mode(tp_mode), .trans_t(tp_t),
        .done_pulse(tp_done), .direct_pulse(tp_direct));
    assign trans_busy = tp_active || pend;

    // ---- 页切换 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin cur_page <= 2'd0; nxt_page <= 2'd0; shown <= 1'b0; end
        else if (frame_pulse && pend) begin
            nxt_page <= pend_page;
            // 首张图或要求直接切换: 立即作为当前页
            if (!shown || pend_mode == 3'd0) begin cur_page <= pend_page; shown <= 1'b1; end
        end else if (tp_done) begin
            cur_page <= nxt_page;
        end
    end

    // 转场完成帧(t 到 255)直接显示目标页, 避免回闪一帧旧页
    wire [1:0] shown_page = tp_done ? nxt_page : cur_page;

    // ---- 应答(scan_req 的下一拍, 进度机已更新) ----
    reg a_d, b_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_d <= 1'b0; b_d <= 1'b0;
            a_scan_ack <= 1'b0; a_scan_base <= 21'd0; a_scan_valid <= 1'b0; a_scan_desc <= 32'd0;
            b_scan_ack <= 1'b0; b_scan_base <= 21'd0; b_scan_valid <= 1'b0; b_scan_desc <= 32'd0;
        end else begin
            a_d <= a_scan_req && !mode_video;
            b_d <= b_scan_req;
            a_scan_ack <= 1'b0; b_scan_ack <= 1'b0;
            if (mode_video) begin
                if (v_scan_ack) begin
                    a_scan_ack <= 1'b1; a_scan_base <= v_scan_base; a_scan_valid <= v_scan_valid;
                    a_scan_desc <= 32'd0;
                end
            end else if (a_d) begin
                a_scan_ack   <= 1'b1;
                a_scan_base  <= img_base(shown_page);
                a_scan_valid <= shown;
                a_scan_desc  <= {15'd0, wall_cell, !tp_active && shown_page[1],
                                 (!tp_active && !shown_page[1]) ? zoom : 2'd0,
                                 tp_active, tp_t, tp_active ? tp_mode : 3'd0};
            end
            if (b_d) begin
                b_scan_ack   <= 1'b1;
                b_scan_base  <= img_base(nxt_page);
                b_scan_valid <= !mode_video && tp_active;
                b_scan_desc  <= 32'd0;
            end
        end
    end
endmodule
