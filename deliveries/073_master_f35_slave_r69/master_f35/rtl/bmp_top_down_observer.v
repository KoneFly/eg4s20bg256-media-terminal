`timescale 1ns / 1ps
// bmp_top_down_observer：观察BMP高度字段符号并输出行序标志，供显示页写地址选择使用。
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