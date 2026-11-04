`timescale 1ns/1ps
// 32x18拆成低16无符号/高16有符号，复用同一18x18流水。
// 每两拍可接一条请求；tag跟随整个乘法，不串上下文。
module r64_anc_mul32x18_r61(input wire clk,rst_n,clear,request,
 input wire signed [31:0] x,input wire signed [17:0] c,input wire [7:0] tag,
 output wire ready,output reg valid,output reg signed [49:0] product,
 output reg [7:0] result_tag,output reg overflow);
 reg issue_hi;reg signed [17:0] high,coeff;reg [7:0] saved_tag;
 reg signed [35:0] low_product;
 wire issue_lo=request&&ready;
 wire signed [17:0] operand=issue_hi?high:$signed({2'b00,x[15:0]});
 wire signed [17:0] factor=issue_hi?coeff:c;
 wire [8:0] token=issue_hi?{1'b1,saved_tag}:{1'b0,tag};
 wire pipe_valid;wire signed [35:0] pipe_product;wire [8:0] pipe_tag;
 wire signed [51:0] high_shift={pipe_product,16'd0};
 wire signed [51:0] low_extended={{16{low_product[35]}},low_product};
 wire signed [51:0] full_product=high_shift+low_extended;
 assign ready=!issue_hi;
 r64_anc_mul18_pipe_r61 m(.clk(clk),.rst_n(rst_n),.clear(clear),.request(issue_hi||issue_lo),.a(operand),.b(factor),.tag(token),.valid(pipe_valid),.product(pipe_product),.result_tag(pipe_tag));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin issue_hi<=0;high<=0;coeff<=0;saved_tag<=0;low_product<=0;valid<=0;product<=0;result_tag<=0;overflow<=0;end
  else if(clear)begin issue_hi<=0;high<=0;coeff<=0;saved_tag<=0;low_product<=0;valid<=0;product<=0;result_tag<=0;overflow<=0;end
  else begin
   valid<=0;
   if(issue_hi)issue_hi<=0;
   else if(issue_lo)begin high<={{2{x[31]}},x[31:16]};coeff<=c;saved_tag<=tag;issue_hi<=1;end
   if(pipe_valid)begin
    if(!pipe_tag[8])low_product<=pipe_product;
    else begin product<=full_product[49:0];result_tag<=pipe_tag[7:0];valid<=1;overflow<=full_product[51:50]!={2{full_product[49]}};end
   end
  end
 end
endmodule
