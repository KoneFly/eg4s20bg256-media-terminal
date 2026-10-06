`timescale 1ns/1ps
// 时间项先记入索引，行尾统一补长度；正文通过保持到确认的写口送CTRL缓存。
module lrc_index_builder(
    input wire clk,input wire rst,input wire start,input wire cancel,
    input wire time_valid,input wire [31:0] time_samples,output wire time_ready,
    input wire character_valid,input wire [7:0] character,output wire character_ready,
    input wire line_done,output wire line_ready,
    output wire [7:0] index_address,output wire [2:0] index_mask,output wire [53:0] index_data,
    output wire text_request,output wire [12:0] text_address,output wire [7:0] text_data,input wire text_ack,
    output reg [8:0] count,output reg overflow,output wire busy
);
    localparam [2:0] IDLE=0,TIME_WRITE=1,TEXT_WRITE=2,LINE_WRITE=3,LINE_ACK=4;
    reg [2:0] state;
    reg [13:0] text_position;
    reg [12:0] line_start;
    reg [8:0] line_first,walk_index;
    reg [6:0] length,last_ink;
    reg line_open;
    assign time_ready=state==TIME_WRITE && !cancel;
    assign character_ready=state==TEXT_WRITE && text_ack && !cancel;
    assign line_ready=state==LINE_ACK && !cancel;
    assign text_request=state==TEXT_WRITE && !cancel;
    assign text_address=text_position[12:0];assign text_data=character;
    assign index_address=(state==LINE_WRITE)?walk_index[7:0]:count[7:0];
    assign index_mask=(!rst && !cancel)?(state==TIME_WRITE?3'b111:state==LINE_WRITE?3'b100:3'b000):3'b000;
    assign index_data={2'd0,(state==LINE_WRITE?last_ink:7'd0),line_start,time_samples};
    assign busy=state!=IDLE;
    always @(posedge clk or posedge rst)begin
        if(rst)begin
            state<=IDLE;text_position<=0;line_start<=0;
            line_first<=0;walk_index<=0;length<=0;last_ink<=0;line_open<=0;count<=0;overflow<=0;
        end else if(start || cancel)begin
            state<=IDLE;text_position<=0;line_start<=0;
            line_first<=0;walk_index<=0;length<=0;last_ink<=0;line_open<=0;count<=0;overflow<=0;
        end else case(state)
            IDLE:if(!overflow)begin
                if(time_valid)begin
                    if(count>=9'd256)overflow<=1;
                    else begin
                        if(!line_open)begin
                            line_start<=text_position[12:0];line_first<=count;length<=0;last_ink<=0;line_open<=1;
                        end
                        state<=TIME_WRITE;
                    end
                end else if(character_valid)begin
                    if(length>=7'd127 || text_position>=14'd8192 || !line_open)overflow<=1;
                    else state<=TEXT_WRITE;
                end else if(line_done)begin walk_index<=line_first;state<=line_open?LINE_WRITE:LINE_ACK;end
            end
            TIME_WRITE:begin count<=count+9'd1;state<=IDLE;end
            TEXT_WRITE:if(text_ack)begin
                text_position<=text_position+14'd1;length<=length+7'd1;
                if(character!=8'h20)last_ink<=length+7'd1;
                state<=IDLE;
            end
            LINE_WRITE:if(walk_index+9'd1>=count)state<=LINE_ACK;else walk_index<=walk_index+9'd1;
            LINE_ACK:begin line_open<=0;length<=0;last_ink<=0;state<=IDLE;end
            default:state<=IDLE;
        endcase
    end
endmodule
