`timescale 1ns/1ps
// 配合既有II2/E+2真实乘法器：x最后使用后才复用给p1；所有外部输出仍在FINISH提交。
module anc_biquad_shared_r61(input wire clk,rst_n,clear,request,
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
 reg signed [49:0] work_a,work_b;
 reg signed [31:0] work_y,work_z;
 reg signed [17:0] cb0,cb1,cb2,ca1,ca2;reg [7:0] ctx;
 reg first_clip,z0_clip,z1_clip;
 assign mult_request=rst_n&&!clear&&(state==ISSUE_FIRST||state==ISSUE_REST);
 assign mult_x=op<3?work_a[31:0]:work_y;
 assign request_tag={5'd0,op};
 always @*case(op)0:mult_c=cb0;1:mult_c=cb1;2:mult_c=cb2;3:mult_c=ca1;default:mult_c=ca2;endcase
 wire signed [49:0] selected_product=mult_tag==3?work_a:work_b;
 wire signed [50:0] difference=$signed({selected_product[49],selected_product})-$signed({mult_product[49],mult_product});
 wire signed [50:0] round_value=mult_tag==0?$signed({mult_product[49],mult_product}):difference;
 wire carry=round_value[15]&&(!round_value[50]||(|round_value[14:0]));
 wire signed [35:0] base={round_value[50],round_value[50:16]};
 wire signed [35:0] state_add=mult_tag==0?{{4{work_y[31]}},work_y}:mult_tag==3?{{4{work_z[31]}},work_z}:36'sd0;
 wire [36:0] encoded={base,1'b1}+{state_add,carry};
 wire signed [35:0] result_full=encoded[36:1];
 wire outside=result_full[35:31]!={5{result_full[31]}};
 wire signed [31:0] result_word=outside?(result_full[35]?32'sh80000000:32'sh7fffffff):result_full[31:0];
 assign ready=state==IDLE;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;op<=0;seen<=0;work_a<=0;work_b<=0;work_y<=0;work_z<=0;cb0<=0;cb1<=0;cb2<=0;ca1<=0;ca2<=0;ctx<=0;first_clip<=0;z0_clip<=0;z1_clip<=0;valid<=0;clipped<=0;overrun<=0;y<=0;new_z0<=0;new_z1<=0;result_context<=0;end
  else if(clear)begin state<=IDLE;op<=0;seen<=0;first_clip<=0;z0_clip<=0;z1_clip<=0;valid<=0;clipped<=0;overrun<=0;y<=0;new_z0<=0;new_z1<=0;result_context<=0;end
  else begin
   valid<=0;
   if(request&&!ready)overrun<=1;
   if(mult_valid&&state!=IDLE)begin
    case(mult_tag)
     0:begin work_y<=result_word;first_clip<=outside||mult_overflow;op<=1;state<=ISSUE_REST;end
     1:begin if(!(op>=3||(state==ISSUE_REST&&op==2&&mult_ready)))overrun<=1;work_a<=mult_product;seen[0]<=1;end
     2:begin work_b<=mult_product;seen[1]<=1;end
     3:begin if(!seen[0])overrun<=1;work_z<=result_word;z0_clip<=outside;seen[2]<=1;end
     4:begin if(!seen[1])overrun<=1;work_a<={{18{result_word[31]}},result_word};z1_clip<=outside;seen[3]<=1;end
     default:overrun<=1;
    endcase
   end
   case(state)
    IDLE:if(request)begin work_a<={{18{x[31]}},x};work_y<=z0;work_z<=z1;cb0<=b0;cb1<=b1;cb2<=b2;ca1<=a1;ca2<=a2;ctx<=context_id;seen<=0;op<=0;first_clip<=0;z0_clip<=0;z1_clip<=0;state<=ISSUE_FIRST;end
    ISSUE_FIRST:if(mult_ready)state<=WAIT_FIRST;
    ISSUE_REST:if(mult_ready)begin if(op==4)state<=WAIT_REST;else op<=op+3'd1;end
    WAIT_REST:if(&seen)state<=FINISH;
    FINISH:begin y<=work_y;new_z0<=work_z;new_z1<=work_a[31:0];result_context<=ctx;clipped<=first_clip||z0_clip||z1_clip;valid<=1;state<=IDLE;end
    default:begin end
   endcase
  end
 end
endmodule
