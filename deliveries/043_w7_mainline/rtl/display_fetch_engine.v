`timescale 1ns / 1ps
// ============================================================================
// display_fetch_engine — VS 触发的整帧取数引擎 (ctrl 域 50MHz)
//
// 职责: arm 后每次 frame_start_pulse(VS 下降沿经 CDC)从屏幕 (0,0) 到 (W-1,H-1)
// 行主序逐像素给出屏幕坐标 (pos_x, pos_y); 下游(顶层映射器 + 输出寄存一级)在
// pos_take 拍收走当前坐标, 本模块随即推进。帧缓冲按收走顺序逐一返回响应
// {data, en, tag}, 本模块着色后压入异步 FIFO 写侧:
//   en = 1          → 缓存图像像素 rsp_data
//   en = 0, tag[1]  → 焦点边框色
//   en = 0, tag[0]  → 占位色(未就绪槽)
//   其余            → 黑(分隔带 / 画面外 / 单格模式的未就绪槽)
// 请求与响应严格 1:1、按序, 本模块不做重排。
//
// almost_full 节流: pos_valid 要求 !fifo_almost_full; 节流期间坐标不变。已被收走
// 的请求在途至多 3 个(输出寄存一级 + 帧缓冲 2 拍), 其响应必须写入 FIFO 而不丢弃。
// 顶层以 AFULL_MARGIN=36 例化 FIFO, 在途响应写入后水位仍 ≤ 契约水位。
//
// 帧对齐闭环: 每帧恰好压入 W*H 个像素, 帧末 FIFO 排空后 pixel 域清除预取标志,
// 下一次 VS 重新触发预填, 屏上位置 (x,y) 恒等于该帧第 y*W+x 个压入像素。
// 取数在上一帧尚未取完时收到的 frame_start_pulse 被忽略(与旧版同语义)。
// ============================================================================
module display_fetch_engine #(
    parameter integer FRAME_WIDTH  = 640,
    parameter integer FRAME_HEIGHT = 480,
    parameter [15:0]  PAD_COLOR    = 16'h4208,   // RGB565 深灰
    parameter [15:0]  BORDER_COLOR = 16'hFFE0    // RGB565 黄
)(
    input  wire        clk,               // ctrl_clk 50MHz 0°
    input  wire        rst_n,
    input  wire        arm,               // 允许取帧(帧缓冲初始化完成后保持为 1)
    input  wire        frame_start_pulse, // VS下降沿经CDC后的ctrl域单拍脉冲
    // 屏幕坐标(交给映射器)
    output reg  [11:0] pos_x,
    output reg  [11:0] pos_y,
    output wire        pos_valid,
    input  wire        pos_take,          // 下游本拍收走当前坐标
    // 帧缓冲读响应(按序)
    input  wire        rsp_valid,
    input  wire [15:0] rsp_data,
    input  wire        rsp_en,
    input  wire [1:0]  rsp_tag,
    // 异步FIFO写侧
    output wire        fifo_wr_en,
    output wire [15:0] fifo_wr_data,
    input  wire        fifo_almost_full,
    // 状态观测
    output wire        fetching,          // 当前正在取一帧
    // [A1 帧同步 2026-09-27] 实际开始新取数帧的单拍脉冲: 仅当"VS 到达 ∧ arm ∧
    //   无旧帧残留(!running)"成立时置位。不改变现有"running 时忽略新 VS"语义,
    //   仅把该接受事件显式引出, 供 nn_scaler/line_supply 的帧首状态与它严格同步
    //   (修复: FE 欠载跨帧忽略 VS 时,  scaler/line_supply 不应被物理 VS 推进)。
    output wire        fetch_frame_accept
);

    localparam [11:0] X_LAST = FRAME_WIDTH  - 1;
    localparam [11:0] Y_LAST = FRAME_HEIGHT - 1;

    reg running;

    wire at_last = (pos_x == X_LAST) && (pos_y == Y_LAST);

    assign pos_valid    = running && !fifo_almost_full;
    assign fetching     = running;
    // [A1] 新取数帧实际接受的那一拍(与 running 0→1 同拍)
    assign fetch_frame_accept = !running && frame_start_pulse && arm;
    assign fifo_wr_en   = rsp_valid;
    assign fifo_wr_data = rsp_en     ? rsp_data     :
                          rsp_tag[1] ? BORDER_COLOR :
                          rsp_tag[0] ? PAD_COLOR    : 16'h0000;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running <= 1'b0;
            pos_x   <= 12'd0;
            pos_y   <= 12'd0;
        end else if (!running) begin
            if (frame_start_pulse && arm) begin
                running <= 1'b1;
                pos_x   <= 12'd0;
                pos_y   <= 12'd0;
            end
        end else if (pos_take) begin
            if (at_last) begin
                running <= 1'b0;
            end else if (pos_x == X_LAST) begin
                pos_x <= 12'd0;
                pos_y <= pos_y + 12'd1;
            end else begin
                pos_x <= pos_x + 12'd1;
            end
        end
    end

endmodule
