`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// task_052 主板(role=master)顶层: 前向发 type=1 PCM 测试源, 反向收 type=2 频带。
// 与副板是两颗不同的 bit(不同顶层名/不同文件名), 不使用同名主从文件。
// 引脚见 constraints/eth_pcm.adc; 接线与电平约定见 doc/output/LINK_REPORT.md。
//------------------------------------------------------------------------------
module eth_pcm_master_top (
    input  wire        clk_50,

    input  wire        phy1_rgmii_rx_clk,
    input  wire        phy1_rgmii_rx_ctl,
    input  wire [3:0]  phy1_rgmii_rx_data,
    output wire        phy1_rgmii_tx_clk,
    output wire        phy1_rgmii_tx_ctl,
    output wire [3:0]  phy1_rgmii_tx_data,

    input  wire        key1,
    input  wire        key2,
    input  wire        key3,
    input  wire [3:0]  sw,

    output wire [3:0]  led,
    output wire [15:0] dled
);
    ethm_link_core #(
        .SRC_MAC     (48'h02_00_00_52_4D_01),
        .DST_MAC     (48'h02_00_00_52_53_02),
        .PKT_TYPE    (8'd1),
        .PACE_NORMAL (17'd48000),
        .PACE_BOOST  (17'd60000),
        .DELIV_REV   (32'h0520_0101),
        .LED_LOW     (0),
        .RX_PHASE    (8'd0)
    ) u_core (
        .clk_50            (clk_50),
        .phy_rxc           (phy1_rgmii_rx_clk),
        .phy_rx_ctl        (phy1_rgmii_rx_ctl),
        .phy_rxd           (phy1_rgmii_rx_data),
        .phy_txc           (phy1_rgmii_tx_clk),
        .phy_tx_ctl        (phy1_rgmii_tx_ctl),
        .phy_txd           (phy1_rgmii_tx_data),
        .key_reset         (key1),
        .key_clear         (key2),
        .key_restart       (key3),
        .sw                (sw),
        .led               (led),
        .dled              (dled)
    );
endmodule
