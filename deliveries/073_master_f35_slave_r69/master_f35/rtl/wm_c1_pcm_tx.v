`timescale 1ns/1ps
// 两个288样本bank。ready bank在尾包snapshot完成前保持只读，CRC随描述符冻结。
module wm_c1_pcm_tx(
    input wire clk,rst_n,flush,discontinuity,sample_valid,input wire [15:0] sample_data,
    output wire sample_ready,output wire serial_data,output wire fault,
    output reg [15:0] sent_blocks,discarded_partial
);
    `include "link062_crc.vh"
    (* ram_style="bram" *) reg [15:0] memory[0:1023];
    reg [15:0] read_q;
    reg [9:0] read_address;
    reg [1:0] bank_ready;
    reg capture_bank,send_bank;
    reg [8:0] capture_index,send_index;
    reg [31:0] epoch,sample_position;
    reg epoch_started;
    reg [31:0] bank_epoch[0:1],bank_first[0:1];
    reg [15:0] bank_crc[0:1],crc,pending_sample;
    reg [1:0] crc_phase;
    reg [3:0] state;
    reg [2:0] slot;
    reg [5:0] packet;
    reg [95:0] tx_data;
    reg [1:0] tx_kind;
    wire tx_ready,packet_fault;
    reg saved_fault;
    assign fault=packet_fault||saved_fault;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)saved_fault<=0;else if(packet_fault)saved_fault<=1;
    end
    wire tx_valid=state==4'd4&&tx_ready;
    wire unused_sync,unused_clock;
    wire [15:0] unused_sent_packets;
    assign sample_ready=!bank_ready[capture_bank]&&crc_phase==0&&!discontinuity&&!fault&&!flush;
    wire take=sample_valid&&sample_ready;
    link062_packet_tx u_packet(.clk(clk),.rst_n(rst_n&&!flush),.valid(tx_valid),.ready(tx_ready),
        .data(tx_data),.kind(tx_kind),.tag(5'd0),.link_data(serial_data),
        .link_sync(unused_sync),.link_clk(unused_clock),.fault(packet_fault),.sent_packets(unused_sent_packets));
    always @(posedge clk) begin
        if(take) memory[{capture_bank,capture_index}]<=sample_data;
        read_q<=memory[read_address];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            bank_ready<=0;capture_bank<=0;send_bank<=0;capture_index<=0;send_index<=0;
            epoch<=0;epoch_started<=0;sample_position<=0;crc<=16'hffff;pending_sample<=0;crc_phase<=0;
            bank_epoch[0]<=0;bank_epoch[1]<=0;bank_first[0]<=0;bank_first[1]<=0;
            bank_crc[0]<=0;bank_crc[1]<=0;state<=0;slot<=0;packet<=0;tx_data<=0;
            tx_kind<=1;read_address<=0;sent_blocks<=0;discarded_partial<=0;
        end else if(flush) begin
            // 清传输/历史队列，累计业务计数与已见fault不清；重新启用后沿原epoch cut规则开始新段。
            bank_ready<=0;capture_bank<=0;send_bank<=0;capture_index<=0;send_index<=0;
            crc<=16'hffff;pending_sample<=0;crc_phase<=0;sample_position<=0;
            state<=0;slot<=0;packet<=0;tx_data<=0;tx_kind<=1;read_address<=0;
            if(capture_index!=0||crc_phase!=0)discarded_partial<=discarded_partial+16'd1;
        end else begin
            if(discontinuity) begin
                if(capture_index!=0||crc_phase!=0) discarded_partial<=discarded_partial+16'd1;
                capture_index<=0;crc_phase<=0;crc<=16'hffff;sample_position<=0;
                if(epoch_started) epoch<=epoch+32'd1;
                epoch_started<=1;
            end else if(take) begin
                epoch_started<=1;
                if(capture_index==0) begin bank_epoch[capture_bank]<=epoch;bank_first[capture_bank]<=sample_position;end
                pending_sample<=sample_data;crc<=crc16_byte(crc,sample_data[7:0]);crc_phase<=1;
                sample_position<=sample_position+32'd1;
            end else if(crc_phase==1) begin
                crc<=crc16_byte(crc,pending_sample[15:8]);crc_phase<=0;
                if(capture_index==9'd287) begin
                    bank_crc[capture_bank]<=crc16_byte(crc,pending_sample[15:8]);bank_ready[capture_bank]<=1;
                    capture_bank<=~capture_bank;capture_index<=0;crc<=16'hffff;
                end else capture_index<=capture_index+9'd1;
            end
            if(!fault) case(state)
                0:if(bank_ready[send_bank]) begin packet<=0;send_index<=0;slot<=0;tx_data<=0;tx_kind<=1;state<=1;end
                1:begin read_address<={send_bank,send_index};state<=2;end
                2:state<=3;
                3:begin
                    tx_data<={read_q,tx_data[95:16]};send_index<=send_index+9'd1;
                    if(slot==3'd5) state<=4;else begin slot<=slot+3'd1;state<=1;end
                end
                4:if(tx_ready) state<=5;
                5:if(!tx_ready) state<=6;
                6:if(tx_ready) begin
                    if(packet==6'd48) begin bank_ready[send_bank]<=0;send_bank<=~send_bank;sent_blocks<=sent_blocks+16'd1;state<=0;end
                    else if(packet==6'd47) begin
                        packet<=48;tx_kind<=3;tx_data<={16'd288,bank_crc[send_bank],bank_first[send_bank],bank_epoch[send_bank]};state<=4;
                    end else begin packet<=packet+6'd1;slot<=0;tx_data<=0;state<=1;end
                end
                default:state<=0;
            endcase
        end
    end
endmodule
