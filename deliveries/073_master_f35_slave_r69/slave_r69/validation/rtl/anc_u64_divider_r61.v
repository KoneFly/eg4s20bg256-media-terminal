`timescale 1ns/1ps
// 无DSP恢复除法：64个迭代拍；clear同步取消在途请求。
module anc_u64_divider_r61(input wire clk,rst_n,clear,request,
 input wire [63:0] numerator,denominator,
 output wire ready,output reg busy,done,divide_by_zero,
 output reg [63:0] quotient,remainder);
 reg [63:0] dividend,divisor,q;
 reg [64:0] r;reg [6:0] count;
 wire [64:0] shifted={r[63:0],dividend[63]};
 wire subtract=shifted>={1'b0,divisor};
 wire [64:0] next_r=subtract?shifted-{1'b0,divisor}:shifted;
 wire [63:0] next_q={q[62:0],subtract};
 assign ready=!busy;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;done<=0;divide_by_zero<=0;quotient<=0;remainder<=0;dividend<=0;divisor<=0;q<=0;r<=0;count<=0;end
  else if(clear)begin busy<=0;done<=0;divide_by_zero<=0;quotient<=0;remainder<=0;dividend<=0;divisor<=0;q<=0;r<=0;count<=0;end
  else begin
   done<=0;
   if(request&&!busy)begin
    divide_by_zero<=denominator==0;
    if(denominator==0)begin quotient<=64'hffffffffffffffff;remainder<=numerator;done<=1;end
    else begin busy<=1;dividend<=numerator;divisor<=denominator;q<=0;r<=0;count<=0;end
   end else if(busy)begin
    dividend<={dividend[62:0],1'b0};q<=next_q;r<=next_r;
    if(count==63)begin quotient<=next_q;remainder<=next_r[63:0];busy<=0;done<=1;end
    else count<=count+1'b1;
   end
  end
 end
endmodule
