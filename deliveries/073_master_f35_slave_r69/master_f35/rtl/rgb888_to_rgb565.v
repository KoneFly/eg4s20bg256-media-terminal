`timescale 1ns/1ps
// rgb888_to_rgb565：RGB888到RGB565通道截位转换：红蓝保留高5位，绿色保留高6位。
module rgb888_to_rgb565 (
    input  wire [7:0]  blue,
    input  wire [7:0]  green,
    input  wire [7:0]  red,
    output wire [15:0] rgb565
);

    assign rgb565 = {red[7:3], green[7:2], blue[7:3]};

endmodule
