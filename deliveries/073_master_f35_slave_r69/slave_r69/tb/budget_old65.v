module budget_old65(input wire signed [31:0] next_c,next_s,input wire signed [23:0] weight_c,weight_s,output wire c_ok,s_ok);
localparam [32:0] COEFF_SUM_LIMIT=33'd4194304;
    wire [31:0] next_c_abs=next_c[31] ? -next_c : next_c;
    wire [31:0] next_s_abs=next_s[31] ? -next_s : next_s;
    wire [23:0] weight_c_abs=weight_c[23] ? -weight_c : weight_c;
    wire [23:0] weight_s_abs=weight_s[23] ? -weight_s : weight_s;
    wire c_budget_ok=({1'b0,next_c_abs}+{9'd0,weight_s_abs})<=COEFF_SUM_LIMIT;
    wire s_budget_ok=({1'b0,next_s_abs}+{9'd0,weight_c_abs})<=COEFF_SUM_LIMIT;
assign c_ok=c_budget_ok,s_ok=s_budget_ok;
endmodule
