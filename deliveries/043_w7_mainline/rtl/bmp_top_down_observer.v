`timescale 1ns / 1ps
// ============================================================================
// bmp_top_down_observer — 轻量 BMP 头部高度符号观测器
//
// 背景（START_PROMPT 约束3）: Task 005 当前接口未导出 image_top_down。
// 本模块从同一条输入字节流**并行**观测 BMP header 的 biHeight 符号位,
// 仅产生 top_down 标志, 绝不修改 Task 005 源码。
//
// BMP header 布局 (小端): biHeight 位于字节偏移 22 起共 4 字节,
//   符号位 = 字节25 的 bit7 (= biHeight[31])。
// 数据流格式 {ByteN,ByteN+1,ByteN+2,ByteN+3} (ByteN 在高位):
//   word5 = 字节20..23  (含 biHeight 低字节 22,23)
//   word6 = 字节24..27  (含 biHeight 高字节 24,25)
//   符号位 = word6 的位 [23] (字节25)
//
// 时序: 在 stream_start 后的第 6 个(0基)输入字 (word6) 采样 data_in[23],
//       锁存为 top_down。错误/非BMP 不影响（由 converter 报 format_error）。
// ============================================================================
module bmp_top_down_observer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stream_start,      // 起始一张 BMP (复位计数)
    input  wire [31:0] data_in,           // loader 实际接受的输入字
    input  wire        accept,            // data_valid && stream_ready (真实消费)
    output reg         top_down           // 1 = 负高度(top-down), 0 = 正高度
);

    reg [3:0] wcnt;
    reg       cap;                        // 已捕获符号

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wcnt     <= 4'd0;
            cap      <= 1'b0;
            top_down <= 1'b0;
        end else if (stream_start) begin
            wcnt     <= 4'd0;
            cap      <= 1'b0;
            top_down <= 1'b0;
        end else begin
            if (accept && !cap) begin
                if (wcnt == 4'd6) begin
                    top_down <= data_in[23];   // 字节25 bit7 = biHeight[31]
                    cap      <= 1'b1;
                end
                wcnt <= wcnt + 4'd1;
            end
        end
    end

endmodule