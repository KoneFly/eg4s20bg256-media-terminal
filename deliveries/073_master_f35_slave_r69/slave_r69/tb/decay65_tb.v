module decay65_tb(input wire clk,input wire signed [31:0] weight,output wire [42:0] actual,original);
 anc_decay_dsp65 dut(.clk(clk),.weight(weight),.scaled(actual));
 wire signed [42:0] w={{11{weight[31]}},weight};
 assign original=((w<<<10)+(w<<<5))+((w<<<4)+(w<<<1));
endmodule
