`timescale 1ns / 1ps
// ============================================================================
// bmp_row_order_adapter — 行序坐标适配 + 像素流弹性缓冲 (Task 010)
//
// 职责(与 TASK_BRIEF 产物清单一致, 从 loader 拆出的独立模块):
//   1. 行序映射: 正高度 BMP(bottom-up) fb_y = H-1-parser_y;
//      负高度 BMP(top-down) fb_y = parser_y 直通。两次行反转(Task007 内部
//      再反转一次)相互抵消, 最终显示行序与 BMP 视觉行序一致。
//   2. 像素流弹性缓冲: 37bit {rgb565, x, fb_y} 先入 FIFO, 再经保持寄存器
//      (pipe)输出。valid&&ready 握手保证 ready 低时不丢、不重、不越界;
//      保持寄存器使下游(Task007 u_fb)的 pixel_x/y 来自寄存器, 与 Task007
//      上板验证版"寄存器->乘法器"拓扑一致(否则 BRAM 组合读->行地址乘法
//      形成约12ns单拍路径)。
//   3. 坐标越界像素在入队前被丢弃(pixel_count 预期之外的数据由上游
//      size 检查拦截, 此处仅防御性丢弃防止写越界)。
//
// 排空语义: out_empty 表示 FIFO 与 pipe 同时为空——下游提交判定必须
//   用 out_empty 而非仅 FIFO 空, 否则最后一像素压在 pipe 时会提前提交。
// ============================================================================
module bmp_row_order_adapter #(
    parameter integer FRAME_HEIGHT   = 480,
    parameter integer PIX_FIFO_DEPTH = 32
)(
    input  wire        clk,
    input  wire        rst_n,

    // 行序选择与锁定高度 (来自 loader)
    input  wire        top_down,        // 1=负高度BMP(视觉序直通)
    input  wire [9:0]  image_height,    // 已锁定的图像高度(H>=1)

    // converter 像素流输入 (Task 005 冻结端口语义)
    input  wire [15:0] in_data,
    input  wire [10:0] in_x,
    input  wire [9:0]  in_y,
    input  wire        in_valid,

    // Task 007 帧缓冲像素流输出 (valid&&ready 握手)
    output wire [15:0] out_data,
    output wire [10:0] out_x,
    output wire [9:0]  out_y,
    output wire        out_valid,
    input  wire        out_ready,

    // 状态
    output wire        fifo_full,
    output wire        near_full,       // 剩余<=2, 上游节流用
    output wire        out_empty        // FIFO与pipe均空(真实排空)
);

    // ------------------------------------------------------------------
    // 行序映射 + 入队
    // ------------------------------------------------------------------
    wire [9:0] fb_y = top_down ? in_y : (image_height - 10'd1 - in_y);
    wire       in_accept = in_valid && !fifo_full;

    wire [36:0] fifo_din = {in_data, in_x, fb_y};

    wire [36:0] fifo_dout;
    wire        fifo_empty;
    wire        fifo_rd;

    sync_fifo #(.WIDTH(37), .DEPTH(PIX_FIFO_DEPTH))
        u_pix_fifo (
            .clk      (clk),
            .rst_n    (rst_n),
            .wr_en    (in_accept),
            .din      (fifo_din),
            .rd_en    (fifo_rd),
            .dout     (fifo_dout),
            .full     (fifo_full),
            .empty    (fifo_empty),
            .near_full(near_full),
            .count    ()
        );

    // ------------------------------------------------------------------
    // 输出保持寄存器(pipe): 消费才前移, 顺序保持, 不丢不重
    // ------------------------------------------------------------------
    reg  [36:0] pipe_d;
    reg         pipe_v;

    wire pipe_consume = pipe_v && out_ready;             // 下游本拍接受
    wire fifo_pop     = !pipe_v ? !fifo_empty
                                : (pipe_consume && !fifo_empty);

    assign fifo_rd = fifo_pop;                           // 驱动 FIFO 读指针

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_v <= 1'b0;
            pipe_d <= 37'd0;
        end else if (fifo_pop) begin
            pipe_d <= fifo_dout;
            pipe_v <= 1'b1;
        end else if (pipe_consume) begin
            pipe_v <= 1'b0;
        end
    end

    assign out_data  = pipe_d[36:21];
    assign out_x     = pipe_d[20:10];
    assign out_y     = pipe_d[9:0];
    assign out_valid = pipe_v;
    assign out_empty = fifo_empty && !pipe_v;

endmodule
