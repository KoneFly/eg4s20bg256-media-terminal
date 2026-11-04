`timescale 1ns/1ps
// 同步1拍双操作数读口 -> 单18x18流水 -> 64bit累加。
// 一颗引擎按作业处理W*r、S/F历史、梯度及窄平方和；存储所有权在上层。
module r64_anc_dot18_engine_r61(input wire clk,rst_n,clear,request,
 input wire [8:0] length,input wire [7:0] context_id,
 output wire ready,read_enable,output wire [7:0] read_index,
 input wire signed [17:0] coefficient,data,
 output reg valid,invalid_length,overrun,output reg signed [63:0] sum,
 output reg [7:0] result_context);
 reg busy,read_valid,read_last;reg [7:0] read_tag,ctx;
 reg [8:0] issued,count;reg signed [63:0] accumulator;
 wire product_valid;wire signed [35:0] product;wire [8:0] product_tag;
 wire signed [63:0] expanded={{28{product[35]}},product};
 assign ready=!busy;assign read_enable=busy&&issued<count;assign read_index=issued[7:0];
 r64_anc_mul18_pipe_r61 m(.clk(clk),.rst_n(rst_n),.clear(clear),.request(read_valid),.a(coefficient),.b(data),.tag({read_last,read_tag}),.valid(product_valid),.product(product),.result_tag(product_tag));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;read_valid<=0;read_last<=0;read_tag<=0;ctx<=0;issued<=0;count<=0;accumulator<=0;valid<=0;invalid_length<=0;overrun<=0;sum<=0;result_context<=0;end
  else if(clear)begin busy<=0;read_valid<=0;read_last<=0;issued<=0;count<=0;accumulator<=0;valid<=0;invalid_length<=0;overrun<=0;sum<=0;result_context<=0;end
  else begin
   valid<=0;read_valid<=read_enable;
   if(request)begin
    if(!ready)overrun<=1;
    else begin
     invalid_length<=length==0||length>256;ctx<=context_id;issued<=0;count<=length;accumulator<=0;
     if(length==0||length>256)begin sum<=0;valid<=1;result_context<=context_id;end
     else busy<=1;
    end
   end
   if(read_enable)begin read_tag<=issued[7:0];read_last<=issued+1'b1==count;issued<=issued+1'b1;end
   if(product_valid&&busy)begin
    accumulator<=accumulator+expanded;
    if(product_tag[8])begin sum<=accumulator+expanded;result_context<=ctx;valid<=1;busy<=0;end
   end
  end
 end
endmodule
