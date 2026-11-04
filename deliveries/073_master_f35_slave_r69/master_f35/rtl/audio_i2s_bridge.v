`timescale 1ns / 1ps
// audio_i2s_bridge：并行PCM经I2S发送、官方I2S接收器和ACR逻辑送入HDMI IP。帧FIFO连接像素域与音频域，保持连续音频时钟。
module audio_i2s_bridge #(
    parameter integer PRIME_FRAMES = 8      // 预充帧数(FIFO 深 16, 取半)
)(
    input  wire        I_clk_pixel,   // 25.2MHz
    input  wire        I_clk_mclk,    // 12.3077MHz (= 48076.923Hz × 256)
    input  wire        I_rst,         // 高有效, 两域同源

    // ---- 像素域帧输入(音源 mux 输出; valid 为单拍脉冲) ----
    input  wire        I_frame_valid,
    input  wire [23:0] I_frame_left,
    input  wire [23:0] I_frame_right,

    // ---- 像素域输出 → 加密 IP 音频口 ----
    output wire        O_audio_valid,
    output wire [23:0] O_audio_left_data,
    output wire [23:0] O_audio_right_data,

    // ---- 像素域输出 → 加密 IP ACR 口 ----
    output wire        O_acr_valid,
    output wire [19:0] O_acr_cts,
    output wire [19:0] O_acr_n
);

    // ------------------------------------------------------------------
    // 帧 FIFO: 像素域写 / mclk 域读
    // ------------------------------------------------------------------
    wire        fifo_full;
    wire        fifo_empty;      // mclk 域
    wire        frame_rd;        // mclk 域
    wire [31:0] frame_data;      // mclk 域

    wire        wr_fire = I_frame_valid && !fifo_full;

    // 24bit → 16bit 截位(取高 16 位, 保留二补数符号); i2s_master 内部再
    //   左对齐回 24bit({s16,8'b0}), 故端到端等价于"高 16 位精度"。
    audio_frame_fifo u_frame_fifo (
        .wr_clk  (I_clk_pixel),
        .wr_rst  (I_rst),
        .wr_en   (wr_fire),
        .wr_left (I_frame_left[23:8]),
        .wr_right(I_frame_right[23:8]),
        .full    (fifo_full),
        .rd_clk  (I_clk_mclk),
        .rd_rst  (I_rst),
        .rd_en   (frame_rd),
        .rd_data (frame_data),
        .empty   (fifo_empty)
    );

    // ------------------------------------------------------------------
    // 预充门控
    // ------------------------------------------------------------------
    // mclk 域 empty → 像素域(2FF 电平同步): 排空则清零写计数以重新预充
    reg [1:0] empty_sync;
    always @(posedge I_clk_pixel or posedge I_rst) begin
        if (I_rst) empty_sync <= 2'b11;
        else       empty_sync <= {empty_sync[0], fifo_empty};
    end
    wire empty_p = empty_sync[1];

    reg [4:0] wr_cnt;
    always @(posedge I_clk_pixel or posedge I_rst) begin
        if (I_rst)
            wr_cnt <= 5'd0;
        else if (empty_p)
            wr_cnt <= 5'd0;
        else if (wr_fire && (wr_cnt != 5'd31))
            wr_cnt <= wr_cnt + 5'd1;
    end

    wire primed_req = (wr_cnt >= PRIME_FRAMES[4:0]);

    // 像素域 primed → mclk 域(2FF 电平同步): 放行 i2s_master 取帧
    reg [1:0] primed_sync;
    always @(posedge I_clk_mclk or posedge I_rst) begin
        if (I_rst) primed_sync <= 2'b00;
        else       primed_sync <= {primed_sync[0], primed_req};
    end
    wire primed_m = primed_sync[1];

    // 读侧"取不到帧"= 真空 或 尚未预充完成
    wire frame_starve = fifo_empty || !primed_m;

    // ------------------------------------------------------------------
    // I2S master(mclk 域) → 三线
    // ------------------------------------------------------------------
    wire i2s_bclk, i2s_lrck, i2s_dout;

    i2s_master u_i2s_master (
        .I_mclk       (I_clk_mclk),
        .I_rst        (I_rst),
        .I_frame_data (frame_data),
        .I_frame_empty(frame_starve),
        .O_frame_rd   (frame_rd),
        .O_i2s_BCLK   (i2s_bclk),
        .O_i2s_LRCK   (i2s_lrck),
        .O_i2s_DOUT   (i2s_dout)
    );

    // ------------------------------------------------------------------
    // 官方 I2S_receiver(像素域解串) → audio_valid / L / R
    // ------------------------------------------------------------------
    I2S_receiver u_i2s_rx (
        .I_clk              (I_clk_pixel),
        .I_rst              (I_rst),
        .I_i2s_BCLK         (i2s_bclk),
        .I_i2s_LRCK         (i2s_lrck),
        .I_i2s_DOUT         (i2s_dout),
        .O_audio_valid      (O_audio_valid),
        .O_audio_left_data  (O_audio_left_data),
        .O_audio_right_data (O_audio_right_data)
    );

    // ------------------------------------------------------------------
    // 官方 ACR(像素域, 由实测 audio_valid 节奏反推 CTS)
    // ------------------------------------------------------------------
    audio_arc_calculate #(
        .ACR_N (6144)
    ) u_acr (
        .I_clk         (I_clk_pixel),
        .I_rst         (I_rst),
        .I_audio_valid (O_audio_valid),
        .O_acr_valid   (O_acr_valid),
        .O_acr_cts     (O_acr_cts),
        .O_acr_n       (O_acr_n)
    );

endmodule
