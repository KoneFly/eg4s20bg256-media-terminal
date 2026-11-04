`timescale 1ns/1ps
// t072_audio_select：媒体源跨域后稳定选择。备用样本由输入端提供，当前顶层接零PCM；视频欠载保持媒体来源身份，不切换到备用源。
module t072_audio_select(
    input wire pixel_clk,pixel_rst,
    input wire mode_video_async,has_audio_async,play_en,
    input wire media_valid,input wire [15:0] media_pcm,
    input wire tone_valid,input wire [23:0] tone_left,tone_right,
    output wire frame_valid,output wire [23:0] frame_left,frame_right,
    output wire [3:0] source_token,output wire media_selected
);
    (* async_reg="true" *) reg [1:0] mode_meta,mode_sync;
    reg [1:0] mode_previous,mode_committed;
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin mode_meta<=0;mode_sync<=0;mode_previous<=0;mode_committed<=0;end
        else begin
            mode_meta<={mode_video_async,has_audio_async};mode_sync<=mode_meta;
            mode_previous<=mode_sync;
            if(mode_sync==mode_previous)mode_committed<=mode_sync;
        end
    end
    assign media_selected=&mode_committed;
    assign source_token=media_selected ? 4'h2 : 4'h1;
    assign frame_valid=play_en&&(media_selected ? media_valid : tone_valid);
    assign frame_left=media_selected ? {media_pcm,8'd0} : tone_left;
    assign frame_right=media_selected ? {media_pcm,8'd0} : tone_right;
endmodule
