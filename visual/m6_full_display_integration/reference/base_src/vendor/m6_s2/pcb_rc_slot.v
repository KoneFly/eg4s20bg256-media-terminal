`timescale 1ns/1ps
// ============================================================================
// pcb_rc_slot —— 环上彗星单槽亮度（class4 内联子逻辑）
//   w = {12'b0, pos[19:10], dir[9:8], amp[7:0]}；back = (±(pos-a)) mod 1024
//   v = amp*(90-back)/90（魔数乘 (p*0x2D83)>>20，p<=22950 穷举精确）
// ============================================================================
module pcb_rc_slot (
    input  wire [31:0] w,
    input  wire [9:0]  a,
    output wire [7:0]  v
);
    wire [7:0]  amp  = w[7:0];
    wire [1:0]  dir  = w[9:8];
    wire [9:0]  pos  = w[19:10];
    wire [9:0]  back = dir[1] ? (a - pos) : (pos - a);
    wire        hit  = (amp != 8'd0) && (back < 10'd90);
    wire [6:0]  tail = 7'd90 - back[6:0];                // back<90 ⇒ = 90-back ∈ [1,90]
    wire [15:0] p    = {1'b0, amp} * {1'b0, tail};       // <= 22950
    wire [31:0] pm   = p * 16'h2D83;
    wire [7:0]  vv   = pm[27:20];
    assign v = hit ? vv : 8'd0;
endmodule
