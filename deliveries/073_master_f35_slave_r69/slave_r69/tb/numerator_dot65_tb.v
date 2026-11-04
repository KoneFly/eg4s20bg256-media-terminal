module numerator_dot65_tb(input wire clk,rst_n,clear,request,input wire [8:0] length,input wire [7:0] ctx,
 input wire signed [17:0] coefficient,data,input wire signed [19:0] gradient,
 output wire ready,valid,invalid_length,overrun,diff,negative,output wire signed [63:0] sum,output wire [63:0] magnitude);
 wire ory,ov,oi,oo,ore;wire [7:0] oridx,nidx,oc,nc;wire signed [63:0] os;
 old_dot65 old(.clk(clk),.rst_n(rst_n),.clear(clear),.request(request),.length(length),.context_id(ctx),.ready(ory),.read_enable(ore),.read_index(oridx),.coefficient(coefficient),.data(data),.valid(ov),.invalid_length(oi),.overrun(oo),.sum(os),.result_context(oc));
 wire nr;
 anc_dot18_engine_r61 candidate(.clk(clk),.rst_n(rst_n),.clear(clear),.request(request),.length(length),.context_id(ctx),.ready(ready),.read_enable(nr),.read_index(nidx),.coefficient(coefficient),.data(data),.valid(valid),.invalid_length(invalid_length),.overrun(overrun),.sum(sum),.result_context(nc));
 assign diff=ory!=ready||ov!=valid||oi!=invalid_length||oo!=overrun||os!=sum||oc!=nc||ore!=nr||oridx!=nidx;
 anc_gain_numerator_r62 numerator(.gradient(gradient),.negative(negative),.magnitude(magnitude));
endmodule
