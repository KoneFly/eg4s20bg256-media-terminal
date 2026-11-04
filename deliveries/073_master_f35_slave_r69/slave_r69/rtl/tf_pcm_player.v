`timescale 1ns/1ps
// 接收器已验CRC的144字块，低16位先写；完整288样本后发布，再按本地帧节拍播放。
module tf_pcm_player #(
    parameter [11:0] PREFILL_SAMPLES = 12'd1152
)(
    input wire clk,rst_n,selected,frame_tick,
    input wire block_start,history_reset,word_valid,input wire [31:0] word_data,
    input wire input_fault,
    output reg sample_valid,output reg signed [15:0] sample_data,
    output reg playing,fault,underflow,overflow,
    output wire [11:0] level
);
    (* ram_style="bram" *) reg [15:0] memory [0:2047];
    reg [15:0] read_q,high_q;
    reg [11:0] write_ptr,committed_ptr,read_ptr;
    reg [7:0] received_words;
    reg receiving,high_pending;
    assign level=committed_ptr-read_ptr;
    wire too_full=level>12'd1760;
    wire bad_start=block_start&&(receiving||too_full);
    wire bad_word=word_valid&&receiving&&(high_pending||received_words>=8'd144);
    wire empty_frame=frame_tick&&playing&&level==0;
    wire failure=input_fault||(!history_reset&&(bad_start||bad_word||empty_frame));
    wire write_low=word_valid&&receiving&&!high_pending;
    wire write_high=receiving&&high_pending;
    wire memory_write=rst_n&&selected&&!fault&&!history_reset&&!failure&&(write_low||write_high);
    wire [15:0] write_data=write_high?high_q:word_data[15:0];
    always @(posedge clk)begin
        if(memory_write)memory[write_ptr[10:0]]<=write_data;
        read_q<=memory[read_ptr[10:0]];
    end
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            write_ptr<=0;committed_ptr<=0;read_ptr<=0;received_words<=0;
            receiving<=0;high_pending<=0;high_q<=0;
            sample_valid<=0;sample_data<=0;playing<=0;fault<=0;underflow<=0;overflow<=0;
        end else if(!selected)begin
            write_ptr<=0;committed_ptr<=0;read_ptr<=0;received_words<=0;
            receiving<=0;high_pending<=0;
            sample_valid<=0;sample_data<=0;playing<=0;fault<=0;underflow<=0;overflow<=0;
        end else begin
            sample_valid<=frame_tick;sample_data<=0;
            if(failure||fault)begin
                fault<=1;playing<=0;receiving<=0;high_pending<=0;
                write_ptr<=0;committed_ptr<=0;read_ptr<=0;
                if(empty_frame&&!history_reset)underflow<=1;
                if(block_start&&too_full&&!history_reset)overflow<=1;
            end else if(history_reset)begin
                // 新epoch/不连续段不复用旧缓存；同拍合法块头可以直接启动新段。
                write_ptr<=0;committed_ptr<=0;read_ptr<=0;received_words<=0;
                receiving<=block_start;high_pending<=0;playing<=0;
            end else begin
                if(frame_tick&&(playing||level>=PREFILL_SAMPLES)&&level!=0)begin
                    sample_data<=read_q;read_ptr<=read_ptr+12'd1;playing<=1;
                end
                if(block_start)begin
                    receiving<=1;received_words<=0;high_pending<=0;write_ptr<=committed_ptr;
                end
                if(write_low)begin
                    high_q<=word_data[31:16];high_pending<=1;
                    write_ptr<=write_ptr+12'd1;received_words<=received_words+8'd1;
                end else if(write_high)begin
                    high_pending<=0;write_ptr<=write_ptr+12'd1;
                    if(received_words==8'd144)begin
                        committed_ptr<=write_ptr+12'd1;receiving<=0;
                    end
                end
            end
        end
    end
endmodule
