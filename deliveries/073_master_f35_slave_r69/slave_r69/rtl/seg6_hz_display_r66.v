`timescale 1ns/1ps
// 仅显示真实Hz或----；高两位空白，低有效段/位选与原板保持，每位先消隐一拍。
module seg6_hz_display_r66 #(
 parameter [15:0] SCAN_LAST=16'd49999,parameter REVERSE_DIGITS=1'b0
)(input wire clk,rst_n,display_enable,frequency_valid,input wire [9:0] frequency_hz,
 output reg [7:0] seg_data,output reg [5:0] seg_sel);
 reg [9:0] last_hz;
 reg [21:0] conversion;
 reg [3:0] conversion_count;
 reg converting,bcd_valid;
 reg [11:0] bcd;
 reg [21:0] adjusted;
 integer nibble;
 always @*begin
  adjusted=conversion;
  for(nibble=0;nibble<3;nibble=nibble+1)
   if(conversion[10+nibble*4+:4]>=5)adjusted[10+nibble*4+:4]=conversion[10+nibble*4+:4]+4'd3;
 end
 wire [21:0] shifted={adjusted[20:0],1'b0};
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin last_hz<=1023;conversion<=0;conversion_count<=0;converting<=0;bcd_valid<=0;bcd<=0;end
  else if(converting)begin
   conversion<=shifted;
   if(conversion_count==9)begin bcd<=shifted[21:10];bcd_valid<=1;converting<=0;end
   else conversion_count<=conversion_count+4'd1;
  end else if(frequency_valid&&frequency_hz!=last_hz)begin last_hz<=frequency_hz;conversion<={12'd0,frequency_hz};conversion_count<=0;converting<=1;end
 end
 function [7:0] digit_code;
  input [3:0] d;
  begin case(d)
   0:digit_code=8'hc0;1:digit_code=8'hf9;2:digit_code=8'ha4;3:digit_code=8'hb0;4:digit_code=8'h99;
   5:digit_code=8'h92;6:digit_code=8'h82;7:digit_code=8'hf8;8:digit_code=8'h80;9:digit_code=8'h90;
   default:digit_code=8'hff;
  endcase end
 endfunction
 reg [15:0] scan_count;
 reg [2:0] digit_index;
 reg [11:0] frame_bcd;
 reg frame_valid;
 wire [2:0] physical_digit=REVERSE_DIGITS?3'd5-digit_index:digit_index;
 reg [7:0] selected;
 always @*begin
  selected=8'hff;
  if(!frame_valid)begin if(digit_index<4)selected=8'hbf;end
  else case(digit_index)
   0:selected=digit_code(frame_bcd[3:0]);
   1:if(frame_bcd[11:4]!=0)selected=digit_code(frame_bcd[7:4]);
   2:if(frame_bcd[11:8]!=0)selected=digit_code(frame_bcd[11:8]);
   default:selected=8'hff;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin scan_count<=0;digit_index<=0;frame_bcd<=0;frame_valid<=0;seg_data<=8'hff;seg_sel<=6'b111111;end
  else if(!display_enable)begin scan_count<=0;digit_index<=0;seg_data<=8'hff;seg_sel<=6'b111111;end
  else begin
   if(scan_count==0)begin
    seg_data<=8'hff;seg_sel<=6'b111111;
    if(digit_index==0)begin frame_bcd<=bcd;frame_valid<=frequency_valid&&bcd_valid;end
   end else begin seg_data<=selected;seg_sel<=~(6'b000001<<physical_digit);end
   if(scan_count==SCAN_LAST)begin scan_count<=0;digit_index<=digit_index==5?3'd0:digit_index+3'd1;end
   else scan_count<=scan_count+16'd1;
  end
 end
endmodule
