`timescale 1ns/1ps
// 与原43位(w<<10)+(w<<5)+(w<<4)+(w<<1)全32bit输入域精确相同。
// 两片无寄存器18x18，常量1074；没有新增时钟拍或舍入。
module anc_decay_dsp65(input wire clk,input wire signed [31:0] weight,output wire signed [42:0] scaled);
 wire [35:0] pl,ph;wire [17:0] unused_al,unused_bl,unused_ah,unused_bh;
 wire signed [51:0] full=$signed({ph,16'd0})+$signed({{16{pl[35]}},pl});
 assign scaled=full[42:0];
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),.SRMODE("ASYNC"),.MODE("MULT18X18C"),.CEAMUX("1"),.CEBMUX("1"),.CEPDMUX("1"),.RSTANMUX("1"),.RSTBNMUX("1"),.RSTPDNMUX("1"),.CLKMUX("SIG"),.SIGNEDAMUX("1"),.SIGNEDBMUX("1"),.SOURCEAMUX("1"),.SOURCEBMUX("1")) u_decay_lo(
 .a({2'b00,weight[15:0]}),.b(18'd1074),.acin(18'd0),.bcin(18'd0),.signeda(1'b1),.signedb(1'b1),.sourcea(1'b1),.sourceb(1'b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(clk),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.p(pl),.acout(unused_al),.bcout(unused_bl));
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),.SRMODE("ASYNC"),.MODE("MULT18X18C"),.CEAMUX("1"),.CEBMUX("1"),.CEPDMUX("1"),.RSTANMUX("1"),.RSTBNMUX("1"),.RSTPDNMUX("1"),.CLKMUX("SIG"),.SIGNEDAMUX("1"),.SIGNEDBMUX("1"),.SOURCEAMUX("1"),.SOURCEBMUX("1")) u_decay_hi(
 .a({{2{weight[31]}},weight[31:16]}),.b(18'd1074),.acin(18'd0),.bcin(18'd0),.signeda(1'b1),.signedb(1'b1),.sourcea(1'b1),.sourceb(1'b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(clk),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.p(ph),.acout(unused_ah),.bcout(unused_bh));
endmodule
