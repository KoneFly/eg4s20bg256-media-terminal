`timescale 1ns/1ps
// 宽字稳定排序，两个端口同拍读相邻记录，交换整字不复制正文。
module lrc_index_sorter(input wire clk,input wire rst,input wire start,input wire cancel,input wire [8:0] count,
 output wire [7:0] address,output wire [7:0] address_b,output wire write_enable,output wire [53:0] write_data,
 input wire [53:0] read_data,input wire [53:0] read_data_b,output reg done,output reg bad_limit,output wire busy);
 localparam [2:0] IDLE=0,READ=1,WAIT=2,WRITE_A=3,WRITE_B=4,NEXT=5,FINISH=6;
 reg [2:0] state;reg [8:0] pair_index,last_index;reg [53:0] record_a,record_b;reg swapped;
 assign address=state==WRITE_B?pair_index[7:0]+8'd1:pair_index[7:0];
 assign address_b=pair_index[7:0]+8'd1;
 assign write_enable=!cancel && !rst && (state==WRITE_A||state==WRITE_B);
 assign write_data=state==WRITE_A?record_b:record_a;assign busy=state!=IDLE;
 always @(posedge clk or posedge rst)begin
  if(rst)begin state<=IDLE;pair_index<=0;last_index<=0;record_a<=0;record_b<=0;swapped<=0;done<=0;bad_limit<=0;end
  else if(cancel)begin state<=IDLE;done<=0;bad_limit<=0;end
  else begin done<=0;case(state)
   IDLE:if(start)begin bad_limit<=count>256;pair_index<=0;swapped<=0;if(count<=1||count>256)state<=FINISH;else begin last_index<=count-9'd1;state<=READ;end end
   READ:state<=WAIT;
   WAIT:if(read_data[31:0]>read_data_b[31:0])begin record_a<=read_data;record_b<=read_data_b;swapped<=1;state<=WRITE_A;end else state<=NEXT;
   WRITE_A:state<=WRITE_B;WRITE_B:state<=NEXT;
   NEXT:if(pair_index+9'd1>=last_index)begin if(!swapped||last_index<=1)state<=FINISH;else begin last_index<=last_index-9'd1;pair_index<=0;swapped<=0;state<=READ;end end
        else begin pair_index<=pair_index+9'd1;state<=READ;end
   FINISH:begin done<=1;state<=IDLE;end default:state<=IDLE;
  endcase end
 end
endmodule
