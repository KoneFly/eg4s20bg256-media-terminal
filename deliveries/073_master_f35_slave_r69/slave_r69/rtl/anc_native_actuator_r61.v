`timescale 1ns/1ps
// 12k命令按时间戳延后8个控制组，在原生组内phase1提交完整I2S字。
// 新旧命令交界第一字取均值，等效保持核[0.5,1,1,1,0.5]。
// clear必须与抽取器start同一epoch；frame_id由对应抽取样本携带，不能用完成时刻推算。
`include "r63_output_limits.vh"
module anc_native_actuator_r61 #(parameter integer OUTPUT_LIMIT=`ANC_R63_OUTPUT_LIMIT)(input wire clk,rst_n,clear,native_valid,force_zero,
 input wire submit,input wire [15:0] frame_id,input wire signed [17:0] command,
 output wire signed [15:0] native_word,output wire [15:0] native_group,
 output wire [1:0] native_phase,output reg fault,output reg [3:0] reason);
 reg [15:0] group_id;reg [1:0] phase;reg [3:0] warm_groups;
 reg [7:0] slots_valid;reg [15:0] tags[0:7];reg signed [15:0] words[0:7];
 reg signed [15:0] held;
 reg pending;reg [15:0] due,arrival_group;reg [1:0] arrival_phase;
 reg arrival_valid,arrival_collision,arrival_muted,pending_range;
 reg signed [15:0] pending_word;
 wire [15:0] ahead=due-arrival_group;
 localparam signed [17:0] LIMIT_NATIVE=OUTPUT_LIMIT[17:0];
 wire in_range=command>= -LIMIT_NATIVE&&command<=LIMIT_NATIVE;
 wire in_time=!ahead[15]&&ahead<=16'd8&&(ahead!=0||(arrival_phase==0&&!arrival_valid));
 wire due_valid=slots_valid[group_id[2:0]]&&tags[group_id[2:0]]==group_id;
 wire signed [15:0] next_word=due_valid?words[group_id[2:0]]:16'sd0;
 wire signed [16:0] transition_sum={held[15],held}+{next_word[15],next_word};
 wire signed [17:0] sum_extended={transition_sum[16],transition_sum};
 wire signed [17:0] average=(sum_extended+(sum_extended[17]?18'sd0:18'sd1))>>>1;
 reg signed [15:0] average_q;
 wire collision=arrival_collision||slots_valid[due[2:0]];
 wire invalid_submit=pending&&(!pending_range||!in_time||collision);
 assign native_group=group_id;assign native_phase=phase;
 assign native_word=force_zero||fault||clear||(submit&&!in_range)||invalid_submit?16'sd0:phase==1?average_q:held;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)average_q<=0;
  else if(clear||force_zero||fault)average_q<=0;
  else average_q<=average[15:0];
 end
 integer j;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   group_id<=0;phase<=0;warm_groups<=0;slots_valid<=0;held<=0;fault<=0;reason<=0;pending<=0;due<=0;arrival_group<=0;arrival_phase<=0;arrival_valid<=0;arrival_collision<=0;arrival_muted<=0;pending_range<=0;pending_word<=0;
   for(j=0;j<8;j=j+1)begin tags[j]<=0;words[j]<=0;end
  end else if(clear)begin group_id<=0;phase<=0;warm_groups<=0;slots_valid<=0;held<=0;fault<=0;reason<=0;pending<=0;end
  else begin
   // 一拍接收、一拍校验，截止判定使用到达时刻，保持原队列截止契约。
   pending<=submit;
   if(submit)begin due<=frame_id+16'd8;arrival_group<=group_id;arrival_phase<=phase;arrival_valid<=native_valid;arrival_collision<=slots_valid[frame_id[2:0]];arrival_muted<=force_zero;pending_range<=in_range;pending_word<=command[15:0];end
   // 取消已经排队的旧反相命令；解除静音也不能使它们重新发声。
   if(force_zero)begin held<=0;for(j=0;j<8;j=j+1)words[j]<=0;end
   if(pending&&!fault)begin
    if(!pending_range||!in_time||collision)begin
     fault<=1;reason<=!pending_range?4'd1:!in_time?4'd2:4'd3;
    end else begin slots_valid[due[2:0]]<=1;tags[due[2:0]]<=due;words[due[2:0]]<=force_zero||arrival_muted?16'sd0:pending_word;end
   end
   if(native_valid)begin
    phase<=phase+2'd1;
    if(phase==3)begin group_id<=group_id+16'd1;if(warm_groups<8)warm_groups<=warm_groups+4'd1;end
    if(force_zero||fault)held<=0;
    else if(phase==1)held<=next_word;
    if(phase==1)begin
     if(due_valid)slots_valid[group_id[2:0]]<=0;
     if(!force_zero&&!fault&&warm_groups==8&&!due_valid)begin fault<=1;if(!invalid_submit)reason<=4'd4;end
    end
   end
  end
 end
endmodule
