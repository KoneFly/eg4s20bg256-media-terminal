// crc7_calc — combinational CRC-7 generator for SD command frames
//
// Polynomial : x^7 + x^3 + 1  (7'h09)
// Init       : 7'h00, MSB-first over the 40 input bits, no reflection
// data_in    : {transmission bit(=1), command index(6), command argument(32)}
// crc7_out   : 7-bit CRC; the frame's last byte is {crc7_out, 1'b1}
//
// Recurrence per input bit:
//   fb  = crc[6] ^ data_in[i]
//   crc = {crc[5:0], 1'b0} ^ (fb ? 7'h09 : 7'h00)
//
// Verified against the SD standard vectors:
//   CMD0  (0x40,0x00000000) -> CRC 7'h4A -> last byte 8'h95
//   CMD8  (0x48,0x000001AA) -> CRC 7'h43 -> last byte 8'h87
//   CMD55 (0x77,0x00000000) -> CRC 7'h32 -> last byte 8'h65
//
// Implemented as a pure combinational function driven by a continuous
// assignment: single-cycle result, no latched state, synthesizable
// (the loop unrolls into a 40-stage XOR network).

`timescale 1ns/1ps

module crc7_calc (
    input  wire [39:0] data_in,
    output wire [6:0]  crc7_out
);

    function [6:0] crc7_f;
        input [39:0] d;
        reg   [6:0] crc;
        integer     i;
        begin
            crc = 7'h00;
            for (i = 39; i >= 0; i = i - 1) begin
                if (crc[6] ^ d[i])
                    crc = {crc[5:0], 1'b0} ^ 7'h09;
                else
                    crc = {crc[5:0], 1'b0};
            end
            crc7_f = crc;
        end
    endfunction

    assign crc7_out = crc7_f(data_in);

endmodule
