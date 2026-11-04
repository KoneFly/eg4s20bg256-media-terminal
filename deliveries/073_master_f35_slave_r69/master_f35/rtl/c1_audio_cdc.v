`timescale 1ns/1ps
// 32×16 Gray FIFO；中断后停止写入、排尽旧段、确认清除，再等待32个B点样本。
module c1_audio_cdc(
    input wire pixel_clk,ctrl_clk,pixel_rst_n,ctrl_rst_n,
    input wire audio_valid,input wire [15:0] audio_data,input wire [3:0] source_token,
    input wire sample_ready,output reg sample_valid,output reg [15:0] sample_data,
    output reg discontinuity,output reg [15:0] overflow_count
);
    (* ram_style="bram" *) reg [15:0] memory[0:31];
    reg [5:0] wp,wg,rp,rg;
    (* preserve="true" *) reg [5:0] rg0,rg1,wg0,wg1;
    reg request,ack;
    (* preserve="true" *) reg [1:0] req_sync,ack_sync;
    reg [3:0] source0,source1,source_previous;
    reg [5:0] quarantine;
    reg rearm;
    reg [2:0] drain_wait;
    reg ctrl_alive,pixel_alive;
    reg [3:0] ctrl_boot,pixel_boot;
    reg [1:0] ca_sync,pa_sync;
    wire full=wg=={~rg1[5:4],rg1[3:0]};
    wire empty=rg==wg1;
    wire source_changed=source1!=source_previous;
    wire take=audio_valid&&!request&&!rearm&&quarantine==0&&!full&&ca_sync[1]&&!source_changed;
    wire pop=!empty&&(req_sync[1]||!pa_sync[1]||(ctrl_alive&&(!sample_valid||sample_ready)));
    always @(posedge pixel_clk) if(take) memory[wp[4:0]]<=audio_data;
    always @(posedge ctrl_clk) if(pop) sample_data<=memory[rp[4:0]];
    always @(posedge pixel_clk or negedge pixel_rst_n) begin
        if(!pixel_rst_n) begin
            wp<=0;wg<=0;rg0<=0;rg1<=0;request<=1;ack_sync<=0;
            source0<=0;source1<=0;source_previous<=0;quarantine<=32;rearm<=0;
            ca_sync<=0;pixel_alive<=0;pixel_boot<=0;overflow_count<=0;
        end else begin
            rg0<=rg;rg1<=rg0;ack_sync<={ack_sync[0],ack};ca_sync<={ca_sync[0],ctrl_alive};
            source0<=source_token;source1<=source0;source_previous<=source1;
            if(pixel_boot!=4'd8) pixel_boot<=pixel_boot+4'd1;else pixel_alive<=1;
            if(take) begin wp<=wp+6'd1;wg<=((wp+6'd1)>>1)^(wp+6'd1);end
            if(audio_valid&&quarantine!=0) quarantine<=quarantine-6'd1;
            if(source_changed||!ca_sync[1]||(audio_valid&&full&&!request&&!rearm)) begin
                request<=1;quarantine<=32;
                if(audio_valid&&full&&!request&&!rearm) overflow_count<=overflow_count+16'd1;
            end else if(request&&ack_sync[1]) begin request<=0;rearm<=1;end
            else if(rearm&&!ack_sync[1]) rearm<=0;
        end
    end
    always @(posedge ctrl_clk or negedge ctrl_rst_n) begin
        if(!ctrl_rst_n) begin
            rp<=0;rg<=0;wg0<=0;wg1<=0;req_sync<=0;ack<=0;sample_valid<=0;
            discontinuity<=0;drain_wait<=0;ctrl_alive<=0;ctrl_boot<=0;pa_sync<=0;
        end else begin
            wg0<=wg;wg1<=wg0;req_sync<={req_sync[0],request};pa_sync<={pa_sync[0],pixel_alive};
            if(ctrl_boot!=4'd8) ctrl_boot<=ctrl_boot+4'd1;else ctrl_alive<=1;
            if(req_sync[1]||!pa_sync[1]||!ctrl_alive) sample_valid<=0;
            else if(pop) sample_valid<=1;
            else if(sample_ready) sample_valid<=0;
            discontinuity<=req_sync[1]&&!ack&&drain_wait==0;
            if(pop) begin rp<=rp+6'd1;rg<=((rp+6'd1)>>1)^(rp+6'd1);end
            if(req_sync[1]) begin
                if(empty) begin
                    if(drain_wait==3'd4) ack<=1;else drain_wait<=drain_wait+3'd1;
                end else drain_wait<=1;
            end else begin ack<=0;drain_wait<=0;end
        end
    end
endmodule
