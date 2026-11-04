module leak_old65(input wire clk,input wire signed [31:0] weight,input wire saved_recovery,output wire signed [32:0] result);
 wire signed [42:0] drift_product;
 anc_decay_dsp65 decay_multiplier(.clk(clk),.weight(weight),.scaled(drift_product));
 // w+floor((bias-w*1074)/2^30)，bias按原权值符号选择，保留半整数远离零。
 wire signed [42:0] leakage_numerator=(weight[31]?43'sd536870911:43'sd536870912)-drift_product;
 wire signed [32:0] leakage_delta={{20{leakage_numerator[42]}},leakage_numerator[42:30]};
 wire signed [32:0] weight_extended={weight[31],weight};
 wire signed [32:0] backoff_numerator=(weight[31]?33'sd511:33'sd512)-weight_extended;
 wire signed [32:0] backoff_delta=backoff_numerator>>>10;
 wire signed [32:0] leaked=weight_extended+(saved_recovery?backoff_delta:leakage_delta);
assign result=leaked;
endmodule
