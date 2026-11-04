`timescale 1ns/1ps
// Q28权值、Q24增益、Q4梯度；同步RAM读一拍，逐项原位提交。
// 乘法端口外置，供SOS/更新调度器复用；clear取消未完成工作，不能继续旧epoch。
// 盒约束±0.25保证256项输出权值L2<=4；这是比旧球投影更严格的约束。
module r64_anc_weight_update_r61(
 input wire clk,rst_n,clear,request,input wire [8:0] length,
 input wire signed [31:0] gain,input wire [7:0] context_id,input wire recovery,
 output wire ready,output reg valid,output reg [7:0] result_context,
 output reg overrun,output reg arithmetic_fault,
 output reg [8:0] box_events,output reg [8:0] overflow_events,
 output wire memory_read,output wire [7:0] read_address,
 input wire memory_valid,input wire signed [31:0] weight,
 input wire signed [17:0] gradient,
 output wire memory_write,output wire [7:0] write_address,
 output wire signed [31:0] write_weight,
 output wire multiply_request,input wire multiply_ready,
 output wire signed [31:0] multiply_x,output wire signed [17:0] multiply_c,
 output wire [7:0] multiply_tag,input wire multiply_valid,
 input wire signed [49:0] multiply_product,input wire [7:0] multiply_result_tag,
 input wire multiply_overflow);
 localparam [1:0] IDLE=0,READ=1,ISSUE=2,PRODUCT=3;
 localparam signed [34:0] BOX=35'sd67108864;
 reg [1:0] state;reg [8:0] count;reg [7:0] index,saved_context;
 reg signed [31:0] saved_gain,leaked_weight;reg signed [17:0] saved_gradient;reg have_memory,saved_recovery;
 wire last_item={1'b0,index}+9'd1==count;
 wire accepted_product=state==PRODUCT&&multiply_valid;
 wire product_ok=multiply_result_tag==index&&!multiply_overflow;
 wire signed [42:0] weight_wide={{11{weight[31]}},weight};
 wire signed [42:0] drift_a=(weight_wide<<<10)+(weight_wide<<<5);
 wire signed [42:0] drift_b=(weight_wide<<<4)+(weight_wide<<<1);
 // w+floor((bias-w*1074)/2^30)，bias按原权值符号选择，保留半整数远离零。
 wire signed [42:0] leakage_numerator=(weight[31]?43'sd536870911:43'sd536870912)-(drift_a+drift_b);
 wire signed [32:0] leakage_delta={{20{leakage_numerator[42]}},leakage_numerator[42:30]};
 wire signed [32:0] weight_extended={weight[31],weight};
 wire signed [32:0] backoff_numerator=(weight[31]?33'sd511:33'sd512)-weight_extended;
 wire signed [32:0] backoff_delta=backoff_numerator>>>10;
 wire signed [32:0] leaked=weight_extended+(saved_recovery?backoff_delta:leakage_delta);
 wire signed [50:0] product_extended={multiply_product[49],multiply_product};
 wire signed [50:0] rounded_product=product_extended+(product_extended[50]?51'sd8388607:51'sd8388608);
 wire signed [34:0] rounded_update={{8{rounded_product[50]}},rounded_product[50:24]};
 wire signed [34:0] candidate={{3{leaked_weight[31]}},leaked_weight}+rounded_update;
 wire candidate_overflow=candidate>35'sd2147483647||candidate< -35'sd2147483648;
 wire candidate_box=candidate>BOX||candidate< -BOX;
 assign ready=state==IDLE;
 assign memory_read=rst_n&&!clear&&(state==READ||(accepted_product&&product_ok&&!last_item));
 assign read_address=state==READ?index:index+8'd1;
 assign multiply_request=rst_n&&!clear&&state==ISSUE&&(have_memory||memory_valid);
 assign multiply_x=saved_gain;assign multiply_c=have_memory?saved_gradient:gradient;assign multiply_tag=index;
 assign memory_write=rst_n&&!clear&&accepted_product&&product_ok;
 assign write_address=index;
 assign write_weight=candidate>BOX?32'sd67108864:candidate< -BOX?-32'sd67108864:candidate[31:0];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;count<=0;index<=0;saved_context<=0;saved_gain<=0;leaked_weight<=0;have_memory<=0;saved_gradient<=0;saved_recovery<=0;
   valid<=0;result_context<=0;overrun<=0;arithmetic_fault<=0;box_events<=0;overflow_events<=0;end
  else if(clear)begin state<=IDLE;count<=0;index<=0;saved_context<=0;saved_gain<=0;leaked_weight<=0;have_memory<=0;saved_gradient<=0;saved_recovery<=0;
   valid<=0;result_context<=0;overrun<=0;arithmetic_fault<=0;box_events<=0;overflow_events<=0;end
  else begin
   valid<=0;
   if(request&&state!=IDLE)overrun<=1;
   case(state)
    IDLE:if(request)begin
     box_events<=0;overflow_events<=0;arithmetic_fault<=0;
     if(length==0||length>256)begin arithmetic_fault<=1;valid<=1;result_context<=context_id;end
     else begin count<=length;index<=0;saved_context<=context_id;saved_gain<=gain;saved_recovery<=recovery;have_memory<=0;state<=READ;end
    end
    READ:state<=ISSUE;
    ISSUE:begin
     if(memory_valid&&!have_memory)begin leaked_weight<=leaked[31:0];saved_gradient<=gradient;have_memory<=1;end
     if(multiply_request&&multiply_ready)state<=PRODUCT;
    end
    PRODUCT:if(multiply_valid)begin
     if(!product_ok)begin arithmetic_fault<=1;valid<=1;result_context<=saved_context;state<=IDLE;end
     else begin
      if(candidate_box)box_events<=box_events+9'd1;
      if(candidate_overflow)begin overflow_events<=overflow_events+9'd1;arithmetic_fault<=1;end
      if(last_item)begin valid<=1;result_context<=saved_context;state<=IDLE;end
      else begin index<=index+8'd1;have_memory<=0;state<=ISSUE;end
     end
    end
   endcase
  end
 end
endmodule
