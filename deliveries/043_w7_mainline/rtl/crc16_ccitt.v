// ---------------------------------------------------------------------------
// crc16_ccitt — serial bit-recurrence CRC-16 generator for SD data blocks
//
// Polynomial : x^16 + x^12 + x^5 + 1  (0x1021)
// Init       : 0x0000
// Processing : MSB-first per byte, no input/output reflection
//
// This is the SD Physical Layer Simplified Specification (Appendix B) data
// block CRC16. The parameter set is identical to CRC-16/XMODEM, whose standard
// check value is check("123456789") == 0x31C3.
//
// The 8-stage bit recurrence is unrolled by the synthesizer into a compact
// XOR network; it is intentionally the *bit* recurrence (not the byte lookup
// table) so the RTL path differs structurally from any testbench reference.
//
// Interface:
//   data_valid + data_in  feed exactly one byte per cycle (MSB first inside).
//   crc_clear             synchronously resets the running value to 0x0000.
//   crc_out               mirrors the live running CRC value.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module crc16_ccitt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        data_valid,
    input  wire [7:0]  data_in,
    input  wire        crc_clear,
    output wire [15:0] crc_out
);

    reg [15:0] crc_r;

    // One-byte CRC update: fold the byte into the top 8 bits, then run the
    // 16-bit LFSR for 8 MSB-first bit steps with polynomial 0x1021.
    function [15:0] crc16_next;
        input  [7:0]  din;
        input  [15:0] crc;
        reg    [15:0] c;
        integer       i;
        begin
            c = crc ^ {din, 8'h00};
            for (i = 0; i < 8; i = i + 1) begin
                if (c[15])
                    c = {c[14:0], 1'b0} ^ 16'h1021;
                else
                    c = {c[14:0], 1'b0};
            end
            crc16_next = c;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc_r <= 16'h0000;
        end else if (crc_clear) begin
            crc_r <= 16'h0000;
        end else if (data_valid) begin
            crc_r <= crc16_next(data_in, crc_r);
        end
    end

    assign crc_out = crc_r;

endmodule
