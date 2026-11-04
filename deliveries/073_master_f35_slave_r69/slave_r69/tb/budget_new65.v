module budget_new65(input wire signed [31:0] next_c,next_s,input wire signed [23:0] weight_c,weight_s,output wire c_ok,s_ok);
localparam [32:0] COEFF_SUM_LIMIT=33'd4194304;
    wire [23:0] weight_c_abs=weight_c[23] ? -weight_c : weight_c;
    wire [23:0] weight_s_abs=weight_s[23] ? -weight_s : weight_s;
    // |next|+|other|<=L精确等价于|other|<=L且next处于[-gap,+gap]。
    // gap只由旧权值决定，移除乘积支路上的绝对值和预算求和两段进位链。
    wire [24:0] c_gap=25'd4194304-{1'b0,weight_s_abs};
    wire [24:0] s_gap=25'd4194304-{1'b0,weight_c_abs};
    wire signed [31:0] c_upper=$signed({7'd0,c_gap}),s_upper=$signed({7'd0,s_gap});
    wire signed [31:0] c_lower=-c_upper,s_lower=-s_upper;
    wire c_budget_ok=weight_s_abs<=24'd4194304&&next_c>=c_lower&&next_c<=c_upper;
    wire s_budget_ok=weight_c_abs<=24'd4194304&&next_s>=s_lower&&next_s<=s_upper;
assign c_ok=c_budget_ok,s_ok=s_budget_ok;
endmodule
