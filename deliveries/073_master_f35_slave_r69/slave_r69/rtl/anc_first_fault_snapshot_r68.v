`timescale 1ns/1ps
// 触发拍直接冻结完整原子快照；不保留另一整份逐拍预采样副本。
// 只读fault_bits，WAIT_SOURCE(bit31)仅走LIVE；此模块不反馈控制。
module anc_first_fault_snapshot_r68(input wire clk,rst_n,enabled,
 input wire [31:0] fault_bits,input wire [127:0] live_payload,
 output reg [127:0] first_payload,output reg first_valid);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin first_valid<=0;first_payload<=0;end
  else if(!enabled)first_valid<=0;
  else if(!first_valid&&(|fault_bits[30:0]))begin first_payload<=live_payload;first_valid<=1;end
 end
endmodule
