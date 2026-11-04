`timescale 1ns/1ps
// SOS与整块权值更新独占同一32x18引擎（内部一颗18x18）。
// 一次只接一个作业；冲突请求明确置错，不丢弃/覆盖正在执行的上下文。
module anc_core_arithmetic_r61(input wire clk,rst_n,clear,
 input wire sos_request,input wire signed [31:0] x,z0,z1,
 input wire signed [17:0] b0,b1,b2,a1,a2,input wire [7:0] sos_context,
 output wire sos_valid,sos_clipped,output wire signed [31:0] y,new_z0,new_z1,
 output wire [7:0] sos_result_context,
 input wire weight_request,input wire [8:0] length,input wire signed [31:0] gain,
 input wire [7:0] weight_context,input wire weight_recovery,output wire weight_valid,weight_fault,
 output wire [7:0] weight_result_context,output wire [8:0] box_events,overflow_events,
 output wire memory_read,output wire [7:0] read_address,
 input wire memory_valid,input wire signed [31:0] weight,input wire signed [17:0] gradient,
 output wire memory_write,output wire [7:0] write_address,output wire signed [31:0] write_weight,
 input wire scalar_request,input wire signed [31:0] scalar_x,
 input wire signed [17:0] scalar_c,input wire [7:0] scalar_context,
 output reg scalar_valid,scalar_overflow,output reg signed [49:0] scalar_product,
 output reg [7:0] scalar_result_context,
 output wire ready,output reg dispatch_fault);
 reg [1:0] owner;reg scalar_issued;reg signed [31:0] ax;reg signed [17:0] ac;reg [7:0] atag;wire sr,wr,so,wo;wire ms,mw,mready,mvalid,moverflow;
 wire signed [31:0] sx,wx;wire signed [17:0] sc,wc;
 wire [7:0] st,wt,mt;wire signed [49:0] mp;
 assign ready=owner==0&&sr&&wr&&mready;
 wire sos_start=ready&&sos_request&&!weight_request&&!scalar_request;
 wire weight_start=ready&&weight_request&&!sos_request&&!scalar_request;
 wire scalar_start=ready&&scalar_request&&!sos_request&&!weight_request;
 anc_biquad_shared_r61 sos(.clk(clk),.rst_n(rst_n),.clear(clear),.request(sos_start),
 .x(x),.z0(z0),.z1(z1),.b0(b0),.b1(b1),.b2(b2),.a1(a1),.a2(a2),.context_id(sos_context),
 .ready(sr),.valid(sos_valid),.clipped(sos_clipped),.overrun(so),.y(y),.new_z0(new_z0),.new_z1(new_z1),.result_context(sos_result_context),
 .mult_request(ms),.mult_ready(mready&&owner==1),.mult_valid(mvalid&&owner==1),.mult_overflow(moverflow),
 .mult_product(mp),.mult_tag(mt),.mult_x(sx),.mult_c(sc),.request_tag(st));
 anc_weight_update_r61 weights(.clk(clk),.rst_n(rst_n),.clear(clear),.request(weight_start),
 .length(length),.gain(gain),.context_id(weight_context),.recovery(weight_recovery),.ready(wr),.valid(weight_valid),.result_context(weight_result_context),
 .overrun(wo),.arithmetic_fault(weight_fault),.box_events(box_events),.overflow_events(overflow_events),
 .memory_read(memory_read),.read_address(read_address),.memory_valid(memory_valid),.weight(weight),.gradient(gradient),
 .memory_write(memory_write),.write_address(write_address),.write_weight(write_weight),
 .multiply_request(mw),.multiply_ready(mready&&owner==2),.multiply_x(wx),.multiply_c(wc),.multiply_tag(wt),
 .multiply_valid(mvalid&&owner==2),.multiply_product(mp),.multiply_result_tag(mt),.multiply_overflow(moverflow));
 anc_mul32x18_r61 common_multiplier(.clk(clk),.rst_n(rst_n),.clear(clear),
 .request((owner==1&&ms)||(owner==2&&mw)||(owner==3&&!scalar_issued)),.x(owner==1?sx:owner==2?wx:ax),.c(owner==1?sc:owner==2?wc:ac),.tag(owner==1?st:owner==2?wt:atag),
 .ready(mready),.valid(mvalid),.product(mp),.result_tag(mt),.overflow(moverflow));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin owner<=0;dispatch_fault<=0;scalar_issued<=0;ax<=0;ac<=0;atag<=0;scalar_valid<=0;scalar_overflow<=0;scalar_product<=0;scalar_result_context<=0;end
  else if(clear)begin owner<=0;dispatch_fault<=0;scalar_issued<=0;ax<=0;ac<=0;atag<=0;scalar_valid<=0;scalar_overflow<=0;scalar_product<=0;scalar_result_context<=0;end
  else begin
   scalar_valid<=0;
   if((sos_request||weight_request||scalar_request)&&(!ready||(sos_request&&weight_request)||(sos_request&&scalar_request)||(weight_request&&scalar_request)))dispatch_fault<=1;
   if(owner==3&&!scalar_issued&&mready)scalar_issued<=1;
   if(owner==3&&mvalid)begin scalar_valid<=1;scalar_product<=mp;scalar_overflow<=moverflow;scalar_result_context<=mt;owner<=0;end
   if(so||wo)dispatch_fault<=1;
   if(sos_start)owner<=1;else if(weight_start)owner<=2;else if(scalar_start)begin owner<=3;scalar_issued<=0;ax<=scalar_x;ac<=scalar_c;atag<=scalar_context;end
   else if((owner==1&&sos_valid)||(owner==2&&weight_valid))owner<=0;
  end
 end
endmodule
