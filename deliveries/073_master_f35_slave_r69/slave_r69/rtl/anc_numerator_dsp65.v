`timescale 1ns/1ps
// 与原abs*8389低33bit精确相同；两个正数拆分乘积。
// 两片无寄存器18x18，常量8389；没有新增时钟拍或舍入。
module anc_numerator_dsp65(input wire [19:0] absolute_error,output wire [32:0] scaled);
 wire [35:0] pl,ph;wire [17:0] unused_al,unused_bl,unused_ah,unused_bh;
 wire [15:0] upper=ph[15:0]+pl[32:17];
 assign scaled={upper,pl[16:0]};
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),.SRMODE("ASYNC"),.MODE("MULT18X18C"),.CEAMUX("1"),.CEBMUX("1"),.CEPDMUX("1"),.RSTANMUX("1"),.RSTBNMUX("1"),.RSTPDNMUX("1"),.CLKMUX("SIG"),.SIGNEDAMUX("1"),.SIGNEDBMUX("1"),.SOURCEAMUX("1"),.SOURCEBMUX("1")) u_num_lo(
 .a({1'b0,absolute_error[16:0]}),.b(18'd8389),.acin(18'd0),.bcin(18'd0),.signeda(1'b1),.signedb(1'b1),.sourcea(1'b1),.sourceb(1'b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(1'b0),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.p(pl),.acout(unused_al),.bcout(unused_bl));
 EG_PHY_MULT18 #(.INPUTREGA("DISABLE"),.INPUTREGB("DISABLE"),.OUTPUTREG("DISABLE"),.SRMODE("ASYNC"),.MODE("MULT18X18C"),.CEAMUX("1"),.CEBMUX("1"),.CEPDMUX("1"),.RSTANMUX("1"),.RSTBNMUX("1"),.RSTPDNMUX("1"),.CLKMUX("SIG"),.SIGNEDAMUX("1"),.SIGNEDBMUX("1"),.SOURCEAMUX("1"),.SOURCEBMUX("1")) u_num_hi(
 .a({15'd0,absolute_error[19:17]}),.b(18'd8389),.acin(18'd0),.bcin(18'd0),.signeda(1'b1),.signedb(1'b1),.sourcea(1'b1),.sourceb(1'b1),.cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(1'b0),.rstan(1'b1),.rstbn(1'b1),.rstpdn(1'b1),.p(ph),.acout(unused_ah),.bcout(unused_bh));
endmodule
