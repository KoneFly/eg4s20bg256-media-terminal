`timescale 1ns/1ps
// 精确实现sample*256 > baseline*322。
// 除2并移项为(sample-baseline)*128 > baseline*33；借位排除负差，不引入舍入。
module anc_rise_compare_r62 #(parameter integer WIDTH=48)(
 input wire [WIDTH-1:0] sample,baseline,output wire increased);
 wire [WIDTH:0] difference={1'b0,sample}-{1'b0,baseline};
 wire [WIDTH+7:0] left_value={difference,7'd0};
 wire [WIDTH+7:0] right_value=({8'd0,baseline}<<5)+{8'd0,baseline};
 assign increased=!difference[WIDTH]&&left_value>right_value;
endmodule
