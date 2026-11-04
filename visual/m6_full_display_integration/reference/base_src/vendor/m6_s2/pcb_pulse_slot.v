`timescale 1ns/1ps
// ============================================================================
// pcb_pulse_slot —— 走线起音脉冲单槽亮度（class2/3 内联子逻辑）
//   w = {age[31:24], peak[23:16], pos_q4[15:0]}；空槽 peak==0（偏差登记 2）
//   amp = age<3 ? peak*(age+1)/3 : peak（/3 用魔数乘 (n*0xAAAB)>>17，n<=765 穷举精确）
//   v = d==0 ? min(255, amp+40) : (amp*(16-d))>>4，d = (pos>>4)-k ∈ [0,16)
// ============================================================================
module pcb_pulse_slot (
    input  wire [31:0] w,
    input  wire [6:0]  k,
    output wire [7:0]  v
);
    wire [15:0] pos  = w[15:0];
    wire [7:0]  peak = w[23:16];
    wire [7:0]  age  = w[31:24];
    wire        on   = (peak != 8'd0);

    wire signed [12:0] d  = $signed({1'b0, pos[15:4]}) - $signed({6'b00, k});
    wire               hit = on & (d >= 13'sd0) & (d < 13'sd16);

    // n = peak*(age+1)，age+1 ∈ {1,2,3}
    wire [9:0] n = (age == 8'd0) ? {2'b00, peak} :
                   (age == 8'd1) ? {1'b0, peak, 1'b0} :
                                   ({1'b0, peak, 1'b0} + {2'b00, peak});
    wire [25:0] n3  = n * 16'hAAAB;
    wire [7:0]  amp = (age < 8'd3) ? n3[24:17] : peak;

    wire [4:0]  t16 = 5'd16 - {1'b0, d[3:0]};
    wire [11:0] tp  = amp * {3'b000, t16};               // amp*(16-d)
    wire [8:0]  vv  = (d == 13'sd0) ? ({1'b0, amp} + 9'd40) : {1'b0, tp[11:4]};
    assign v = hit ? ((vv > 9'd255) ? 8'd255 : vv[7:0]) : 8'd0;
endmodule

