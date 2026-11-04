`timescale 1ns/1ps
// 同64迭代/同ready,busy,done时刻；q/r只在done有效，由现有两个私有client消费。
// dividend与商共用寄存器，带借位减法同时产生比较结果，不另做比较器。
module anc_divider_compact_r65(input wire clk,rst_n,clear,request,
 input wire [63:0] numerator,denominator,
 output wire ready,output reg busy,done,divide_by_zero,
 output wire [63:0] quotient,remainder);
 reg [63:0] work,divisor,r;reg [5:0] count;
 wire [64:0] shifted={r,work[63]};
 wire [65:0] difference={1'b0,shifted}-{2'b00,divisor};
 wire take=!difference[65];
 wire [63:0] next_r=take?difference[63:0]:shifted[63:0];
 wire [63:0] next_work={work[62:0],take};
 assign ready=!busy;assign quotient=work;assign remainder=r;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;done<=0;divide_by_zero<=0;work<=0;divisor<=0;r<=0;count<=0;end
  else if(clear)begin busy<=0;done<=0;divide_by_zero<=0;work<=0;divisor<=0;r<=0;count<=0;end
  else begin
   done<=0;
   if(request&&!busy)begin
    divide_by_zero<=denominator==0;
    if(denominator==0)begin work<=64'hffffffffffffffff;r<=numerator;done<=1;end
    else begin busy<=1;work<=numerator;divisor<=denominator;r<=0;count<=0;end
   end else if(busy)begin
    work<=next_work;r<=next_r;
    if(count==63)begin busy<=0;done<=1;end else count<=count+6'd1;
   end
  end
 end
endmodule
