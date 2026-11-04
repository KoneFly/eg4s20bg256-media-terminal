`timescale 1ns/1ps
// LINT ONLY: 六个基线IP边界桩；不验证协议/加密IP/FIFO/PHY内部。
module udp_ip_protocol_stack #(parameter DEVICE="EG4",parameter LOCAL_UDP_PORT_NUM=16'd6003,
    parameter LOCAL_IP_ADDRESS=32'hc0a8f001,parameter LOCAL_MAC_ADDRESS=48'h020000524d01) (
    input wire udp_rx_clk,udp_tx_clk,reset,input wire [15:0] input_local_udp_port_num,
    input wire input_local_udp_port_num_valid,output wire udp2app_tx_ready,udp2app_tx_ack,
    input wire app_tx_request,app_tx_data_valid,input wire [7:0] app_tx_data,
    input wire [15:0] app_tx_data_length,output wire app_rx_data_valid,output wire [7:0] app_rx_data,
    output wire [15:0] app_rx_data_length,app_rx_port_num,input wire [15:0] app_tx_dst_port,
    input wire [31:0] ip_tx_dst_address,input_local_ip_address,input wire input_local_ip_address_valid,
    output wire temac_rx_ready,input wire temac_rx_valid,input wire [7:0] temac_rx_data,
    input wire temac_rx_sof,temac_rx_eof,temac_tx_ready,output wire temac_tx_valid,
    output wire [7:0] temac_tx_data,output wire temac_tx_sof,temac_tx_eof,ip_rx_error,arp_request_no_reply_error);
    assign udp2app_tx_ready=!reset;assign udp2app_tx_ack=app_tx_request&&!reset;
    assign app_rx_data_valid=0;assign app_rx_data=0;assign app_rx_data_length=0;assign app_rx_port_num=0;
    assign temac_rx_ready=0;assign temac_tx_valid=1;assign temac_tx_data=0;
    assign temac_tx_sof=1;assign temac_tx_eof=1;assign ip_rx_error=0;assign arp_request_no_reply_error=0;
endmodule
module tx_client_fifo #(parameter DEVICE="EG4") (
    input wire rd_clk,rd_sreset,rd_enable,output wire [7:0] tx_data,output wire tx_data_valid,
    input wire tx_ack,tx_collision,tx_retransmit,output wire overflow,
    input wire wr_clk,wr_sreset,input wire [7:0] wr_data,input wire wr_sof_n,wr_eof_n,wr_src_rdy_n,
    output wire wr_dst_rdy_n,output wire [3:0] wr_fifo_status);
    assign tx_data=0;assign tx_data_valid=0;assign overflow=0;assign wr_dst_rdy_n=0;assign wr_fifo_status=0;
endmodule
module rx_client_fifo #(parameter DEVICE="EG4") (
    input wire rd_clk,rd_sreset,output wire [7:0] rd_data_out,output wire rd_sof_n,rd_eof_n,rd_src_rdy_n,
    input wire rd_dst_rdy_n,output wire [3:0] rx_fifo_status,input wire wr_clk,wr_sreset,wr_enable,
    input wire [7:0] rx_data,input wire rx_data_valid,rx_good_frame,rx_bad_frame,output wire overflow);
    assign rd_data_out=0;assign rd_sof_n=1;assign rd_eof_n=1;
    assign rd_src_rdy_n=1'b1;
    assign rx_fifo_status=0;assign overflow=0;
endmodule
module temac_block #(parameter DEVICE="EG4") (
    input wire reset,gtx_clk,gtx_clk_90,output wire rx_clk,rx_clk_en,output wire [7:0] rx_data,
    output wire rx_data_valid,rx_correct_frame,rx_error_frame,output wire [26:0] rx_status_vector,
    output wire rx_status_vld,tx_clk,tx_clk_en,input wire [7:0] tx_data,input wire tx_data_en,
    output wire tx_rdy,input wire tx_stop,output wire tx_collision,tx_retransmit,input wire [7:0] tx_ifg_val,
    output wire [28:0] tx_status_vector,output wire tx_status_vld,output wire [1:0] tri_speed,
    input wire pause_req,input wire [15:0] pause_val,input wire [47:0] pause_source_addr,unicast_address,
    input wire [19:0] mac_cfg_vector,output wire [3:0] rgmii_txd,output wire rgmii_tx_ctl,rgmii_txc,
    input wire [3:0] rgmii_rxd,input wire rgmii_rx_ctl,rgmii_rxc,output wire inband_link_status,
    output wire [1:0] inband_clock_speed,output wire inband_duplex_status,input wire mdio_i,
    output wire mdio_o,mdio_oen,mdio_clk);
    assign rx_clk=rgmii_rxc;assign tx_clk=gtx_clk;assign rx_clk_en=1;assign tx_clk_en=1;
    assign rx_data=0;assign rx_data_valid=0;assign rx_correct_frame=0;assign rx_error_frame=0;
    assign rx_status_vector=0;assign rx_status_vld=0;assign tx_rdy=1;assign tx_collision=0;
    assign tx_retransmit=0;assign tx_status_vector=0;assign tx_status_vld=0;assign tri_speed=2;
    assign rgmii_txd=0;assign rgmii_tx_ctl=0;assign rgmii_txc=gtx_clk;assign inband_link_status=0;
    assign inband_clock_speed=0;assign inband_duplex_status=0;assign mdio_o=0;assign mdio_oen=1;assign mdio_clk=0;
endmodule


module hdmi_1_4b_transmitter_core_wrapper#(
    parameter DEVICE            = "EG", //"EF2","EF3","EF4","SF1","SF2","EG","PH1A","PH1P","DR1","PH2A"

    parameter HTOTAL            = 2200,
    parameter HSA               = 44,
    parameter HFP               = 88,
    parameter HBP               = 148,
    parameter HACTIVE           = 1920,
    parameter VTOTAL            = 1125,
    parameter VSA               = 5,
    parameter VFP               = 4,
    parameter VBP               = 36,
    parameter VACTIVE           = 1080,

    parameter VIDEO_TPG         = "Enable",
    parameter VIDEO_FORMAT      = "RGB",
    parameter VIDEO_VIC         = 16,

    parameter AUDIO_SAMPLE_RATE = "48K",

    parameter IIC_SCL_DIV       = 125
)(
    input wire       I_pixel_clk,
    input wire       I_rst,

    /*
        edid read interface 
    */
    input wire       I_edid_read_trig,
    output wire      O_edid_read_valid,
    output wire[7:0] O_edid_read_data,

    /*
        video interface 
    */
    input wire       I_axis_s_user,
    input wire       I_axis_s_valid,
    input wire       I_axis_s_last,
    input wire[23:0] I_axis_s_data,
    output wire      O_axis_s_ready,

    /*
        audio interface 
    */
    input wire       I_audio_valid,     
    input wire[23:0] I_audio_left_data, 
    input wire[23:0] I_audio_right_data,

    /*
        audio regenaration interface
    */
    input wire       I_acr_valid,
    input wire[19:0] I_acr_cts,
    input wire[19:0] I_acr_n,

    /*
        status signal
    */
    output wire      O_video_locked,

    /*
        DDC channel interface
    */
    output wire      O_ddc_scl,
    inout wire       IO_ddc_sda,

    /*
        tmds data interface 
    */
    output wire[9:0] O_ch0_tmds_data,
    output wire[9:0] O_ch1_tmds_data,
    output wire[9:0] O_ch2_tmds_data,
    output wire[9:0] O_clk_tmds_data
);


    integer columns=0,rows=0,frames=0,pixels=0;
    assign O_axis_s_ready=1'b1;
    assign O_video_locked=!I_rst;
    assign O_ddc_scl=1'b1;
    assign IO_ddc_sda=1'bz;
    assign O_edid_read_valid=0;assign O_edid_read_data=0;
    assign O_ch0_tmds_data=0;assign O_ch1_tmds_data=0;assign O_ch2_tmds_data=0;assign O_clk_tmds_data=0;
    always @(posedge I_pixel_clk) if(!I_rst && I_axis_s_valid)begin
        if(I_axis_s_user!==((rows==0)&&(columns==0)))$fatal(1,"HDMI SOF错误");
        if(I_axis_s_last!==(columns==639))$fatal(1,"HDMI EOL错误");
        pixels++;
        if(columns==639)begin columns=0;if(rows==479)begin rows=0;frames++;end else rows++;end else columns++;
    end
endmodule
module hdmi_phy_wrapper #(parameter DEVICE="EG")(input wire I_pixel_clk,I_serial_clk,I_rst,
    input wire [9:0] I_tmds_channel_0,I_tmds_channel_1,I_tmds_channel_2,I_tmds_channel_clk,
    output wire O_tmds_ch0_p,O_tmds_ch1_p,O_tmds_ch2_p,O_tmds_clk_p);
    assign O_tmds_ch0_p=0;assign O_tmds_ch1_p=0;assign O_tmds_ch2_p=0;assign O_tmds_clk_p=I_pixel_clk;
endmodule