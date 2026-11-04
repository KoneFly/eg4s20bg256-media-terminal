`timescale 1ns/1ps
// PCM16样本 -> 既有av_audio_sink的样本数头与小端PCM字；不新增深FIFO。
module t072_wav_audio_pack(
    input wire clk,rst_n,start,
    input wire header_valid,input wire[31:0] samples_total,
    input wire pcm_valid,input wire[15:0] pcm,output wire pcm_ready,
    output wire out_valid,output wire[31:0] out_data,output wire out_first,input wire out_ready,
    output wire done
);
    localparam[2:0] IDLE=0,HEADER=1,LOW=2,HIGH=3,SEND=4,DONE=5;
    reg[2:0] state;
    reg[31:0] left,word_data;
    reg[15:0] block_left,low_sample;
    reg[1:0] word_samples;
    wire[15:0] block_size=left>=1024 ? 16'd1024 : left[15:0];
    assign out_valid=state==HEADER||state==SEND;
    assign out_first=state==HEADER;
    assign out_data=state==HEADER ? {16'd0,block_size} : word_data;
    assign pcm_ready=state==LOW||state==HIGH;
    assign done=state==DONE;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin state<=IDLE;left<=0;block_left<=0;low_sample<=0;word_data<=0;word_samples<=0;end
        else if(start)begin state<=IDLE;left<=0;block_left<=0;word_samples<=0;end
        else case(state)
            IDLE:if(header_valid)begin left<=samples_total;state<=samples_total==0 ? DONE : HEADER;end
            HEADER:if(out_ready)begin block_left<=block_size;state<=LOW;end
            LOW:if(pcm_valid)begin
                low_sample<=pcm;
                if(block_left==1)begin word_data<={16'd0,pcm};word_samples<=1;state<=SEND;end
                else state<=HIGH;
            end
            HIGH:if(pcm_valid)begin word_data<={pcm,low_sample};word_samples<=2;state<=SEND;end
            SEND:if(out_ready)begin
                left<=left-word_samples;block_left<=block_left-word_samples;
                state<=left==word_samples ? DONE : block_left==word_samples ? HEADER : LOW;
            end
            default:begin end
        endcase
    end
endmodule
