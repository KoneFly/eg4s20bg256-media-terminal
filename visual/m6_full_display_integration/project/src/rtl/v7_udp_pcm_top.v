`timescale 1 ns / 10 ps

// v7 第二步：UDP 载荷承载既有 PCM 应用帧。
// PCM 模块仍使用 306 字节内部帧格式；UDP 线上只承载去掉 DA/SA/EtherType
// 后的 292 字节。接收侧桥接器补回虚拟二层头，使 ethm_rx_pack 的判定语义不变。

module v7_udp_pcm_tx_bridge #(
    parameter [47:0] SRC_MAC = 48'h02_00_00_52_4D_01,
    parameter [47:0] DST_MAC = 48'h02_00_00_52_56_01,
    parameter [7:0] PKT_TYPE = 8'd1,
    parameter [16:0] PACE_NORMAL = 17'd48000,
    parameter [16:0] PACE_BOOST = 17'd60000
) (
    input wire clk,
    input wire rst,
    input wire boost,
    input wire [31:0] epoch,
    input wire udp_tx_ready,
    input wire udp_tx_ack,
    output wire udp_tx_request,
    output wire udp_tx_valid,
    output wire [7:0] udp_tx_data,
    output wire [15:0] udp_tx_length,
    output wire [31:0] tx_frames,
    output wire tx_overrun,
    output wire frame_ready_o,
    output wire prepared_o,
    output wire active_o,
    output wire tx_fault
);
    wire [9:0] wr_data, rd_data;
    wire [1:0] rd_kind;
    wire wr_en, wr_full, wr_space, wr_ovf;
    wire rd_vld, rd_last, rd_empty, rd_en;
    wire [9:0] rd_usedw;
    wire drain_rdy;
    wire [7:0] drain_data;
    wire drain_valid;
    wire drain_underrun;
    reg capture_active;
    reg payload_ready;
    reg [7:0] payload [0:511];
    wire [8:0] payload_index, payload_prefetch_index;
    reg [7:0] payload_byte;
    wire packet_done, ctrl_busy;
    wire active = capture_active || ctrl_busy;
    reg [8:0] drain_count;
    wire frame_ready = (rd_usedw >= 10'd305) && !capture_active && !payload_ready;
    assign frame_ready_o = frame_ready;
    assign prepared_o = payload_ready;
    assign active_o = active;
    assign tx_fault = drain_underrun | wr_ovf;

    ethm_tx_pack #(
        .FRAME_BYTES(306), .L2_BYTES(14), .PACE_FULL(27'd50_000_000)
    ) u_pack (
        .clk(clk), .rst(rst),
        .pace_step(boost ? PACE_BOOST : PACE_NORMAL), .pkt_type(PKT_TYPE),
        .pkt_flags({15'd0, boost}), .epoch(epoch), .dst_mac(DST_MAC), .src_mac(SRC_MAC),
        .fifo_wr_en(wr_en), .fifo_wr_data(wr_data), .fifo_wr_space(wr_space),
        .fifo_wr_full(wr_full), .frame_done(), .tx_frames(tx_frames),
        .tx_pacer_overrun(tx_overrun), .tx_stall_max(), .tx_seq_now()
    );
    ethm_bafifo #(.SPACE_MIN(320)) u_fifo (
        .wr_clk(clk), .wr_rst(rst), .wr_en(wr_en), .wr_data(wr_data),
        .wr_full(wr_full), .wr_space(wr_space), .wr_ovf(wr_ovf),
        .rd_clk(clk), .rd_rst(rst), .rd_en(rd_en), .rd_data(rd_data),
        .rd_vld(rd_vld), .rd_kind(rd_kind), .rd_last(rd_last),
        .rd_empty(rd_empty), .rd_usedw(rd_usedw)
    );
    ethm_tx_drain u_drain (
        .clk(clk), .rst(rst), .fifo_rd_data(rd_data), .fifo_rd_kind(rd_kind),
        .fifo_rd_vld(rd_vld), .fifo_rd_last(rd_last), .fifo_rd_empty(rd_empty),
        .fifo_rd_usedw(rd_usedw), .fifo_rd_en(rd_en), .app_tx_rdy(drain_rdy),
        .tx_data(drain_data), .tx_data_en(drain_valid), .underrun(drain_underrun)
    );
    // 生产者只准备完整载荷；UDP控制直接采用国一发送控制块。
    assign drain_rdy = capture_active;
    v7_udp_cam_ctrl_pcm u_ctrl (
        .clk(clk), .rst_n(!rst), .packet_ready(payload_ready), .udp_tx_ready(udp_tx_ready),
        .app_tx_ack(udp_tx_ack), .payload_byte(payload_byte), .payload_index(payload_index),
        .payload_prefetch_index(payload_prefetch_index),
        .packet_done(packet_done), .app_tx_data_request(udp_tx_request),
        .app_tx_data_valid(udp_tx_valid), .app_tx_data(udp_tx_data),
        .udp_data_length(udp_tx_length), .busy(ctrl_busy)
    );
    // 512x8同步读写模板；读出口不复位，valid只在完整载荷备好后开启。
    always @(posedge clk) begin
        if (capture_active && drain_valid && (drain_count >= 9'd14))
            payload[drain_count-9'd14] <= drain_data;
        payload_byte <= payload[payload_prefetch_index];
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            capture_active <= 1'b0;
            payload_ready <= 1'b0;
            drain_count <= 9'd0;
        end else begin
            if (packet_done) payload_ready <= 1'b0;
            if (frame_ready) begin capture_active <= 1'b1; drain_count <= 9'd0; end
            if (capture_active && drain_valid) begin
                if (drain_count == 9'd305) begin
                    capture_active <= 1'b0;
                    payload_ready <= 1'b1;
                end else drain_count <= drain_count + 9'd1;
            end
            if (drain_underrun) begin
                capture_active <= 1'b0;
            end
        end
    end
endmodule

module v7_udp_pcm_rx_bridge #(
    parameter [47:0] LOCAL_MAC = 48'h02_00_00_52_56_01,
    parameter [47:0] REMOTE_MAC = 48'h02_00_00_52_4D_01
) (
    input wire clk,
    input wire rst,
    input wire udp_rx_valid,
    input wire [7:0] udp_rx_data,
    input wire [15:0] udp_rx_length,
    output wire rec_wr_en,
    input wire rec_space_ok,
    output wire [31:0] rec_word,
    output wire rec_drop,
    output wire rec_busy_drop,
    output wire rec_of,
    output wire cap_of,
    output wire [9:0] fifo_usedw
);
    reg [7:0] payload [0:291];
    reg [8:0] rx_count;
    reg [2:0] state;
    reg [8:0] out_count;
    reg [15:0] rx_length_hold;
    reg discard_active;
    reg invalid_drop_evt, busy_drop_evt;
    localparam S_IDLE=3'd0, S_CAPTURE=3'd1, S_WRITE=3'd2, S_META=3'd3;
    wire [9:0] fifo_wr_data;
    wire fifo_wr_en, fifo_wr_full, fifo_wr_space, fifo_wr_ovf;
    wire [9:0] fifo_rd_data;
    wire [1:0] fifo_rd_kind;
    wire fifo_rd_vld, fifo_rd_last, fifo_rd_empty, fifo_rd_en;
    wire push_req, push_dropped, busy_dropped, of_evt;
    wire [31:0] push_word;

    wire [7:0] local_b = (out_count < 9'd6) ? LOCAL_MAC[47 - out_count*8 -: 8] :
                         (out_count < 9'd12) ? REMOTE_MAC[47 - (out_count-9'd6)*8 -: 8] :
                         (out_count == 9'd12) ? 8'h88 :
                         (out_count == 9'd13) ? 8'hB5 :
                         payload[out_count-9'd14];
    assign fifo_wr_en = ((state == S_WRITE) || (state == S_META)) && !fifo_wr_full;
    assign fifo_wr_data = (state == S_META) ? {2'b10, 8'h00}
                        : {((out_count == 9'd305) ? 2'b01 : 2'b00), local_b};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            rx_count <= 9'd0;
            out_count <= 9'd0;
            rx_length_hold <= 16'd0;
            discard_active <= 1'b0;
            invalid_drop_evt <= 1'b0;
            busy_drop_evt <= 1'b0;
        end else begin
            invalid_drop_evt <= 1'b0;
            busy_drop_evt <= 1'b0;
            // 忙时到达的整包一直丢到valid落下，不从该包中间重新起帧。
            if (!udp_rx_valid) discard_active <= 1'b0;
            else if ((state == S_WRITE) || (state == S_META)) begin
                discard_active <= 1'b1;
                if (!discard_active) busy_drop_evt <= 1'b1;
            end
            case (state)
                S_IDLE: if (udp_rx_valid && !discard_active) begin
                    payload[0] <= udp_rx_data;
                    rx_count <= 9'd1;
                    rx_length_hold <= udp_rx_length;
                    state <= S_CAPTURE;
                end
                S_CAPTURE: begin
                    if (udp_rx_valid) begin
                        if (rx_count < 9'd292) begin
                            payload[rx_count] <= udp_rx_data;
                            rx_count <= rx_count + 9'd1;
                        end else rx_count <= 9'd293;
                    end else begin
                        if ((rx_count == 9'd292) && (rx_length_hold == 16'd292)) begin
                            out_count <= 9'd0;
                            state <= S_WRITE;
                        end else begin
                            state <= S_IDLE;
                            invalid_drop_evt <= 1'b1;
                        end
                    end
                end
                S_WRITE: if (fifo_wr_en) begin
                    if (out_count == 9'd305) begin
                        state <= S_META;
                    end else out_count <= out_count + 9'd1;
                end
                S_META: if (fifo_wr_en) state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    ethm_bafifo u_fifo (
        .wr_clk(clk), .wr_rst(rst), .wr_en(fifo_wr_en), .wr_data(fifo_wr_data),
        .wr_full(fifo_wr_full), .wr_space(fifo_wr_space), .wr_ovf(fifo_wr_ovf),
        .rd_clk(clk), .rd_rst(rst), .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
        .rd_vld(fifo_rd_vld), .rd_kind(fifo_rd_kind), .rd_last(fifo_rd_last),
        .rd_empty(fifo_rd_empty), .rd_usedw(fifo_usedw)
    );
    ethm_rx_pack u_pack (
        .clk(clk), .rst(rst), .fifo_rd_data(fifo_rd_data), .fifo_rd_kind(fifo_rd_kind),
        .fifo_rd_vld(fifo_rd_vld), .fifo_rd_last(fifo_rd_last), .fifo_rd_empty(fifo_rd_empty),
        .fifo_rd_en(fifo_rd_en), .expect_da(LOCAL_MAC), .push_ready(rec_space_ok),
        .push_req(push_req), .push_word(push_word), .push_dropped(push_dropped),
        .busy_dropped(busy_dropped), .of_evt(of_evt)
    );
    assign rec_wr_en = push_req && rec_space_ok;
    assign rec_word = push_word;
    assign rec_drop = push_dropped | invalid_drop_evt;
    assign rec_busy_drop = busy_dropped | busy_drop_evt;
    assign rec_of = push_req && !rec_space_ok;
    assign cap_of = of_evt | fifo_wr_ovf;
endmodule

module eth_udp_pcm_top #(
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
    input wire phy1_rgmii_rx_clk, input wire phy1_rgmii_rx_ctl,
    input wire [3:0] phy1_rgmii_rx_data,
    output wire phy1_rgmii_tx_clk, output wire phy1_rgmii_tx_ctl,
    output wire [3:0] phy1_rgmii_tx_data,
    output wire [3:0] led, output wire [15:0] dled
);
    wire reset_reg;
    wire reset;
    assign reset = ~key1 | reset_reg;
    wire clk_125, clk_125_90, clk_12_5, clk_1_25, clk_25;
    wire temac_clk, temac_clk90, udp_clk;
    assign udp_clk = clk_50;
    wire [1:0] tri_speed;
    wire [19:0] mac_cfg;
    wire [47:0] mac_rev;
    assign tri_speed = 2'b10;
    assign mac_cfg = {1'b0,2'b00,tri_speed,8'b00000010,7'b0000010};
    assign mac_rev = {LOCAL_MAC[7:0],LOCAL_MAC[15:8],LOCAL_MAC[23:16],LOCAL_MAC[31:24],LOCAL_MAC[39:32],LOCAL_MAC[47:40]};
    clk_gen_rst_gen #(.DEVICE("EG4")) u_clk(.reset(~key1),.clk_in(clk_50),.rst_out(reset_reg),.clk_125_out0(temac_clk),.clk_125_out1(clk_125),.clk_125_out2(temac_clk90),.clk_12_5_out(clk_12_5),.clk_1_25_out(clk_1_25),.clk_25_out(clk_25));

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
    wire tx_frame_ready, tx_prepared, tx_active, tx_fault, tx_fifo_overflow;
    v7_udp_pcm_tx_bridge #(.SRC_MAC(LOCAL_MAC),.DST_MAC(REMOTE_MAC),.PKT_TYPE(PKT_TYPE),.PACE_NORMAL(PACE_NORMAL),.PACE_BOOST(PACE_BOOST)) u_tx(.clk(udp_clk),.rst(reset),.boost(1'b0),.epoch(epoch),.udp_tx_ready(udp_tx_ready),.udp_tx_ack(udp_tx_ack),.udp_tx_request(app_tx_req),.udp_tx_valid(app_tx_valid),.udp_tx_data(app_tx_data),.udp_tx_length(app_tx_len),.tx_frames(tx_frames),.tx_overrun(tx_overrun),.frame_ready_o(tx_frame_ready),.prepared_o(tx_prepared),.active_o(tx_active),.tx_fault(tx_fault));
    wire rec_wr, rec_drop, rec_busy, rec_of, cap_of; wire [31:0] rec_word; wire [9:0] fifo_used;
    wire rec_full, rec_space; wire rec_rd; wire [31:0] rec_data; wire rec_empty; wire [6:0] rec_used;
    ethm_rec_fifo u_rec(.wr_clk(udp_clk),.wr_rst(reset),.wr_en(rec_wr),.wr_data(rec_word),.wr_full(rec_full),.wr_space_ok(rec_space),.rd_clk(udp_clk),.rd_rst(reset),.rd_en(rec_rd),.rd_data(rec_data),.rd_empty(rec_empty),.rd_usedw(rec_used));
    v7_udp_pcm_rx_bridge #(.LOCAL_MAC(LOCAL_MAC),.REMOTE_MAC(REMOTE_MAC)) u_rx(.clk(udp_clk),.rst(reset),.udp_rx_valid(app_rx_valid),.udp_rx_data(app_rx_data),.udp_rx_length(app_rx_len),.rec_wr_en(rec_wr),.rec_space_ok(rec_space),.rec_word(rec_word),.rec_drop(rec_drop),.rec_busy_drop(rec_busy),.rec_of(rec_of),.cap_of(cap_of),.fifo_usedw(fifo_used));
    reg [15:0] ms_cnt; reg ms_tick;
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
    assign led = {led_i[3:1], rx_recent};
    wire [15:0] ready_value;
    v7_ready_probe #(.BUILD_CODE((PKT_TYPE==8'd1) ? 16'd5209 : 16'd5210)) u_ready_probe (
        .clk(udp_clk), .rst(reset), .ms_tick(ms_tick), .page_sel(sw[3:1]),
        .ready(udp_tx_ready), .request(app_tx_req), .ack(udp_tx_ack),
        .ip_error_raw(ip_error_raw), .arp_error_raw(arp_error_raw), .value(ready_value)
    );
    // SW1改为ready诊断bank选择，调速固定正常档，切页不改变发送行为。
    wire [15:0] display_value = reset ? 16'd60001 :
                               sw[0] ? ready_value : !key2_sync[1] ? diag_value : dled_i;
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

module eth_udp_pcm_master_top (
    input wire clk_50,input wire phy1_rgmii_rx_clk,input wire phy1_rgmii_rx_ctl,input wire [3:0] phy1_rgmii_rx_data,output wire phy1_rgmii_tx_clk,output wire phy1_rgmii_tx_ctl,output wire [3:0] phy1_rgmii_tx_data,input wire key1,input wire key2,input wire key3,input wire [3:0] sw,output wire [3:0] led,output wire [15:0] dled);
    eth_udp_pcm_top #(.LOCAL_IP(32'hC0A8F001),.REMOTE_IP(32'hC0A8F002),.LOCAL_MAC(48'h02_00_00_52_4D_01),.REMOTE_MAC(48'h02_00_00_52_56_01),.PKT_TYPE(8'd1),.PACE_NORMAL(17'd48000),.PACE_BOOST(17'd60000),.DELIV_REV(32'h0520_0607)) u(.clk_50(clk_50),.key1(key1),.key2(key2),.key3(key3),.sw(sw),.phy1_rgmii_rx_clk(phy1_rgmii_rx_clk),.phy1_rgmii_rx_ctl(phy1_rgmii_rx_ctl),.phy1_rgmii_rx_data(phy1_rgmii_rx_data),.phy1_rgmii_tx_clk(phy1_rgmii_tx_clk),.phy1_rgmii_tx_ctl(phy1_rgmii_tx_ctl),.phy1_rgmii_tx_data(phy1_rgmii_tx_data),.led(led),.dled(dled));
endmodule

module eth_udp_pcm_slave_top (
    input wire clk_50,input wire phy1_rgmii_rx_clk,input wire phy1_rgmii_rx_ctl,input wire [3:0] phy1_rgmii_rx_data,output wire phy1_rgmii_tx_clk,output wire phy1_rgmii_tx_ctl,output wire [3:0] phy1_rgmii_tx_data,input wire key1,input wire key2,input wire key3,input wire [3:0] sw,output wire [3:0] led,output wire [15:0] dled);
    eth_udp_pcm_top #(.LOCAL_IP(32'hC0A8F002),.REMOTE_IP(32'hC0A8F001),.LOCAL_MAC(48'h02_00_00_52_56_01),.REMOTE_MAC(48'h02_00_00_52_4D_01),.PKT_TYPE(8'd2),.PACE_NORMAL(17'd60),.PACE_BOOST(17'd75),.DELIV_REV(32'h0520_0608)) u(.clk_50(clk_50),.key1(key1),.key2(key2),.key3(key3),.sw(sw),.phy1_rgmii_rx_clk(phy1_rgmii_rx_clk),.phy1_rgmii_rx_ctl(phy1_rgmii_rx_ctl),.phy1_rgmii_rx_data(phy1_rgmii_rx_data),.phy1_rgmii_tx_clk(phy1_rgmii_tx_clk),.phy1_rgmii_tx_ctl(phy1_rgmii_tx_ctl),.phy1_rgmii_tx_data(phy1_rgmii_tx_data),.led(led),.dled(dled));
endmodule
