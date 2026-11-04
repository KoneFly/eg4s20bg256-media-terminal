`timescale 1ns/1ps
// 旁路快照：AC68 + sequence16 + type8 + length8 + payload16 + CRC16/CCITT。
// 首错快照优先发送，后续20Hz当前状态；UART永不反压ANC。
module anc_uart_snapshot_r68 #(
 parameter integer PERIOD_CLOCKS=2500000,
 parameter integer BIT_CLOCKS=50
)(input wire clk,rst_n,input wire [127:0] live_payload,first_payload,
 input wire first_valid,output wire tx,output wire window_tick);
 reg [21:0] period_count;
 reg periodic_pending,first_sent;
 assign window_tick={10'd0,period_count}==PERIOD_CLOCKS-1;
 reg [1:0] state;
 reg [7:0] index,byte_data;
 reg [15:0] packet_sequence,active_sequence,crc;
 reg [7:0] packet_kind;
 reg [127:0] payload;
 reg byte_valid;wire byte_ready;
 r58_uart_tx #(.BIT_CLOCKS(BIT_CLOCKS)) transmitter(.clk(clk),.rst_n(rst_n),.valid(byte_valid),.data(byte_data),.ready(byte_ready),.tx(tx));
 function [15:0] crc_byte;
  input [15:0] initial_crc;input [7:0] value;
  reg [15:0] c;integer j;
  begin c=initial_crc^{value,8'd0};for(j=0;j<8;j=j+1)c=c[15]?{c[14:0],1'b0}^16'h1021:{c[14:0],1'b0};crc_byte=c;end
 endfunction
 wire [15:0] next_crc=crc_byte(crc,byte_data);
 wire [4:0] payload_index=index[4:0]-5'd8;
 wire [255:0] packet_storage={128'd0,payload};
 reg [7:0] selected;
 always @*begin
  case(index)
   0:selected=8'h41;1:selected=8'h43;2:selected=8'h36;3:selected=8'h38;
   4:selected=active_sequence[7:0];5:selected=active_sequence[15:8];
   6:selected=packet_kind;7:selected=8'd16;
   24:selected=crc[7:0];25:selected=crc[15:8];
   default:selected=packet_storage[{payload_index,3'd0}+:8];
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin period_count<=0;periodic_pending<=1;first_sent<=0;state<=0;index<=0;packet_sequence<=0;active_sequence<=0;crc<=16'hffff;packet_kind<=0;payload<=0;byte_data<=0;byte_valid<=0;end
  else begin
   byte_valid<=0;
   if(window_tick)begin period_count<=0;periodic_pending<=1;end else period_count<=period_count+1'b1;
   if(!first_valid)first_sent<=0;
   case(state)
    0:if((first_valid&&!first_sent)||periodic_pending)begin
     if(first_valid&&(!first_sent||(periodic_pending&&packet_kind==0)))begin payload<=first_payload;packet_kind<=1;first_sent<=1;end
     else begin payload<=live_payload;packet_kind<=0;periodic_pending<=0;end
     active_sequence<=packet_sequence;packet_sequence<=packet_sequence+1'b1;crc<=16'hffff;index<=0;state<=1;
    end
    1:if(byte_ready)begin byte_data<=selected;byte_valid<=1;state<=2;end
    2:state<=3;
    3:if(byte_ready)begin
     if(index<24)crc<=next_crc;
     if(index==25)state<=0;else begin index<=index+1'b1;state<=1;end
    end
   endcase
  end
 end
endmodule
