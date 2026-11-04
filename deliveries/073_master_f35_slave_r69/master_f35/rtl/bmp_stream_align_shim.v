`timescale 1ns / 1ps
// bmp_stream_align_shim：重排BMP头尾交界处的字节，使像素流按下游转换器的字边界约定连续输入。
module bmp_stream_align_shim (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        stream_start,      // 启动重对齐序列 (复位内部字计数)
    // 原始连续流输入 (来自输入 FIFO)
    input  wire [31:0] raw_data,
    input  wire        raw_valid,
    input  wire        align_ready,       // loader 允许本 shim 输出一个字
    // 重对齐后输出 (喂给  converter)
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