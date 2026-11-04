`timescale 1ns/1ps
// 独立窄数学模型，仅支持本次从官方EG4模板选择的无寄存器有符号直通配置。
// 不宣称为厂家加密模型或综合网表仿真。
module EG_PHY_MULT18 #(
 parameter INPUTREGA="DISABLE",INPUTREGB="DISABLE",OUTPUTREG="DISABLE",SRMODE="ASYNC",MODE="MULT18X18C",
 parameter CEAMUX="1",CEBMUX="1",CEPDMUX="1",RSTANMUX="1",RSTBNMUX="1",RSTPDNMUX="1",CLKMUX="SIG",
 parameter SIGNEDAMUX="1",SIGNEDBMUX="1",SOURCEAMUX="1",SOURCEBMUX="1"
)(input wire [17:0] a,b,acin,bcin,input wire signeda,signedb,sourcea,sourceb,cea,ceb,cepd,clk,rstan,rstbn,rstpdn,
 output wire [17:0] acout,bcout,output wire [35:0] p);
 wire unused_inputs=^{acin,bcin,signeda,signedb,sourcea,sourceb,cea,ceb,cepd,clk,rstan,rstbn,rstpdn};
 // 厂商原模型：0为级联acin/bcin，1为直接a/b；复现测试已绑定。
`ifdef R67_FORCE_OLD_SOURCE
 wire [17:0] selected_a=acin,selected_b=bcin;
`else
 wire [17:0] selected_a=SOURCEAMUX=="1"?a:acin;
 wire [17:0] selected_b=SOURCEBMUX=="1"?b:bcin;
`endif
 assign p=$signed(selected_a)*$signed(selected_b);assign acout=a;assign bcout=b;
 initial begin
  if(INPUTREGA!="DISABLE"||INPUTREGB!="DISABLE"||OUTPUTREG!="DISABLE"||SRMODE!="ASYNC"||MODE!="MULT18X18C"||SIGNEDAMUX!="1"||SIGNEDBMUX!="1"||(SOURCEAMUX!="0"&&SOURCEAMUX!="1")||(SOURCEBMUX!="0"&&SOURCEBMUX!="1")||CEAMUX!="1"||CEBMUX!="1"||CEPDMUX!="1"||RSTANMUX!="1"||RSTBNMUX!="1"||RSTPDNMUX!="1"||CLKMUX!="SIG")$fatal(1,"unsupported DSP model configuration");
 end
endmodule
