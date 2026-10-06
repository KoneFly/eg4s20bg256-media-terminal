`timescale 1ns/1ps
// 消隐窗按排序时间选行；未到首时间戳/停止/缓存失效时隐藏。
module lrc_viewer(input wire clk,input wire rst,input wire frame_tick,input wire cache_valid,input wire [8:0] count,
 input wire audio_active,input wire [31:0] samples,input wire [53:0] index_data,
 output wire [7:0] index_address,output reg line_valid,output reg [12:0] line_start,output reg [6:0] line_length,output reg [7:0] line_id,output reg selection_commit);
 localparam [1:0] IDLE=0,READ=1,SELECT=2;reg [1:0] state;reg [8:0] record_index;reg [31:0] snapshot;reg candidate_valid;
 assign index_address=record_index[7:0];
 wire unused_padding=|index_data[53:52];
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;record_index<=0;snapshot<=0;candidate_valid<=0;line_valid<=0;line_start<=0;line_length<=0;line_id<=0;selection_commit<=0;end
  else begin
   selection_commit<=0;
   if(!cache_valid || !audio_active)begin state<=IDLE;line_valid<=0;line_length<=0;candidate_valid<=0;end
  else case(state)
   IDLE:if(frame_tick)begin snapshot<=samples;record_index<=0;candidate_valid<=0;if(count==0)begin line_valid<=0;line_length<=0;selection_commit<=1;end else state<=READ;end
   READ:state<=SELECT;
   SELECT:if(index_data[31:0]<=snapshot)begin
      candidate_valid<=1;line_start<=index_data[44:32];line_length<=index_data[51:45];line_id<=record_index[7:0];
      if(record_index+9'd1>=count)begin line_valid<=index_data[51:45]!=0;selection_commit<=1;state<=IDLE;end
      else begin record_index<=record_index+9'd1;state<=READ;end
   end else begin line_valid<=candidate_valid && line_length!=0;selection_commit<=1;state<=IDLE;end
   default:state<=IDLE;
  endcase
  end
 end
endmodule
