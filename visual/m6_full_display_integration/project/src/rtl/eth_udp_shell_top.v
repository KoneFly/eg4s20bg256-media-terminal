`timescale 1ns / 1ps

// task_052 v7 第一步：国一 UDP/IP + TEMAC/RGMII 空壳。
// 收到任意 UDP 载荷后原样回发；PCM 应用层在下一步接入。
module eth_udp_shell_top #(
    parameter DEVICE = "EG4",
    parameter LOCAL_UDP_PORT = 16'h1773,
    parameter LOCAL_IP = 32'hc0a8f002,
    parameter LOCAL_MAC = 48'h02_00_00_52_56_01,
    parameter REMOTE_UDP_PORT = 16'h1773,
    parameter REMOTE_IP = 32'hc0a8f001
) (
    input  wire       clk_50,
    input  wire       key1,
    input  wire       key2,
    input  wire       key3,
    input  wire       phy1_rgmii_rx_clk,
    input  wire       phy1_rgmii_rx_ctl,
    input  wire [3:0] phy1_rgmii_rx_data,
    output wire       phy1_rgmii_tx_clk,
    output wire       phy1_rgmii_tx_ctl,
    output wire [3:0] phy1_rgmii_tx_data,
    output wire [3:0] led,
    output wire [15:0] dled
);
    wire reset_reg;
    wire reset;
    wire app_rst_n;
    wire clk_125;
    wire clk_125_90;
    wire clk_12_5;
    wire clk_1_25;
    wire clk_25;
    wire udp_clk;
    wire temac_clk;
    wire temac_clk90;
    wire rx_clk;
    wire rx_clk_en;
    wire tx_clk;
    wire tx_clk_en;
    wire [1:0] tri_speed;

    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_good;
    wire rx_bad;
    wire [7:0] tx_data;
    wire tx_valid;
    wire tx_ready;
    wire tx_collision;
    wire tx_retransmit;

    wire udp_tx_ready;
    wire udp_tx_ack;
    wire udp_tx_request;
    wire udp_tx_data_valid;
    wire [7:0] udp_tx_data;
    wire [15:0] udp_tx_length;
    wire udp_rx_data_valid;
    wire [7:0] udp_rx_data;
    wire [15:0] udp_rx_length;
    wire [15:0] udp_rx_port;
    wire temac_rx_ready;
    wire temac_rx_valid_n;
    wire [7:0] temac_rx_data;
    wire temac_rx_sof_n;
    wire temac_rx_eof_n;
    wire temac_tx_ready;
    wire temac_tx_valid_n;
    wire [7:0] temac_tx_data;
    wire temac_tx_sof_n;
    wire temac_tx_eof_n;
    wire link_status;
    wire [1:0] clock_speed;
    wire duplex_status;
    wire [19:0] mac_cfg_vector;
    wire [47:0] unicast_address;
    wire [26:0] rx_status_vector;
    wire rx_status_vld;
    wire [28:0] tx_status_vector;
    wire tx_status_vld;
    wire mdio_o;
    wire mdio_oen;
    wire mdio_clk;
    reg [15:0] rx_packets;
    reg rx_seen;
    reg tx_seen;
    reg error_seen;

    assign reset = (~key1) | reset_reg;
    assign app_rst_n = ~reset;
    assign tri_speed = 2'b10;
    assign mac_cfg_vector = {1'b0, 2'b00, tri_speed, 8'b00000010, 7'b0000010};
    assign unicast_address = {LOCAL_MAC[7:0], LOCAL_MAC[15:8], LOCAL_MAC[23:16],
                              LOCAL_MAC[31:24], LOCAL_MAC[39:32], LOCAL_MAC[47:40]};
    assign led = {error_seen, tx_seen, rx_seen, link_status};
    assign dled = rx_packets;

    clk_gen_rst_gen #(.DEVICE(DEVICE)) u_clk_gen (
        .reset(~key1), .clk_in(clk_50), .rst_out(reset_reg),
        .clk_125_out0(temac_clk), .clk_125_out1(clk_125),
        .clk_125_out2(temac_clk90), .clk_12_5_out(clk_12_5),
        .clk_1_25_out(clk_1_25), .clk_25_out(clk_25)
    );

    // 应用栈通过国一客户端 FIFO 与 TEMAC 125MHz 域隔离。空壳业务速率很低，
    // 使用板载 50MHz 应用时钟为 ARP/IP/UDP 组合路径留下充分时序余量；
    // TEMAC/RGMII 物理侧仍固定为千兆 125MHz。
    assign udp_clk = clk_50;

    v7_udp_echo u_echo (
        .clk(udp_clk), .rst_n(app_rst_n),
        .app_rx_data_valid(udp_rx_data_valid), .app_rx_data(udp_rx_data),
        .app_rx_data_length(udp_rx_length), .app_tx_ack(udp_tx_ack),
        .app_tx_data_request(udp_tx_request), .app_tx_data_valid(udp_tx_data_valid),
        .app_tx_data(udp_tx_data), .udp_data_length(udp_tx_length)
    );

    udp_ip_protocol_stack #(
        .DEVICE(DEVICE), .LOCAL_UDP_PORT_NUM(LOCAL_UDP_PORT),
        .LOCAL_IP_ADDRESS(LOCAL_IP), .LOCAL_MAC_ADDRESS(LOCAL_MAC)
    ) u_udp_stack (
        .udp_rx_clk(udp_clk), .udp_tx_clk(udp_clk), .reset(reset),
        .input_local_udp_port_num(LOCAL_UDP_PORT),
        .input_local_udp_port_num_valid(1'b0),
        .udp2app_tx_ready(udp_tx_ready), .udp2app_tx_ack(udp_tx_ack),
        .app_tx_request(udp_tx_request), .app_tx_data_valid(udp_tx_data_valid),
        .app_tx_data(udp_tx_data), .app_tx_data_length(udp_tx_length),
        .app_tx_dst_port(REMOTE_UDP_PORT), .ip_tx_dst_address(REMOTE_IP),
        .input_local_ip_address(LOCAL_IP), .input_local_ip_address_valid(1'b0),
        .app_rx_data_valid(udp_rx_data_valid), .app_rx_data(udp_rx_data),
        .app_rx_data_length(udp_rx_length), .app_rx_port_num(udp_rx_port),
        .temac_rx_ready(temac_rx_ready), .temac_rx_valid(temac_rx_valid_n),
        .temac_rx_data(temac_rx_data), .temac_rx_sof(temac_rx_sof_n),
        .temac_rx_eof(temac_rx_eof_n), .temac_tx_ready(temac_tx_ready),
        .temac_tx_valid(temac_tx_valid_n), .temac_tx_data(temac_tx_data),
        .temac_tx_sof(temac_tx_sof_n), .temac_tx_eof(temac_tx_eof_n),
        .ip_rx_error(), .arp_request_no_reply_error()
    );

    temac_block #(.DEVICE(DEVICE)) u_temac (
        .reset(reset), .gtx_clk(temac_clk), .gtx_clk_90(temac_clk90),
        .rx_clk(rx_clk), .rx_clk_en(rx_clk_en), .rx_data(rx_data),
        .rx_data_valid(rx_valid), .rx_correct_frame(rx_good),
        .rx_error_frame(rx_bad), .rx_status_vector(rx_status_vector),
        .rx_status_vld(rx_status_vld), .tx_clk(tx_clk), .tx_clk_en(tx_clk_en),
        .tx_data(tx_data), .tx_data_en(tx_valid), .tx_rdy(tx_ready),
        .tx_stop(1'b0), .tx_collision(tx_collision), .tx_retransmit(tx_retransmit),
        .tx_ifg_val(8'd0), .tx_status_vector(tx_status_vector),
        .tx_status_vld(tx_status_vld), .tri_speed(), .pause_req(1'b0),
        .pause_val(16'd0), .pause_source_addr(48'd0),
        .unicast_address(unicast_address), .mac_cfg_vector(mac_cfg_vector),
        .rgmii_txd(phy1_rgmii_tx_data), .rgmii_tx_ctl(phy1_rgmii_tx_ctl),
        .rgmii_txc(phy1_rgmii_tx_clk), .rgmii_rxd(phy1_rgmii_rx_data),
        .rgmii_rx_ctl(phy1_rgmii_rx_ctl), .rgmii_rxc(phy1_rgmii_rx_clk),
        .inband_link_status(link_status), .inband_clock_speed(clock_speed),
        .inband_duplex_status(duplex_status), .mdio_i(1'b1), .mdio_o(mdio_o),
        .mdio_oen(mdio_oen), .mdio_clk(mdio_clk)
    );

    tx_client_fifo #(.DEVICE(DEVICE)) u_tx_fifo (
        .rd_clk(tx_clk), .rd_sreset(reset), .rd_enable(tx_clk_en),
        .tx_data(tx_data), .tx_data_valid(tx_valid), .tx_ack(tx_ready),
        .tx_collision(tx_collision), .tx_retransmit(tx_retransmit), .overflow(),
        .wr_clk(udp_clk), .wr_sreset(reset), .wr_data(temac_tx_data),
        .wr_sof_n(temac_tx_sof_n), .wr_eof_n(temac_tx_eof_n),
        .wr_src_rdy_n(temac_tx_valid_n), .wr_dst_rdy_n(temac_tx_ready), .wr_fifo_status()
    );

    rx_client_fifo #(.DEVICE(DEVICE)) u_rx_fifo (
        .wr_clk(rx_clk), .wr_enable(rx_clk_en), .wr_sreset(reset),
        .rx_data(rx_data), .rx_data_valid(rx_valid), .rx_good_frame(rx_good),
        .rx_bad_frame(rx_bad), .overflow(), .rd_clk(udp_clk), .rd_sreset(reset),
        .rd_data_out(temac_rx_data), .rd_sof_n(temac_rx_sof_n),
        .rd_eof_n(temac_rx_eof_n), .rd_src_rdy_n(temac_rx_valid_n),
        .rd_dst_rdy_n(temac_rx_ready), .rx_fifo_status()
    );

    always @(posedge udp_clk or negedge app_rst_n) begin
        if (!app_rst_n) begin
            rx_packets <= 16'd0;
            rx_seen <= 1'b0;
            tx_seen <= 1'b0;
            error_seen <= 1'b0;
        end else begin
            if (udp_rx_data_valid && !rx_seen) begin
                rx_seen <= 1'b1;
                rx_packets <= rx_packets + 1'b1;
            end
            if (udp_tx_data_valid) tx_seen <= 1'b1;
            if (rx_bad || tx_collision || tx_retransmit) error_seen <= 1'b1;
            if (!udp_rx_data_valid && !udp_tx_data_valid) rx_seen <= 1'b0;
        end
    end
endmodule
