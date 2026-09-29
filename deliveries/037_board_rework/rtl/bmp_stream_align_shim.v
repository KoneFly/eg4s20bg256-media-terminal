`timescale 1ns / 1ps
// ============================================================================
// bmp_stream_align_shim — Task 005 输入流的 2 字节滞后重对齐
//
// 背景（Task 010 探针实证，勿改 Task 005 源码）:
//   bmp24_to_rgb565_converter 的头部解析在喂入连续文件字节流时, 第14个字
//   (stream_cnt==52) 只用 data_in[31:16] 填 header[52..53], 丢弃 data_in[15:0]
//   （即文件字节 54,55）, 之后像素从下一字的高字节起算。于是按本任务冻结的
//   连续流 {ByteN..ByteN+3} 直接喂会丢失文件字节54,55, 整帧像素相位错2字节。
//
// 本 shim 将输入连续流重排为 Task 005 实际能正确消费的序列:
//   word 0..12  : 直通 (文件字节 0..51)
//   word 13     : {b52,b53,00,00}, 余量 residual<={b54,b55}
//   word k>=14  : {residual, b(4k), b(4k+1)}, residual<={b(4k+2),b(4k+3)}
// 使得 converter 内部字节位置 54+4*(k-14) 与真实文件字节对齐。
//
// 时序: 受控输出。仅当 align_ready=1 时才消费 raw 并输出 align_valid;
//       该语法使 loader 可节流（converter 无 ready 输入）。每次 feed 后
//       wcnt 自增 (stream_start 复位到 0)。
// ============================================================================
module bmp_stream_align_shim (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stream_start,      // 启动重对齐序列 (复位内部字计数)
    // 原始连续流输入 (来自输入 FIFO)
    input  wire [31:0] raw_data,
    input  wire        raw_valid,
    input  wire        align_ready,       // loader 允许本 shim 输出一个字
    // 重对齐后输出 (喂给 Task 005 converter)
    output reg  [31:0] align_data,
    output reg         align_valid
);

    reg  [3:0]  wcnt;              // 原始字序号 0..15 (饱和到 >=14)
    reg  [15:0] residual;          // 上一字低16位 (待滞后注入的高16位)
    reg         started;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt        <= 4'd0;
            residual    <= 16'd0;
            started     <= 1'b0;
            align_data  <= 32'd0;
            align_valid <= 1'b0;
        end else if (stream_start) begin
            wcnt        <= 4'd0;
            residual    <= 16'd0;
            started     <= 1'b1;
            align_data  <= 32'd0;
            align_valid <= 1'b0;
        end else begin
            align_valid <= 1'b0;
            if (started && raw_valid && align_ready) begin
                if (wcnt < 4'd13) begin
                    // words 0..12: pass-through
                    align_data  <= raw_data;
                    align_valid <= 1'b1;
                    wcnt        <= wcnt + 4'd1;
                end else if (wcnt == 4'd13) begin
                    // word 13: take high16 into header, capture low16 as residual
                    align_data  <= {raw_data[31:16], 16'h0000};
                    align_valid <= 1'b1;
                    residual    <= raw_data[15:0];
                    wcnt        <= wcnt + 4'd1;
                end else begin
                    // word >=14: inject previous residual, advance
                    align_data  <= {residual, raw_data[31:16]};
                    align_valid <= 1'b1;
                    residual    <= raw_data[15:0];
                end
            end
        end
    end

endmodule