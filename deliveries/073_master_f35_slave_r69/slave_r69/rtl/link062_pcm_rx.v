`timescale 1ns/1ps
// 单块staging：完整288样本和CRC/序号/epoch通过后才向环形缓存提交。
module link062_pcm_rx(
    input wire clk,input wire rst_n,input wire serial_data,
    output wire locked,output wire [7:0] transport_errors,
    output wire [15:0] transport_lost,
    output reg block_start,output reg history_reset,
    output reg [31:0] block_epoch,output reg [31:0] block_first,
    output reg word_valid,output reg [31:0] word_data,
    output reg fault,output reg [15:0] accepted_blocks,output reg [15:0] rejected_blocks
);
    `include "link062_crc.vh"
    wire [95:0] energy;
    wire packet_valid,frame_strobe;
    wire [1:0] kind;
    wire [2:0] version;
    wire [7:0] param;
    wire [15:0] packet_id;
    interboard_rx u_transport(.clk(clk),.rst_n(rst_n),.link_clk(1'b0),.link_sync(1'b0),
        .link_data(serial_data),.energy(energy),.energy_valid(packet_valid),
        .asset_id(kind),.effect_mode(version),.param(param),.frame_ref_out(frame_strobe),
        .frame_id_out(packet_id),.link_locked(locked),.link_error(transport_errors),
        .frame_lost_cnt(transport_lost));
    wire [95:0] decoded=seed_transform(energy,param[2:0]);
    (* ram_style="bram" *) reg [31:0] staging[0:255];
    reg [31:0] stage_q;
    reg [7:0] write_address,read_address,words;
    reg [95:0] pending_data;
    reg [1:0] writes_left;
    reg [1:0] commit_state;
    reg [7:0] commit_word;
    reg [5:0] packets;
    reg [15:0] block_crc,expected_id;
    reg have_id,bad_block,previous_locked,epoch_valid;
    reg [31:0] current_epoch,expected_first;
    wire sequence_ok=!have_id||(packet_id==expected_id);
    wire metadata_ok=sequence_ok&&!bad_block&&packets==6'd48&&words==8'd144&&
        decoded[95:80]==16'd288&&decoded[79:64]==block_crc;
    always @(posedge clk) begin
        if(writes_left!=0) staging[write_address]<=pending_data[31:0];
        stage_q<=staging[read_address];
    end
    always @(posedge clk) begin
        if(!rst_n) begin
            write_address<=0;read_address<=0;words<=0;pending_data<=0;writes_left<=0;
            commit_state<=0;commit_word<=0;packets<=0;block_crc<=16'hffff;expected_id<=0;
            have_id<=0;bad_block<=0;previous_locked<=0;epoch_valid<=0;current_epoch<=0;expected_first<=0;
            block_start<=0;history_reset<=0;block_epoch<=0;block_first<=0;word_valid<=0;word_data<=0;
            fault<=0;accepted_blocks<=0;rejected_blocks<=0;
        end else begin
            block_start<=0;history_reset<=0;word_valid<=0;previous_locked<=locked;
            if(writes_left!=0) begin
                write_address<=write_address+8'd1;pending_data<=pending_data>>32;
                writes_left<=writes_left-2'd1;
            end
            case(commit_state)
                1:commit_state<=2;
                2:begin
                    word_valid<=1;word_data<=stage_q;
                    if(commit_word==8'd143) commit_state<=0;
                    else begin
                        commit_word<=commit_word+8'd1;read_address<=read_address+8'd1;commit_state<=1;
                    end
                end
                default:begin end
            endcase
            if(previous_locked&&!locked) begin
                history_reset<=1;epoch_valid<=0;have_id<=0;bad_block<=0;packets<=0;words<=0;
                writes_left<=0;block_crc<=16'hffff;commit_state<=0;
                if(accepted_blocks!=0) fault<=1;
            end else if(packet_valid) begin
                have_id<=1;expected_id<=packet_id+16'd1;
                if(version!=0||!frame_strobe||commit_state!=0||writes_left!=0) begin
                    bad_block<=1;fault<=1;
                end else if(kind==2'd1&&param[7:3]==0) begin
                    if(sequence_ok&&!bad_block&&packets<6'd48) begin
                        pending_data<=decoded;write_address<=words;writes_left<=3;
                        words<=words+8'd3;packets<=packets+6'd1;
                        block_crc<=crc16_packet(block_crc,decoded);
                    end else bad_block<=1;
                end else if(kind==2'd3&&param[7:3]==0) begin
                    if(metadata_ok) begin
                        block_start<=1;block_epoch<=decoded[31:0];block_first<=decoded[63:32];
                        history_reset<=!epoch_valid||decoded[31:0]!=current_epoch||decoded[63:32]!=expected_first;
                        current_epoch<=decoded[31:0];expected_first<=decoded[63:32]+32'd288;epoch_valid<=1;
                        read_address<=0;commit_word<=0;commit_state<=1;
                        accepted_blocks<=accepted_blocks+16'd1;
                    end else begin
                        rejected_blocks<=rejected_blocks+16'd1;
                        history_reset<=1;epoch_valid<=0;
                        if(accepted_blocks!=0) fault<=1;
                    end
                    packets<=0;words<=0;bad_block<=0;block_crc<=16'hffff;
                end else begin bad_block<=1;if(accepted_blocks!=0) fault<=1;end
            end
        end
    end
endmodule
