`timescale 1ns/1ps
// μ=67112/2^24。幅值用无符号64bit，避免合法大误差越过signed64上界而翻转梯度。
module anc_gain_numerator_r62(input wire signed [19:0] gradient,
 output wire negative,output wire [63:0] magnitude);
 wire [19:0] absolute_error=gradient[19]?-gradient:gradient;
 wire [32:0] scaled;
 anc_numerator_dsp65 exact_numerator(.absolute_error(absolute_error),.scaled(scaled));
 assign magnitude={scaled,31'd0};
 assign negative=!gradient[19]&&gradient!=0;
endmodule
