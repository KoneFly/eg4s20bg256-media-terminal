module eth_udp_m6_master_top #(
    parameter [31:0] LOCAL_IP = 32'hC0A8F001,
    parameter [31:0] REMOTE_IP = 32'hC0A8F002,
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_52_4D_01,
    parameter [47:0] REMOTE_MAC = 48'h02_00_00_52_56_01,
    parameter [7:0] PKT_TYPE = 8'd1,
    parameter [16:0] PACE_NORMAL = 17'd48000,
    parameter [16:0] PACE_BOOST = 17'd60000,
    parameter [31:0] DELIV_REV = 32'h0520_0607
) (
    input wire clk_50, input wire key1, input wire key2, input wire key3, input wire [3:0] sw,
    input wire sd_miso, output wire sd_dclk, sd_mosi, sd_ncs,
    input wire phy1_rgmii_rx_clk, input wire phy1_rgmii_rx_ctl,
    input wire [3:0] phy1_rgmii_rx_data,
    output wire phy1_rgmii_tx_clk, output wire phy1_rgmii_tx_ctl,
    output wire [3:0] phy1_rgmii_tx_data,
    output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P,HDMI_DDC_SCL, inout wire HDMI_DDC_SDA,
    output wire [3:0] led, output wire [15:0] dled
);
    reg [15:0] ms_cnt; reg ms_tick;
    wire tx_fifo_overflow;
    wire reset_reg;
    wire reset;
    assign reset = ~key1 | reset_reg;
    wire ctrl_clk, mem_clk;
    wire ctrl_arst=reset;
    reg [1:0] ctrl_reset_sync;
    always @(posedge ctrl_clk or posedge ctrl_arst)
        if(ctrl_arst)ctrl_reset_sync<=2'b11;else ctrl_reset_sync<={ctrl_reset_sync[0],1'b0};
    wire ctrl_rst_n=!ctrl_reset_sync[1];
    wire temac_clk, temac_clk90, udp_clk;
    assign udp_clk = clk_50;
    wire [1:0] tri_speed;
    wire [19:0] mac_cfg;
    wire [47:0] mac_rev;
    assign tri_speed = 2'b10;
    assign mac_cfg = {1'b0,2'b00,tri_speed,8'b00000010,7'b0000010};
    assign mac_rev = {LOCAL_MAC[7:0],LOCAL_MAC[15:8],LOCAL_MAC[23:16],LOCAL_MAC[31:24],LOCAL_MAC[39:32],LOCAL_MAC[47:40]};
    fdi_clock_tree u_clk(.reset(~key1),.clk_in(clk_50),.rst_out(reset_reg),
        .clk_125(temac_clk),.clk_125_90(temac_clk90),.ctrl_clk(ctrl_clk),.mem_clk(mem_clk));

    wire udp_tx_ready, udp_tx_ack, app_tx_req, app_tx_valid;
    wire [7:0] app_tx_data; wire [15:0] app_tx_len;
    wire app_rx_valid; wire [7:0] app_rx_data; wire [15:0] app_rx_len;
    wire ip_error_raw, arp_error_raw;
    // RX FIFO 的 valid 为低有效；同版国一栈入口要求取反。SOF/EOF仍保持原极性。
    wire temac_rx_ready, temac_rx_valid, temac_tx_ready, temac_tx_valid;
    wire [7:0] temac_rx_data, temac_tx_data; wire temac_rx_sof, temac_rx_eof, temac_tx_sof, temac_tx_eof;
    udp_ip_protocol_stack #(.DEVICE("EG4"),.LOCAL_UDP_PORT_NUM(16'd6003),.LOCAL_IP_ADDRESS(LOCAL_IP),.LOCAL_MAC_ADDRESS(LOCAL_MAC)) u_udp (
        .udp_rx_clk(udp_clk),.udp_tx_clk(udp_clk),.reset(reset),.input_local_udp_port_num(16'd6003),.input_local_udp_port_num_valid(1'b0),
        .udp2app_tx_ready(udp_tx_ready),.udp2app_tx_ack(udp_tx_ack),.app_tx_request(app_tx_req),.app_tx_data_valid(app_tx_valid),.app_tx_data(app_tx_data),.app_tx_data_length(app_tx_len),.app_tx_dst_port(16'd6003),.ip_tx_dst_address(REMOTE_IP),.input_local_ip_address(LOCAL_IP),.input_local_ip_address_valid(1'b0),.app_rx_data_valid(app_rx_valid),.app_rx_data(app_rx_data),.app_rx_data_length(app_rx_len),.app_rx_port_num(),.temac_rx_ready(temac_rx_ready),.temac_rx_valid(!temac_rx_valid),.temac_rx_data(temac_rx_data),.temac_rx_sof(temac_rx_sof),.temac_rx_eof(temac_rx_eof),.temac_tx_ready(temac_tx_ready),.temac_tx_valid(temac_tx_valid),.temac_tx_data(temac_tx_data),.temac_tx_sof(temac_tx_sof),.temac_tx_eof(temac_tx_eof),.ip_rx_error(ip_error_raw),.arp_request_no_reply_error(arp_error_raw));

    wire rx_clk, rx_clk_en, tx_clk, tx_clk_en, rx_valid, rx_good, rx_bad, tx_ready, tx_collision, tx_retransmit, tx_valid;
    wire inband_link_status;
    wire [1:0] inband_clock_speed;
    wire inband_duplex_status;
    wire [7:0] rx_data, tx_data; wire [26:0] rx_status; wire [28:0] tx_status;
    temac_block #(.DEVICE("EG4")) u_temac(.reset(reset),.gtx_clk(temac_clk),.gtx_clk_90(temac_clk90),.rx_clk(rx_clk),.rx_clk_en(rx_clk_en),.rx_data(rx_data),.rx_data_valid(rx_valid),.rx_correct_frame(rx_good),.rx_error_frame(rx_bad),.rx_status_vector(rx_status),.rx_status_vld(),.tx_clk(tx_clk),.tx_clk_en(tx_clk_en),.tx_data(tx_data),.tx_data_en(tx_valid),.tx_rdy(tx_ready),.tx_stop(1'b0),.tx_collision(tx_collision),.tx_retransmit(tx_retransmit),.tx_ifg_val(8'd0),.tx_status_vector(tx_status),.tx_status_vld(),.tri_speed(),.pause_req(1'b0),.pause_val(16'd0),.pause_source_addr(48'd0),.unicast_address(mac_rev),.mac_cfg_vector(mac_cfg),.rgmii_txd(phy1_rgmii_tx_data),.rgmii_tx_ctl(phy1_rgmii_tx_ctl),.rgmii_txc(phy1_rgmii_tx_clk),.rgmii_rxd(phy1_rgmii_rx_data),.rgmii_rx_ctl(phy1_rgmii_rx_ctl),.rgmii_rxc(phy1_rgmii_rx_clk),.inband_link_status(inband_link_status),.inband_clock_speed(inband_clock_speed),.inband_duplex_status(inband_duplex_status),.mdio_i(1'b1),.mdio_o(),.mdio_oen(),.mdio_clk());
    (* keep_hierarchy = "true" *) tx_client_fifo #(.DEVICE("EG4")) u_txf(.rd_clk(tx_clk),.rd_sreset(reset),.rd_enable(tx_clk_en),.tx_data(tx_data),.tx_data_valid(tx_valid),.tx_ack(tx_ready),.tx_collision(tx_collision),.tx_retransmit(tx_retransmit),.overflow(tx_fifo_overflow),.wr_clk(udp_clk),.wr_sreset(reset),.wr_data(temac_tx_data),.wr_sof_n(temac_tx_sof),.wr_eof_n(temac_tx_eof),.wr_src_rdy_n(temac_tx_valid),.wr_dst_rdy_n(temac_tx_ready),.wr_fifo_status());
    rx_client_fifo #(.DEVICE("EG4")) u_rxf(.wr_clk(rx_clk),.wr_enable(rx_clk_en),.wr_sreset(reset),.rx_data(rx_data),.rx_data_valid(rx_valid),.rx_good_frame(rx_good),.rx_bad_frame(rx_bad),.overflow(),.rd_clk(udp_clk),.rd_sreset(reset),.rd_data_out(temac_rx_data),.rd_sof_n(temac_rx_sof),.rd_eof_n(temac_rx_eof),.rd_src_rdy_n(temac_rx_valid),.rd_dst_rdy_n(temac_rx_ready),.rx_fifo_status());

    wire [31:0] epoch; wire [31:0] tx_frames; wire tx_overrun;
    wire tx_frame_ready, tx_prepared, tx_active, tx_fault;
    v7_udp_pcm_tx_bridge #(.SRC_MAC(LOCAL_MAC),.DST_MAC(REMOTE_MAC),.PKT_TYPE(PKT_TYPE),.PACE_NORMAL(PACE_NORMAL),.PACE_BOOST(PACE_BOOST)) u_tx(.clk(udp_clk),.rst(reset),.boost(1'b0),.epoch(epoch),.udp_tx_ready(udp_tx_ready),.udp_tx_ack(udp_tx_ack),.udp_tx_request(app_tx_req),.udp_tx_valid(app_tx_valid),.udp_tx_data(app_tx_data),.udp_tx_length(app_tx_len),.tx_frames(tx_frames),.tx_overrun(tx_overrun),.frame_ready_o(tx_frame_ready),.prepared_o(tx_prepared),.active_o(tx_active),.tx_fault(tx_fault));
    wire rec_wr, rec_drop, rec_busy, rec_of, cap_of; wire [31:0] rec_word; wire [9:0] fifo_used;
    wire rec_full, rec_space; wire rec_rd; wire [31:0] rec_data; wire rec_empty; wire [6:0] rec_used;
    ethm_rec_fifo u_rec(.wr_clk(udp_clk),.wr_rst(reset),.wr_en(rec_wr),.wr_data(rec_word),.wr_full(rec_full),.wr_space_ok(rec_space),.rd_clk(udp_clk),.rd_rst(reset),.rd_en(rec_rd),.rd_data(rec_data),.rd_empty(rec_empty),.rd_usedw(rec_used));
    v7_udp_pcm_rx_bridge #(.LOCAL_MAC(LOCAL_MAC),.REMOTE_MAC(REMOTE_MAC)) u_rx(.clk(udp_clk),.rst(reset),.udp_rx_valid(app_rx_valid),.udp_rx_data(app_rx_data),.udp_rx_length(app_rx_len),.rec_wr_en(rec_wr),.rec_space_ok(rec_space),.rec_word(rec_word),.rec_drop(rec_drop),.rec_busy_drop(rec_busy),.rec_of(rec_of),.cap_of(cap_of),.fifo_usedw(fifo_used));
    reg key2_d, key3_d;
    reg [1:0] key2_sync, key3_sync;
    wire clear_pulse = key2_d && !key2_sync[1];
    wire restart_pulse = key3_d && !key3_sync[1];
    always @(posedge udp_clk) begin
        if(reset) begin ms_cnt<=0; ms_tick<=0; key2_d<=1'b1; key3_d<=1'b1; key2_sync<=2'b11; key3_sync<=2'b11; end
        else begin
            key2_sync <= {key2_sync[0], key2};
            key3_sync <= {key3_sync[0], key3};
            key2_d <= key2_sync[1];
            key3_d <= key3_sync[1];
            if(ms_cnt==16'd49999) begin ms_cnt<=0; ms_tick<=1; end else begin ms_cnt<=ms_cnt+1; ms_tick<=0; end
        end
    end
    wire [3:0] rxc_rate_code;
    ethm_rxc_rate u_rate(.rx_clk(rx_clk),.clk(udp_clk),.rx_rst(reset),.tx_rst(reset),.ms_tick(ms_tick),.rate_code(rxc_rate_code));
    wire offline_evt, fft_ready; wire [15:0] dled_i; wire [3:0] led_i;
    ethm_stats #(.DELIV_REV(DELIV_REV),.EXPECT_TYPE((PKT_TYPE == 8'd1) ? 8'd2 : 8'd1)) u_stats(.clk(udp_clk),.rst(reset),.ms_tick(ms_tick),.rec_data(rec_data),.rec_empty(rec_empty),.rec_usedw(rec_used),.rxf_usedw(fifo_used),.rec_rd_en(rec_rd),.rec_drop_evt(rec_drop),.busy_drop_evt(rec_busy),.rec_of_evt(rec_of),.cap_of_evt(cap_of),.tx_pacer_overrun(tx_overrun),.tx_stall_max(16'd0),.tx_frames(tx_frames),.tx_mac_fault(tx_collision|tx_retransmit),.rx_locked(rxc_rate_code!=4'd0),.speed_1000(rxc_rate_code==4'd3),.rxc_rate_code(rxc_rate_code),.force_restart(restart_pulse),.clear_sticky(clear_pulse),.page_sel(sw[3:1]),.flush_done(1'b0),.flush_drop_n(10'd0),.offline_evt(offline_evt),.fft_ready(fft_ready),.epoch(epoch),.dled_val(dled_i),.led(led_i));
    wire [15:0] diag_value;
    wire rx_recent;
    v7_udp_pcm_diag u_diag (
        .clk(udp_clk), .rst(reset), .ms_tick(ms_tick), .page_sel(sw[3:1]),
        .frame_ready(tx_frame_ready), .prepared(tx_prepared), .active(tx_active),
        .ready(udp_tx_ready), .request(app_tx_req), .ack(udp_tx_ack), .tx_valid(app_tx_valid),
        .rx_valid(app_rx_valid), .tx_take(!temac_tx_valid && !temac_tx_ready),
        .tx_sof_n(temac_tx_sof), .rx_take(!temac_rx_valid && !temac_rx_ready),
        .fault(tx_fault | tx_fifo_overflow), .ip_error_raw(ip_error_raw),
        .arp_error_raw(arp_error_raw), .value(diag_value), .rx_recent(rx_recent)
    );
    // LED0只指示最近1秒的原始UDP载荷接收活动，不称PHY链路状态。
    wire [15:0] display_diagnostic;
    wire spectrum_online,spectrum_fault;
    wire [7:0] label_fault_code;
    v9_m6_hdmi u_display(.clk(udp_clk),.rst(reset),.ms_tick(ms_tick),.rx_valid(app_rx_valid),
        .rx_data(app_rx_data),.rx_length(app_rx_len),.expected_epoch(epoch),.page(sw[3:1]),
        .ctrl_clk(ctrl_clk),.mem_clk(mem_clk),.ctrl_rst_n(ctrl_rst_n),
        .sd_miso(sd_miso),.sd_dclk(sd_dclk),.sd_mosi(sd_mosi),.sd_ncs(sd_ncs),.label_fault_code(label_fault_code),
        .HDMI_CLK_P(HDMI_CLK_P),.HDMI_D0_P(HDMI_D0_P),.HDMI_D1_P(HDMI_D1_P),.HDMI_D2_P(HDMI_D2_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL),.HDMI_DDC_SDA(HDMI_DDC_SDA),.diagnostic(display_diagnostic),
        .online(spectrum_online),.fault(spectrum_fault));
    assign led = {!spectrum_online,spectrum_fault || (label_fault_code!=0),spectrum_online,rx_recent};
    wire [15:0] ready_value;
    v7_ready_probe #(.BUILD_CODE(16'd5401)) u_ready_probe (
        .clk(udp_clk), .rst(reset), .ms_tick(ms_tick), .page_sel(sw[3:1]),
        .ready(udp_tx_ready), .request(app_tx_req), .ack(udp_tx_ack),
        .ip_error_raw(ip_error_raw), .arp_error_raw(arp_error_raw), .value(ready_value)
    );
    // SW1改为ready诊断bank选择，调速固定正常档，切页不改变发送行为。
    wire [15:0] display_value = reset ? 16'd60001 :
                               (label_fault_code!=0) ? 16'd60000+{8'd0,label_fault_code} :
                               sw[0] ? ready_value : !key2_sync[1] ? diag_value : display_diagnostic;
    wire [1:0] display_mode = reset ? 2'd3 : sw[0] ? 2'd2 : !key2_sync[1] ? 2'd1 : 2'd0;
    wire [15:0] scan_pins;
    reg [15:0] dled_pins;
    v7_decimal_display u_decimal (
        .clk(clk_50), .rst_n(key1), .value(display_value), .mode(display_mode),
        .page(sw[3:1]), .pins(scan_pins)
    );
    always @(posedge clk_50 or negedge key1) begin
        if(!key1) dled_pins<=16'hffff;
        else dled_pins<=scan_pins;
    end
    assign dled=dled_pins;
endmodule
