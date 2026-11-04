`timescale 1ns/1ps
// 同一R10 BCLK/LRCK下发送同索引pair：左槽RAW，右槽POST。
// 所有状态均由50MHz驱动，BCLK只作边沿使能，不作为内部时钟。
module audio_i2s_stereo_tx_r12(
    input  wire               clk_50m,
    input  wire               rst_n,
    input  wire               mic_bclk,
    input  wire               mic_lrck,
    input  wire               mic_pair_valid,
    input  wire signed [15:0] mic_pair_raw,
    input  wire signed [15:0] mic_pair_filtered,
    output reg                audio_din,
    output reg                pair_overrun
);
    reg bclk_q,lrck_q;
    reg [5:0] slot_rises;
    reg pending_valid,frame_valid;
    reg signed [15:0] pending_raw,pending_post;
    reg [15:0] left_shift,right_shift;

    wire bclk_rise=!bclk_q&&mic_bclk;
    wire bclk_fall=bclk_q&&!mic_bclk;
    wire lrck_changed=lrck_q!=mic_lrck;
    wire frame_start=bclk_fall&&lrck_q&&!mic_lrck;

    always @(posedge clk_50m or negedge rst_n) begin
        if(!rst_n)begin
            bclk_q<=1'b0;
            lrck_q<=1'b1;
            slot_rises<=6'd0;
            pending_valid<=1'b0;
            frame_valid<=1'b0;
            pending_raw<=16'sd0;
            pending_post<=16'sd0;
            left_shift<=16'd0;
            right_shift<=16'd0;
            audio_din<=1'b0;
            pair_overrun<=1'b0;
        end else begin
            bclk_q<=mic_bclk;
            lrck_q<=mic_lrck;

            // R->L WS切换是新帧边界。先消费旧pair；同拍新pair留给下一帧。
            if(frame_start)begin
                slot_rises<=6'd0;
                audio_din<=1'b0;
                if(pending_valid)begin
                    left_shift<=pending_raw;
                    right_shift<=pending_post;
                    frame_valid<=1'b1;
                end else begin
                    left_shift<=16'd0;
                    right_shift<=16'd0;
                    frame_valid<=1'b0;
                end
                pending_valid<=1'b0;
            end else if(bclk_fall)begin
                if(lrck_changed)begin
                    // I2S在WS切换后的一个BCLK沿输出延迟位。
                    slot_rises<=6'd0;
                    audio_din<=1'b0;
                end else if(slot_rises>=6'd1&&slot_rises<=6'd16)begin
                    if(frame_valid)begin
                        if(!mic_lrck)begin
                            audio_din<=left_shift[15];
                            left_shift<={left_shift[14:0],1'b0};
                        end else begin
                            audio_din<=right_shift[15];
                            right_shift<={right_shift[14:0],1'b0};
                        end
                    end else audio_din<=1'b0;
                end else audio_din<=1'b0;
            end

            if(bclk_rise&&slot_rises<6'd32)
                slot_rises<=slot_rises+6'd1;

            if(mic_pair_valid)begin
                if(pending_valid&&!frame_start)begin
                    // 单pair待发缓冲契约违例只置诊断位，不扩成FIFO。
                    pair_overrun<=1'b1;
                end else begin
                    pending_raw<=mic_pair_raw;
                    pending_post<=mic_pair_filtered;
                    pending_valid<=1'b1;
                end
            end
        end
    end
endmodule
