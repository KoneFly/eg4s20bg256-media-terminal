`timescale 1ns/1ps
// 单写/同步单读，优先映射普通9K；clear后扫写零，不依赖RAM上电初值。
// 同地址同时读写不承诺器件碰撞语义：写入生效，读无效并置access_error。
module anc_work_ram_r61 #(parameter integer WIDTH=32,ADDR_BITS=9)(
 input wire clk,rst_n,clear,
 input wire write_request,input wire [ADDR_BITS-1:0] write_address,input wire [WIDTH-1:0] write_data,
 input wire read_request,input wire [ADDR_BITS-1:0] read_address,
 output wire ready,output reg read_valid,output wire [WIDTH-1:0] read_data,
 output reg access_error);
 localparam integer DEPTH=1<<ADDR_BITS;
 (* ram_style="bram" *) reg [WIDTH-1:0] memory[0:DEPTH-1];
 reg initializing;reg [ADDR_BITS-1:0] zero_address;
 reg [WIDTH-1:0] memory_read;
 wire collision=write_request&&read_request&&write_address==read_address;
 assign ready=!initializing;assign read_data=read_valid?memory_read:{WIDTH{1'b0}};
 always @(posedge clk)begin
  memory_read<=memory[read_address];
  if(rst_n&&!clear)begin
   if(initializing)memory[zero_address]<={WIDTH{1'b0}};
   else if(write_request)memory[write_address]<=write_data;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin initializing<=1;zero_address<=0;read_valid<=0;access_error<=0;end
  else if(clear)begin initializing<=1;zero_address<=0;read_valid<=0;access_error<=0;end
  else if(initializing)begin
   read_valid<=0;
   if(&zero_address)initializing<=0;
   else zero_address<=zero_address+1'b1;
  end else begin
   read_valid<=read_request&&!collision;
   if(collision)access_error<=1;
  end
 end
endmodule
