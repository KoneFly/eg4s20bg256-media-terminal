`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// RGMII 接收物理层(千兆)。IDDR 上升沿得低半字节, 下降沿得高半字节。
// CRS/COL 由 GMII 侧组合得到, 供 TEMAC 的全双工/载波侦听输入。
//------------------------------------------------------------------------------
module ethm_rgmii_rx (
    input  wire       rx_clk,
    input  wire [3:0] rgmii_rxd,
    input  wire       rgmii_rx_ctl,
    input  wire       gmii_tx_en,
    input  wire       gmii_tx_er,
    output wire [7:0] gmii_rxd,
    output wire       gmii_rx_dv,
    output wire       gmii_rx_er,
    output wire       gmii_crs,
    output wire       gmii_col
);
    wire ctl_er;

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_rxd
            EG_LOGIC_IDDR #(
                .ASYNCRST ("ENABLE"),
                .PIPEMODE ("PIPED")
            ) u_rxd_ddr (
                .q0  (gmii_rxd[k]),
                .q1  (gmii_rxd[k+4]),
                .clk (rx_clk),
                .d   (rgmii_rxd[k]),
                .rst (1'b0)
            );
        end
    endgenerate

    EG_LOGIC_IDDR #(
        .ASYNCRST ("ENABLE"),
        .PIPEMODE ("PIPED")
    ) u_rx_ctl_ddr (
        .q0  (gmii_rx_dv),
        .q1  (ctl_er),
        .clk (rx_clk),
        .d   (rgmii_rx_ctl),
        .rst (1'b0)
    );

    assign gmii_rx_er = gmii_rx_dv ^ ctl_er;

    assign gmii_col = (gmii_tx_en | gmii_tx_er) & (gmii_rx_dv | gmii_rx_er);
    assign gmii_crs = (gmii_tx_en | gmii_tx_er) | (gmii_rx_dv | gmii_rx_er);
endmodule
