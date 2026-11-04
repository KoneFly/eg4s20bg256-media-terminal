`timescale 1ns/1ps
// 两颗既签18x18同拍锁低16无符号/高16有符号积；52位fabric合成。
// E+1寄存完整和，E+2提交，ready仅低一拍、II2及tag/overflow合同不变。
module anc_mul32x18_r61(input wire clk,rst_n,clear,request,
 input wire signed [31:0] x,input wire signed [17:0] c,input wire [7:0] tag,
 output wire ready,output reg valid,output reg signed [49:0] product,
 output reg [7:0] result_tag,output reg overflow);
 reg issue_hi,sum_valid;reg signed [51:0] full_saved;reg [7:0] sum_tag;
 wire issue_lo=request&&ready;
 wire low_valid,high_valid;wire signed [35:0] low_product,high_product;
 wire [8:0] low_tag,unused_high_tag;
 wire signed [51:0] high_shift={high_product,16'd0};
 wire signed [51:0] low_extended={{16{low_product[35]}},low_product};
 wire signed [51:0] full_product=high_shift+low_extended;
 assign ready=!issue_hi;
 anc_mul18_pipe_r61 m_low(.clk(clk),.rst_n(rst_n),.clear(clear),.request(issue_lo),
  .a($signed({2'b00,x[15:0]})),.b(c),.tag({1'b0,tag}),
  .valid(low_valid),.product(low_product),.result_tag(low_tag));
 anc_mul18_pipe_r61 m_high(.clk(clk),.rst_n(rst_n),.clear(clear),.request(issue_lo),
  .a({{2{x[31]}},x[31:16]}),.b(c),.tag({1'b0,tag}),
  .valid(high_valid),.product(high_product),.result_tag(unused_high_tag));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin issue_hi<=0;sum_valid<=0;full_saved<=0;sum_tag<=0;valid<=0;product<=0;result_tag<=0;overflow<=0;end
  else if(clear)begin issue_hi<=0;sum_valid<=0;full_saved<=0;sum_tag<=0;valid<=0;product<=0;result_tag<=0;overflow<=0;end
  else begin
   valid<=0;
   if(issue_hi)issue_hi<=0;else if(issue_lo)issue_hi<=1;
   sum_valid<=low_valid&&high_valid;
   if(low_valid&&high_valid)begin full_saved<=full_product;sum_tag<=low_tag[7:0];end
   if(sum_valid)begin product<=full_saved[49:0];result_tag<=sum_tag;valid<=1;overflow<=full_saved[51:50]!={2{full_saved[49]}};end
  end
 end
endmodule
