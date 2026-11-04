`timescale 1ns/1ps
// EWMA功率由共享MAC路径供给，归一化用单颗串行除法器，不新增FFT。
module anc_ratio_monitor_r65 #(parameter [47:0] MIN_REFERENCE=48'd4096)(
 input wire clk,rst_n,clear,power_commit,
 input wire [47:0] error_power,reference_power,
 output wire busy,output reg ratio_valid,reference_ok,ratio_overflow,overrun,
 output reg [31:0] ratio_q16,output reg [47:0] reference_snapshot,error_snapshot,
 output wire div_request,output wire [63:0] div_numerator,div_denominator,
 input wire div_busy,div_done,div_zero,input wire [63:0] div_q);
 reg launch,waiting;reg [63:0] numerator,denominator;
 assign div_request=launch;assign div_numerator=numerator;assign div_denominator=denominator;
 assign busy=waiting||launch||div_busy;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin launch<=0;waiting<=0;numerator<=0;denominator<=0;ratio_valid<=0;reference_ok<=0;ratio_overflow<=0;overrun<=0;ratio_q16<=0;reference_snapshot<=0;error_snapshot<=0;end
  else if(clear)begin launch<=0;waiting<=0;numerator<=0;denominator<=0;ratio_valid<=0;reference_ok<=0;ratio_overflow<=0;overrun<=0;ratio_q16<=0;reference_snapshot<=0;error_snapshot<=0;end
  else begin
   launch<=0;ratio_valid<=0;
   if(power_commit)begin
    if(busy)overrun<=1;
    else begin
     reference_snapshot<=reference_power;error_snapshot<=error_power;ratio_overflow<=0;
     if(reference_power<MIN_REFERENCE)begin ratio_q16<=0;reference_ok<=0;ratio_valid<=1;end
     else begin numerator<={error_power,16'd0};denominator<={16'd0,reference_power};reference_ok<=1;launch<=1;waiting<=1;end
    end
   end
   if(waiting&&div_done)begin
    ratio_q16<=|div_q[63:32]?32'hffffffff:div_q[31:0];
    ratio_overflow<=|div_q[63:32]||div_zero;ratio_valid<=1;waiting<=0;
   end
  end
 end
endmodule
