module leak_new65(input wire clk,input wire signed [31:0] weight,input wire saved_recovery,output wire signed [32:0] result);
 wire signed [42:0] drift_product;
 anc_decay_dsp65 decay_multiplier(.clk(clk),.weight(weight),.scaled(drift_product));
 // floor((bias-product)/2^k) = -upper(product,k)-carry_half_toward_zero。
 // product与weight同号；正半整数不进位、负半整数进位，保持原权值舍入方向。
 wire signed [32:0] weight_extended={weight[31],weight};
 wire signed [32:0] normal_base={{20{drift_product[42]}},drift_product[42:30]};
 wire signed [32:0] backoff_base={{11{weight[31]}},weight[31:10]};
 wire normal_carry=drift_product[29]&&(weight[31]||(|drift_product[28:0]));
 wire backoff_carry=weight[9]&&(weight[31]||(|weight[8:0]));
 wire [32:0] leak_base=saved_recovery?backoff_base:normal_base;
 wire leak_carry=saved_recovery?backoff_carry:normal_carry;
 // 最低位编码borrow-in，取[33:1]精确实现weight-base-carry。
 wire [33:0] leak_encoded={weight_extended,1'b1}+{~leak_base,!leak_carry};
 wire signed [32:0] leaked=leak_encoded[33:1];
assign result=leaked;
endmodule
