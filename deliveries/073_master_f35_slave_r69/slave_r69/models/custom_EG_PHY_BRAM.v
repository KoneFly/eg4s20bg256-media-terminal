`timescale 1ns/1ps
// Independent narrow model: DP8K, 9-bit read-only A port, synchronous one-cycle.
module EG_PHY_BRAM #(
    parameter CEAMUX="SIG", CEBMUX="SIG", CSA0="SIG", CSA1="SIG", CSA2="SIG",
    parameter CSB0="SIG", CSB1="SIG", CSB2="SIG", DATA_WIDTH_A="9", DATA_WIDTH_B="9",
    parameter MODE="DP8K", REGMODE_A="NOREG", REGMODE_B="NOREG", RESETMODE="SYNC",
    parameter RSTAMUX="0", RSTBMUX="0", WEBMUX="0", WRITEMODE_A="NORMAL", WRITEMODE_B="NORMAL",
    parameter [255:0] INITP_00=256'd0,
    parameter [255:0] INITP_01=256'd0,
    parameter [255:0] INITP_02=256'd0,
    parameter [255:0] INITP_03=256'd0,
    parameter [255:0] INIT_00=256'd0,
    parameter [255:0] INIT_01=256'd0,
    parameter [255:0] INIT_02=256'd0,
    parameter [255:0] INIT_03=256'd0,
    parameter [255:0] INIT_04=256'd0,
    parameter [255:0] INIT_05=256'd0,
    parameter [255:0] INIT_06=256'd0,
    parameter [255:0] INIT_07=256'd0,
    parameter [255:0] INIT_08=256'd0,
    parameter [255:0] INIT_09=256'd0,
    parameter [255:0] INIT_0A=256'd0,
    parameter [255:0] INIT_0B=256'd0,
    parameter [255:0] INIT_0C=256'd0,
    parameter [255:0] INIT_0D=256'd0,
    parameter [255:0] INIT_0E=256'd0,
    parameter [255:0] INIT_0F=256'd0,
    parameter [255:0] INIT_10=256'd0,
    parameter [255:0] INIT_11=256'd0,
    parameter [255:0] INIT_12=256'd0,
    parameter [255:0] INIT_13=256'd0,
    parameter [255:0] INIT_14=256'd0,
    parameter [255:0] INIT_15=256'd0,
    parameter [255:0] INIT_16=256'd0,
    parameter [255:0] INIT_17=256'd0,
    parameter [255:0] INIT_18=256'd0,
    parameter [255:0] INIT_19=256'd0,
    parameter [255:0] INIT_1A=256'd0,
    parameter [255:0] INIT_1B=256'd0,
    parameter [255:0] INIT_1C=256'd0,
    parameter [255:0] INIT_1D=256'd0,
    parameter [255:0] INIT_1E=256'd0,
    parameter [255:0] INIT_1F=256'd0
)(input wire [8:0] dia,dib,input wire [12:0] addra,addrb,input wire [2:0] csa,csb,
   input wire cea,ocea,clka,wea,rsta,ceb,oceb,clkb,web,rstb,
   output reg [8:0] doa,output wire [8:0] dob);
    wire [8191:0] data = {INIT_1F,INIT_1E,INIT_1D,INIT_1C,INIT_1B,INIT_1A,INIT_19,INIT_18,INIT_17,INIT_16,INIT_15,INIT_14,INIT_13,INIT_12,INIT_11,INIT_10,INIT_0F,INIT_0E,INIT_0D,INIT_0C,INIT_0B,INIT_0A,INIT_09,INIT_08,INIT_07,INIT_06,INIT_05,INIT_04,INIT_03,INIT_02,INIT_01,INIT_00};
    wire unused_inputs = ^{dia,dib,addrb,csb,ocea,rsta,ceb,oceb,clkb,web,rstb};
    assign dob=9'd0;
    initial begin
      if(CEAMUX!="1" || CEBMUX!="1" || CSA0!="1" || CSA1!="1" || CSA2!="1" ||
         CSB0!="1" || CSB1!="1" || CSB2!="1" || DATA_WIDTH_A!="9" || DATA_WIDTH_B!="9" ||
         MODE!="DP8K" || REGMODE_A!="NOREG" || REGMODE_B!="NOREG" || RESETMODE!="SYNC" ||
         RSTAMUX!="0" || RSTBMUX!="0" || WEBMUX!="0" || WRITEMODE_A!="NORMAL" || WRITEMODE_B!="NORMAL" ||
         (INITP_00|INITP_01|INITP_02|INITP_03)!=256'd0) $fatal(1,"unexpected primitive configuration");
    end
    always @(posedge clka) begin
      if(cea && csa==3'b111) begin
        if(wea || addra[2:0]!=3'b111) $fatal(1,"unexpected write or address wiring");
        doa <= {1'b0,data[{addra[12:3],3'b000} +: 8]};
      end
    end
endmodule
