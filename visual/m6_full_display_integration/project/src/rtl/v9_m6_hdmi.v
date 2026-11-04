`timescale 1ns/1ps
module v9_m6_hdmi (
    input wire clk,rst,ms_tick,rx_valid,input wire [7:0] rx_data,input wire [15:0] rx_length,
    input wire [31:0] expected_epoch,input wire [2:0] page,
    input wire ctrl_clk,mem_clk,ctrl_rst_n,sd_miso,
    output wire sd_dclk,sd_mosi,sd_ncs,output wire [7:0] label_fault_code,
    output wire HDMI_CLK_P,HDMI_D0_P,HDMI_D1_P,HDMI_D2_P,HDMI_DDC_SCL,inout wire HDMI_DDC_SDA,
    output reg [15:0] diagnostic,output wire online,output wire fault
);
    wire pixel_clk,serial_clk,pll_locked;
    wire pixel_arst=rst || !pll_locked;
    reg [1:0] pixel_reset_sync;
    always @(posedge pixel_clk or posedge pixel_arst)
        if(pixel_arst)pixel_reset_sync<=2'b11;else pixel_reset_sync<={pixel_reset_sync[0],1'b0};
    wire pixel_rst=pixel_reset_sync[1];
    hdmi_pll u_pll(.ref_clk(clk),.pll_rst_n(!rst),.pixel_clk(pixel_clk),.serial_clk(serial_clk),.audio_mclk(),.pll_locked(pll_locked));
    wire frame_request,snapshot_done;wire [6:0] energy_addr;wire [7:0] energy_data;
    wire [15:0] good,bad,old_packets,gaps,replaced;
    wire [15:0] display_frames;
    v9_spectrum_snapshot u_snapshot(.clk(clk),.rst(rst),.ms_tick(ms_tick),.rx_valid(rx_valid),.rx_data(rx_data),
        .rx_length(rx_length),.expected_epoch(expected_epoch),.pixel_clk(pixel_clk),.pixel_rst(pixel_rst),
        .frame_request(frame_request),.energy_addr(energy_addr),.energy_data(energy_data),.snapshot_done(snapshot_done),
        .good(good),.bad(bad),.old_packets(old_packets),.gaps(gaps),.replaced(replaced),.online(online));
    wire de,vs;wire [15:0] rgb;
    wire label_ready,rd_req_valid,rd_req_ready,rd_beat_valid,rd_done;
    wire [20:0] rd_req_addr,rd_beat_addr;
    wire [31:0] rd_beat_data,pixel_data;
    wire pixel_take,pixel_valid,pixel_ready;
    wire [7:0] store_error,stream_error,scan_error;
    fdi_label_store u_label_store(.clk(ctrl_clk),.mem_clk(mem_clk),.rst_n(ctrl_rst_n),
        .sd_miso(sd_miso),.sd_dclk(sd_dclk),.sd_mosi(sd_mosi),.sd_ncs(sd_ncs),
        .label_ready(label_ready),.error_code(store_error),.rd_req_valid(rd_req_valid),
        .rd_req_addr(rd_req_addr),.rd_req_ready(rd_req_ready),.rd_beat_valid(rd_beat_valid),
        .rd_beat_data(rd_beat_data),.rd_beat_addr(rd_beat_addr),.rd_done(rd_done));
    fdi_label_stream u_label_stream(.clk(ctrl_clk),.rst_n(ctrl_rst_n),.label_ready(label_ready),
        .rd_req_valid(rd_req_valid),.rd_req_addr(rd_req_addr),.rd_req_ready(rd_req_ready),
        .rd_beat_valid(rd_beat_valid),.rd_beat_data(rd_beat_data),.rd_beat_addr(rd_beat_addr),.rd_done(rd_done),
        .pixel_clk(pixel_clk),.pixel_rst(pixel_rst),.pixel_take(pixel_take),
        .pixel_data(pixel_data),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),.error_code(stream_error));
    v9_m6_scan u_scan(.clk(pixel_clk),.rst(pixel_rst),.snapshot_done(snapshot_done),.energy_data(energy_data),
        .ctrl_clk(ctrl_clk),.ctrl_rst_n(ctrl_rst_n),.label_ready(label_ready),.pixel_ready(pixel_ready),
        .pixel_data(pixel_data),.pixel_valid(pixel_valid),.pixel_take(pixel_take),.error_code(scan_error),
        .frame_request(frame_request),.energy_addr(energy_addr),.video_de(de),.video_vs(vs),.video_rgb(rgb),.display_frames(display_frames));
    wire [7:0] fault_code_async=(store_error!=0) ? store_error : (stream_error!=0) ? stream_error : scan_error;
    (* ASYNC_REG="TRUE" *) reg [7:0] fault_code_meta,fault_code_sync;
    always @(posedge clk)if(rst)begin fault_code_meta<=0;fault_code_sync<=0;end
        else begin fault_code_meta<=fault_code_async;fault_code_sync<=fault_code_meta;end
    assign label_fault_code=fault_code_sync;
    wire axis_ready,axis_valid,axis_last,axis_user;
    wire [23:0] axis_data;
    wire [23:0] rgb888={rgb[15:11],rgb[15:13],rgb[10:5],rgb[10:9],rgb[4:0],rgb[4:2]};
    axis_pixel_adapter u_axis(.I_clk(pixel_clk),.I_rst(pixel_rst),.I_vs(vs),.I_de(de),.pixel_valid(de),
        .pixel_rgb888(rgb888),.axis_s_ready(axis_ready),.axis_s_user(axis_user),.axis_s_valid(axis_valid),.axis_s_last(axis_last),.axis_s_data(axis_data));
    reg [16:0] edid_count;
    always @(posedge pixel_clk)if(pixel_rst)edid_count<=0;else if(edid_count<100000)edid_count<=edid_count+1'b1;
    wire edid_trigger=edid_count==99999;
    wire video_locked;
    wire [9:0] ch0,ch1,ch2,chclk;
    hdmi_1_4b_transmitter_core_wrapper #(.DEVICE("EG"),.HTOTAL(800),.HSA(96),.HFP(16),.HBP(48),.HACTIVE(640),
        .VTOTAL(525),.VSA(2),.VFP(10),.VBP(33),.VACTIVE(480),.VIDEO_TPG("Disable"),.VIDEO_FORMAT("RGB"),.VIDEO_VIC(1),
        .AUDIO_SAMPLE_RATE("48K"),.IIC_SCL_DIV(250)) u_hdmi(
        .I_pixel_clk(pixel_clk),.I_rst(pixel_rst),.I_edid_read_trig(edid_trigger),.O_edid_read_valid(),.O_edid_read_data(),
        .I_axis_s_user(axis_user),.I_axis_s_valid(axis_valid),.I_axis_s_last(axis_last),.I_axis_s_data(axis_data),.O_axis_s_ready(axis_ready),
        .I_audio_valid(1'b0),.I_audio_left_data(24'd0),.I_audio_right_data(24'd0),.I_acr_valid(1'b0),.I_acr_cts(20'd0),.I_acr_n(20'd0),
        .O_video_locked(video_locked),.O_ddc_scl(HDMI_DDC_SCL),.IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(ch0),.O_ch1_tmds_data(ch1),.O_ch2_tmds_data(ch2),.O_clk_tmds_data(chclk));
    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy(.I_pixel_clk(pixel_clk),.I_serial_clk(serial_clk),.I_rst(pixel_rst),
        .I_tmds_channel_0(ch0),.I_tmds_channel_1(ch1),.I_tmds_channel_2(ch2),.I_tmds_channel_clk(chclk),
        .O_tmds_ch0_p(HDMI_D0_P),.O_tmds_ch1_p(HDMI_D1_P),.O_tmds_ch2_p(HDMI_D2_P),.O_tmds_clk_p(HDMI_CLK_P));
    (* ASYNC_REG="TRUE" *) reg locked_meta,locked_sync;
    always @(posedge clk)if(rst)begin locked_meta<=0;locked_sync<=0;end else begin locked_meta<=video_locked;locked_sync<=locked_meta;end
    assign fault=(bad!=0);
    always @(*)case(page)
        0:diagnostic=good;
        1:diagnostic={15'd0,locked_sync};
        2:diagnostic=bad;
        3:diagnostic=old_packets;
        4:diagnostic=gaps;
        5:diagnostic=replaced;
        6:diagnostic={15'd0,online};
        default:diagnostic=16'd5401;
    endcase
endmodule
