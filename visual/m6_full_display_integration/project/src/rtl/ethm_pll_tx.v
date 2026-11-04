`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 发送侧 PLL: 50MHz 板载晶振(R7) -> 125MHz 两路 + 125MHz/90° 一路 + 25MHz 应用域一路。
// VCO = (FIN/REFCLK_DIV) * FBCLK_DIV * CLKC0_DIV = 25 * 5 * 8 = 1000MHz。
// CPHASE=7 -> 0°, CPHASE=1 -> 90°(官方 pll_gen 生成器口径)。
// 环滤参数沿用官方 50MHz 输入配置, 不自拟。
//
// app_clk(25MHz) 是给"应用侧"(发包机/收包机/统计/LED)的第三域: 它是 clk_50 的
// 同源衍生前向时钟, 因此链路没建立时照样存在, 发送端不会因为没链路而停摆。
// C3 分频 40 => 1000MHz/40 = 25MHz; CPHASE=39(与 DIV=40 配成官方口径的 0°),
// FPHASE=0。clkc 总线顺序保持 {C4,C3,C2,C1,C0}。
//------------------------------------------------------------------------------
module ethm_pll_tx (
    input  wire clk_50,
    input  wire pll_rst,
    output wire tx_clk,
    output wire tx_clk90,
    output wire app_clk,
    output wire tx_locked
);
    wire clk0_buf;
    wire clk0_fb;
    wire clk_unused2;
    wire [7:0] do_unused;
    wire       psdone_unused;

    EG_LOGIC_BUFG u_fb_bufg (
        .i (clk0_buf),
        .o (clk0_fb)
    );

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("50.000000"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("CLKC0_EXT"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (2),
        .ICP_CURRENT   (9),
        .KVCO          (2),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (8),
        .REFCLK_DIV    (2),
        .FBCLK_DIV     (5),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (8),
        .CLKC0_CPHASE  (7),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("ENABLE"),
        .CLKC1_DIV     (8),
        .CLKC1_CPHASE  (7),
        .CLKC1_FPHASE  (0),
        .CLKC2_ENABLE  ("ENABLE"),
        .CLKC2_DIV     (8),
        .CLKC2_CPHASE  (1),
        .CLKC2_FPHASE  (0),
        .CLKC3_ENABLE  ("ENABLE"),
        .CLKC3_DIV     (40),
        .CLKC3_CPHASE  (39),
        .CLKC3_FPHASE  (0),
        .CLKC4_ENABLE  ("DISABLE"),
        .CLKC4_DIV     (8),
        .CLKC4_CPHASE  (7),
        .CLKC4_FPHASE  (0)
    ) u_pll (
        .refclk   (clk_50),
        .reset    (pll_rst),
        .stdby    (1'b0),
        .extlock  (tx_locked),
        .load_reg (1'b0),
        .psclk    (1'b0),
        .psdown   (1'b0),
        .psstep   (1'b0),
        .psclksel (3'b000),
        .psdone   (psdone_unused),
        .dclk     (1'b0),
        .dcs      (1'b0),
        .dwe      (1'b0),
        .di       (8'd0),
        .daddr    (6'd0),
        .do       (do_unused),
        .fbclk    (clk0_fb),
        .clkc     ({clk_unused2, app_clk, tx_clk90, tx_clk, clk0_buf})
    );
endmodule
