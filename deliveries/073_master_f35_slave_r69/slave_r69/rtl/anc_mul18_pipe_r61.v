`timescale 1ns/1ps
// 一拍流水乘法；valid/tag可清空，数据寄存器不需要复位值。
module anc_mul18_pipe_r61(input wire clk,rst_n,clear,request,
 input wire signed [17:0] a,b,input wire [8:0] tag,
 output reg valid,output reg signed [35:0] product,output reg [8:0] result_tag);
 always @(posedge clk)product<=a*b;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin valid<=0;result_tag<=0;end
  else if(clear)begin valid<=0;result_tag<=0;end
  else begin valid<=request;if(request)result_tag<=tag;end
 end
endmodule
