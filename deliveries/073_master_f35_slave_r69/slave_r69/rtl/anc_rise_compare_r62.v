`timescale 1ns/1ps
// sample*256 > baseline*322，精确等价整数sample > floor(161*baseline/128)。
// 161=5*32+1；只在baseline支路作两级移位加法，sample直接进入最终比较。
module anc_rise_compare_r62 #(parameter integer WIDTH=48)(
 input wire [WIDTH-1:0] sample,baseline,output wire increased);
 wire [WIDTH+2:0] five=({3'b0,baseline}<<2)+{3'b0,baseline};
 wire [WIDTH+7:0] scaled={five,5'b0}+{8'b0,baseline};
 assign increased={1'b0,sample}>scaled[WIDTH+7:7];
endmodule
