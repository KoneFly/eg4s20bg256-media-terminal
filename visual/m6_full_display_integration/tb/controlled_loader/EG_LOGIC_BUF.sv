`timescale 1ns/1ps
// 对应Anlogic公开eg_logic_gate.v的恒等BUF功能；物理延迟仅由TD验证。
module EG_LOGIC_BUF(input wire i,output wire o);
 assign o=i;
endmodule
