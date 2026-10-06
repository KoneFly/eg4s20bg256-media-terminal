`timescale 1ns/1ps
// pixel域离线解析与排序；原始/压缩正文共用缓存，压缩写口逐字节握手。
module lrc_parser_engine(
    input wire clk,input wire rst,input wire start,input wire cancel,input wire [13:0] size,
    output wire [12:0] raw_address,input wire [7:0] raw_data,
    output wire text_request,output wire [12:0] text_address,output wire [7:0] text_data,input wire text_ack,
    output wire [7:0] index_address,output wire [7:0] sort_address_b,output wire sorting,output wire [2:0] index_mask,output wire [53:0] index_data,input wire [53:0] index_q,input wire [53:0] index_q_b,
    output wire [8:0] count,output reg done,output reg valid,output reg bad_format,output wire busy
);
    localparam [3:0] IDLE=0,START=1,FETCH=2,READ_WAIT=3,SEND=4,DRAIN=5,SORT_START=6,SORT=7,FINISH=8;
    reg [3:0] state;
    reg [13:0] position;
    reg [7:0] byte_data;
    reg last_byte;
    wire token_ready,time_valid,char_valid,line_done,token_finish,token_bad,builder_busy,builder_overflow;
    wire [31:0] time_samples;wire [7:0] character;
    wire time_ready,char_ready,line_ready;
    wire [7:0] build_address,sort_address;wire [2:0] build_mask;wire sort_we;wire [53:0] build_data,sort_data;
    wire sort_done,sort_bad,sort_busy;
    wire local_cancel=cancel || builder_overflow || token_bad || bad_format;
    assign raw_address=position[12:0];assign busy=state!=IDLE || sort_busy;
    lrc_tokenizer tokens(.clk(clk),.rst(rst),.start(state==START),.cancel(local_cancel),
        .in_valid(state==SEND),.in_byte(byte_data),.in_last(last_byte),.in_ready(token_ready),
        .timestamp_valid(time_valid),.timestamp_samples(time_samples),.timestamp_ready(time_ready),
        .character_valid(char_valid),.character(character),.character_ready(char_ready),
        .line_done(line_done),.line_ready(line_ready),.finish(token_finish),.bad_format(token_bad));
    lrc_index_builder builder(.clk(clk),.rst(rst),.start(state==START),.cancel(cancel || bad_format),
        .time_valid(time_valid),.time_samples(time_samples),.time_ready(time_ready),
        .character_valid(char_valid),.character(character),.character_ready(char_ready),
        .line_done(line_done),.line_ready(line_ready),
        .index_address(build_address),.index_mask(build_mask),.index_data(build_data),
        .text_request(text_request),.text_address(text_address),.text_data(text_data),.text_ack(text_ack),
        .count(count),.overflow(builder_overflow),.busy(builder_busy));
    lrc_index_sorter sorter(.clk(clk),.rst(rst),.start(state==SORT_START),.cancel(cancel),.count(count),
        .address(sort_address),.address_b(sort_address_b),.write_enable(sort_we),.write_data(sort_data),.read_data(index_q),.read_data_b(index_q_b),
        .done(sort_done),.bad_limit(sort_bad),.busy(sort_busy));
    assign index_address=(state==SORT_START || state==SORT)?sort_address:build_address;
    assign sorting=state==SORT_START || state==SORT;
    assign index_mask=local_cancel?3'b000:state==SORT?(sort_we?3'b111:3'b000):build_mask;
    assign index_data=(state==SORT)?sort_data:build_data;
    always @(posedge clk or posedge rst)begin
        if(rst)begin state<=IDLE;position<=0;byte_data<=0;last_byte<=0;done<=0;valid<=0;bad_format<=0;end
        else if(cancel)begin state<=IDLE;done<=0;valid<=0;bad_format<=0;end
        else begin
            done<=0;
            if((builder_overflow || token_bad) && state!=IDLE && state!=FINISH)begin bad_format<=1;valid<=0;state<=FINISH;end
            else case(state)
                IDLE:if(start)begin
                    position<=0;bad_format<=0;valid<=0;
                    if(size==0 || size>14'd8192)state<=FINISH;else state<=START;
                end
                START:state<=FETCH;
                FETCH:if(token_ready)state<=READ_WAIT;
                READ_WAIT:begin byte_data<=raw_data;last_byte<=position+14'd1>=size;state<=SEND;end
                SEND:if(token_ready)begin position<=position+14'd1;state<=last_byte?DRAIN:FETCH;end
                DRAIN:if(token_finish && !builder_busy)begin
                    if(count==0)state<=FINISH;else state<=SORT_START;
                end
                SORT_START:state<=SORT;
                SORT:if(sort_done)begin valid<=!sort_bad;bad_format<=sort_bad;state<=FINISH;end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
