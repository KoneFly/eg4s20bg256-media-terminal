`timescale 1ns/1ps

// SDK仅端口/参数声明：无原语内部仿真保证。
module EG_PHY_PLL(clkc,extlock,stdby,refclk,fbclk,reset,load_reg,
                  psdone,psclk,psdown,psstep,psclksel,
                  do,dclk,dcs,dwe,di,daddr);
output [4:0] clkc;      
output extlock;         
input  stdby;           
input  refclk;          
input  fbclk;           
input  reset;           
input  load_reg;        
output psdone;          
input  psclk;           
input  psdown;          
input  psstep;          
input  [2:0] psclksel;  
output [7:0]do;         
input  dclk;            
input  dcs;             
input  dwe;             
input  [7:0] di;        
input  [5:0] daddr;     
parameter DYNCFG = "DISABLE";          // "ENABLE","DISABLE".
parameter IF_ESCLKSTSW = "DISABLE";    // "ENABLE","DISABLE".
parameter REFCLK_SEL = "INTERNAL";     // "INTERNAL", "EXTRNAL".
parameter FIN = "100.0000";              // "ENABLE","DISABLE".
parameter REFCLK_DIV    = 1;             // 1~128.
parameter FBCLK_DIV     = 1;             // 1~128.
parameter CLKC0_DIV     = 1;             // 1~128.
parameter CLKC1_DIV     = 1;             // 1~128.
parameter CLKC2_DIV     = 1;             // 1~128.
parameter CLKC3_DIV     = 1;             // 1~128.
parameter CLKC4_DIV     = 1;             // 1~128.
parameter CLKC0_ENABLE  = "DISABLE";     // "ENABLE", "DISABLE", "SIGNAL".
parameter CLKC1_ENABLE  = "DISABLE";     // "ENABLE", "DISABLE", "SIGNAL".
parameter CLKC2_ENABLE  = "DISABLE";     // "ENABLE", "DISABLE", "SIGNAL".
parameter CLKC3_ENABLE  = "DISABLE";     // "ENABLE", "DISABLE", "SIGNAL".
parameter CLKC4_ENABLE  = "DISABLE";     // "ENABLE", "DISABLE", "SIGNAL".
parameter CLKC0_DIV2_ENABLE = "DISABLE";   // "ENABLE", "DISABLE".
parameter CLKC1_DIV2_ENABLE = "DISABLE";   // "ENABLE", "DISABLE".
parameter CLKC2_DIV2_ENABLE = "DISABLE";   // "ENABLE", "DISABLE".
parameter CLKC3_DIV2_ENABLE = "DISABLE";   // "ENABLE", "DISABLE".
parameter CLKC4_DIV2_ENABLE = "DISABLE";   // "ENABLE", "DISABLE".
parameter FEEDBK_MODE   = "NORMAL";    // "NORMAL", "SOURCESYNC", "NOCOMP", "ZERODELAY".
parameter FEEDBK_PATH   = "VCO_PHASE_0";  
parameter STDBY_ENABLE  = "ENABLE";   // ENABLE/DISABLE
parameter CLKC0_FPHASE     = 0;    // 0~7.
parameter CLKC1_FPHASE     = 0;    // 0~7.
parameter CLKC2_FPHASE     = 0;    // 0~7.
parameter CLKC3_FPHASE     = 0;    // 0~7.
parameter CLKC4_FPHASE     = 0;    // 0~7.
parameter CLKC0_CPHASE     = 1;    // 1~127  ,CLKC0_CPHASE <= CLKC0_DIV
parameter CLKC1_CPHASE     = 1;    // 1~127  ,CLKC1_CPHASE <= CLKC1_DIV
parameter CLKC2_CPHASE     = 1;    // 1~127  ,CLKC2_CPHASE <= CLKC2_DIV
parameter CLKC3_CPHASE     = 1;    // 1~127  ,CLKC3_CPHASE <= CLKC3_DIV
parameter CLKC4_CPHASE     = 1;    // 1~127  ,CLKC4_CPHASE <= CLKC4_DIV
parameter GMC_GAIN         = 7;  // 0~7.
parameter GMC_TEST         = 14; // 0~15.
parameter ICP_CURRENT      = 14;   // 1~32.
parameter KVCO             = 7;  // 0~7.
parameter LPF_CAPACITOR    = 3;  // 0~3.
parameter LPF_RESISTOR     = 1;    // 1~128.
parameter PLLRST_ENA       = "ENABLE";     // "ENABLE", "DISABLE".
parameter PLLMRST_ENA      = "DISABLE";    // "ENABLE", "DISABLE".
parameter PLLC2RST_ENA     = "DISABLE";    // "ENABLE", "DISABLE".
parameter PLLC34RST_ENA    = "DISABLE";    // "ENABLE", "DISABLE".
parameter PREDIV_MUXC0 = "VCO";    // VCO/CLKMINUS1/CLKPLUS1/REFCLK
parameter PREDIV_MUXC1 = "VCO";    // VCO/CLKMINUS1/CLKPLUS1/REFCLK
parameter PREDIV_MUXC2 = "VCO";    // VCO/CLKMINUS1/CLKPLUS1/REFCLK
parameter PREDIV_MUXC3 = "VCO";    // VCO/CLKMINUS1/CLKPLUS1/REFCLK
parameter PREDIV_MUXC4 = "VCO";    // VCO/CLKMINUS1/CLKPLUS1/REFCLK
parameter ODIV_MUXC0 = "DIV";     // "VCO", "CLKMINUS1", "CLKPLUS1", "REFCLK".
parameter ODIV_MUXC1 = "DIV";     // "VCO", "CLKMINUS1", "SSCCLK","REFCLK".
parameter ODIV_MUXC2 = "DIV";     // "VCO", "CLKMINUS1", "SSCCLK","REFCLK".
parameter ODIV_MUXC3 = "DIV";     // "VCO", "CLKMINUS1", "SSCCLK","REFCLK".
parameter ODIV_MUXC4 = "DIV";     // "VCO", "CLKMINUS1", "CLKPLUS1", "REFCLK".
parameter FREQ_LOCK_ACCURACY = 2; // 0~3
parameter PLL_LOCK_MODE = 0;    // 0~7, 2 => sticky, 0 => non-sticky
parameter INTFB_WAKE      = "DISABLE"; // "ENBALE", "DISABLE".
parameter DPHASE_SOURCE   = "DISABLE"; // "ENABLE", "DISABLE".
parameter VCO_NORESET     = "DISABLE"; // "ENABLE", "DISABLE".
parameter STDBY_VCO_ENA   = "DISABLE"; // "ENABLE", "DISABLE".
parameter NORESET         = "DISABLE"; // "ENABLE", "DISABLE".
parameter SYNC_ENABLE     = "ENABLE";  // "ENABLE", "DISABLE".
parameter DERIVE_PLL_CLOCKS = "DISABLE";   // "ENABLE", "DISABLE".
parameter GEN_BASIC_CLOCK   = "DISABLE";   // "ENABLE", "DISABLE".
endmodule

// SDK仅端口/参数声明：无原语内部仿真保证。
module EG_PHY_SDRAM_2M_32 (
    clk,
    ras_n,
    cas_n,
    we_n,
    addr,
    ba,
    dq,
    cs_n,
    dm0,
    dm1,
    dm2,
    dm3,
    cke
);
input         clk;		
input         ras_n;    
input         cas_n;    
input         we_n;     
input  [10:0] addr;     
input  [1:0]  ba;       
inout  [31:0] dq;        
input         cs_n; 
input         dm0; 
input         dm1; 
input         dm2; 
input         dm3; 
input         cke; 
endmodule

module EG_LOGIC_BUFG(input wire i,output wire o); assign o=i; endmodule
// 公开BUF原语功能与官方eg_logic_gate.v一致；不提供物理延迟模型。
module EG_LOGIC_BUF(input wire i,output wire o); assign o=i; endmodule
