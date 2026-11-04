`timescale 1ns / 1ps
// hdmi_out：将已对齐的像素与音频接口连接到HDMI发送IP；VIC=1，输出640×480扫描时序。
module hdmi_out (
    input  wire        pixel_clk,
    input  wire        serial_clk,
    input  wire        rst,             // 像素域高有效
    input  wire        rst_phy,         // PHY 专用复位副本(释放时刻与 rst 相同)
    input  wire        i_vs,            // 负极性
    input  wire        i_de,
    input  wire [15:0] i_rgb565,
    output wire        video_locked,
    input  wire        audio_valid,
    input  wire [23:0] audio_left,
    input  wire [23:0] audio_right,
    input  wire        acr_valid,
    input  wire [19:0] acr_cts,
    input  wire [19:0] acr_n,

    output wire        HDMI_CLK_P,
    output wire        HDMI_D0_P,
    output wire        HDMI_D1_P,
    output wire        HDMI_D2_P,
    output wire        HDMI_DDC_SCL,
    inout  wire        HDMI_DDC_SDA
);
    // EDID 启动读取: 复位释放后约 4ms 触发一次
    reg [19:0] edid_cnt;
    wire edid_trig = (edid_cnt == 20'd100000);
    always @(posedge pixel_clk or posedge rst)
        if (rst) edid_cnt <= 20'd0;
        else if (edid_cnt < 20'd100000) edid_cnt <= edid_cnt + 20'd1;

    // AXIS 帧首 / 行尾标记(输入已与像素同拍)
    reg [9:0] col;
    reg       sof_pend, de_d;
    always @(posedge pixel_clk or posedge rst) begin
        if (rst) begin col <= 10'd0; sof_pend <= 1'b0; de_d <= 1'b0; end
        else begin
            de_d <= i_de;
            if (!i_vs) sof_pend <= 1'b1;
            else if (i_de) sof_pend <= 1'b0;
            col <= i_de ? col + 10'd1 : 10'd0;
        end
    end
    wire axis_user = i_de && sof_pend;
    wire axis_last = i_de && (col == 10'd639);

    // RGB565 -> RGB888(位复制), 组合送出与 valid 同拍
    wire [23:0] rgb888 = {i_rgb565[15:11], i_rgb565[15:13],
                          i_rgb565[10:5],  i_rgb565[10:9],
                          i_rgb565[4:0],   i_rgb565[4:2]};

    wire [9:0] tmds0, tmds1, tmds2, tmdsc;
    wire       axis_ready, edid_valid, ddc_scl;
    wire [7:0] edid_data;

    hdmi_1_4b_transmitter_core_wrapper #(
        .DEVICE("EG"), .HTOTAL(800), .HSA(96), .HFP(16), .HBP(48), .HACTIVE(640),
        .VTOTAL(525), .VSA(2), .VFP(10), .VBP(33), .VACTIVE(480),
        .VIDEO_TPG("Disable"), .VIDEO_FORMAT("RGB"), .VIDEO_VIC(1),
        .AUDIO_SAMPLE_RATE("48K"), .IIC_SCL_DIV(250)
    ) u_ip (
        .I_pixel_clk(pixel_clk), .I_rst(rst),
        .I_edid_read_trig(edid_trig), .O_edid_read_valid(edid_valid), .O_edid_read_data(edid_data),
        .I_axis_s_user(axis_user), .I_axis_s_valid(i_de), .I_axis_s_last(axis_last),
        .I_axis_s_data(rgb888), .O_axis_s_ready(axis_ready),
        .I_audio_valid(audio_valid), .I_audio_left_data(audio_left), .I_audio_right_data(audio_right),
        .I_acr_valid(acr_valid), .I_acr_cts(acr_cts), .I_acr_n(acr_n),
        .O_video_locked(video_locked), .O_ddc_scl(ddc_scl), .IO_ddc_sda(HDMI_DDC_SDA),
        .O_ch0_tmds_data(tmds0), .O_ch1_tmds_data(tmds1), .O_ch2_tmds_data(tmds2),
        .O_clk_tmds_data(tmdsc));
    assign HDMI_DDC_SCL = ddc_scl;

    // PHY 复位在本模块内再寄存一级(像素域): 顶层副本可放在任意位置(到本级有整拍
    // 预算), 本级驱动串化器复位端的走线短, 像素→串行时钟 7.9ns 的恢复检查不受布局影响。
    // 释放只延后 1 个像素拍, 断言仍为异步。
    (* preserve = "true" *) reg rst_phy_l;
    always @(posedge pixel_clk or posedge rst_phy)
        if (rst_phy) rst_phy_l <= 1'b1; else rst_phy_l <= 1'b0;

    hdmi_phy_wrapper #(.DEVICE("EG")) u_phy (
        .I_pixel_clk(pixel_clk), .I_serial_clk(serial_clk), .I_rst(rst_phy_l),
        .I_tmds_channel_0(tmds0), .I_tmds_channel_1(tmds1), .I_tmds_channel_2(tmds2),
        .I_tmds_channel_clk(tmdsc),
        .O_tmds_ch0_p(HDMI_D0_P), .O_tmds_ch1_p(HDMI_D1_P), .O_tmds_ch2_p(HDMI_D2_P),
        .O_tmds_clk_p(HDMI_CLK_P));
endmodule
