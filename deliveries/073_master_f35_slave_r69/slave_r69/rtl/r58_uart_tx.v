`timescale 1ns/1ps
// 50MHz/50=1Mbps，8N1；只接收ready拍的数据，不接触板载UART的RX输出线。
module r58_uart_tx #(parameter integer BIT_CLOCKS=50)(
 input wire clk,rst_n,valid,input wire [7:0] data,output wire ready,output reg tx);
 reg busy;reg [7:0] bits;reg [3:0] bit_index;reg [7:0] count;
 localparam integer LAST_CLOCK=BIT_CLOCKS-1;
 localparam [7:0] LAST_CLOCK8=LAST_CLOCK[7:0];
 assign ready=!busy;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;tx<=1;bits<=0;bit_index<=0;count<=0;end
  else if(!busy)begin
   tx<=1;
   if(valid)begin busy<=1;bits<=data;bit_index<=0;count<=LAST_CLOCK8;tx<=0;end
  end else if(count!=0)count<=count-1'b1;
  else begin
   count<=LAST_CLOCK8;
   if(bit_index<8)begin tx<=bits[0];bits<={1'b0,bits[7:1]};bit_index<=bit_index+1'b1;end
   else if(bit_index==8)begin tx<=1;bit_index<=9;end
   else begin busy<=0;tx<=1;end
  end
 end
endmodule
