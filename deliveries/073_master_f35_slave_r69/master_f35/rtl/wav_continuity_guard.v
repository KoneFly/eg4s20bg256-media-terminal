`timescale 1ns/1ps
// 仅基于固定数字路径容量的有界守护，不是远端反馈ACK。
// 暖链不消费文件，计数只使用真实桥后B点tick；EOF守护保持原track epoch。
module wav_continuity_guard #(
    parameter integer REMOTE_PREFILL_SAMPLES=1152,
    parameter integer START_SAMPLES=2*REMOTE_PREFILL_SAMPLES,
    parameter integer TAIL_SAMPLES=3*REMOTE_PREFILL_SAMPLES
)(
    input wire pixel_clk,pixel_rst,
    input wire[1:0] owner_identity,
    input wire session_flush,source_drained,bpoint_valid,
    output wire hold_file,output reg tail_done
);
    localparam integer CW=$clog2((START_SAMPLES>TAIL_SAMPLES?START_SAMPLES:TAIL_SAMPLES)+1);
    reg[1:0] previous_owner;
    reg[CW-1:0] warm_left,tail_left;
    reg warming;
    assign hold_file=owner_identity[0]&&warming;
    always @(posedge pixel_clk or posedge pixel_rst)begin
        if(pixel_rst)begin previous_owner<=0;warm_left<=0;tail_left<=TAIL_SAMPLES;warming<=0;tail_done<=0;end
        else begin
            previous_owner<=owner_identity;
            if(!owner_identity[0])begin warm_left<=0;tail_left<=TAIL_SAMPLES;warming<=0;tail_done<=0;end
            else if(owner_identity!=previous_owner)begin warm_left<=START_SAMPLES;tail_left<=TAIL_SAMPLES;warming<=1;tail_done<=0;end
            else begin
                if(warming&&!session_flush&&bpoint_valid)begin
                    if(warm_left==1)begin warm_left<=0;warming<=0;end else warm_left<=warm_left-1'b1;
                end
                if(!source_drained||session_flush)begin tail_left<=TAIL_SAMPLES;tail_done<=0;end
                else if(!warming&&!tail_done&&bpoint_valid)begin
                    if(tail_left==1)begin tail_left<=0;tail_done<=1;end else tail_left<=tail_left-1'b1;
                end
            end
        end
    end
endmodule
