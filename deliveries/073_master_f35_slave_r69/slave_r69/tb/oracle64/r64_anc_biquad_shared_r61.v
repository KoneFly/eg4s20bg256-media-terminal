// 此文件由extract_shared_sos.py生成：原SOS公式/状态机未改变，只外置乘法接口。
`timescale 1ns/1ps
// 外置状态的共享二阶节引擎：一个引擎可轮流处理多个SOS/context。
// 系数Q16，输入/状态Q12；与R05先差积再舍入的算式对应。
module r64_anc_biquad_shared_r61(input wire clk,rst_n,clear,request,
 input wire signed [31:0] x,z0,z1,
 input wire signed [17:0] b0,b1,b2,a1,a2,input wire [7:0] context_id,
 output wire ready,output reg valid,clipped,overrun,
 output reg signed [31:0] y,new_z0,new_z1,output reg [7:0] result_context,
 output wire mult_request,input wire mult_ready,mult_valid,mult_overflow,
 input wire signed [49:0] mult_product,input wire [7:0] mult_tag,
 output wire signed [31:0] mult_x,output reg signed [17:0] mult_c,
 output wire [7:0] request_tag);
 localparam [2:0] IDLE=0,ISSUE_FIRST=1,WAIT_FIRST=2,ISSUE_REST=3,WAIT_REST=4,FINISH=5;
 reg [2:0] state,op;reg [3:0] seen;
 reg signed [31:0] in_x,in_z0,in_z1,computed_y;
 reg signed [17:0] cb0,cb1,cb2,ca1,ca2;reg [7:0] ctx;
 reg signed [63:0] p1,p2,p3,p4;reg first_clip;
 assign mult_request=rst_n&&!clear&&(state==ISSUE_FIRST||state==ISSUE_REST);
 assign mult_x=op<3?in_x:computed_y;
 assign request_tag={5'd0,op};
 always @*case(op)0:mult_c=cb0;1:mult_c=cb1;2:mult_c=cb2;3:mult_c=ca1;default:mult_c=ca2;endcase
 wire signed [63:0] expanded={{14{mult_product[49]}},mult_product};
 function automatic signed [63:0] round16;input signed [63:0] value;reg signed [64:0] rounded;begin rounded=($signed({value[63],value})+65'sd32768-(value[63]?65'sd1:65'sd0))>>>16;round16=rounded[63:0];end endfunction
 function signed [31:0] sat32;input signed [63:0] value;begin if(value>64'sd2147483647)sat32=32'sh7fffffff;else if(value< -64'sd2147483648)sat32=32'sh80000000;else sat32=value[31:0];end endfunction
 function outside32;input signed [63:0] value;begin outside32=value>64'sd2147483647||value< -64'sd2147483648;end endfunction
 wire signed [63:0] y_full=round16(expanded)+{{32{in_z0[31]}},in_z0};
 wire signed [63:0] z0_full=round16(p1-p3)+{{32{in_z1[31]}},in_z1};
 wire signed [63:0] z1_full=round16(p2-p4);
 assign ready=state==IDLE;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;op<=0;seen<=0;in_x<=0;in_z0<=0;in_z1<=0;computed_y<=0;cb0<=0;cb1<=0;cb2<=0;ca1<=0;ca2<=0;ctx<=0;p1<=0;p2<=0;p3<=0;p4<=0;first_clip<=0;valid<=0;clipped<=0;overrun<=0;y<=0;new_z0<=0;new_z1<=0;result_context<=0;end
  else if(clear)begin state<=IDLE;op<=0;seen<=0;first_clip<=0;valid<=0;clipped<=0;overrun<=0;y<=0;new_z0<=0;new_z1<=0;result_context<=0;end
  else begin
   valid<=0;
   if(request&&!ready)overrun<=1;
   if(mult_valid&&state!=IDLE)begin
    case(mult_tag)
     0:begin computed_y<=sat32(y_full);first_clip<=outside32(y_full)||mult_overflow;op<=1;state<=ISSUE_REST;end
     1:begin p1<=expanded;seen[0]<=1;end
     2:begin p2<=expanded;seen[1]<=1;end
     3:begin p3<=expanded;seen[2]<=1;end
     4:begin p4<=expanded;seen[3]<=1;end
     default:overrun<=1;
    endcase
   end
   case(state)
    IDLE:if(request)begin in_x<=x;in_z0<=z0;in_z1<=z1;cb0<=b0;cb1<=b1;cb2<=b2;ca1<=a1;ca2<=a2;ctx<=context_id;seen<=0;op<=0;first_clip<=0;state<=ISSUE_FIRST;end
    ISSUE_FIRST:if(mult_ready)state<=WAIT_FIRST;
    ISSUE_REST:if(mult_ready)begin if(op==4)state<=WAIT_REST;else op<=op+1'b1;end
    WAIT_REST:if(&seen)state<=FINISH;
    FINISH:begin y<=computed_y;new_z0<=sat32(z0_full);new_z1<=sat32(z1_full);result_context<=ctx;clipped<=first_clip||outside32(z0_full)||outside32(z1_full);valid<=1;state<=IDLE;end
    default:begin end
   endcase
  end
 end
endmodule
