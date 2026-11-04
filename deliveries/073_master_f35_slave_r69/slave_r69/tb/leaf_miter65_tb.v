module leaf_miter65_tb(input wire clk,rst_n,clear,breq,dreq,
 input wire signed [31:0] x,z0,z1,input wire signed [17:0] b0,b1,b2,a1,a2,input wire [7:0] ctx,
 input wire [63:0] numerator,denominator,
 output wire bready,bvalid,bdiff,dready,dbusy,ddone,dzero,ddiff,
 output wire [63:0] quotient,remainder);
 wire ory,ov,oc,oo,nc,no;wire signed [31:0] oy,oz0,oz1,ny,nz0,nz1;wire [7:0] ot,nt;
 wire omr,nmr,mready,mvalid,moverflow;wire signed [31:0] omx,nmx;wire signed [17:0] omc,nmc;wire [7:0] omt,nmt,mt;wire signed [49:0] mp;
 old_biquad65 old(.clk(clk),.rst_n(rst_n),.clear(clear),.request(breq),.x(x),.z0(z0),.z1(z1),.b0(b0),.b1(b1),.b2(b2),.a1(a1),.a2(a2),.context_id(ctx),.ready(ory),.valid(ov),.clipped(oc),.overrun(oo),.y(oy),.new_z0(oz0),.new_z1(oz1),.result_context(ot),.mult_request(omr),.mult_ready(mready),.mult_valid(mvalid),.mult_overflow(moverflow),.mult_product(mp),.mult_tag(mt),.mult_x(omx),.mult_c(omc),.request_tag(omt));
 anc_biquad_shared_r61 candidate(.clk(clk),.rst_n(rst_n),.clear(clear),.request(breq),.x(x),.z0(z0),.z1(z1),.b0(b0),.b1(b1),.b2(b2),.a1(a1),.a2(a2),.context_id(ctx),.ready(bready),.valid(bvalid),.clipped(nc),.overrun(no),.y(ny),.new_z0(nz0),.new_z1(nz1),.result_context(nt),.mult_request(nmr),.mult_ready(mready),.mult_valid(mvalid),.mult_overflow(moverflow),.mult_product(mp),.mult_tag(mt),.mult_x(nmx),.mult_c(nmc),.request_tag(nmt));
 anc_mul32x18_r61 provider(.clk(clk),.rst_n(rst_n),.clear(clear),.request(omr),.x(omx),.c(omc),.tag(omt),.ready(mready),.valid(mvalid),.product(mp),.result_tag(mt),.overflow(moverflow));
 assign bdiff=ory!=bready||ov!=bvalid||oc!=nc||oo!=no||oy!=ny||oz0!=nz0||oz1!=nz1||ot!=nt||omr!=nmr||(omr&&(omx!=nmx||omc!=nmc||omt!=nmt));
 wire ordy,obusy,odone,ozero;wire [63:0] oq,orr;
 anc_u64_divider_r61 old_div(.clk(clk),.rst_n(rst_n),.clear(clear),.request(dreq),.numerator(numerator),.denominator(denominator),.ready(ordy),.busy(obusy),.done(odone),.divide_by_zero(ozero),.quotient(oq),.remainder(orr));
 anc_divider_compact_r65 new_div(.clk(clk),.rst_n(rst_n),.clear(clear),.request(dreq),.numerator(numerator),.denominator(denominator),.ready(dready),.busy(dbusy),.done(ddone),.divide_by_zero(dzero),.quotient(quotient),.remainder(remainder));
 assign ddiff=ordy!=dready||obusy!=dbusy||odone!=ddone||ozero!=dzero||(odone&&(oq!=quotient||orr!=remainder));
endmodule
