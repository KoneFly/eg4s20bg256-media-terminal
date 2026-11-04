`timescale 1ns / 1ps
// ============================================================================
// SD 协议串行 CRC: CRC7(x^7+x^3+1) 与 CRC16-CCITT(x^16+x^12+x^5+1)
// MSB 先入, 初值 0, 无最终异或。每个 en 拍移入 1 bit。
// 4-bit 数据模式每根 DAT 线各用一个 sd_crc16 实例。
// ============================================================================
module sd_crc7 (
    input  wire       clk,
    input  wire       clr,
    input  wire       en,
    input  wire       bit_in,
    output reg  [6:0] crc
);
    wire fb = crc[6] ^ bit_in;
    always @(posedge clk)
        if (clr)     crc <= 7'd0;
        else if (en) crc <= {crc[5:3], crc[2] ^ fb, crc[1:0], fb};
endmodule

module sd_crc16 (
    input  wire        clk,
    input  wire        clr,
    input  wire        en,
    input  wire        bit_in,
    output reg  [15:0] crc
);
    wire fb = crc[15] ^ bit_in;
    always @(posedge clk)
        if (clr)     crc <= 16'd0;
        else if (en) crc <= {crc[14:12], crc[11] ^ fb, crc[10:5], crc[4] ^ fb, crc[3:0], fb};
endmodule
