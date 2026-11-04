`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 接收侧 PLL: 参考时钟 = PHY 送来的 RGMII RXC 引脚(T14), 125MHz@1G。
// C0 = 125MHz/0°, C1 = 125MHz/90°, C2~C4 关闭。采样相位由上层 RX_PHASE 参数选择。
// VCO = (125/1) * 1 * 8 = 1000MHz。环滤参数沿用官方 rx_pll 配置。
// 链路未建立时 RXC 可能缺失 => extlock=0, 本工程把它当作"物理链路存在"判据。
//------------------------------------------------------------------------------
module ethm_pll_rx (
    input  wire rx_clk_pin,
    input  wire pll_rst,
    output wire rx_clk0,
    output wire rx_clk90,
    output wire rx_locked
);
    wire clk0_buf;
    wire clk0_fb;
    wire clk_unused2;
    wire clk_unused3;
    wire clk_unused4;
    wire [7:0] do_unused;
    wire       psdone_unused;

    EG_LOGIC_BUFG u_fb_bufg (
        .i (clk0_buf),
        .o (clk0_fb)
    );

    // C0 经 BUFG 后既是 PLL 自反馈(FEEDBK_PATH=CLKC0_EXT), 也是对外提供的 0° 时钟
    assign rx_clk0 = clk0_fb;

    EG_PHY_PLL #(
        .DPHASE_SOURCE ("DISABLE"),
        .DYNCFG        ("DISABLE"),
        .FIN           ("125.000000"),
        .FEEDBK_MODE   ("NORMAL"),
        .FEEDBK_PATH   ("CLKC0_EXT"),
        .STDBY_ENABLE  ("DISABLE"),
        .PLLRST_ENA    ("ENABLE"),
        .SYNC_ENABLE   ("DISABLE"),
        .GMC_GAIN      (6),
        .GMC_TEST      (15),
        .ICP_CURRENT   (13),
        .KVCO          (4),
        .LPF_CAPACITOR (1),
        .LPF_RESISTOR  (2),
        .REFCLK_DIV    (1),
        .FBCLK_DIV     (1),
        .CLKC0_ENABLE  ("ENABLE"),
        .CLKC0_DIV     (8),
        .CLKC0_CPHASE  (7),
        .CLKC0_FPHASE  (0),
        .CLKC1_ENABLE  ("ENABLE"),
        .CLKC1_DIV     (8),
        .CLKC1_CPHASE  (1),
        .CLKC1_FPHASE  (0),
        .CLKC2_ENABLE  ("DISABLE"),
        .CLKC2_DIV     (4),
        .CLKC2_CPHASE  (3),
        .CLKC2_FPHASE  (0),
        .CLKC3_ENABLE  ("DISABLE"),
        .CLKC3_DIV     (4),
        .CLKC3_CPHASE  (3),
        .CLKC3_FPHASE  (0),
        .CLKC4_ENABLE  ("DISABLE"),
        .CLKC4_DIV     (4),
        .CLKC4_CPHASE  (3),
        .CLKC4_FPHASE  (0)
    ) u_pll (
        .refclk   (rx_clk_pin),
        .reset    (pll_rst),
        .stdby    (1'b0),
        .extlock  (rx_locked),
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
        .clkc     ({clk_unused4, clk_unused3, clk_unused2, rx_clk90, clk0_buf})
    );
endmodule
