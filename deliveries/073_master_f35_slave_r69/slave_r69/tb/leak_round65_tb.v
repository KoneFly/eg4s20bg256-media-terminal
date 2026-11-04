module leak_round65_tb(input wire clk,input wire signed [31:0] weight,input wire recovery,output wire [32:0] old_value,new_value);
 leak_old65 old(.clk(clk),.weight(weight),.saved_recovery(recovery),.result(old_value));
 leak_new65 candidate(.clk(clk),.weight(weight),.saved_recovery(recovery),.result(new_value));
endmodule
