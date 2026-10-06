// ---------------------------------------------------------------------------
// rgb888_to_rgb565 — RGB888(BGR888) -> RGB565 color space converter (Task 005)
//
// Pure combinational truncation converter:
//
//     rgb565[15:11] = red[7:3]    (5-bit red,   low 3 bits discarded)
//     rgb565[10:5]  = green[7:2]  (6-bit green, low 2 bits discarded)
//     rgb565[4:0]   = blue[7:3]   (5-bit blue,  low 3 bits discarded)
//
// Port names are color-component names (red/green/blue), so the caller may
// feed BMP storage order (B,G,R) directly: blue = 1st byte, green = 2nd byte,
// red = 3rd byte of each BMP pixel.
//
// Truncation (no rounding) is mandated by INTERFACE_SPEC.md: simplest pure
// combinational logic, worst-case per-channel error is bounded by the
// discarded LSBs and visually negligible.
// ---------------------------------------------------------------------------

`timescale 1ns/1ps

module rgb888_to_rgb565 (
    input  wire [7:0]  blue,
    input  wire [7:0]  green,
    input  wire [7:0]  red,
    output wire [15:0] rgb565
);

    assign rgb565 = {red[7:3], green[7:2], blue[7:3]};

endmodule
