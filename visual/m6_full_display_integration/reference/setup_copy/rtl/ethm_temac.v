`timescale 1 ns / 10 ps
//------------------------------------------------------------------------------
// 官方 EG_LOGIC_TEMAC(TEMAC_2.0, TRI/FD/CFG_VEC, EG4S20BG256)薄封装。
// IP 以官方例程生成的门级网表 TEMAC_CORE_gate.v 形式只读引用(见 BASELINE_MANIFEST),
// 参数取网表内建默认值: P_TRI_SPEED=1 P_HALF_DUPLEX=0 P_HOST_EN=0
//                          P_ADD_FILT_EN=1 P_ADD_FILT_LIST=0 P_SPEED_1000=0
// 本封装固定千兆: tx_clk_en/rx_clk_en/gmii_tx_clken 恒 1(三速中 1G 的使能占空)。
// mac_cfg_vector[19:0] 位域沿用官方例程口径:
//   [19]    地址过滤模式      1'b0
//   [18:17] 流控配置          2'b00
//   [16:15] 速度配置          2'b10 = 1000Mbps
//   [14:7]  接收器配置        8'h02
//   [6:0]   发送器配置        7'h02
//------------------------------------------------------------------------------
module ethm_temac (
    input  wire        reset,

    input  wire        tx_mac_clk,
    input  wire        rx_mac_clk,

    // 客户端发送流(应用侧, tx_mac_clk 域)
    input  wire [7:0]  app_tx_data,
    input  wire        app_tx_data_en,
    output wire        app_tx_rdy,
    output wire        app_tx_retransmit,
    output wire        app_tx_collision,

    // 客户端接收流(应用侧, rx_mac_clk 域)
    output wire [7:0]  app_rx_data,
    output wire        app_rx_data_vld,
    output wire        app_rx_correct_frame,
    output wire        app_rx_error_frame,

    // GMII 侧(与 ethm_rgmii_tx/rx 对接)
    output wire [7:0]  gmii_txd,
    output wire        gmii_tx_en,
    output wire        gmii_tx_er,
    input  wire [7:0]  gmii_rxd,
    input  wire        gmii_rx_dv,
    input  wire        gmii_rx_er,
    input  wire        gmii_crs,
    input  wire        gmii_col,

    // 本板单播地址, 位[7:0]=线上第一个字节(与官方例程的字节反转约定一致)
    input  wire [47:0] local_mac_rev,

    output wire        speed_1000
);
    wire [19:0] mac_cfg_vector;
    wire [7:0]  tx_ifg_val;
    wire        pause_req;
    wire [15:0] pause_val;
    wire [47:0] pause_source_addr;
    wire        tx_stop;

    assign mac_cfg_vector     = {1'b0, 2'b00, 2'b10, 8'h02, 7'h02};
    assign tx_ifg_val         = 8'h00;
    assign pause_req          = 1'b0;
    assign pause_val          = 16'h0000;
    assign pause_source_addr  = 48'h5af1_f2f3_f4f5;
    assign tx_stop            = 1'b0;

    /* 未使用的输出(GMII 之外的状态总线/AXI 从口/MDIO 主机)有意不接线:
        本包只用客户端字节流与 MDIO 输入恒 1。 */
    /* verilator lint_off PINMISSING */
    TEMAC_CORE u_temac_core (
        .reset               (reset),
        .tx_mac_clk          (tx_mac_clk),
        .rx_mac_clk          (rx_mac_clk),
        .speed_1000          (speed_1000),

        .tx_clk_en           (1'b1),
        .tx_data             (app_tx_data),
        .tx_data_en          (app_tx_data_en),
        .tx_rdy              (app_tx_rdy),
        .tx_stop             (tx_stop),
        .tx_retransmit       (app_tx_retransmit),
        .tx_collision        (app_tx_collision),
        .tx_ifg_val          (tx_ifg_val),

        .rx_clk_en           (1'b1),
        .rx_data             (app_rx_data),
        .rx_data_vld         (app_rx_data_vld),
        .rx_correct_frame    (app_rx_correct_frame),
        .rx_error_frame      (app_rx_error_frame),

        .pause_req           (pause_req),
        .pause_val           (pause_val),
        .pause_source_addr   (pause_source_addr),
        .unicast_addr        (local_mac_rev),
        .mac_cfg_vector      (mac_cfg_vector),

        .gmii_tx_clken       (1'b1),
        .gmii_txd            (gmii_txd),
        .gmii_tx_en          (gmii_tx_en),
        .gmii_tx_er          (gmii_tx_er),
        .gmii_rxd            (gmii_rxd),
        .gmii_rx_vld         (gmii_rx_dv),
        .gmii_rx_er          (gmii_rx_er),
        .gmii_col            (gmii_col),
        .gmii_crs            (gmii_crs),

        .s_axi_aclk          (1'b0),
        .s_axi_awaddr        (8'd0),
        .s_axi_awvalid       (1'b0),
        .s_axi_wdata         (32'd0),
        .s_axi_wvalid        (1'b0),
        .s_axi_bready        (1'b0),
        .s_axi_araddr        (8'd0),
        .s_axi_arvalid       (1'b0),
        .s_axi_rready        (1'b0),

        .mdio_in             (1'b1)
    );
    /* verilator lint_on PINMISSING */
endmodule
