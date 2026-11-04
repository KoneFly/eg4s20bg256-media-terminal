`timescale 1ns / 1ps
// 50MHz单时钟四路共享I2S接收器：BCLK/LRCK仅作输出，不用作内部逻辑时钟。
// 8/65次每系统拍翻转BCLK，使半周期为8/9拍、64个BCLK周期恰为1040系统拍。
module i2s_mic4_rx_50m (
    input  wire        clk_50m,
    input  wire        rst_n,
    input  wire [3:0]  mic_sd,
    output reg         mic_bclk,
    output reg         mic_lrck,
    output reg         pcm_valid,
    output reg  [15:0] pcm0,
    output reg  [15:0] pcm1,
    output reg  [15:0] pcm2,
    output reg  [15:0] pcm3,
    output wire        pcm_capture_event
);
    (* async_reg = "true" *) reg [3:0] mic_sd_meta;
    (* async_reg = "true" *) reg [3:0] mic_sd_sync;
    reg [6:0] edge_phase;
    reg [5:0] slot_rise_index;
    reg       lrck_pending;
    reg       first_left_seen;
    reg [14:0] shift0, shift1, shift2, shift3;

    wire [6:0] edge_sum = edge_phase + 7'd8;
    wire [6:0] edge_remainder = edge_sum - 7'd65;
    wire [15:0] next0 = {shift0, mic_sd_sync[0]};
    wire [15:0] next1 = {shift1, mic_sd_sync[1]};
    wire [15:0] next2 = {shift2, mic_sd_sync[2]};
    wire [15:0] next3 = {shift3, mic_sd_sync[3]};

    // 本拍将提交完整样本的使能预告，供清窗安全判定使用；不改变采样逻辑。
    assign pcm_capture_event = rst_n && edge_sum >= 7'd65 && !mic_bclk &&
        !mic_lrck && slot_rise_index == 6'd16 && first_left_seen;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            mic_sd_meta     <= 4'd0;
            mic_sd_sync     <= 4'd0;
            edge_phase      <= 7'd0;
            mic_bclk        <= 1'b0;
            mic_lrck        <= 1'b1;
            slot_rise_index <= 6'd0;
            lrck_pending    <= 1'b0;
            first_left_seen <= 1'b0;
            shift0          <= 15'd0;
            shift1          <= 15'd0;
            shift2          <= 15'd0;
            shift3          <= 15'd0;
            pcm_valid       <= 1'b0;
            pcm0            <= 16'd0;
            pcm1            <= 16'd0;
            pcm2            <= 16'd0;
            pcm3            <= 16'd0;
        end else begin
            mic_sd_meta <= mic_sd;
            mic_sd_sync <= mic_sd_meta;
            pcm_valid <= 1'b0;

            if (edge_sum >= 7'd65) begin
                edge_phase <= edge_remainder;
                mic_bclk <= ~mic_bclk;
                if (!mic_bclk) begin
                    // 同步采样两级器之后的SD；采样事件仍是clk_50m时钟使能。
                    if (slot_rise_index == 6'd0) begin
                        slot_rise_index <= 6'd1;
                    end else if (slot_rise_index <= 6'd16) begin
                        if (!mic_lrck) begin
                            shift0 <= next0[14:0];
                            shift1 <= next1[14:0];
                            shift2 <= next2[14:0];
                            shift3 <= next3[14:0];
                            if (slot_rise_index == 6'd16) begin
                                if (first_left_seen) begin
                                    pcm0 <= next0;
                                    pcm1 <= next1;
                                    pcm2 <= next2;
                                    pcm3 <= next3;
                                    pcm_valid <= 1'b1;
                                end else begin
                                    first_left_seen <= 1'b1;
                                end
                            end
                        end
                        slot_rise_index <= slot_rise_index + 6'd1;
                    end else if (slot_rise_index < 6'd31) begin
                        // 忽略24-bit PCM低8位与槽尾7位填充，只保留高16位。
                        slot_rise_index <= slot_rise_index + 6'd1;
                    end else begin
                        lrck_pending <= 1'b1;
                    end
                end else if (lrck_pending) begin
                    // 每32个BCLK上升沿切换一个左右槽，在BCLK下降沿更新WS。
                    mic_lrck <= ~mic_lrck;
                    slot_rise_index <= 6'd0;
                    lrck_pending <= 1'b0;
                end
            end else begin
                edge_phase <= edge_sum;
            end
        end
    end
endmodule
