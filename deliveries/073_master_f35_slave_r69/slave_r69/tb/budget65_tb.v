module budget65_tb(input wire signed [31:0] next_c,next_s,input wire signed [23:0] weight_c,weight_s,output wire [1:0] old_flags,new_flags);
budget_old65 old(.next_c(next_c),.next_s(next_s),.weight_c(weight_c),.weight_s(weight_s),.c_ok(old_flags[0]),.s_ok(old_flags[1]));
budget_new65 candidate(.next_c(next_c),.next_s(next_s),.weight_c(weight_c),.weight_s(weight_s),.c_ok(new_flags[0]),.s_ok(new_flags[1]));
endmodule
